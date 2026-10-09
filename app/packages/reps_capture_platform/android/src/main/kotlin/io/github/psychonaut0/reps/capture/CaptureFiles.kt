package io.github.psychonaut0.reps.capture

import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.atomic.AtomicLong

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
}
