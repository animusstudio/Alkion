package dev.animusstudio.alkion

import android.content.Context
import android.content.MutableContextWrapper
import android.graphics.Color
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject
import java.io.ByteArrayInputStream

internal class CharacterBodyFactory(context: Context, private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    private val application = context.applicationContext
    private val views = mutableSetOf<CharacterBodyView>()
    private var paused = true
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        CharacterBodyView(MutableContextWrapper(application), viewId, messenger, { views.remove(it) }).also {
            views.add(it)
            it.hostPaused(paused)
        }
    fun hostPaused(value: Boolean) { paused = value; views.toList().forEach { it.hostPaused(value) } }
}

/** One display-only, offline surface. No URI from Dart/JS reaches AssetManager. */
internal class CharacterBodyView(
    private val context: MutableContextWrapper,
    id: Int,
    messenger: BinaryMessenger,
    private val onDispose: (CharacterBodyView) -> Unit,
) : PlatformView {
    private val application = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "dev.animusstudio.alkion/character-body/$id")
    private val web = WebView(context)
    private val evaluations = LatestBodyEvaluation { script, complete ->
        web.evaluateJavascript(script) { complete.run() }
    }
    private val container = FrameLayout(context)
    private var processGone = false
    @Volatile private var disposed = false
    private var loaded = false
    private var attached = false
    private var hostIsPaused = true
    private var paused = true
    private var display: JSONObject? = null
    private val origin = "https://appassets.androidplatform.net/body/"
    private val files: Map<String, Pair<String, String>> = buildMap {
        val loader = FlutterInjector.instance().flutterLoader()
        for (name in listOf("index.html", "runtime.css", "runtime.js", "protocol.js", "renderer.js",
            "material.js", "motion.js", "geometry.js", "source-geometry.js", "pose-geometry.js")) {
            val mime = when (name.substringAfterLast('.')) {
                "html" -> "text/html"; "css" -> "text/css"; else -> "application/javascript"
            }
            put(origin + name, loader.getLookupKeyForAsset("assets/character_body/$name") to mime)
        }
        put(origin + "SpaceMono-Regular.ttf",
            loader.getLookupKeyForAsset("assets/google_fonts/SpaceMono-Regular.ttf") to "font/ttf")
        for (style in listOf("male", "female")) {
            for ((name, mime) in listOf("body.mesh.json" to "application/json",
                "body.mesh.bin" to "application/octet-stream", "regions.png" to "image/png")) {
                put(origin + "models/$style/$name", "body_models/$style/$name" to mime)
            }
        }
    }
    init {
        container.addView(web, FrameLayout.LayoutParams(-1, -1))
        web.setBackgroundColor(Color.TRANSPARENT)
        web.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        web.isVerticalScrollBarEnabled = false
        web.isHorizontalScrollBarEnabled = false
        web.settings.apply {
            javaScriptEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            domStorageEnabled = false
            databaseEnabled = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            setGeolocationEnabled(false)
            setSupportZoom(false)
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            mediaPlaybackRequiresUserGesture = true
            if (Build.VERSION.SDK_INT >= 29) {
                @Suppress("DEPRECATION")
                forceDark = WebSettings.FORCE_DARK_OFF
            }
        }
        web.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
        }
        web.setDownloadListener { _, _, _, _, _ -> /* No downloads. */ }
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true
            @Suppress("DEPRECATION")
            override fun shouldOverrideUrlLoading(view: WebView, url: String) = true
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                if (disposed || request.method != "GET") return denied(403)
                val entry = files[request.url.toString()] ?: return denied(403)
                return try {
                    WebResourceResponse(entry.second, if (entry.second.startsWith("text/") ||
                        entry.second in listOf("application/javascript", "application/json")) "UTF-8" else null,
                        200, "OK", mapOf(
                            "Cache-Control" to "no-store",
                            "X-Content-Type-Options" to "nosniff",
                            "Content-Security-Policy" to "default-src 'none'; script-src 'self'; style-src 'self'; font-src 'self'; img-src 'self'; connect-src 'self'; worker-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'",
                        ), application.assets.open(entry.first))
                } catch (_: java.io.IOException) { denied(404) }
            }
            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                if (!disposed) {
                    processGone = true
                    evaluations.close()
                    loaded = false
                    container.removeView(web)
                    web.destroy()
                    channel.invokeMethod("status", mapOf("version" to 2, "status" to "error", "yaw" to 0.0))
                }
                return true
            }
            override fun onPageFinished(view: WebView, url: String) {
                if (disposed || processGone || url != origin + "index.html") return
                loaded = true
                updatePaused()
            }
        }
        web.addJavascriptInterface(object {
            @JavascriptInterface fun postMessage(text: String) {
                if (disposed || text.length > 1024) return
                val event = try { JSONObject(text) } catch (_: Exception) { return }
                val status = event.optString("status")
                if (event.optInt("version") != 2 || status !in listOf("loading", "ready", "unavailable", "error")) return
                val yaw = event.optDouble("yaw", 0.0)
                if (!yaw.isFinite() || yaw < 0 || yaw >= Math.PI * 2) return
                val command = event.optDouble("command", -1.0)
                val turn = event.optDouble("turn", -1.0)
                val revision = event.optDouble("revision", -1.0)
                val safe = mutableMapOf<String, Any>("version" to 2, "status" to status, "yaw" to yaw)
                if (command.isFinite() && command >= 0 && command <= 9007199254740991.0 &&
                    command == Math.floor(command) && turn.isFinite() && turn >= 0 && turn < Math.PI * 2 &&
                    revision.isFinite() && revision >= 0 && revision <= 9007199254740991.0 && revision == Math.floor(revision)) {
                    safe["command"] = command.toLong()
                    safe["turn"] = turn
                    safe["revision"] = revision.toLong()
                }
                // Only aggregate renderer timings; no workout or source payload in logs.
                val metrics = listOf("frames", "totalMs", "maxMs", "loadMs").associateWith {
                    event.optDouble(it, 0.0).takeIf { value -> value.isFinite() && value >= 0 } ?: 0.0
                }
                main.post {
                    if (!disposed && !processGone) {
                        channel.invokeMethod("status", safe)
                        if (BuildConfig.DEBUG) Log.i("AlkionBody", "$status $metrics")
                    }
                }
            }
        }, "AlkionNative")
        channel.setMethodCallHandler { call, result ->
            if (disposed || processGone) { result.error("disposed", "Body surface disposed", null); return@setMethodCallHandler }
            if (call.method != "display") { result.notImplemented(); return@setMethodCallHandler }
            val value = validateDisplay(call.arguments)
            if (value == null) { result.error("invalid_display", "Invalid body display state", null); return@setMethodCallHandler }
            display = value
            val background = value.getJSONArray("background")
            web.setBackgroundColor(Color.rgb(background.getInt(0), background.getInt(1), background.getInt(2)))
            sendDisplay()
            result.success(null)
        }
        web.loadUrl(origin + "index.html")
    }
    private fun sendDisplay() {
        if (disposed || processGone || !loaded) return
        val update = display?.let { ",window.AlkionBody.update($it)" } ?: ""
        // Include lifecycle in every replaceable snapshot. A late display
        // completion can never drain an older unpaused state after a pause.
        evaluations.offer("window.AlkionBody && (window.AlkionBody.hostPaused($paused)$update)")
    }
    fun hostPaused(value: Boolean) {
        hostIsPaused = value
        updatePaused()
    }
    private fun updatePaused() {
        paused = hostIsPaused || !attached
        if (disposed || processGone) return
        sendDisplay()
        if (paused) web.onPause() else web.onResume()
    }
    override fun onFlutterViewAttached(flutterView: View) {
        if (disposed) return
        context.baseContext = flutterView.context
        attached = true
        updatePaused()
    }
    override fun onFlutterViewDetached() {
        attached = false
        context.baseContext = application
        updatePaused()
    }
    override fun getView(): View = container
    override fun dispose() {
        if (disposed) return
        disposed = true
        attached = false
        context.baseContext = application
        evaluations.close()
        channel.setMethodCallHandler(null)
        if (!processGone) {
            web.removeJavascriptInterface("AlkionNative")
            web.stopLoading()
            container.removeView(web)
            web.destroy()
        }
        onDispose(this)
    }
    private fun denied(code: Int) = WebResourceResponse("text/plain", "UTF-8", code,
        if (code == 404) "Not Found" else "Forbidden", mapOf("Cache-Control" to "no-store"), ByteArrayInputStream(byteArrayOf()))
}

/** Native guard complements JS validation, before anything is evaluated. */
internal fun validateDisplay(raw: Any?): JSONObject? {
    val map = raw as? Map<*, *> ?: return null
    val keys = setOf("version", "style", "scores", "neutral", "accent", "background", "theme", "visible", "reduced", "compact", "paused", "yaw", "turn", "command", "revision", "retry")
    if (map.keys != keys || map["version"] != 2 || map["style"] !in listOf("male", "female") || map["theme"] !in listOf("light", "dark")) return null
    if (listOf("visible", "reduced", "compact", "paused").any { map[it] !is Boolean }) return null
    for (key in listOf("neutral", "accent", "background")) {
        val rgb = map[key] as? List<*> ?: return null
        if (rgb.size != 3 || rgb.any { it !is Int || it !in 0..255 }) return null
    }
    val muscles = setOf("chest", "back", "shoulders", "quads", "hamstrings", "calves", "biceps", "triceps")
    val scores = map["scores"] as? Map<*, *> ?: return null
    if (scores.keys != muscles || scores.values.any { it !is Number || !it.toDouble().isFinite() || it.toDouble() !in 0.0..1.0 }) return null
    val yaw = (map["yaw"] as? Number)?.toDouble() ?: return null
    if (!yaw.isFinite() || yaw < 0 || yaw >= Math.PI * 2) return null
    val turn = (map["turn"] as? Number)?.toDouble() ?: return null
    if (!turn.isFinite() || turn < 0 || turn >= Math.PI * 2) return null
    for (key in listOf("command", "revision", "retry")) {
        val number = map[key]
        if ((number !is Int && number !is Long) || (number as Number).toLong() !in 0..9007199254740991L) return null
    }
    return JSONObject(map)
}
