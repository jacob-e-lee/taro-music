import 'package:dio/dio.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/errors/failures.dart';
import '../../domain/search_results.dart';
import '../../domain/track.dart';
import 'search_source.dart';

/// Fallback search source: a Piped instance's `/search` endpoint filtered to
/// `music_songs` or `music_videos`, which returns only playable tracks (no
/// channels, no playlists, no vlog noise).
///
/// Like [PipedExtractor] it rotates to the next instance on every network
/// failure, so a dead mirror costs one attempt rather than the whole search.
class PipedSearchSource implements SearchSource {
  PipedSearchSource(
    this._dio, {
    this.instances = AppConfig.pipedInstances,
    this.filter = AppConfig.pipedSearchFilter,
  }) : assert(instances.isNotEmpty, 'at least one Piped instance is required');

  final Dio _dio;
  final List<String> instances;

  /// Fallback filter used when a caller does not specify one, so this source
  /// keeps working as a plain `music_songs` provider outside the search UI.
  final String filter;

  int _cursor = 0;

  @override
  MediaSourceKind get kind => MediaSourceKind.piped;

  @override
  String get label => 'Piped';

  String get currentInstance =>
      instances[_cursor % instances.length].replaceAll(RegExp(r'/+$'), '');

  void rotateInstance() => _cursor++;

  @override
  Future<SearchResults> search(
    String query, {
    String? continuation,
    SearchScope filter = SearchScope.songs,
  }) async {
    final base = currentInstance;
    final host = Uri.parse(base).host;

    final Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        '$base/search',
        queryParameters: <String, dynamic>{
          'q': query,
          'filter': filter.pipedValue,
          if (continuation != null && continuation.isNotEmpty)
            'nextpage': continuation,
        },
        options: Options(
          responseType: ResponseType.json,
          headers: const <String, String>{'Accept': 'application/json'},
        ),
      );
    } on DioException catch (error) {
      rotateInstance();
      throw NetworkFailure(
        '$label@$host: ${error.message ?? error.type.name}',
        source: kind,
        cause: error,
      );
    }

    final payload = response.data;
    if (payload is! Map) {
      rotateInstance();
      throw ExtractionFailure(
        '$label@$host returned an unexpected search payload',
        source: kind,
        cause: payload?.runtimeType,
      );
    }

    final items = (payload['items'] as List?) ?? const <dynamic>[];
    final tracks = items
        .whereType<Map<String, dynamic>>()
        .map(_trackFrom)
        .whereType<Track>()
        .toList(growable: false);

    final next = payload['nextpage'];
    return SearchResults(
      tracks: tracks,
      source: kind,
      continuation: next is String && next.isNotEmpty ? next : null,
    );
  }

  static final RegExp _videoIdPattern = RegExp(r'[?&]v=([A-Za-z0-9_-]{11})');

  static Track? _trackFrom(Map<String, dynamic> item) {
    // Piped tags playable results with type == 'stream'; anything else
    // (channel, playlist) cannot be played directly.
    if (item['type'] is String && item['type'] != 'stream') return null;
    final id = _extractVideoId(item['url']);
    if (id == null) return null;

    final views = item['views'];
    return Track(
      id: id,
      title: (item['title'] as String?) ?? 'Unknown title',
      artist: (item['uploaderName'] as String?) ?? '',
      duration: parseDurationSeconds(item['duration'] as num?),
      artworkUrl: (item['thumbnail'] as String?)?.isNotEmpty == true
          ? item['thumbnail'] as String
          : null,
      viewCount: views is int && views >= 0 ? views : null,
      isLive: (item['duration'] as num?) == 0,
      source: MediaSourceKind.piped,
    );
  }

  static String? _extractVideoId(Object? url) {
    if (url is! String) return null;
    final match = _videoIdPattern.firstMatch(url);
    if (match != null) return match.group(1);
    // Piped also answers with a bare id for some search filters.
    final bare = RegExp(r'^[A-Za-z0-9_-]{11}$').firstMatch(url);
    return bare?.group(0);
  }
}
