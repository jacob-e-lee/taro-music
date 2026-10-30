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

// The view type and channel name must match `lib/main.dart`.
private const val VIEW_TYPE = "ytm_webview"

private class YtmWebViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        YtmPlatformView(
            YtmWebView(context),
            MethodChannel(messenger, "com.example.taro_music/$VIEW_TYPE/$viewId"),
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

    /** `back`: navigates back and answers true, or answers false at the first page. */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "back") return result.notImplemented()
        val canGoBack = webView.canGoBack()
        if (canGoBack) webView.goBack()
        result.success(canGoBack)
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
