import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The whole app is the YouTube Music web app in one native WebView
/// (see `YtmWebView.kt`); there is no Flutter UI beyond hosting it.
void main() {
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: _YtmScreen()),
  );
}

// The app draws under the phone's bars (Android forces edge-to-edge): the page under the
// status bar, the grey strip below under the navigation bar. Light icons for both dark
// backgrounds, and no contrast scrims, which Android would otherwise darken them with.
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
          body: Column(
            children: [
              // The page extends under the status bar and keeps its own content below it
              // (inject.js reads the height from env(safe-area-inset-top)).
              Expanded(
                child: SafeArea(
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
              // Behind the phone's navigation bar: the grey of the page's tab bar (inject.js).
              const ColoredBox(
                color: Color(0xFF212121),
                child: SafeArea(
                  top: false,
                  child: SizedBox(width: double.infinity),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
