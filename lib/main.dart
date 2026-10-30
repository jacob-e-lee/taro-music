import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The whole app is the YouTube Music web app in one native WebView
/// (see `YtmWebView.kt`); there is no Flutter UI beyond hosting it.
void main() {
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: _YtmScreen()),
  );
}

// The app draws under the phone's bars (Android forces edge-to-edge). Light icons for the
// page's dark backgrounds, and no contrast scrims, which Android would otherwise darken them with.
const _systemBars = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemStatusBarContrastEnforced: false,
  systemNavigationBarContrastEnforced: false,
  systemNavigationBarIconBrightness: Brightness.light,
);

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
      // Re-applied on every frame, unlike a one-off SystemChrome call.
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: _systemBars,
        child: Scaffold(
          backgroundColor: Colors.black,
          // The page runs under both system bars, so whatever it shows (the tab bar's grey,
          // the player's black) continues behind them. inject.js keeps its content clear of
          // them using env(safe-area-inset-top / -bottom).
          body: SafeArea(
            top: false,
            bottom: false,
            child: AndroidView(
              viewType: 'ytm_webview',
              onPlatformViewCreated: (id) => _web = MethodChannel(
                'com.example.taro_music/ytm_webview/$id',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
