import '../../../../core/errors/failures.dart';
import '../../domain/search_results.dart';

/// A provider that can turn a text query into playable [Track]s.
///
/// Implementations throw a [TaroFailure] on failure; the repository layer is
/// responsible for falling back to the next source.
abstract interface class SearchSource {
  MediaSourceKind get kind;
  String get label;

  /// Fetches one page of results. [continuation] is an *untagged* token
  /// previously returned inside [SearchResults.continuation]; pass null for the
  /// first page.
  Future<SearchResults> search(String query, {String? continuation});
}
