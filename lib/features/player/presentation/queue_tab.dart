import 'package:audio_service/audio_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/webview_audio_handler.dart';
import '../domain/track.dart';

/// The "Up Next" queue, rendered as a **sliver** rather than a box widget.
///
/// This is the performance fix for the player feeling laggy: as a regular child
/// of the player's scroll view the queue had to build every one of its rows on
/// every frame the sheet was resized, which is exactly what happens while the
/// user drags the player up. As a [SliverReorderableList] the rows are built
/// lazily, so dragging the player costs nothing until the queue is actually
/// scrolled into view - while still being reachable by scrolling down, and
/// still fully drag-to-reorderable.
class QueueTab extends StatelessWidget {
  const QueueTab({super.key, required this.handler});

  final WebViewAudioHandler handler;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<List<MediaItem>>(
      stream: handler.queue,
      initialData: handler.queue.value,
      builder: (context, queueSnapshot) {
        final queue = queueSnapshot.data ?? handler.queue.value;
        return StreamBuilder<PlaybackState>(
          stream: handler.playbackState,
          initialData: handler.playbackState.value,
          builder: (context, stateSnapshot) {
            final state = stateSnapshot.data ?? handler.playbackState.value;
            final currentIndex = state.queueIndex ?? 0;

            if (queue.isEmpty) {
              // Still a scroll view, and an always-draggable one: the panel
              // closes from a swipe-down at the top of its body, and this
              // empty state has no scrollable content to be at the top of -
              // the drag must still reach a scroll view to report the
              // under-scroll the gesture is read from.
              return CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: <Widget>[
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: const Center(child: Text('Queue is empty')),
                  ),
                ],
              );
            }

            // A box, not a bare sliver: this lives inside a Column, and it
            // scrolls on its own controller so queue scrolling never competes
            // with the player's dismiss gesture.
            //
            // Always-draggable even when the queue does not overflow: the
            // swipe-down-to-leave-panel gesture is this view reporting an
            // under-scroll at its top, and a short queue would otherwise
            // reject the drag outright.
            return CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: <Widget>[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 8, 28, 4),
                    child: Text(
                      'Up Next (${queue.length} tracks)',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                  sliver: SliverReorderableList(
                    itemCount: queue.length,
                    // ignore: deprecated_member_use
                    onReorder: (oldIndex, newIndex) {
                      handler.reorderQueue(oldIndex, newIndex);
                    },
                    // Confirms the drag has actually started. Without it the
                    // long press, the drag and the reorder all happen with no
                    // feedback at all, so a hold that is not quite long enough
                    // looks exactly like one that is.
                    onReorderStart: (index) => HapticFeedback.selectionClick(),
                    proxyDecorator: _dragProxy,
                    itemBuilder: (context, index) => _QueueRow(
                      key: ValueKey<String>('queue_${queue[index].id}_$index'),
                      index: index,
                      item: queue[index],
                      isPlayingThis: index == currentIndex,
                      handler: handler,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// A [ReorderableDragStartListener] that starts on the first movement instead of
/// waiting out the touch slop.
///
/// The default [ImmediateMultiDragGestureRecognizer] only resolves the gesture
/// once the pointer has moved further than the platform touch slop (18dp on
/// Android). The player panel puts a [RawGestureDetector] above this list whose
/// pull-to-close recognizer accepts a vertical drag after 8dp, so the panel won
/// that contest and the handle never started a drag at all. Lowering the
/// threshold below the panel's is what makes the handle win.
class _ImmediateReorderHandle extends ReorderableDragStartListener {
  const _ImmediateReorderHandle({required super.index, required super.child});

  @override
  MultiDragGestureRecognizer createRecognizer() =>
      _EagerMultiDragGestureRecognizer(debugOwner: this);
}

/// [ImmediateMultiDragGestureRecognizer] with the touch slop lowered.
class _EagerMultiDragGestureRecognizer
    extends ImmediateMultiDragGestureRecognizer {
  _EagerMultiDragGestureRecognizer({super.debugOwner});

  /// Comfortably under the panel's 8dp accept threshold, but still a real
  /// movement rather than zero: accepting on the down event itself would turn a
  /// tap on the handle into a drag.
  static const double _acceptPx = 2;

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _EagerPointerState(event.position, event.kind, null);
}

class _EagerPointerState extends MultiDragPointerState {
  _EagerPointerState(super.initialPosition, super.kind, super.gestureSettings);

  @override
  void checkForResolutionAfterMove() {
    assert(pendingDelta != null);
    if (pendingDelta!.distance > _EagerMultiDragGestureRecognizer._acceptPx) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    starter(initialPosition);
  }
}

/// Wraps the row being dragged so it survives being lifted out of the list.
///
/// A reorderable list moves the dragged row into the nearest [Overlay], which
/// is the navigator's - and the navigator's overlay sits *above* the player's
/// own `Material`, not inside it. So the row arrives with no material ancestor,
/// and its `ListTile` - which paints its ink splashes on a material surface -
/// threw "No Material widget found" the instant a drag began. Putting the
/// material back here is the fix, and it has to be here rather than further up
/// the tree: the widget that lands in the overlay is exactly the one this
/// returns.
///
/// Transparent rather than a surface colour, so the row keeps its own
/// background; the elevation is what makes the lifted row read as picked up
/// rather than as a gap in the list.
Widget _dragProxy(Widget child, int index, Animation<double> animation) =>
    Material(
      elevation: 6,
      color: Colors.transparent,
      borderRadius: BorderRadius.zero,
      child: child,
    );

/// One row of the queue. Split out so the sliver can build and discard it.
class _QueueRow extends StatelessWidget {
  const _QueueRow({
    super.key,
    required this.index,
    required this.item,
    required this.isPlayingThis,
    required this.handler,
  });

  final int index;
  final MediaItem item;
  final bool isPlayingThis;
  final WebViewAudioHandler handler;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final track = Track.fromExtras(item.extras);
    final isOffline = track?.isDownloaded ?? false;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      // The whole row is a long-press drag target, not just the handle. A
      // delayed start rather than an immediate one, because the queue scrolls
      // vertically and the row's own area is where scrolling happens - an
      // immediate listener here would swallow every swipe that began over a
      // row, and the row is most of the list.
      //
      // The handle *inside* this is immediate (see below), so a user who reaches
      // for the grip gets a drag straight away and one who long-presses
      // anywhere else on the row gets the same result a beat later.
      child: ReorderableDelayedDragStartListener(
        index: index,
        child: ListTile(
          dense: true,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
          selected: isPlayingThis,
          selectedTileColor: theme.colorScheme.primaryContainer.withValues(
            alpha: 0.3,
          ),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // Immediate, unlike the row around it. The threshold is lowered
              // rather than left at the default touch slop because of a real
              // conflict: the panel's own pull-to-close recognizer sits above
              // this list and claims a vertical drag at 8px, while the default
              // slop is 18px. So the default lost the gesture arena every time
              // and the handle simply did not drag.
              //
              // A delayed handle dodged this only by accident: it never resolves
              // on its own, so it was still in the arena at sweep time and won by
              // being the deepest member. It could not have won a contested
              // accept.
              _ImmediateReorderHandle(
                index: index,
                child: Semantics(
                  button: true,
                  label: 'Reorder ${item.title}',
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    child: Icon(
                      Icons.drag_handle,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: item.artUri != null
                    ? Image.network(
                        item.artUri.toString(),
                        width: 36,
                        height: 36,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.music_note, size: 20),
                      )
                    : const Icon(Icons.music_note, size: 20),
              ),
            ],
          ),
          title: Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: isPlayingThis ? FontWeight.bold : FontWeight.normal,
              color: isPlayingThis
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
            ),
          ),
          subtitle: Row(
            children: <Widget>[
              if (isOffline) ...<Widget>[
                Icon(
                  Icons.offline_pin,
                  size: 12,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  item.artist ?? 'Unknown artist',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          trailing: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            child: IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Remove from queue',
              onPressed: () => handler.removeTrackAt(index),
            ),
          ),
          onTap: () => handler.skipToQueueItem(index),
        ),
      ),
    );
  }
}
