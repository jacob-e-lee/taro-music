import 'package:flutter/material.dart';

import '../core/config/app_config.dart';
import '../features/player/application/webview_bridge.dart';
import '../features/player/presentation/youtube_webview_player.dart';
import 'routes.dart';
import 'shell_screen.dart';

/// Root widget: dark Material 3 theme, 3-tab ShellScreen, persistent mini-player,
/// and direct content deep-link routing.
class TaroMusicApp extends StatelessWidget {
  const TaroMusicApp({super.key, this.initialRoute});

  final String? initialRoute;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1DB954),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: AppConfig.appName,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: scheme.surface,
        listTileTheme: const ListTileThemeData(dense: true),
      ),
      initialRoute: initialRoute,
      onGenerateRoute: AppRoutes.onGenerateRoute,
      home: const ShellScreen(),
      // The audio engine lives here, above the navigator, so it survives
      // every route change. `Offstage` inside the widget keeps it invisible.
      //
      // Gated on `enabled`, which only `main()` turns on: a widget test cannot
      // create a platform view, and the player would otherwise be built in
      // every one of them.
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: <Widget>[
          child ?? const SizedBox.shrink(),
          if (YouTubeWebViewBridge.enabled) const YoutubeWebviewPlayer(),
        ],
      ),
    );
  }
}
