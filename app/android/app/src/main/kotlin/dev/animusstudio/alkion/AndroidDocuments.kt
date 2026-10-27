package dev.animusstudio.alkion

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.system.Os
import android.system.OsConstants
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors

/** SAF grants are consumed into private completed copies, never URI paths.
 * No provider atomicity/fsync is promised; a failed output is left untouched.
 */
class AndroidDocuments(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "dev.animusstudio.alkion/documents")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val root: File
        get() {
            val lexical = File(activity.applicationInfo.dataDir)
            // Android's OS-owned /data/user/0 parent may alias /data/data.
            // The package directory and its descendants are never adopted
            // through a symlink, even when they point at an existing folder.
            val parent = lexical.parentFile ?: throw Refusal("document_staging_invalid")
            if (lexical.name != activity.packageName) throw Refusal("document_staging_invalid")
            val owned = File(parent.canonicalFile, lexical.name)
            val files = File(owned, "files")
            if (owned.absolutePath != owned.canonicalPath || !owned.isDirectory ||
                files.absolutePath != files.canonicalPath || !files.isDirectory) {
                throw Refusal("document_staging_invalid")
            }
            val staging = File(files, "alkion-documents")
            if (staging.absolutePath != staging.canonicalPath) throw Refusal("document_staging_invalid")
            return staging
        }
    private var pending: Request? = null
    private var destroyed = false

    private data class Request(
        val result: MethodChannel.Result,
        val create: Boolean,
        val limit: Long,
        val directory: File,
        val source: File? = null,
        val length: Long? = null,
        val digest: String? = null,
        var awaitingResult: Boolean = true,
    )
    private class Refusal(val category: String) : Exception(category)

    init {
        channel.setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (destroyed) { result.error("document_interrupted", null, null); return }
        if (pending != null) { result.error("document_busy", null, null); return }
        try {
            if (call.method == "stage") {
                val directory = newDirectory()
                result.success(mapOf("root" to root.canonicalPath, "path" to directory.canonicalPath))
                return
            }
            if (call.method != "open" && call.method != "create") {
                result.notImplemented(); return
            }
            val limit = (call.argument<Number>("maxBytes") ?: throw Refusal("document_arguments_invalid")).toLong()
            if (limit !in 1..MAX_BYTES) throw Refusal("document_resource_limit")
            val create = call.method == "create"
            val directory = newDirectory()
            val request: Request
            val intent: Intent
            if (create) {
                val source = ownedFile(call.argument<String>("sourcePath") ?: "")
                if (source.name != "source.complete" || !source.isFile) throw Refusal("document_staging_invalid")
                val length = (call.argument<Number>("length") ?: throw Refusal("document_arguments_invalid")).toLong()
                val digest = call.argument<String>("sha256") ?: ""
                if (length !in 0..limit || source.length() != length || !digest.matches(Regex("[a-f0-9]{64}"))) {
                    throw Refusal("document_source_changed")
                }
                val filename = call.argument<String>("filename") ?: ""
                val mime = call.argument<String>("mimeType") ?: "application/octet-stream"
                if (filename.isBlank() || filename.length > 240 || filename.any { it == '/' || it == '\\' || it.code < 32 }) {
                    throw Refusal("document_filename_invalid")
                }
                request = Request(result, true, limit, directory, source, length, digest)
                intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mime
                    putExtra(Intent.EXTRA_TITLE, filename)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                }
            } else {
                val types = call.argument<List<String>>("mimeTypes") ?: listOf("application/octet-stream")
                if (types.isEmpty() || types.size > 8 || types.any { it.length > 100 || !it.contains('/') }) {
                    throw Refusal("document_arguments_invalid")
                }
                request = Request(result, false, limit, directory)
                intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = if (types.size == 1) types.single() else "*/*"
                    if (types.size > 1) putExtra(Intent.EXTRA_MIME_TYPES, types.toTypedArray())
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            }
            pending = request
            activity.startActivityForResult(intent, REQUEST_CODE)
        } catch (error: Exception) {
            pending = null
            result.error(category(error), null, null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val request = pending ?: return true // A process restart requires reselection.
        if (!request.awaitingResult) return true
        request.awaitingResult = false
        if (resultCode == Activity.RESULT_CANCELED) {
            complete(request, null, null); return true
        }
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || uri.scheme != "content") {
            complete(request, null, Refusal("document_selection_invalid")); return true
        }
        worker.execute {
            try {
                val receipt = if (request.create) save(request, uri) else receive(request, uri, "input")
                main.post { complete(request, receipt, null) }
            } catch (error: Exception) {
                main.post { complete(request, null, error) }
            }
        }
        return true
    }

    private fun complete(request: Request, value: Any?, error: Exception?) {
        if (pending !== request) return
        pending = null
        if (error == null) request.result.success(value) else request.result.error(
            category(error),
            if (request.create) "The external copy may be incomplete; private originals are retained." else "The original document is unchanged; private staging is retained.",
            mapOf("externalMayBeIncomplete" to request.create, "stagingPath" to request.directory.path),
        )
    }

    private fun save(request: Request, uri: Uri): Map<String, Any> {
        val source = ownedFile(request.source!!.path)
        // Compare before opening an external output, and again while streaming.
        val before = FileInputStream(source).use { digest(it, null, request.limit) }
        if (before.first != request.length || before.second != request.digest) throw Refusal("document_source_changed")
        flushDirectory(source.parentFile!!)
        val copied = activity.contentResolver.openOutputStream(uri, "w")?.use { output ->
            FileInputStream(source).use { input -> digest(input, output, request.limit) }
        } ?: throw Refusal("document_provider_write_failed")
        if (copied.first != request.length || copied.second != request.digest) throw Refusal("document_source_changed")
        val receipt = receive(request, uri, "readback")
        if (receipt["length"] != request.length || receipt["sha256"] != request.digest) {
            throw Refusal("document_readback_mismatch")
        }
        return receipt
    }

    private fun receive(request: Request, uri: Uri, stem: String): Map<String, Any> {
        val (name, declared) = metadata(uri)
        if (declared != null && declared > request.limit) throw Refusal("document_resource_limit")
        val partial = File(request.directory, "$stem.partial")
        val complete = File(request.directory, "$stem.complete")
        if (!partial.createNewFile()) throw Refusal("document_staging_collision")
        val copied = FileOutputStream(partial).use { output ->
            val result = activity.contentResolver.openInputStream(uri)?.use { input ->
                digest(input, output, request.limit)
            } ?: throw Refusal("document_provider_read_failed")
            output.flush()
            output.fd.sync()
            result
        }
        if (declared != null && copied.first != declared) throw Refusal("document_length_mismatch")
        if (!partial.renameTo(complete)) throw Refusal("document_staging_failed")
        flushDirectory(request.directory)
        return mapOf(
            "root" to root.canonicalPath,
            "path" to complete.canonicalPath,
            "name" to name,
            "length" to copied.first,
            "sha256" to copied.second,
        )
    }

    private fun metadata(uri: Uri): Pair<String, Long?> {
        var name = "Selected document"
        var length: Long? = null
        // Missing metadata is permitted; the stream itself always has a bound.
        try {
            activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                        name = cursor.getString(nameIndex).filter { it.code >= 32 }.take(240)
                    }
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        cursor.getLong(sizeIndex).takeIf { it >= 0 }?.let { length = it }
                    }
                }
            }
        } catch (_: IllegalArgumentException) { /* Provider has no metadata. */ }
        return name to length
    }

    private fun digest(input: InputStream, output: OutputStream?, limit: Long): Pair<Long, String> {
        val hash = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        var length = 0L
        while (true) {
            if (Thread.currentThread().isInterrupted) throw Refusal("document_interrupted")
            val count = input.read(buffer)
            if (count < 0) break
            if (count == 0) continue
            length += count
            if (length > limit) throw Refusal("document_resource_limit")
            output?.write(buffer, 0, count)
            hash.update(buffer, 0, count)
        }
        output?.flush()
        return length to hash.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun newDirectory(): File {
        if (!root.exists() && !root.mkdir()) throw Refusal("document_staging_failed")
        if (root.absolutePath != root.canonicalPath || !root.isDirectory) throw Refusal("document_staging_invalid")
        val directory = File(root, UUID.randomUUID().toString())
        if (!directory.mkdir()) throw Refusal("document_staging_failed")
        flushDirectory(root)
        return directory
    }

    private fun ownedFile(path: String): File {
        val file = File(path)
        val base = root.canonicalPath
        if (!file.isAbsolute || file.absolutePath != file.canonicalPath ||
            !file.canonicalPath.startsWith("$base/") || file.parentFile?.parentFile?.canonicalPath != base ||
            !file.parentFile!!.name.matches(Regex("[a-f0-9-]{36}"))) {
            throw Refusal("document_staging_invalid")
        }
        return file
    }

    private fun flushDirectory(directory: File) {
        val fd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
        try {
            if (!OsConstants.S_ISDIR(Os.fstat(fd).st_mode)) throw Refusal("document_staging_invalid")
            Os.fsync(fd)
        } finally { Os.close(fd) }
    }

    private fun category(error: Exception): String = when (error) {
        is Refusal -> error.category
        is SecurityException -> "document_permission_denied"
        is android.content.ActivityNotFoundException -> "document_picker_unavailable"
        else -> "document_io_failed"
    }

    fun close() {
        destroyed = true
        worker.shutdownNow()
        pending?.let { complete(it, null, Refusal("document_interrupted")) }
        channel.setMethodCallHandler(null)
    }

    companion object {
        private const val REQUEST_CODE = 0xA1D0
        private const val MAX_BYTES = 512L * 1024 * 1024
    }
}
