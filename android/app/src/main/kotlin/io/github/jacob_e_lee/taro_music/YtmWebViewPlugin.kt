package io.github.jacob_e_lee.taro_music

import android.content.Context
import android.view.View
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

// The view type and channel name must match `lib/main.dart`.
private const val VIEW_TYPE = "ytm_webview"

/**
 * Built by `MainActivity.onCreate` so the page starts loading while Flutter is still booting;
 * the platform view takes it over once Dart asks for it.
 */
var prewarmedWebView: YtmWebView? = null

private class YtmWebViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        YtmPlatformView(
            prewarmedWebView?.also { prewarmedWebView = null } ?: YtmWebView(context),
            MethodChannel(messenger, "io.github.jacob_e_lee.taro_music/$VIEW_TYPE/$viewId"),
        )
}

private class YtmPlatformView(
    private val webView: YtmWebView,
    private val channel: MethodChannel,
) : PlatformView, MethodChannel.MethodCallHandler {

    init {
        channel.setMethodCallHandler(this)
    }

    override fun getView(): View = webView

    /**
     * `back`: lets the page handle it (closing a panel) or navigates back, and answers true;
     * answers false at the first page.
     * `ready`: answers whether the page has painted yet.
     */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ready" -> result.success(webView.visible)
            "back" -> webView.evaluateJavascript("!!(window.__taroBack && __taroBack())") { handled ->
                val goBack = handled != "true" && webView.canGoBack()
                if (goBack) webView.goBack()
                result.success(handled == "true" || goBack)
            }
            else -> result.notImplemented()
        }
    }

    override fun dispose() {
        channel.setMethodCallHandler(null)
        MediaControls.runInPage = null  // don't call into a destroyed WebView
        webView.destroy()
    }
}

/** Registers the factory with the engine. Wired up from `MainActivity`. */
class YtmWebViewPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        binding.platformViewRegistry.registerViewFactory(VIEW_TYPE, YtmWebViewFactory(binding.binaryMessenger))
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
