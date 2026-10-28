package dev.animusstudio.alkion

import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.ConsoleMessage
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.ByteArrayInputStream

/** Dataless, debug-only isolation probe. Declared only by the offline opt-in manifest. */
class BodyGraphicsProbeActivity : Activity() {
    private lateinit var web: WebView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED)
        // The separate process must not share the main WebView's directory lock.
        if (Build.VERSION.SDK_INT >= 28 && !dataSuffixSet) {
            WebView.setDataDirectorySuffix("body-graphics-probe")
            dataSuffixSet = true
        }
        web = WebView(this)
        web.settings.apply {
            javaScriptEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            domStorageEnabled = false
            databaseEnabled = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            setGeolocationEnabled(false)
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        }
        web.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
            override fun onConsoleMessage(message: ConsoleMessage): Boolean {
                if (message.message().startsWith("ALKION_PROBE ")) {
                    Log.i("AlkionBodyProbe", message.message().take(4096))
                } else {
                    Log.i("AlkionBodyProbe", "console ${message.messageLevel()} line=${message.lineNumber()} ${message.message().take(1000)}")
                }
                return true
            }
        }
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = request.url.toString() != PROBE_URL
            @Suppress("DEPRECATION")
            override fun shouldOverrideUrlLoading(view: WebView, url: String) = url != PROBE_URL
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                if (request.method == "GET" && request.url.toString() == PROBE_URL) {
                    return WebResourceResponse("text/html", "UTF-8", 200, "OK",
                        mapOf("Cache-Control" to "no-store", "X-Content-Type-Options" to "nosniff"),
                        ByteArrayInputStream(HTML.toByteArray(Charsets.UTF_8)))
                }
                Log.i("AlkionBodyProbe", "denied ${request.method} ${request.url.toString().take(180)}")
                return WebResourceResponse("text/plain", "UTF-8", 403, "Forbidden", emptyMap(), ByteArrayInputStream(byteArrayOf()))
            }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                Log.i("AlkionBodyProbe", "load-error main=${request.isForMainFrame} code=${error.errorCode} url=${request.url.toString().take(180)} ${error.description.toString().take(300)}")
            }
            override fun onPageFinished(view: WebView, url: String) {
                logWindow("page-finished url=${url.take(180)}")
                view.evaluateJavascript("JSON.stringify({ready:document.readyState,resultElement:!!document.getElementById('result')})") {
                    Log.i("AlkionBodyProbe", "document ${it.take(300)}")
                }
            }
        }
        web.setDownloadListener { _, _, _, _, _ -> }
        web.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(view: View) {
                web.removeOnAttachStateChangeListener(this)
                web.post {
                    logWindow("attached url=$PROBE_URL")
                    web.loadUrl(PROBE_URL)
                }
            }
            override fun onViewDetachedFromWindow(view: View) {}
        })
        setContentView(web)
    }

    private fun logWindow(stage: String) {
        val provider = if (Build.VERSION.SDK_INT >= 26) WebView.getCurrentWebViewPackage()?.let { "${it.packageName}/${it.versionName}" } else "unavailable"
        Log.i("AlkionBodyProbe", "$stage hardware=${web.isHardwareAccelerated} layer=${web.layerType} windowHardware=${window.attributes.flags and WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED != 0} provider=$provider")
    }

    override fun onDestroy() {
        if (::web.isInitialized) {
            web.stopLoading()
            (web.parent as? ViewGroup)?.removeView(web)
            web.destroy()
        }
        super.onDestroy()
    }

    companion object {
        private const val PROBE_URL = "https://appassets.androidplatform.net/probe/index.html"
        private var dataSuffixSet = false
        private val HTML = """
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'">
<title>Native graphics probe</title></head><body><h1>Native graphics probe</h1><pre id="result">Checking WebGL context</pre><script>
(()=>{
 const result={version:1,secureContext:isSecureContext,hardwareResult:'reported by native host',context:false,readPixel:false,creationError:null};
 const canvas=document.createElement('canvas');canvas.width=1;canvas.height=1;
 canvas.addEventListener('webglcontextcreationerror',event=>{result.creationError=String(event.statusMessage||'').slice(0,1000);});
 try{
  // Exact approved renderer context attributes; no WebGL2 or fallback attempt.
  const gl=canvas.getContext('webgl',{alpha:true,antialias:false,preserveDrawingBuffer:true});
  result.context=!!gl;
  if(gl){
   result.attributes=gl.getContextAttributes();
   result.versionString=gl.getParameter(gl.VERSION);result.vendor=gl.getParameter(gl.VENDOR);result.renderer=gl.getParameter(gl.RENDERER);
   const debug=gl.getExtension('WEBGL_debug_renderer_info');
   if(debug){result.unmaskedVendor=gl.getParameter(debug.UNMASKED_VENDOR_WEBGL);result.unmaskedRenderer=gl.getParameter(debug.UNMASKED_RENDERER_WEBGL);}
   result.extensions=gl.getSupportedExtensions();result.uintIndices=!!gl.getExtension('OES_element_index_uint');
   result.robustnessExtensions=result.extensions.filter(name=>/robust|lose_context/i.test(name));
   result.resetNotificationStrategy='Native EGL strategy is not exposed by WebGL';
   gl.clearColor(.25,.5,.75,1);gl.clear(gl.COLOR_BUFFER_BIT);const pixel=new Uint8Array(4);gl.readPixels(0,0,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);
   result.pixel=Array.from(pixel);result.error=gl.getError();result.readPixel=result.error===gl.NO_ERROR&&Math.abs(pixel[0]-64)<=1&&Math.abs(pixel[1]-128)<=1&&Math.abs(pixel[2]-191)<=1&&pixel[3]===255;
  }
 }catch(error){result.exception=String(error).slice(0,300);}
 document.getElementById('result').textContent=JSON.stringify(result,null,2);console.log('ALKION_PROBE '+JSON.stringify(result));
})();
</script></body></html>
""".trimIndent()
    }
}
