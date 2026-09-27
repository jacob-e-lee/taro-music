import 'package:dio/dio.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../features/player/data/extractors/extractor_chain.dart';
import '../../features/player/data/extractors/piped_extractor.dart';
import '../../features/player/data/extractors/stream_extractor.dart';
import '../../features/player/data/extractors/youtube_extractor.dart';
import '../../features/player/data/repositories/fallback_media_repository.dart';
import '../../features/player/data/sources/piped_search_source.dart';
import '../../features/player/data/sources/search_source.dart';
import '../../features/player/data/sources/youtube_search_source.dart';
import '../../features/player/domain/media_repository.dart';
import '../config/app_config.dart';

/// Owns every long-lived network resource, in one place, created exactly once.
///
/// `YoutubeExplode` keeps an HTTP client and a cache alive; `Dio` owns a pool of
/// sockets. Both are built here so the app has a single teardown path, and so
/// the extractor chain and the search sources share one client per provider
/// (re-connecting per request is what makes public Piped instances feel slow).
class MediaStack {
  MediaStack._({
    required this.youtube,
    required this.dio,
    required this.repository,
  });

  /// The real, network-backed wiring: YouTube first, Piped as the fallback for
  /// both search and stream extraction.
  factory MediaStack.live() {
    final youtube = YoutubeExplode();
    final dio = Dio(
      BaseOptions(
        connectTimeout: AppConfig.connectTimeout,
        receiveTimeout: AppConfig.httpTimeout,
        responseType: ResponseType.json,
        headers: <String, dynamic>{'User-Agent': AppConfig.extractionUserAgent},
      ),
    );

    return MediaStack._(
      youtube: youtube,
      dio: dio,
      repository: FallbackMediaRepository(
        searchSources: <SearchSource>[
          // Direct YouTube first: richer metadata and no third-party uptime
          // risk. Piped catches both bot checks and instance outages.
          YoutubeSearchSource(youtube),
          PipedSearchSource(dio),
        ],
        extractorChain: ExtractorChain(<StreamExtractor>[
          YoutubeExtractor(youtube),
          PipedExtractor(dio),
        ]),
      ),
    );
  }

  final YoutubeExplode youtube;
  final Dio dio;
  final MediaRepository repository;

  void dispose() {
    dio.close(force: true);
    youtube.close();
  }
}
