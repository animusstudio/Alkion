package io.github.psychonaut0.reps.capture

import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.atomic.AtomicLong
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * Durable file primitives: flushed temporary file plus rename for single
 * files, and no-replace publication of a whole staging directory.
 *
 * No-replace on Android: there is no Java API for renameat2(RENAME_NOREPLACE)
 * and bionic only exposes it from API 30 (minSdk is 24), so publication first
 * reserves the destination with mkdir(2), which atomically fails with EEXIST
 * if anything already exists there, and then rename(2)s the staging directory
 * over that reservation. rename(2) may only replace an EMPTY directory, so it
 * can never replace content; at worst a crash between the two calls leaves an
 * empty, coordinator-owned reservation that recovery removes with rmdir(2),
 * which itself refuses a non-empty directory.
 */
object CaptureFiles {
    /** Set at plugin attach: fault injection only works in debuggable apps. */
    @Volatile
    var faultInjectionAllowed = false

    @Volatile
    private var fault: String? = null
    private val counter = AtomicLong()

    fun injectFault(kind: String): String {
        if (!faultInjectionAllowed) return "unsupported"
        if (kind != "file_sync" && kind != "dir_sync") return "invalid_argument"
        fault = kind
        return "ok"
    }

    private fun consumeFault(kind: String): Boolean = synchronized(this) {
        if (fault == kind) {
            fault = null
            true
        } else {
            false
        }
    }

    private fun syncFile(path: String) {
        val fd = Os.open(path, OsConstants.O_RDONLY, 0)
        try {
            if (consumeFault("file_sync")) throw IOException("injected file sync failure")
            Os.fsync(fd)
        } finally {
            Os.close(fd)
        }
    }

    fun syncDir(dir: File): Boolean = try {
        val fd = Os.open(dir.path, OsConstants.O_RDONLY, 0)
        try {
            if (consumeFault("dir_sync")) {
                false
            } else {
                Os.fsync(fd)
                true
            }
        } finally {
            Os.close(fd)
        }
    } catch (e: ErrnoException) {
        false
    }

    fun durableReplace(path: String, bytes: ByteArray): String {
        if (path.isEmpty() || path.endsWith("/")) return "invalid_argument"
        val destination = File(path)
        val parent = destination.parentFile ?: return "invalid_argument"
        if (!parent.isDirectory) return "invalid_argument"
        val tmp = File(parent, "${destination.name}.capture-tmp-${android.os.Process.myPid()}-${counter.incrementAndGet()}")
        try {
            if (!tmp.createNewFile()) return "io_error"
            FileOutputStream(tmp).use { out ->
                out.write(bytes)
                out.flush()
                if (consumeFault("file_sync")) throw IOException("injected file sync failure")
                out.fd.sync()
            }
            Os.rename(tmp.path, destination.path)
        } catch (e: Exception) {
            tmp.delete()
            return "io_error"
        }
        return if (syncDir(parent)) "ok" else "io_error"
    }

    /**
     * Makes every directory from [basePath] (which must exist) down to [path]
     * exist durably: each missing component is created and the parent of every
     * component below [basePath] is flushed, created now or not. Symbolic links
     * below [basePath] are refused. Mirrors the Linux primitive; uncompiled
     * until an Android SDK host builds it.
     */
    fun ensureDirectory(path: String, basePath: String): String {
        if (!path.startsWith("/") || !basePath.startsWith("/")) return "invalid_argument"
        val base = basePath.trimEnd('/').ifEmpty { "/" }
        val rest = when {
            path == base -> ""
            path.startsWith("$base/") -> path.substring(base.length + 1).trimEnd('/')
            else -> return "invalid_argument"
        }
        if (!File(base).isDirectory) return "invalid_argument"
        var current = File(base)
        if (rest.isEmpty()) return "ok"
        for (part in rest.split('/')) {
            if (part.isEmpty() || part == "." || part == "..") return "invalid_argument"
            val parent = current
            current = File(parent, part)
            try {
                Os.mkdir(current.path, OsConstants.S_IRWXU)
            } catch (e: ErrnoException) {
                if (e.errno == OsConstants.ENOTDIR) return "not_a_directory"
                if (e.errno != OsConstants.EEXIST) return "io_error"
            }
            val mode = try {
                Os.lstat(current.path).st_mode
            } catch (e: ErrnoException) {
                return "io_error"
            }
            if (!OsConstants.S_ISDIR(mode)) return "not_a_directory"
            if (!syncDir(parent)) return "io_error"
        }
        return "ok"
    }

    private fun syncTree(file: File): String {
        val mode = try {
            Os.lstat(file.path).st_mode
        } catch (e: ErrnoException) {
            return "io_error"
        }
        if (OsConstants.S_ISREG(mode)) {
            return try {
                syncFile(file.path)
                "ok"
            } catch (e: Exception) {
                "io_error"
            }
        }
        if (!OsConstants.S_ISDIR(mode)) return "invalid_argument"
        val children = file.listFiles() ?: return "io_error"
        for (child in children) {
            val code = syncTree(child)
            if (code != "ok") return code
        }
        return if (syncDir(file)) "ok" else "io_error"
    }

    /** Bytes still usable on the file system holding [path] (StatFs). */
    fun availableBytes(path: String): GateResult {
        if (path.isEmpty() || !File(path).isDirectory) return GateResult("invalid_argument")
        return try {
            GateResult("ok", bytes = android.os.StatFs(path).availableBytes)
        } catch (e: IllegalArgumentException) {
            GateResult("io_error")
        }
    }

    fun publishNoReplace(stagingPath: String, finalPath: String): String {
        if (stagingPath.isEmpty() || finalPath.isEmpty()) return "invalid_argument"
        val staging = File(stagingPath)
        val destination = File(finalPath)
        val stagingMode = try {
            Os.lstat(staging.path).st_mode
        } catch (e: ErrnoException) {
            return "invalid_argument"
        }
        if (!OsConstants.S_ISDIR(stagingMode)) return "invalid_argument"
        val code = syncTree(staging)
        if (code != "ok") return code
        try {
            Os.mkdir(destination.path, 0x1c0) // 0700
        } catch (e: ErrnoException) {
            return when (e.errno) {
                OsConstants.EEXIST -> "destination_exists"
                OsConstants.ENOENT, OsConstants.ENOTDIR -> "invalid_argument"
                else -> "io_error"
            }
        }
        try {
            Os.rename(staging.path, destination.path)
        } catch (e: ErrnoException) {
            try {
                Os.rmdir(destination.path)
            } catch (_: ErrnoException) {
                // Not empty or gone: left for recovery, never overwritten.
            }
            return when (e.errno) {
                OsConstants.EXDEV -> "cross_device"
                OsConstants.EEXIST, OsConstants.ENOTEMPTY -> "destination_exists"
                else -> "io_error"
            }
        }
        val destinationParent = destination.parentFile ?: return "io_error"
        var ok = syncDir(destinationParent)
        val stagingParent = staging.parentFile
        if (stagingParent != null && stagingParent.path != destinationParent.path) {
            ok = syncDir(stagingParent) && ok
        }
        return if (ok) "ok" else "io_error"
    }

    /** Largest manifest and largest captured file the v1 reader accepts. */
    private const val MANIFEST_LIMIT = 1L shl 20
    private const val STORE_LIMIT = 64L shl 20
    private const val ENTRY_LIMIT = 1 shl 16
    private val segment = Regex("^[A-Za-z0-9_.-]{1,128}$")

    private class ArchiveRefused(val code: String) : Exception(code)

    /** Whether [path] is `manifest.json` or `stores/<one plain segment>`. */
    private fun archivePathValid(path: String): Boolean {
        if (path == "manifest.json") return true
        val parts = path.split('/')
        return parts.size == 2 && parts[0] == "stores" && segment.matches(parts[1]) &&
            parts[1] != "." && parts[1] != ".."
    }

    /**
     * Writes the published capture at [capturePath] as a ZIP into the new
     * file [archivePath] for an explicit share intent. Exactly [entries]
     * (`path`, declared `bytes`; `manifest.json` first) are written: every
     * path must be `manifest.json` or `stores/<file>`, unique, and every file
     * in the capture directory must be listed. Each source is opened without
     * following links and must be a regular file of exactly the declared
     * size (at most 1 MiB for the manifest, 64 MiB per store), checked while
     * streaming. The archive is created exclusively, flushed, and removed
     * again on any failure; the capture is only read. Uncompiled until an
     * Android SDK host builds it; the receiving end re-verifies everything.
     */
    fun writeArchive(capturePath: String, archivePath: String, entries: List<Map<String, Any?>>): String {
        if (capturePath.isEmpty() || archivePath.isEmpty()) return "invalid_argument"
        if (entries.isEmpty() || entries.size > ENTRY_LIMIT) return "invalid_argument"
        val capture = File(capturePath)
        val captureMode = try {
            Os.lstat(capture.path).st_mode
        } catch (e: ErrnoException) {
            return "invalid_argument"
        }
        if (!OsConstants.S_ISDIR(captureMode)) return "invalid_argument"

        // The declared inventory: strict paths, sizes within the v1 limits.
        val declared = LinkedHashMap<String, Long>()
        for (entry in entries) {
            val path = entry["path"] as? String ?: return "invalid_argument"
            val bytes = (entry["bytes"] as? Number)?.toLong() ?: return "invalid_argument"
            if (!archivePathValid(path)) return "invalid_argument"
            val limit = if (path == "manifest.json") MANIFEST_LIMIT else STORE_LIMIT
            if (bytes < 0 || bytes > limit) return "invalid_argument"
            if (declared.put(path, bytes) != null) return "invalid_argument"
        }
        if (declared.keys.first() != "manifest.json") return "invalid_argument"

        // Nothing in the capture directory beyond the declared files.
        val listed = HashSet<String>()
        val top = capture.list() ?: return "io_error"
        for (name in top) {
            if (name == "stores") {
                val stores = File(capture, "stores")
                val storesMode = try {
                    Os.lstat(stores.path).st_mode
                } catch (e: ErrnoException) {
                    return "io_error"
                }
                if (!OsConstants.S_ISDIR(storesMode)) return "unlisted_file"
                for (child in stores.list() ?: return "io_error") listed.add("stores/$child")
            } else {
                listed.add(name)
            }
        }
        if (listed != declared.keys) return "unlisted_file"

        val archive = File(archivePath)
        val fd: FileDescriptor = try {
            Os.open(
                archive.path,
                OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL,
                0x180, // 0600
            )
        } catch (e: ErrnoException) {
            return if (e.errno == OsConstants.EEXIST) "destination_exists" else "io_error"
        }
        var ok = false
        try {
            FileOutputStream(fd).use { raw ->
                ZipOutputStream(raw).use { zip ->
                    zip.setLevel(9)
                    val buffer = ByteArray(1 shl 16)
                    for ((path, bytes) in declared) {
                        val source = File(capture, path)
                        val input = try {
                            Os.open(source.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW, 0)
                        } catch (e: ErrnoException) {
                            throw ArchiveRefused(if (e.errno == OsConstants.ELOOP) "not_regular" else "io_error")
                        }
                        // The stream owns the descriptor from here on and closes
                        // it exactly once.
                        FileInputStream(input).use { stream ->
                            if (!OsConstants.S_ISREG(Os.fstat(input).st_mode)) throw ArchiveRefused("not_regular")
                            zip.putNextEntry(ZipEntry(path))
                            var total = 0L
                            while (true) {
                                val n = stream.read(buffer)
                                if (n < 0) break
                                total += n
                                if (total > bytes) throw ArchiveRefused("capture_changed")
                                zip.write(buffer, 0, n)
                            }
                            if (total != bytes) throw ArchiveRefused("capture_changed")
                            zip.closeEntry()
                        }
                    }
                    zip.finish()
                    raw.flush()
                    Os.fsync(fd)
                }
            }
            ok = archive.parentFile?.let { syncDir(it) } ?: false
            return if (ok) "ok" else "io_error"
        } catch (e: ArchiveRefused) {
            return e.code
        } catch (e: Exception) {
            return "io_error"
        } finally {
            if (!ok) archive.delete()
        }
    }
}
