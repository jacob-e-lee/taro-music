package com.example.taro_music

import android.content.Context
import android.view.View
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Creates [RiPlayWebView]s for the Dart side.
 *
 * A Flutter platform view is three moving parts, and all of them live here:
 * the view itself ([RiPlayWebView]), a factory that Flutter's platform-view
 * registry calls, and a thin [PlatformView] wrapper. The [FlutterPlugin] at the
 * bottom is what puts the factory into that registry.
 */
class RiPlayWebViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val channel = MethodChannel(messenger, "$CHANNEL_NAME/$viewId")
        val view = RiPlayWebView(context, channel)
        // The view owns the channel's lifetime, so it is the one that answers
        // Dart's calls; `dispose` is what tears it down.
        return RiPlayPlatformView(view, channel)
    }

    companion object {
        /** Must match the channel name on the Dart side. */
        const val CHANNEL_NAME = "com.example.taro_music/riplay"
    }
}

/** Flutter's handle on the native view. */
private class RiPlayPlatformView(
    private val webView: RiPlayWebView,
    private val channel: MethodChannel,
) : PlatformView, MethodChannel.MethodCallHandler {

    init {
        channel.setMethodCallHandler(this)

        // The origin the page claims, and it must be *ours*.
        //
        // YouTube decides whether to play by asking who is embedding it, and
        // the answer comes from this base URL. Claiming
        // `https://www.youtube.com` made YouTube identify itself as its own
        // embedder and refuse with error 152 ("This video is unavailable").
        //
        // This must equal the `origin` playerVar in `playerHtml`, or the
        // player's postMessage handshake rejects our own commands.
        webView.loadDataWithBaseURL(
            /* baseUrl = */ RiPlayWebView.EMBED_ORIGIN,
            /* data = */ RiPlayWebView.playerHtml(),
            /* mimeType = */ "text/html",
            /* encoding = */ "utf-8",
            /* historyUrl = */ RiPlayWebView.EMBED_ORIGIN,
        )
    }

    override fun getView(): View = webView

    // `MethodCallHandler` names this `onMethodCall`; the WebView-side helper
    // keeps the shorter name because it is also called from `handle` below.
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        webView.handle(call, result)
    }

    override fun dispose() {
        channel.setMethodCallHandler(null)
        // Stop loading before detaching, or a navigation in flight can outlive
        // the view and keep the renderer alive.
        webView.stopLoading()
        webView.loadUrl("about:blank")
        webView.destroy()
    }
}

/** Registers the factory with the engine. Wired up from `MainActivity`. */
class RiPlayPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // `platformViewsController` was replaced by `platformViewRegistry` in
        // newer Flutter embeddings; this is the supported accessor now.
        binding.platformViewRegistry.registerViewFactory(
            VIEW_TYPE,
            RiPlayWebViewFactory(binding.binaryMessenger),
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}

    companion object {
        /** Must match the `viewType` Dart passes to `AndroidView`. */
        const val VIEW_TYPE = "riplay_webview"
    }
}
