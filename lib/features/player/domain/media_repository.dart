import './playback_source.dart';
import './search_results.dart';
import './track.dart';

/// Everything the rest of the app needs from the outside world.
///
/// Deliberately tiny and async-only: the UI and the audio handler both talk to
/// this interface and never to a concrete provider, which is what makes the
/// YouTube -> Piped fallback invisible everywhere else.
abstract interface class MediaRepository {
  /// One page of results for [query]; pass [continuation] from a previous page
  /// to page further.
  Future<SearchResults> search(String query, {String? continuation});

  /// Resolves a playable stream for [track], trying every available source.
  Future<PlaybackSource> resolveSource(Track track);
}
