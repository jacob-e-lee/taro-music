import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/application/providers.dart';
import '../../player/domain/search_results.dart';
import '../../player/domain/track.dart';
import '../application/search_providers.dart';
import 'track_tile.dart';

/// Search box + results. Tapping a row replaces the handler queue with the
/// visible results, starting at the tapped track.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    final query = ref.read(searchQueryProvider);
    if (query.isEmpty) return;
    final metrics = _scroll.position;
    if (metrics.pixels < metrics.maxScrollExtent - 400) return;
    final notifier = ref.read(
      searchProvider(query, ref.read(searchScopeFilterProvider)).notifier,
    );
    // Fire and forget: failures surface as a snack bar from the tile row.
    unawaited(notifier.loadMore());
  }

  void _submit(String text) {
    ref.read(searchQueryProvider.notifier).update(text);
    // The controller is only attached while a results list exists (the
    // empty-state placeholder and the loading spinner attach nothing), and a
    // freshly built list starts at offset 0 anyway — so only reset the
    // position when a list is actually attached.
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  /// Switching Songs/Videos re-runs the current query against the new scope,
  /// so the list is scrolled back to the top for the fresh result set.
  void _selectScope(SearchScope scope) {
    if (ref.read(searchScopeFilterProvider) == scope) return;
    ref.read(searchScopeFilterProvider.notifier).select(scope);
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  Future<void> _play(List<Track> tracks, int index) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(audioHandlerProvider).playQueue(tracks, startIndex: index);
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Playback failed: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    final scope = ref.watch(searchScopeFilterProvider);
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            autofocus: false,
            onSubmitted: _submit,
            decoration: InputDecoration(
              hintText: 'Search songs, artists, albums…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _controller.clear();
                        ref.read(searchQueryProvider.notifier).clear();
                      },
                    ),
              border: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(24)),
              ),
            ),
          ),
        ),
        // Songs / Videos scope toggle directly under the search bar.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<SearchScope>(
              segments: <ButtonSegment<SearchScope>>[
                for (final option in SearchScope.values)
                  ButtonSegment<SearchScope>(
                    value: option,
                    label: Text(option.label),
                    icon: Icon(
                      option == SearchScope.songs
                          ? Icons.music_note
                          : Icons.videocam_outlined,
                    ),
                  ),
              ],
              selected: <SearchScope>{scope},
              showSelectedIcon: false,
              onSelectionChanged: (selection) => _selectScope(selection.first),
            ),
          ),
        ),
        Expanded(
          child: _Results(
            query: query,
            scope: scope,
            scroll: _scroll,
            onTap: _play,
          ),
        ),
      ],
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({
    required this.query,
    required this.scope,
    required this.scroll,
    required this.onTap,
  });

  final String query;
  final SearchScope scope;
  final ScrollController scroll;
  final Future<void> Function(List<Track>, int) onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (query.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.music_note, size: 64),
            SizedBox(height: 12),
            Text('Search for music to start listening'),
          ],
        ),
      );
    }

    final results = ref.watch(searchProvider(query, scope));
    return results.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text('Search failed. $error', textAlign: TextAlign.center),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => ref.invalidate(searchProvider(query, scope)),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
      data: (page) {
        final itemCount = page.tracks.length + (page.hasMore ? 1 : 0);
        return ListView.builder(
          controller: scroll,
          itemCount: itemCount,
          itemBuilder: (context, index) {
            if (index >= page.tracks.length) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return TrackTile(
              track: page.tracks[index],
              onTap: () => onTap(page.tracks, index),
            );
          },
        );
      },
    );
  }
}
