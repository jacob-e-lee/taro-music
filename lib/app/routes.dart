import 'package:flutter/material.dart';

import '../core/errors/failures.dart';
import '../features/player/domain/track.dart';
import '../features/search/presentation/track_tile.dart';

/// Deep link route names and parser
class AppRoutes {
  static const String root = '/';
  static const String playlist = '/playlist';
  static const String track = '/track';

  /// Generates direct content routes for deep links without forcing the user
  /// through the Home screen.
  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    final uri = Uri.tryParse(settings.name ?? '');
    if (uri == null) return null;

    if (uri.path == playlist) {
      final playlistId = uri.queryParameters['id'] ?? 'unknown';
      final title = uri.queryParameters['title'] ?? 'Shared Playlist';
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (_) =>
            PlaylistDeepLinkScreen(playlistId: playlistId, title: title),
      );
    }

    if (uri.path == track) {
      final trackId = uri.queryParameters['id'] ?? 'unknown';
      final title = uri.queryParameters['title'] ?? 'Shared Track';
      final artist = uri.queryParameters['artist'] ?? 'Shared Artist';
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => TrackDeepLinkScreen(
          track: Track(
            id: trackId,
            title: title,
            artist: artist,
            source: MediaSourceKind.youtube,
          ),
        ),
      );
    }

    return null;
  }
}

/// Direct screen when navigating to a shared playlist deep link
class PlaylistDeepLinkScreen extends StatelessWidget {
  const PlaylistDeepLinkScreen({
    super.key,
    required this.playlistId,
    required this.title,
  });

  final String playlistId;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.playlist_play,
              size: 72,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Playlist ID: $playlistId',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Direct screen when navigating to a shared track deep link
class TrackDeepLinkScreen extends StatelessWidget {
  const TrackDeepLinkScreen({super.key, required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Shared Track')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.music_note, size: 80, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              track.title,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              track.artist,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            TrackTile(
              track: track,
              onTap: () {
                // Tapping plays directly
              },
            ),
          ],
        ),
      ),
    );
  }
}
