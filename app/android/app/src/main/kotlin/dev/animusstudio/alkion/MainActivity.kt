package dev.animusstudio.alkion

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var documents: AndroidDocuments? = null
    private var characterBodies: CharacterBodyFactory? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        characterBodies = CharacterBodyFactory(flutterEngine.dartExecutor.binaryMessenger).also {
            flutterEngine.platformViewsController.registry.registerViewFactory("dev.animusstudio.alkion/character-body", it)
        }
        documents = AndroidDocuments(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.animusstudio.alkion/identity",
        ).setMethodCallHandler { call, result ->
            if (call.method == "identity") {
                try {
                    val dataDirectory = File(applicationInfo.dataDir)
                    result.success(
                        mapOf(
                            "applicationId" to packageName,
                            "flavor" to BuildConfig.FLAVOR,
                            "displayName" to applicationInfo.loadLabel(packageManager).toString(),
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
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (documents?.onActivityResult(requestCode, resultCode, data) != true) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun onPause() {
        characterBodies?.hostPaused(true)
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        characterBodies?.hostPaused(false)
    }

    override fun onDestroy() {
        characterBodies?.close()
        characterBodies = null
        documents?.close()
        documents = null
        super.onDestroy()
    }
}
