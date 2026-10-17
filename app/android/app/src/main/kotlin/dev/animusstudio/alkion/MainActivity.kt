package dev.animusstudio.alkion

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
}
