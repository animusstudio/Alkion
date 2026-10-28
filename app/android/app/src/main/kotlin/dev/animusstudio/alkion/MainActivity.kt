package dev.animusstudio.alkion

import android.content.Context
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var runtime: AlkionRuntime? = null

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        AlkionRuntime.get(context).also { runtime = it }.engine

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        runtime!!.attach(this)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        runtime?.detach(this)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (runtime?.documentsFor(this)?.onActivityResult(requestCode, resultCode, data) != true) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun onPause() {
        runtime?.hostPaused(this, true)
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        runtime?.hostPaused(this, false)
    }
}
