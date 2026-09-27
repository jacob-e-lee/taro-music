import 'package:flutter/material.dart';

import '../../player/domain/track.dart';

/// One tappable search result: 56px artwork, title, artist, duration, and a
/// small chip showing which backend served it (useful while fallbacks exist).
class TrackTile extends StatelessWidget {
  const TrackTile({super.key, required this.track, required this.onTap});

  final Track track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        child: track.hasArtwork
            ? Image.network(
                track.artworkUrl!,
                width: 52,
                height: 52,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const _FallbackArt(size: 52),
              )
            : const _FallbackArt(size: 52),
      ),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${track.subtitle} · ${_format(track.duration)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Tooltip(
        message: track.isLive
            ? 'Live stream'
            : 'Served by ${track.source.name}',
        child: Icon(
          track.isLive ? Icons.radio : Icons.play_circle_outline,
          color: track.isLive
              ? Colors.redAccent
              : theme.colorScheme.onSurfaceVariant,
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
