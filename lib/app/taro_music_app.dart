import 'package:flutter/material.dart';

import '../core/config/app_config.dart';
import '../features/player/presentation/mini_player.dart';
import '../features/search/presentation/search_screen.dart';

/// Root widget: dark Material 3 theme, search as the home tab, and a
/// persistent mini player.
class TaroMusicApp extends StatelessWidget {
  const TaroMusicApp({super.key});

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
      home: const Scaffold(
        body: SafeArea(child: SearchScreen()),
        bottomNavigationBar: MiniPlayer(),
      ),
    );
  }
}
