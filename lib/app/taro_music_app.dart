import 'package:flutter/material.dart';

import '../core/config/app_config.dart';
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
    );
  }
}
