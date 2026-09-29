import '../../../../core/errors/failures.dart';
import '../../domain/search_results.dart';

/// A provider that can turn a text query into playable [Track]s.
///
/// Implementations throw a [TaroFailure] on failure; the repository layer is
/// responsible for falling back to the next source.
abstract interface class SearchSource {
  MediaSourceKind get kind;
  String get label;

  /// Whether this source can answer [scope] at all. The repository filters on
  /// this *before* trying a source, so a refusal here silently skips the
  /// source instead of surfacing as a failed attempt.
  ///
  /// Catalogue sources are scope-bound (YouTube Music only knows songs), while
  /// proxy sources answer every scope; the default keeps existing sources
  /// working unchanged.
  bool supportsScope(SearchScope scope) => true;

  /// Fetches one page of results. [continuation] is an *untagged* token
  /// previously returned inside [SearchResults.continuation]; pass null for the
  /// first page. [filter] selects the songs/videos slice of the catalogue.
  Future<SearchResults> search(
    String query, {
    String? continuation,
    SearchScope filter = SearchScope.songs,
  });
}
