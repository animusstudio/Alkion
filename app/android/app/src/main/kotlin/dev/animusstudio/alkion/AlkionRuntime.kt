package dev.animusstudio.alkion

import android.content.Context
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** The Dart store and its native engine share the lifetime of this process. */
internal class AlkionRuntime private constructor(context: Context) {
    private val application = context.applicationContext
    // FlutterEngine registers generated plugins once; the external-engine host
    // then performs their normal ActivityAware attach/detach lifecycle.
    val engine = FlutterEngine(application)
    private val bodies = CharacterBodyFactory(application, engine.dartExecutor.binaryMessenger)
    private var host: MainActivity? = null
    private var documents: AndroidDocuments? = null

    init {
        check(engine.platformViewsController.registry.registerViewFactory(
            "dev.animusstudio.alkion/character-body", bodies,
        )) { "Character body factory is already registered" }
        MethodChannel(
            engine.dartExecutor.binaryMessenger,
            "dev.animusstudio.alkion/identity",
        ).setMethodCallHandler { call, result ->
            if (call.method == "identity") {
                try {
                    val dataDirectory = File(application.applicationInfo.dataDir)
                    result.success(
                        mapOf(
                            "applicationId" to application.packageName,
                            "flavor" to BuildConfig.FLAVOR,
                            "displayName" to application.applicationInfo.loadLabel(application.packageManager).toString(),
                            "dataDirectory" to dataDirectory.absolutePath,
                            // Resolve only the OS-owned parent. Never canonicalize
                            // the app data directory or its app-owned descendants.
                            "dataParentCanonical" to dataDirectory.parentFile!!.canonicalPath,
                            "filesDirectory" to File(dataDirectory, "files").absolutePath,
                        ),
                    )
                } catch (_: Exception) {
                    result.error("alkion_identity_unavailable", "Android identity/storage is unavailable", null)
                }
            } else {
                result.notImplemented()
            }
        }
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
    }

    fun attach(activity: MainActivity) {
        checkMainThread()
        if (host === activity) return
        // Close the previous handler before installing its replacement. Late
        // cleanup from that Activity must never clear this new handler.
        documents?.close()
        host = activity
        bodies.hostPaused(true)
        documents = AndroidDocuments(activity, engine.dartExecutor.binaryMessenger)
    }

    fun detach(activity: MainActivity) {
        checkMainThread()
        if (host !== activity) return
        documents?.close()
        documents = null
        host = null
        bodies.hostPaused(true)
    }

    fun documentsFor(activity: MainActivity): AndroidDocuments? {
        checkMainThread()
        return if (host === activity) documents else null
    }

    fun hostPaused(activity: MainActivity, paused: Boolean) {
        checkMainThread()
        if (host === activity) bodies.hostPaused(paused)
    }

    companion object {
        private var process: AlkionRuntime? = null

        fun get(context: Context): AlkionRuntime {
            checkMainThread()
            return process ?: AlkionRuntime(context).also { process = it }
        }

        private fun checkMainThread() {
            check(Looper.myLooper() == Looper.getMainLooper()) { "Runtime attachment requires the main thread" }
        }
    }
}
