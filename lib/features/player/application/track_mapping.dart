import 'package:audio_service/audio_service.dart';

import '../domain/track.dart';

/// Translation between the app's [Track] and audio_service's `MediaItem`.
///
/// The whole [Track] travels inside `MediaItem.extras`, so the queue survives a
/// round trip through Android's media session (and a process restart) without
/// needing a database.
extension TrackMediaItem on Track {
  MediaItem toMediaItem() => MediaItem(
    id: id,
    title: title,
    artist: artist.isEmpty ? null : artist,
    album: album,
    duration: duration,
    artUri: hasArtwork ? Uri.tryParse(artworkUrl!) : null,
    playable: !isLive,
    isLive: isLive,
    extras: toExtras(),
  );

  static Track? fromMediaItem(MediaItem? item) =>
      item == null ? null : Track.fromExtras(item.extras);
}
