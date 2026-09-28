import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../player/application/providers.dart';
import '../../player/domain/search_results.dart';
import '../../player/domain/track.dart';

part 'search_providers.g.dart';

/// The query the user last submitted (as opposed to the text sitting in the
/// search box), so results survive rebuilds and can be re-fetched.
@riverpod
class SearchQuery extends _$SearchQuery {
  @override
  String build() => '';

  void update(String value) {
    final trimmed = value.trim();
    if (trimmed == state) return;
    state = trimmed;
  }

  void clear() => state = '';
}

/// Which slice of the catalogue the user is searching (songs or videos).
///
/// Kept beside [SearchQuery] so flipping the toggle re-runs the current query
/// against the other filter instead of requiring a new search.
///
/// Named `...Filter` (rather than `SearchScope`) because the generated
/// provider class must not shadow the [SearchScope] enum it returns.
@riverpod
class SearchScopeFilter extends _$SearchScopeFilter {
  @override
  SearchScope build() => SearchScope.songs;

  void select(SearchScope value) {
    if (value == state) return;
    state = value;
  }
}

/// One page-set of search results per [query] and [scope], plus cursor pagination.
///
/// Pagination is deliberately *not* modelled as a new provider state per page:
/// `loadMore` appends into the same [SearchResults] so the list never rebuilds
/// from scratch and the scroll position is preserved.
@riverpod
class Search extends _$Search {
  bool _loadingMore = false;

  @override
  Future<SearchResults> build(String query, SearchScope scope) {
    _loadingMore = false;
    return ref.watch(mediaRepositoryProvider).search(query, filter: scope);
  }

  /// Fetches the next page and appends it.
  ///
  /// Failures are rethrown instead of being pushed into [state]: a broken
  /// "load more" must not wipe the results already on screen. The caller shows
  /// a snack bar and the user can try again.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore) return;
    if (_loadingMore) return;

    _loadingMore = true;
    try {
      final next = await ref
          .read(mediaRepositoryProvider)
          .search(query, continuation: current.continuation, filter: scope);
      state = AsyncData(
        SearchResults(
          tracks: <Track>[...current.tracks, ...next.tracks],
          source: current.source,
          continuation: next.continuation,
        ),
      );
    } finally {
      _loadingMore = false;
    }
  }
}
