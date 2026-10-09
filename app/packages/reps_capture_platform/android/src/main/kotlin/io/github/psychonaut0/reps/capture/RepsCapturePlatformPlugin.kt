package io.github.psychonaut0.reps.capture

import android.content.pm.ApplicationInfo
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * `reps/capture` channel. Registered independently by every engine
 * (foreground and background); all engines share the process-wide
 * [SourceGate] and [CaptureFiles], so no engine-local flag decides admission.
 * Calls run on one process-wide worker thread and answer on the main thread.
 */
class RepsCapturePlatformPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val flags = binding.applicationContext.applicationInfo.flags
        CaptureFiles.faultInjectionAllowed = (flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        channel = MethodChannel(binding.binaryMessenger, "reps/capture").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        worker.execute {
            val answer = try {
                dispatch(call).toMap()
            } catch (e: Exception) {
                GateResult("io_error").toMap()
            }
            main.post { result.success(answer) }
        }
    }

    private fun dispatch(call: MethodCall): GateResult {
        val dir = call.argument<String>("dir")
        val capture = call.argument<String>("captureId")
        val generation = call.argument<Number>("generation")?.toLong()
        return when (call.method) {
            "admit" -> SourceGate.admit(dir, call.argument<String>("parent"))
            "complete" -> SourceGate.complete(dir, call.argument<String>("ticket"))
            "prepare" -> SourceGate.prepare(dir, capture)
            "drain" -> SourceGate.drain(dir, capture, generation)
            "release" -> SourceGate.release(dir, capture, generation, call.argument<String>("decisionDigest"))
            "verifyHold" -> SourceGate.verifyHold(dir, capture, generation)
            "durableReplace" -> GateResult(
                CaptureFiles.durableReplace(
                    call.argument<String>("path") ?: "",
                    call.argument<ByteArray>("bytes") ?: return GateResult("invalid_argument"),
                ),
            )
            "publishNoReplace" -> GateResult(
                CaptureFiles.publishNoReplace(
                    call.argument<String>("staging") ?: "",
                    call.argument<String>("final") ?: "",
                ),
            )
            "injectFault" -> GateResult(CaptureFiles.injectFault(call.argument<String>("fault") ?: ""))
            else -> GateResult("unsupported")
        }
    }

    companion object {
        private val worker = Executors.newSingleThreadExecutor()
        private val main = Handler(Looper.getMainLooper())
    }
}
