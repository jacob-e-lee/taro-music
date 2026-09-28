package com.example.taro_music

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Registers the `riplay_webview` platform-view factory. It has to be
        // added here rather than declared in pubspec: the view lives in this
        // app's own Android source, not in a plugin package.
        flutterEngine.plugins.add(RiPlayPlugin())
    }
}
