package com.example.taro_music

import android.annotation.SuppressLint
import android.content.Context
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * A WebView that lies to Chromium about its own visibility.
 *
 * YouTube's player listens for the `visibilitychange` DOM event and pauses
 * playback when the page goes hidden. In a normal app that fires the moment the
 * user locks the screen or the WebView leaves the view hierarchy, so a
 * backgrounded player goes silent. This subclass reports itself as always
 * visible and focused, so the event never fires and the audio keeps running.
 *
 * This is the same trick the RiPlay project uses. The honest caveats:
 *  - It is a lie to the platform, not a supported API. `onVisibilityAggregated`
 *    exists from API 24; on older devices it is simply never called.
 *  - Keeping a WebView "visible" does not by itself keep the process alive.
 *    That is the `audio_service` foreground service's job.
 */
class RiPlayWebView(
    context: Context,
    private val methodChannel: MethodChannel,
) : WebView(context) {

    /** The video the Dart side last asked for, reloaded on configuration changes. */
    private var currentVideoId: String = ""

    init {
        setLayerType(LAYER_TYPE_HARDWARE, null)
        isSoundEffectsEnabled = false
        isHapticFeedbackEnabled = false

        settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            // Without this Chromium withholds playback until a user gesture,
            // and `playVideo()` would silently do nothing.
            mediaPlaybackRequiresUserGesture = false
            cacheMode = WebSettings.LOAD_DEFAULT
            // The mobile player asks for a Play Integrity attestation a WebView
            // cannot supply, so ask for the desktop player instead.
            userAgentString = DESKTOP_USER_AGENT
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
        }

        // Keep playing: audio must not be routed through a hardware key that
        // only exists while something is pressed.
        setBackgroundColor(android.graphics.Color.TRANSPARENT)

        webChromeClient = WebChromeClient()

        webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String) {
                // Re-install the page's message bridge after every navigation.
                view.evaluateJavascript(PLAYER_BOOTSTRAP, null)
            }

            override fun shouldOverrideUrlLoading(
                view: WebView,
                request: WebResourceRequest,
            ): Boolean = false
        }

        // Typed as Any on purpose: left to inference, Kotlin picks the
        // single-argument overload and this call will not compile.
        val bridge: Any = PlayerBridge()
        addJavascriptInterface(bridge, JS_BRIDGE_NAME)

        // startSafeBrowsing is noise for a fixed-origin player page.
        settings.safeBrowsingEnabled = false
    }

    /** Native -> JS entry point used by the page for player events. */
    private inner class PlayerBridge {
        @JavascriptInterface
        fun sendState(state: Int) = emit("onStateChange", state)

        @JavascriptInterface
        fun sendInfo(info: String) = emit("onPlayerInfo", info)

        @JavascriptInterface
        fun sendError(message: String) = emit("onPlayerError", message)

        @JavascriptInterface
        fun sendReady() = emit("onPlayerReady", true)
    }

    /**
     * JS calls arrive on a private WebView thread, and a MethodChannel must only
     * be touched from the main thread, so every emit hops across.
     */
    private fun emit(method: String, argument: Any) {
        post { methodChannel.invokeMethod(method, argument) }
    }

    /** Handles Dart -> native calls. */
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadVideo" -> {
                val videoId = call.argument<String>("videoId").orEmpty()
                val autoplay = call.argument<Boolean>("autoplay") ?: false
                currentVideoId = videoId
                if (videoId.isEmpty()) {
                    result.success(null)
                    return
                }
                evaluateJavascript("taroLoad('$videoId', $autoplay);", null)
                result.success(null)
            }
            "call" -> {
                val method = call.argument<String>("method").orEmpty()
                val args = call.argument<List<Any?>>("args").orEmpty()
                evaluateJavascript(taroCall(method, args), null)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------- visibility overrides

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(View.VISIBLE)
    }

    override fun onVisibilityChanged(changedView: View, visibility: Int) {
        super.onVisibilityChanged(changedView, View.VISIBLE)
    }

    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(true)
    }

    override fun onVisibilityAggregated(isVisible: Boolean) {
        super.onVisibilityAggregated(true)
    }

    override fun onDetachedFromWindow() {
        // Do not tear the renderer down; the audio engine has to outlive the
        // window it was created in.
        super.onDetachedFromWindow()
    }


    /** Serialises a call to [name] on the page's own command queue. */
    private fun taroCall(name: String, args: List<Any?>): String {
        val encoded = args.joinToString(",") { arg ->
            when (arg) {
                null -> "null"
                is Boolean, is Int, is Long, is Double -> arg.toString()
                is String -> "\"" + arg.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
                else -> "\"${arg.toString()}\""
            }
        }
        return "window.taro && window.taro.call('$name', [$encoded]);"
    }

    companion object {
        const val DESKTOP_USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"

        /** Name the page uses to reach the native bridge. */
        const val JS_BRIDGE_NAME = "RiPlayBridge"

        /**
         * The origin the player page claims to be embedded from.
         *
         * This is the single value that decides whether playback is allowed at
         * all, and it is deliberately *not* `https://www.youtube.com`:
         *
         *  - no origin at all -> **153**, no `Referer` was sent;
         *  - `https://www.youtube.com` -> **152**, YouTube identified itself as
         *    the embedder and refused.
         *
         * An app-owned origin in the `https://<app-id>` form is what YouTube's
         * "Required Minimum Functionality" guidance prescribes for clients that
         * load local HTML, and it matches this app's `applicationId`.
         *
         * If 152 ever returns, this is the first thing to suspect: swap in a real
         * domain you control. Nothing else has to change.
         */
        const val EMBED_ORIGIN = "https://com.example.taro_music"

        /**
         * The player page.
         *
         * The `origin` playerVar below must match the base URL passed to
         * `loadDataWithBaseURL` (see [EMBED_ORIGIN]). YouTube identifies the
         * embedder from that origin, and the two failure modes are worth
         * keeping straight, because only one of them is "missing":
         *
         *  - **153** `embedder.identity.missing.referrer` — the page had no
         *    origin at all, so no `Referer` was sent. Any base URL fixes this;
         *    it is why this page is loaded via `loadDataWithBaseURL` rather
         *    than as a bare string.
         *  - **152** "This video is unavailable" — the page claimed to be
         *    `https://www.youtube.com`, so YouTube identified *itself* as the
         *    embedder and refused. The origin has to be one we own.
         */
        fun playerHtml(): String = """
            <!DOCTYPE html>
            <html>
              <head>
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
              </head>
              <body style="margin:0;padding:0;background-color:black;">
                <div id="player"></div>
                <script>
                  var pending = [];
                  var player = null;

                  // The IFrame API is a network script, so on a cold start
                  // `player` is briefly undefined. Commands queue here and
                  // flush on ready, in order.
                  window.taro = {
                    call: function (name, args) {
                      if (player && typeof player[name] === 'function') {
                        player[name].apply(player, args);
                      } else {
                        pending.push([name, args]);
                      }
                    }
                  };

                  window.taroLoad = function (videoId, autoplay) {
                    window.taro.call('loadVideoById', [videoId, autoplay ? 1 : 0]);
                  };

                  function onYouTubeIframeAPIReady() {
                    player = new YT.Player('player', {
                      height: '100%',
                      width: '100%',
                      videoId: '',
                      playerVars: {
                        'playsinline': 1,
                        'autoplay': 0,
                        'controls': 0,
                        'disablekb': 1,
                        'modestbranding': 1,
                        'origin': '$EMBED_ORIGIN'
                      },
                      events: {
                        onReady: function () {
                          var queued = pending;
                          pending = [];
                          for (var i = 0; i < queued.length; i++) {
                            var cmd = queued[i];
                            player[cmd[0]].apply(player, cmd[1]);
                          }
                          $JS_BRIDGE_NAME.sendReady();
                        },
                        onStateChange: function (event) {
                          $JS_BRIDGE_NAME.sendState(event.data);
                        },
                        onError: function (event) {
                          $JS_BRIDGE_NAME.sendError(String(event.data));
                        },
                        onInfoDelivery: function (event) {
                          $JS_BRIDGE_NAME.sendInfo(JSON.stringify(event.info));
                        }
                      }
                    });
                  }

                  var tag = document.createElement('script');
                  tag.src = 'https://www.youtube.com/iframe_api';
                  var first = document.getElementsByTagName('script')[0];
                  first.parentNode.insertBefore(tag, first);
                </script>
              </body>
            </html>
        """.trimIndent()

        /**
         * Re-arms the page bridge after a navigation. Kept separate from
         * [playerHtml] because it must not redeclare the IFrame API.
         */
        @SuppressLint("unused")
        const val PLAYER_BOOTSTRAP: String = "window.taro && window.taro.call('playVideo', []);"
    }
}
