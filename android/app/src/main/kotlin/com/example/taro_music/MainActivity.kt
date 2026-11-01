package com.example.taro_music

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Start loading the page now instead of when Flutter asks for the view (~0.5 s later).
        prewarmedWebView?.destroy()
        prewarmedWebView = YtmWebView(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(YtmWebViewPlugin())
        startForegroundService(Intent(this, KeepAliveService::class.java))
    }
}
