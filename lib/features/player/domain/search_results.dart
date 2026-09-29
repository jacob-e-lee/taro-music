import '../../../core/errors/failures.dart';
import 'track.dart';

/// Which kind of result the user is searching for.
///
/// This is a *presentation* choice that decides which providers are asked, not
/// a different query against the same source: songs are served by the YouTube
/// Music catalogue (with Piped's `music_songs` as fallback), videos by regular
/// YouTube search (with Piped's `music_videos` as fallback). It is threaded
/// all the way down to [SearchSource] rather than being filtered client-side.
enum SearchScope {
  songs('Songs', 'music_songs'),
  videos('Videos', 'music_videos');

  const SearchScope(this.label, this.pipedValue);

  /// Text shown on the toggle.
  final String label;

  /// The value Piped's `/search` endpoint expects in its `filter` param.
  final String pipedValue;
}

/// One page of search results plus the cursor needed to fetch the next one.
///
/// [continuation] is an *opaque, source-tagged* token (`yt:`/`piped:` prefix).
/// Tagging it means "load more" goes straight back to the provider that
/// produced the page instead of re-trying the whole fallback chain on every
/// scroll.
class SearchResults {
  const SearchResults({
    required this.tracks,
    required this.source,
    this.continuation,
  });

  final List<Track> tracks;
  final MediaSourceKind source;
  final String? continuation;

  bool get hasMore => continuation != null && continuation!.isNotEmpty;

  @override
  String toString() =>
      'SearchResults(${tracks.length} tracks from ${source.name}, '
      '${hasMore ? 'more available' : 'last page'})';
}

/// Encodes the source into the continuation token.
String tagContinuation(MediaSourceKind source, String token) =>
    '${source.name}:$token';

/// Returns the provider a continuation token belongs to, or null when the
/// token is not one we issued.
MediaSourceKind? continuationSource(String? continuation) {
  if (continuation == null) return null;
  final separator = continuation.indexOf(':');
  if (separator <= 0) return null;
  final prefix = continuation.substring(0, separator);
  for (final kind in MediaSourceKind.values) {
    if (kind.name == prefix) return kind;
  }
  return null;
}

/// Strips the source tag before handing the token back to the provider.
String untagContinuation(String continuation) {
  final separator = continuation.indexOf(':');
  return separator < 0 ? continuation : continuation.substring(separator + 1);
}

/// YouTube reports search durations as `HH:MM:SS` / `MM:SS`, Piped as seconds.
Duration parseDurationSeconds(num? seconds) =>
    Duration(seconds: (seconds ?? 0).round());

Duration? parseClockDuration(String? text) {
  if (text == null || text.trim().isEmpty) return null;
  final parts = text.trim().split(':');
  if (parts.isEmpty || parts.length > 3) return null;
  var minutes = 0, seconds = 0, hours = 0;
  try {
    switch (parts.length) {
      case 1:
        seconds = int.parse(parts[0]);
      case 2:
        minutes = int.parse(parts[0]);
        seconds = int.parse(parts[1]);
      case 3:
        hours = int.parse(parts[0]);
        minutes = int.parse(parts[1]);
        seconds = int.parse(parts[2]);
      default:
        return null;
    }
  } on FormatException {
    return null;
  }
  return Duration(hours: hours, minutes: minutes, seconds: seconds);
}
