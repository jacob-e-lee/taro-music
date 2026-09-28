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
  /// to page further. [filter] narrows results to songs or videos.
  Future<SearchResults> search(
    String query, {
    String? continuation,
    SearchScope filter = SearchScope.songs,
  });

  /// Resolves a playable stream for [track], trying every available source.
  Future<PlaybackSource> resolveSource(Track track);

  /// Reports that the player refused the stream just resolved for [track], so
  /// the next [resolveSource] rotates to a different source or instance.
  ///
  /// A stream that *verified* can still be refused at playback time - a probe
  /// gets 206 while the player's request gets a 403 - and without this the
  /// same dead URL is handed back on every subsequent attempt.
  void noteRefused(Track track);
}
