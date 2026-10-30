package com.example.taro_music

import android.content.Context
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.util.Log
import android.view.View
import android.webkit.ConsoleMessage
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import java.io.ByteArrayInputStream

/**
 * The YouTube Music web app, NouTube-style: the site itself is the UI, with ad
 * blocking and a little CSS/JS (`assets/ytm/inject.js`) layered on top.
 *
 * It also lies to Chromium about its visibility. YouTube pauses playback on the
 * `visibilitychange` DOM event, which would fire when the screen locks; always
 * reporting "visible" keeps audio running. [KeepAliveService] keeps the process
 * alive.
 */
class YtmWebView(context: Context) : WebView(context) {

    private val debuggable = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    // Debug builds prefer a file pushed by tool/dev-js.ps1, so JS changes skip the rebuild.
    private val script: String = context.getExternalFilesDir(null)
        ?.resolve("inject.js")?.takeIf { debuggable && it.isFile }?.readText()
        ?: context.assets.open("flutter_assets/assets/ytm/inject.js").bufferedReader().use { it.readText() }

    init {
        // Lets edge://inspect / brave://inspect attach to this WebView over USB.
        WebView.setWebContentsDebuggingEnabled(debuggable)
        settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            cacheMode = WebSettings.LOAD_DEFAULT
            // The stock WebView UA carries a `wv` token that Google uses to refuse sign-in.
            userAgentString = WebSettings.getDefaultUserAgent(context)
                .replace("; wv", "").replace("Version/4.0 ", "")
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
        webChromeClient = object : WebChromeClient() {
            // Page console output → `adb logcat -s TaroMusic`.
            override fun onConsoleMessage(m: ConsoleMessage): Boolean {
                Log.d("TaroMusic", "${m.messageLevel()} ${m.message()} (${m.sourceId()}:${m.lineNumber()})")
                return true
            }
        }
        webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                // Fallback for WebViews without document-start scripts (see init).
                view.evaluateJavascript(script, null)
            }

            override fun onPageFinished(view: WebView, url: String?) {
                // Independent of inject.js, so a stale bundled asset can't keep the button alive.
                view.evaluateJavascript(HIDE_OPEN_APP, null)
            }

            override fun shouldInterceptRequest(
                view: WebView,
                request: WebResourceRequest,
            ): WebResourceResponse? {
                val url = request.url
                val blocked = BLOCKED_HOSTS.any { (url.host ?: "").endsWith(it) } ||
                    BLOCKED_PATHS.any { url.path?.contains(it) == true }
                return if (blocked) {
                    WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(ByteArray(0)))
                } else null
            }
        }
        // Runs before any page script, so the ad hooks beat the first player response.
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(this, script, setOf("https://music.youtube.com"))
        }
        // Playback state for the media notification and lock screen. Only the YouTube Music
        // origin gets the `TaroMedia` object, so no other frame can post to it.
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(this, "TaroMedia", setOf("https://music.youtube.com")) { _, message, _, _, _ ->
                MediaControls.update(context, message.data ?: return@addWebMessageListener)
            }
        }
        MediaControls.runInPage = { command, arg ->
            evaluateJavascript("window.__taroMedia && __taroMedia('$command', $arg)", null)
        }
        loadUrl("https://music.youtube.com")
    }

    // ---------------------------------------------------- visibility overrides

    override fun onWindowVisibilityChanged(visibility: Int) =
        super.onWindowVisibilityChanged(View.VISIBLE)

    override fun onVisibilityChanged(changedView: View, visibility: Int) =
        super.onVisibilityChanged(changedView, View.VISIBLE)

    override fun onWindowFocusChanged(hasWindowFocus: Boolean) =
        super.onWindowFocusChanged(true)

    override fun onVisibilityAggregated(isVisible: Boolean) =
        super.onVisibilityAggregated(true)

    private companion object {
        val HIDE_OPEN_APP = """
            if (!window.__taroHideOpen) {
              window.__taroHideOpen = true;
              var hide = function (r) {
                r.querySelectorAll('*').forEach(function (e) {
                  if (e.shadowRoot) hide(e.shadowRoot);
                  if (e.matches('.app-install-link, a[href^="https://app.music.youtube.com"]'))
                    e.style.setProperty('display', 'none', 'important');
                });
              };
              setInterval(function () { hide(document); }, 500);
            }
        """.trimIndent()

        val BLOCKED_HOSTS = listOf("doubleclick.net", "googlesyndication.com", "googleadservices.com", "googletagmanager.com")
        val BLOCKED_PATHS = listOf("/pagead/", "/api/stats/ads", "/pcs/activeview")
    }
}
