import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../../../core/errors/failures.dart';
import '../../domain/search_results.dart';
import '../../domain/track.dart';
import 'search_source.dart';

/// Primary search source: YouTube's own innertube search endpoint.
///
/// YouTube pages with an opaque `continuation` token that can only be replayed
/// by the exact list object that issued it, so the last few pages are kept in
/// memory long enough to serve "load more" without re-running the search.
class YoutubeSearchSource implements SearchSource {
  YoutubeSearchSource(YoutubeExplode youtube, {this.maxRetainedPages = 12})
    : _youtube = youtube;

  final YoutubeExplode _youtube;
  final int maxRetainedPages;

  final Map<String, VideoSearchList> _pages = <String, VideoSearchList>{};
  int _issued = 0;

  @override
  MediaSourceKind get kind => MediaSourceKind.youtube;

  @override
  String get label => 'YouTube';

  @override
  Future<SearchResults> search(
    String query, {
    String? continuation,
    SearchScope filter = SearchScope.songs,
  }) async {
    final VideoSearchList page;
    if (continuation == null) {
      page = await _guard(
        () => _youtube.search.search(
          _queryFor(query, filter),
          filter: _spFilterFor(filter),
        ),
      );
    } else {
      final previous = _pages[continuation];
      if (previous == null) {
        throw const InvalidStateFailure(
          'The YouTube results page expired, please search again',
        );
      }
      final next = await _guard<VideoSearchList?>(() => previous.nextPage());
      if (next == null || next.isEmpty) {
        return const SearchResults(tracks: [], source: MediaSourceKind.youtube);
      }
      page = next;
    }

    final tracks = page
        .map(_trackFrom)
        .nonNulls
        .where((track) => !track.isLive)
        .toList(growable: false);

    if (page.isEmpty) {
      return const SearchResults(tracks: [], source: MediaSourceKind.youtube);
    }

    final token = 'p${++_issued}';
    _pages[token] = page;
    while (_pages.length > maxRetainedPages) {
      _pages.remove(_pages.keys.first);
    }

    return SearchResults(tracks: tracks, source: kind, continuation: token);
  }

  /// Innertube has no "songs" type — its `sp` filter only distinguishes videos
  /// from channels/playlists — so the music slice is expressed by biasing the
  /// query instead, and the *video* slice is the one that uses a real `sp`
  /// filter. Songs additionally drop live streams below.
  static SearchFilter _spFilterFor(SearchScope filter) =>
      filter == SearchScope.videos ? TypeFilters.video : const SearchFilter('');

  /// YouTube's music search is the normal search with a music-leaning suffix.
  /// `official audio` biases toward the audio upload rather than a music video,
  /// which is what a listener actually wants from the "Songs" toggle.
  static String _queryFor(String query, SearchScope filter) =>
      filter == SearchScope.songs ? '$query official audio' : query;

  static Track? _trackFrom(Video video) {
    final id = video.id.value;
    if (id.isEmpty) return null;
    return Track(
      id: id,
      title: video.title,
      artist: video.author,
      duration: video.duration ?? Duration.zero,
      artworkUrl: video.thumbnails.maxResUrl,
      viewCount: video.engagement.viewCount,
      isLive: video.isLive,
      source: MediaSourceKind.youtube,
    );
  }

  Future<T> _guard<T>(Future<T> Function() request) async {
    try {
      return await request();
    } catch (error) {
      throw NetworkFailure(
        'YouTube search failed: $error',
        source: kind,
        cause: error,
      );
    }
  }
}
