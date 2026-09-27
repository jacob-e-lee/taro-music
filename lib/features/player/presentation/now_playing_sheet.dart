import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/audio_handler.dart';
import '../application/providers.dart';

/// Full-screen-ish player sheet: artwork, title, seek bar, transport controls
/// and repeat/shuffle toggles, all bound to the handler streams.
class NowPlayingSheet extends ConsumerWidget {
  const NowPlayingSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.watch(audioHandlerProvider);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (context, scrollController) => StreamBuilder<MediaItem?>(
        stream: handler.mediaItem,
        builder: (context, itemSnapshot) {
          final item = itemSnapshot.data;
          if (item == null) {
            return const Center(child: Text('Nothing playing'));
          }
          return ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
            children: <Widget>[
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Center(
                child: ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                  child: item.artUri != null
                      ? Image.network(
                          item.artUri.toString(),
                          width: 280,
                          height: 280,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              const _NowPlayingFallbackArt(),
                        )
                      : const _NowPlayingFallbackArt(),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                item.title,
                style: Theme.of(context).textTheme.headlineSmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                item.artist ?? 'Unknown artist',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              _SeekBar(handler: handler),
              const SizedBox(height: 8),
              _TransportControls(handler: handler),
              const SizedBox(height: 8),
              _ModeToggles(handler: handler),
            ],
          );
        },
      ),
    );
  }
}

class _SeekBar extends StatelessWidget {
  const _SeekBar({required this.handler});

  final MusicAudioHandler handler;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return StreamBuilder<Duration?>(
      stream: handler.durationStream,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? Duration.zero;
        final maxMs = duration.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: handler.positionStream,
          initialData: Duration.zero,
          builder: (context, positionSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
            final value = position.inMilliseconds
                .toDouble()
                .clamp(0, maxMs <= 0 ? 1 : maxMs)
                .toDouble();
            return Column(
              children: <Widget>[
                Slider(
                  min: 0,
                  max: maxMs <= 0 ? 1 : maxMs,
                  value: value,
                  onChanged: duration == Duration.zero
                      ? null
                      : (v) => handler.seek(Duration(milliseconds: v.round())),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text(_clock(position), style: style),
                    Text(_clock(duration), style: style),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _TransportControls extends StatelessWidget {
  const _TransportControls({required this.handler});

  final MusicAudioHandler handler;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      initialData: handler.playbackState.value,
      builder: (context, snapshot) {
        final state = snapshot.data ?? handler.playbackState.value;
        final busy =
            state.processingState == AudioProcessingState.loading ||
            state.processingState == AudioProcessingState.buffering;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            IconButton.filledTonal(
              tooltip: 'Previous',
              iconSize: 32,
              icon: const Icon(Icons.skip_previous),
              onPressed: handler.skipToPrevious,
            ),
            const SizedBox(width: 16),
            IconButton.filled(
              tooltip: state.playing ? 'Pause' : 'Play',
              iconSize: 40,
              icon: busy
                  ? const SizedBox.square(
                      dimension: 32,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    )
                  : Icon(state.playing ? Icons.pause : Icons.play_arrow),
              onPressed: () => state.playing ? handler.pause() : handler.play(),
            ),
            const SizedBox(width: 16),
            IconButton.filledTonal(
              tooltip: 'Next',
              iconSize: 32,
              icon: const Icon(Icons.skip_next),
              onPressed: handler.skipToNext,
            ),
          ],
        );
      },
    );
  }
}

class _ModeToggles extends StatelessWidget {
  const _ModeToggles({required this.handler});

  final MusicAudioHandler handler;

  @override
  Widget build(BuildContext context) {
    final active = Theme.of(context).colorScheme.primary;
    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      initialData: handler.playbackState.value,
      builder: (context, snapshot) {
        final state = snapshot.data ?? handler.playbackState.value;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            IconButton(
              tooltip: 'Shuffle',
              color: state.shuffleMode == AudioServiceShuffleMode.all
                  ? active
                  : null,
              icon: const Icon(Icons.shuffle),
              onPressed: () => handler.setShuffleMode(
                state.shuffleMode == AudioServiceShuffleMode.all
                    ? AudioServiceShuffleMode.none
                    : AudioServiceShuffleMode.all,
              ),
            ),
            IconButton(
              tooltip: 'Repeat: ${state.repeatMode.name}',
              color: state.repeatMode == AudioServiceRepeatMode.none
                  ? null
                  : active,
              icon: Icon(
                state.repeatMode == AudioServiceRepeatMode.one
                    ? Icons.repeat_one
                    : Icons.repeat,
              ),
              onPressed: () => handler.setRepeatMode(switch (state.repeatMode) {
                AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
                AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
                _ => AudioServiceRepeatMode.none,
              }),
            ),
            IconButton(
              tooltip: 'Stop',
              icon: const Icon(Icons.stop),
              onPressed: handler.stop,
            ),
          ],
        );
      },
    );
  }
}

String _clock(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class _NowPlayingFallbackArt extends StatelessWidget {
  const _NowPlayingFallbackArt();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 280,
      height: 280,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.music_note, size: 120),
    );
  }
}
