package dev.animusstudio.alkion

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var documents: AndroidDocuments? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        documents = AndroidDocuments(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.animusstudio.alkion/identity",
        ).setMethodCallHandler { call, result ->
            if (call.method == "identity") {
                result.success(
                    mapOf(
                        "applicationId" to packageName,
                        "flavor" to BuildConfig.FLAVOR,
                        "displayName" to applicationInfo.loadLabel(packageManager).toString(),
                    ),
                )
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

    override fun onDestroy() {
        documents?.close()
        documents = null
        super.onDestroy()
    }
}
