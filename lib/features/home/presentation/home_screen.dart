import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/failures.dart';
import '../../player/application/providers.dart';
import '../../player/domain/track.dart';
import '../../search/application/search_providers.dart';
import '../../search/presentation/track_tile.dart';

/// Home tab: Quick picks, trending songs, and curated mixes
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key, this.onSelectQuery});

  final void Function(String)? onSelectQuery;

  static const _quickQueries = [
    'Lo-fi beats to relax',
    'Acoustic favorites',
    'Synthwave hits',
    'Top charts today',
  ];

  static final List<Track> _featuredTracks = [
    const Track(
      id: 'featured_1',
      title: 'Midnight Journey',
      artist: 'Solaris Wave',
      source: MediaSourceKind.youtube,
      duration: Duration(minutes: 3, seconds: 24),
      isDownloaded: true,
    ),
    const Track(
      id: 'featured_2',
      title: 'City Lights Serenade',
      artist: 'Velvet Echo',
      source: MediaSourceKind.youtube,
      duration: Duration(minutes: 4, seconds: 12),
      isDownloaded: false,
    ),
    const Track(
      id: 'featured_3',
      title: 'Floating Through Clouds',
      artist: 'Aura Dream',
      source: MediaSourceKind.youtube,
      duration: Duration(minutes: 2, seconds: 58),
      isDownloaded: true,
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final handler = ref.watch(audioHandlerProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Taro Music',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Settings coming soon')),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Quick Picks',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: _quickQueries.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final query = _quickQueries[index];
                return ActionChip(
                  label: Text(query),
                  onPressed: () {
                    ref.read(searchQueryProvider.notifier).update(query);
                    onSelectQuery?.call(query);
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Featured Songs',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          ..._featuredTracks.asMap().entries.map((entry) {
            final index = entry.key;
            final track = entry.value;
            return TrackTile(
              track: track,
              onTap: () {
                handler.playQueue(_featuredTracks, startIndex: index);
              },
            );
          }),
        ],
      ),
    );
  }
}
