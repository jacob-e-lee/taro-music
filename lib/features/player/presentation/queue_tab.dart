import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

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
              return const Center(child: Text('Queue is empty'));
            }

            // A box, not a bare sliver: this lives inside a Column, and it
            // scrolls on its own controller so queue scrolling never competes
            // with the player's dismiss gesture.
            return CustomScrollView(
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
      // The "now playing" highlight lives on the ListTile itself: wrapping it
      // in a decorated Container would hide the tile's ink splashes.
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
            // Delayed (long-press) rather than immediate: the queue scrolls
            // vertically, and an immediate handle would hijack every swipe.
            ReorderableDelayedDragStartListener(
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
    );
  }
}
