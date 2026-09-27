import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/providers.dart';
import 'now_playing_sheet.dart';

/// The slim bar pinned above the bottom edge, bound to the handler's streams.
/// Hidden until the first track is loaded.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.watch(audioHandlerProvider);
    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      builder: (context, itemSnapshot) {
        final item = itemSnapshot.data;
        if (item == null) return const SizedBox.shrink();
        return StreamBuilder<PlaybackState>(
          stream: handler.playbackState,
          initialData: handler.playbackState.value,
          builder: (context, stateSnapshot) {
            final state = stateSnapshot.data ?? handler.playbackState.value;
            final theme = Theme.of(context);
            return Material(
              color: theme.colorScheme.surfaceContainer,
              child: SafeArea(
                top: false,
                child: GestureDetector(
                  onTap: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => const NowPlayingSheet(),
                  ),
                  child: Row(
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: ClipRRect(
                          borderRadius: const BorderRadius.all(
                            Radius.circular(6),
                          ),
                          child: item.artUri != null
                              ? Image.network(
                                  item.artUri.toString(),
                                  width: 48,
                                  height: 48,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      const _MiniFallbackArt(),
                                )
                              : const _MiniFallbackArt(),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyLarge,
                            ),
                            Text(
                              item.artist ?? 'Unknown artist',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (state.processingState ==
                                    AudioProcessingState.loading ||
                                state.processingState ==
                                    AudioProcessingState.buffering)
                              const LinearProgressIndicator(minHeight: 2),
                            if (state.processingState ==
                                AudioProcessingState.error)
                              Text(
                                state.errorMessage ?? 'Playback failed',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: state.playing ? 'Pause' : 'Play',
                        icon: Icon(
                          state.playing ? Icons.pause : Icons.play_arrow,
                        ),
                        onPressed: () =>
                            state.playing ? handler.pause() : handler.play(),
                      ),
                      IconButton(
                        tooltip: 'Next',
                        icon: const Icon(Icons.skip_next),
                        onPressed: handler.skipToNext,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _MiniFallbackArt extends StatelessWidget {
  const _MiniFallbackArt();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.music_note),
    );
  }
}
