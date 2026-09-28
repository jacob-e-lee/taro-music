import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/providers.dart';
import '../domain/track.dart';
import 'player_sheet_controller.dart';

/// The slim bar pinned above the bottom edge, bound to the handler's streams.
/// Hidden until the first track is loaded.
///
/// The bar never presents the player itself: it only pushes the finger position
/// into [sheetController], which the shell renders as a persistent layer. That
/// is what makes an upward drag feel continuous - the real player grows with the
/// finger instead of appearing once the finger has lifted.
class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key, required this.sheetController});

  /// The persistent player sheet this bar expands into.
  final PlayerSheetController sheetController;

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer> {
  // Optimistic playing state so the button flips with zero visual latency,
  // even while the audio buffer is still loading in the background.
  bool? _optimisticPlaying;

  /// How far the drag has pulled the player up, as a fraction of the screen.
  /// Seeded from the controller so a drag that interrupts a running animation
  /// continues from wherever the player actually is.
  double _progress = 0;

  double _screenHeight = 1;

  /// Release past this much travel springs the player fully open; below it the
  /// player springs back into the bar. Kept small because the player reveals
  /// itself faster than the finger moves, so a short swipe is a deliberate
  /// intent to open rather than a stray nudge.
  static const double _kOpenThreshold = 0.08;

  /// An upward fling always opens, even from a short drag.
  static const double _kFlingVelocity = -400;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _screenHeight = MediaQuery.sizeOf(context).height;
  }

  void _onVerticalDragStart(DragStartDetails details) {
    _progress = widget.sheetController.size;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (details.delta.dy >= 0) return; // only react to upward drags
    if (_screenHeight <= 0) return;
    setState(() {
      _progress = (_progress - (details.delta.dy / _screenHeight)).clamp(
        0.0,
        widget.sheetController.maxSize,
      );
    });
    // Written straight into the sheet extent every frame: no animation and no
    // route, so the player's top edge stays glued to the finger.
    widget.sheetController.dragTo(_progress);
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldOpen =
        _progress >= _kOpenThreshold || velocity <= _kFlingVelocity;
    setState(() => _progress = 0);
    if (shouldOpen) {
      widget.sheetController.open();
    } else {
      widget.sheetController.close();
    }
  }

  void _onVerticalDragCancel() {
    // A tap (rather than a drag) also produces a drag-cancel. Only spring
    // back if a drag had actually started, otherwise this would close the
    // player that the tap is in the middle of opening.
    if (_progress <= 0) return;
    setState(() => _progress = 0);
    widget.sheetController.close();
  }

  /// Tap (or accessibility activation) still opens the player, just without a
  /// drag in front of it.
  void _openFromTap() {
    setState(() => _progress = 0);
    widget.sheetController.open();
  }

  @override
  Widget build(BuildContext context) {
    final handler = ref.watch(audioHandlerProvider);
    final theme = Theme.of(context);

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
            final isPlaying = _optimisticPlaying ?? state.playing;
            if (_optimisticPlaying != null &&
                _optimisticPlaying == state.playing) {
              _optimisticPlaying = null;
            }
            final busy =
                state.processingState == AudioProcessingState.loading ||
                state.processingState == AudioProcessingState.buffering;
            final isOffline =
                Track.fromExtras(item.extras)?.isDownloaded ?? false;

            return Semantics(
              container: true,
              label:
                  'Now playing: ${item.title} by '
                  '${item.artist ?? "Unknown artist"}. '
                  'Tap or swipe up to expand player.',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: _onVerticalDragStart,
                onVerticalDragUpdate: _onVerticalDragUpdate,
                onVerticalDragEnd: _onVerticalDragEnd,
                onVerticalDragCancel: _onVerticalDragCancel,
                // The bar rides the finger 1:1 and dissolves into the player
                // that is rising behind it, so the hand-off reads as one
                // surface changing rather than the bar blinking out of
                // existence. Opacity is intentionally *not* applied here: the
                // shell fades the whole bottom chrome so the navigation bar
                // cross-fades with it in one step.
                child: Transform.translate(
                  offset: Offset(
                    0,
                    -widget.sheetController.dragFraction * _screenHeight,
                  ),
                  child: Material(
                    elevation: 4,
                    color: theme.colorScheme.surfaceContainerHigh,
                    child: SafeArea(
                      top: false,
                      bottom: false,
                      child: InkWell(
                        onTap: _openFromTap,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: Row(
                            children: <Widget>[
                              _MiniArt(
                                artUri: item.artUri,
                                isOffline: isOffline,
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
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                    if (busy)
                                      const LinearProgressIndicator(
                                        minHeight: 2,
                                      ),
                                    if (state.processingState ==
                                        AudioProcessingState.error)
                                      Text(
                                        state.errorMessage ?? 'Playback failed',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme.colorScheme.error,
                                            ),
                                      ),
                                  ],
                                ),
                              ),
                              Semantics(
                                button: true,
                                label: isPlaying ? 'Pause track' : 'Play track',
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: IconButton(
                                    constraints: const BoxConstraints(
                                      minWidth: 48,
                                      minHeight: 48,
                                    ),
                                    tooltip: isPlaying ? 'Pause' : 'Play',
                                    icon: Icon(
                                      isPlaying
                                          ? Icons.pause
                                          : Icons.play_arrow,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        _optimisticPlaying = !isPlaying;
                                      });
                                      if (isPlaying) {
                                        handler.pause();
                                      } else {
                                        handler.play();
                                      }
                                    },
                                  ),
                                ),
                              ),
                              Semantics(
                                button: true,
                                label: 'Skip to next track',
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: IconButton(
                                    constraints: const BoxConstraints(
                                      minWidth: 48,
                                      minHeight: 48,
                                    ),
                                    tooltip: 'Next track',
                                    icon: const Icon(Icons.skip_next, size: 28),
                                    onPressed: handler.skipToNext,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
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

/// Artwork with an offline (downloaded) badge in the corner.
class _MiniArt extends StatelessWidget {
  const _MiniArt({required this.artUri, required this.isOffline});

  final Uri? artUri;
  final bool isOffline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(6)),
          child: artUri != null
              ? Image.network(
                  artUri.toString(),
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const _MiniFallbackArt(),
                )
              : const _MiniFallbackArt(),
        ),
        if (isOffline)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check,
                size: 12,
                color: theme.colorScheme.onPrimary,
              ),
            ),
          ),
      ],
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
