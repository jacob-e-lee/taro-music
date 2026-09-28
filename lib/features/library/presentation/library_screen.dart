import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/failures.dart';
import '../../player/application/providers.dart';
import '../../player/domain/track.dart';
import '../../search/presentation/track_tile.dart';

/// Library tab: Offline downloaded songs, favorites, playlists, and cached media
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  int _selectedFilter = 0; // 0: All, 1: Downloaded / Offline, 2: Playlists

  // Sample mock downloaded tracks for offline demonstration
  static final List<Track> _sampleDownloadedTracks = [
    const Track(
      id: 'offline_1',
      title: 'Midnight Echoes',
      artist: 'Lunar Horizon',
      source: MediaSourceKind.youtube,
      duration: Duration(minutes: 3, seconds: 42),
      isDownloaded: true,
    ),
    const Track(
      id: 'offline_2',
      title: 'Neon Skyline',
      artist: 'Retro Dreamer',
      source: MediaSourceKind.youtube,
      duration: Duration(minutes: 4, seconds: 15),
      isDownloaded: true,
    ),
    const Track(
      id: 'offline_3',
      title: 'Deep Ocean Waves',
      artist: 'Ambient Soundscapes',
      source: MediaSourceKind.youtube,
      duration: Duration(minutes: 5, seconds: 0),
      isDownloaded: true,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final handler = ref.watch(audioHandlerProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Your Library',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('All'),
                  selected: _selectedFilter == 0,
                  onSelected: (_) => setState(() => _selectedFilter = 0),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  avatar: const Icon(Icons.offline_pin, size: 16),
                  label: const Text('Downloaded'),
                  selected: _selectedFilter == 1,
                  onSelected: (_) => setState(() => _selectedFilter = 1),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('Playlists'),
                  selected: _selectedFilter == 2,
                  onSelected: (_) => setState(() => _selectedFilter = 2),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _selectedFilter == 2
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.playlist_play,
                          size: 64,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No custom playlists yet',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Shared playlist deep links will appear here',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Row(
                          children: [
                            Icon(
                              Icons.offline_pin,
                              size: 20,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Offline Tracks (${_sampleDownloadedTracks.length})',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ..._sampleDownloadedTracks.asMap().entries.map((entry) {
                        final index = entry.key;
                        final track = entry.value;
                        return TrackTile(
                          track: track,
                          onTap: () {
                            handler.playQueue(
                              _sampleDownloadedTracks,
                              startIndex: index,
                            );
                          },
                        );
                      }),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
