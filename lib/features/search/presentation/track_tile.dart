import 'package:flutter/material.dart';

import '../../../core/artwork/resilient_artwork.dart';
import '../../player/domain/track.dart';

/// One tappable search result: 56px artwork, title, artist, duration, offline
/// indicator badge, and a small chip showing which backend served it.
class TrackTile extends StatelessWidget {
  const TrackTile({super.key, required this.track, required this.onTap});

  final Track track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label:
          'Play ${track.title} by ${track.subtitle}${track.isDownloaded ? ", downloaded offline" : ""}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: ListTile(
          onTap: onTap,
          leading: Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(6)),
                child: ResilientArtwork(
                  url: track.artworkUrl,
                  width: 52,
                  height: 52,
                  fallback: const _FallbackArt(size: 52),
                ),
              ),
              if (track.isDownloaded)
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
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          subtitle: Row(
            children: [
              if (track.isDownloaded) ...[
                Icon(
                  Icons.offline_pin,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  '${track.subtitle} · ${_format(track.duration)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          trailing: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Tooltip(
              message: track.isLive
                  ? 'Live stream'
                  : 'Served by ${track.source.name}',
              child: Icon(
                track.isLive ? Icons.radio : Icons.play_circle_outline,
                size: 26,
                color: track.isLive
                    ? Colors.redAccent
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _format(Duration duration) {
  if (duration == Duration.zero) return 'live';
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class _FallbackArt extends StatelessWidget {
  const _FallbackArt({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.music_note,
        size: size * 0.5,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
