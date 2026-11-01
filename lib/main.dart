import 'dart:async';

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

/// Logo breathing over a soft purple glow, covering the page until it has painted.
class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen({required this.pulse});

  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: AnimatedBuilder(
          animation: pulse,
          builder: (context, _) {
            final t = Curves.easeInOut.transform(pulse.value);
            return Container(
              width: 280,
              height: 280,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    Color.fromRGBO(124, 80, 194, 0.12 + 0.22 * t),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Transform.scale(
                scale: 0.92 + 0.10 * t,
                child: Image.asset('assets/icon/icon.png', width: 150, height: 150),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _YtmScreen extends StatefulWidget {
  const _YtmScreen();

  @override
  State<_YtmScreen> createState() => _YtmScreenState();
}

class _YtmScreenState extends State<_YtmScreen> with SingleTickerProviderStateMixin {
  MethodChannel? _web;
  Timer? _poll;
  bool _loading = true;
  bool _gone = false;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  // Asks the WebView whether the page has painted. Polling, because a push from native
  // could land before Dart has set up the channel. Gives up after 10 s so a stuck page
  // doesn't hide behind the logo.
  void _watchPage() {
    final started = DateTime.now();
    _poll = Timer.periodic(const Duration(milliseconds: 100), (t) async {
      final ready = await _web?.invokeMethod<bool>('ready') ?? false;
      if (ready || DateTime.now().difference(started).inSeconds >= 10) {
        t.cancel();
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _pulse.dispose();
    super.dispose();
  }

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
          // The keyboard covers the page instead of shrinking it, so nothing jumps when it opens.
          resizeToAvoidBottomInset: false,
          // The page runs under both system bars, so whatever it shows (the tab bar's grey,
          // the player's black) continues behind them. inject.js keeps its content clear of
          // them using env(safe-area-inset-top / -bottom).
          body: Stack(
            fit: StackFit.expand,
            children: [
              SafeArea(
                top: false,
                bottom: false,
                child: AndroidView(
                  viewType: 'ytm_webview',
                  onPlatformViewCreated: (id) {
                    _web = MethodChannel('io.github.jacob_e_lee.taro_music/ytm_webview/$id');
                    _watchPage();
                  },
                ),
              ),
              if (!_gone)
                IgnorePointer(
                  ignoring: !_loading,
                  child: AnimatedOpacity(
                    opacity: _loading ? 1 : 0,
                    duration: const Duration(milliseconds: 350),
                    onEnd: () {
                      _pulse.stop();
                      setState(() => _gone = true);
                    },
                    child: _LoadingScreen(pulse: _pulse),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
