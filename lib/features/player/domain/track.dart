import 'package:flutter/foundation.dart';

import '../../../core/errors/failures.dart';

/// One playable thing: a song, a video, a live stream.
///
/// This is the app's own vocabulary; it is what the UI, the queue and the
/// database all speak, and it deliberately knows nothing about *how* to play
/// the item. Resolving a [Track] into an actual URL is the job of
/// `StreamExtractor`.
@immutable
class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.source,
    this.duration = Duration.zero,
    this.artworkUrl,
    this.album,
    this.viewCount,
    this.isLive = false,
  });

  /// Stable identity: the YouTube `videoId`, which is common to every source,
  /// so the same song found through YouTube and through Piped collapses to one
  /// track and survives re-opening the app.
  final String id;

  final String title;
  final String artist;
  final String? album;

  /// [Duration.zero] when the provider did not report a length (typical for
  /// live streams), which the UI renders as "live" rather than `0:00`.
  final Duration duration;

  final String? artworkUrl;
  final int? viewCount;
  final bool isLive;

  /// Which provider surfaced this track. Used as a *hint*: it is the preferred
  /// extractor for this item, but a failure still falls through to the others.
  final MediaSourceKind source;

  bool get hasArtwork => artworkUrl != null && artworkUrl!.isNotEmpty;

  bool get isLiveOrUnknownLength => isLive || duration == Duration.zero;

  /// `"Artist — Title"`, used by the media notification and the mini player.
  String get subtitle => artist.isEmpty ? 'Unknown artist' : artist;

  Track copyWith({
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    String? artworkUrl,
    int? viewCount,
    bool? isLive,
    MediaSourceKind? source,
  }) => Track(
    id: id,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    duration: duration ?? this.duration,
    artworkUrl: artworkUrl ?? this.artworkUrl,
    viewCount: viewCount ?? this.viewCount,
    isLive: isLive ?? this.isLive,
    source: source ?? this.source,
  );

  /// Flattens the track into the primitive map that `MediaItem.extras` accepts
  /// (`int`, `String`, `bool`, `double` only) so the queue can survive a trip
  /// through the platform media session.
  Map<String, dynamic> toExtras() => <String, dynamic>{
    'id': id,
    'title': title,
    'artist': artist,
    if (album != null) 'album': album,
    'durationMs': duration.inMilliseconds,
    if (artworkUrl != null) 'artworkUrl': artworkUrl,
    if (viewCount != null) 'viewCount': viewCount,
    'isLive': isLive,
    'source': source.name,
  };

  static Track? fromExtras(Map<String, dynamic>? extras) {
    if (extras == null) return null;
    final id = extras['id'];
    if (id is! String || id.isEmpty) return null;
    final sourceName = extras['source'];
    return Track(
      id: id,
      title: (extras['title'] as String?) ?? 'Unknown title',
      artist: (extras['artist'] as String?) ?? '',
      album: extras['album'] as String?,
      duration: Duration(milliseconds: (extras['durationMs'] as int?) ?? 0),
      artworkUrl: extras['artworkUrl'] as String?,
      viewCount: extras['viewCount'] as int?,
      isLive: (extras['isLive'] as bool?) ?? false,
      source: MediaSourceKind.values.firstWhere(
        (s) => s.name == sourceName,
        orElse: () => MediaSourceKind.youtube,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Track &&
          other.id == id &&
          other.title == title &&
          other.artist == artist &&
          other.album == album &&
          other.duration == duration &&
          other.artworkUrl == artworkUrl &&
          other.viewCount == viewCount &&
          other.isLive == isLive &&
          other.source == source;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    artist,
    album,
    duration,
    artworkUrl,
    viewCount,
    isLive,
    source,
  );

  @override
  String toString() => 'Track($id, $title, $artist)';
}
