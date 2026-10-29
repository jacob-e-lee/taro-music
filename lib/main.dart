import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The whole app is the YouTube Music web app in one native WebView
/// (see `RiPlayWebView.kt`); there is no Flutter UI beyond hosting it.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: _Ytm()));
}

class _Ytm extends StatefulWidget {
  const _Ytm();

  @override
  State<_Ytm> createState() => _YtmState();
}

class _YtmState extends State<_Ytm> {
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
            viewType: 'riplay_webview',
            creationParams: const <String, Object>{'mode': 'ytm'},
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: (id) =>
                _web = MethodChannel('com.example.taro_music/riplay/$id'),
          ),
        ),
      ),
    );
  }
}
