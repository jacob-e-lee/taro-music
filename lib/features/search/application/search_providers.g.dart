// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'search_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The query the user last submitted (as opposed to the text sitting in the
/// search box), so results survive rebuilds and can be re-fetched.

@ProviderFor(SearchQuery)
final searchQueryProvider = SearchQueryProvider._();

/// The query the user last submitted (as opposed to the text sitting in the
/// search box), so results survive rebuilds and can be re-fetched.
final class SearchQueryProvider extends $NotifierProvider<SearchQuery, String> {
  /// The query the user last submitted (as opposed to the text sitting in the
  /// search box), so results survive rebuilds and can be re-fetched.
  SearchQueryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'searchQueryProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$searchQueryHash();

  @$internal
  @override
  SearchQuery create() => SearchQuery();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(String value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<String>(value),
    );
  }
}

String _$searchQueryHash() => r'19e7363ad5e7986acdf867dd5e2fb1c8e8dfaa7f';

/// The query the user last submitted (as opposed to the text sitting in the
/// search box), so results survive rebuilds and can be re-fetched.

abstract class _$SearchQuery extends $Notifier<String> {
  String build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<String, String>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<String, String>,
              String,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// Which slice of the catalogue the user is searching (songs or videos).
///
/// Kept beside [SearchQuery] so flipping the toggle re-runs the current query
/// against the other filter instead of requiring a new search.
///
/// Named `...Filter` (rather than `SearchScope`) because the generated
/// provider class must not shadow the [SearchScope] enum it returns.

@ProviderFor(SearchScopeFilter)
final searchScopeFilterProvider = SearchScopeFilterProvider._();

/// Which slice of the catalogue the user is searching (songs or videos).
///
/// Kept beside [SearchQuery] so flipping the toggle re-runs the current query
/// against the other filter instead of requiring a new search.
///
/// Named `...Filter` (rather than `SearchScope`) because the generated
/// provider class must not shadow the [SearchScope] enum it returns.
final class SearchScopeFilterProvider
    extends $NotifierProvider<SearchScopeFilter, SearchScope> {
  /// Which slice of the catalogue the user is searching (songs or videos).
  ///
  /// Kept beside [SearchQuery] so flipping the toggle re-runs the current query
  /// against the other filter instead of requiring a new search.
  ///
  /// Named `...Filter` (rather than `SearchScope`) because the generated
  /// provider class must not shadow the [SearchScope] enum it returns.
  SearchScopeFilterProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'searchScopeFilterProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$searchScopeFilterHash();

  @$internal
  @override
  SearchScopeFilter create() => SearchScopeFilter();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(SearchScope value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<SearchScope>(value),
    );
  }
}

String _$searchScopeFilterHash() => r'5ee5979a65c0fc00f4e6c44b0c582491e7a95f2b';

/// Which slice of the catalogue the user is searching (songs or videos).
///
/// Kept beside [SearchQuery] so flipping the toggle re-runs the current query
/// against the other filter instead of requiring a new search.
///
/// Named `...Filter` (rather than `SearchScope`) because the generated
/// provider class must not shadow the [SearchScope] enum it returns.

abstract class _$SearchScopeFilter extends $Notifier<SearchScope> {
  SearchScope build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<SearchScope, SearchScope>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<SearchScope, SearchScope>,
              SearchScope,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// One page-set of search results per [query] and [scope], plus cursor pagination.
///
/// Pagination is deliberately *not* modelled as a new provider state per page:
/// `loadMore` appends into the same [SearchResults] so the list never rebuilds
/// from scratch and the scroll position is preserved.

@ProviderFor(Search)
final searchProvider = SearchFamily._();

/// One page-set of search results per [query] and [scope], plus cursor pagination.
///
/// Pagination is deliberately *not* modelled as a new provider state per page:
/// `loadMore` appends into the same [SearchResults] so the list never rebuilds
/// from scratch and the scroll position is preserved.
final class SearchProvider
    extends $AsyncNotifierProvider<Search, SearchResults> {
  /// One page-set of search results per [query] and [scope], plus cursor pagination.
  ///
  /// Pagination is deliberately *not* modelled as a new provider state per page:
  /// `loadMore` appends into the same [SearchResults] so the list never rebuilds
  /// from scratch and the scroll position is preserved.
  SearchProvider._({
    required SearchFamily super.from,
    required (String, SearchScope) super.argument,
  }) : super(
         retry: null,
         name: r'searchProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$searchHash();

  @override
  String toString() {
    return r'searchProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  Search create() => Search();

  @override
  bool operator ==(Object other) {
    return other is SearchProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$searchHash() => r'a4a510eaa505596e1f8de204d43dfe651fcf747f';

/// One page-set of search results per [query] and [scope], plus cursor pagination.
///
/// Pagination is deliberately *not* modelled as a new provider state per page:
/// `loadMore` appends into the same [SearchResults] so the list never rebuilds
/// from scratch and the scroll position is preserved.

final class SearchFamily extends $Family
    with
        $ClassFamilyOverride<
          Search,
          AsyncValue<SearchResults>,
          SearchResults,
          FutureOr<SearchResults>,
          (String, SearchScope)
        > {
  SearchFamily._()
    : super(
        retry: null,
        name: r'searchProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// One page-set of search results per [query] and [scope], plus cursor pagination.
  ///
  /// Pagination is deliberately *not* modelled as a new provider state per page:
  /// `loadMore` appends into the same [SearchResults] so the list never rebuilds
  /// from scratch and the scroll position is preserved.

  SearchProvider call(String query, SearchScope scope) =>
      SearchProvider._(argument: (query, scope), from: this);

  @override
  String toString() => r'searchProvider';
}

/// One page-set of search results per [query] and [scope], plus cursor pagination.
///
/// Pagination is deliberately *not* modelled as a new provider state per page:
/// `loadMore` appends into the same [SearchResults] so the list never rebuilds
/// from scratch and the scroll position is preserved.

abstract class _$Search extends $AsyncNotifier<SearchResults> {
  late final _$args = ref.$arg as (String, SearchScope);
  String get query => _$args.$1;
  SearchScope get scope => _$args.$2;

  FutureOr<SearchResults> build(String query, SearchScope scope);
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<SearchResults>, SearchResults>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<SearchResults>, SearchResults>,
              AsyncValue<SearchResults>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, () => build(_$args.$1, _$args.$2));
  }
}
