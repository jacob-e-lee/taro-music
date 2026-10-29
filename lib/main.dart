import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The whole app is the YouTube Music web app in one native WebView
/// (see `YtmWebView.kt`); there is no Flutter UI beyond hosting it.
void main() {
  runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: _YtmScreen()));
}

class _YtmScreen extends StatefulWidget {
  const _YtmScreen();

  @override
  State<_YtmScreen> createState() => _YtmScreenState();
}

class _YtmScreenState extends State<_YtmScreen> {
  MethodChannel? _web;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      // The WebView answers false when it has no history left; only then exit.
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _web?.invokeMethod<bool>('back') != true) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: AndroidView(
            viewType: 'ytm_webview',
            onPlatformViewCreated: (id) =>
                _web = MethodChannel('com.example.taro_music/ytm_webview/$id'),
          ),
        ),
      ),
    );
  }
}
