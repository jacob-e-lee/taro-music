import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/js_challenge.dart';
import 'package:youtube_explode_dart/solvers.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../features/player/data/extractors/extractor_chain.dart';
import '../../features/player/data/extractors/piped_extractor.dart';
import '../../features/player/data/extractors/stream_extractor.dart';
import '../../features/player/data/extractors/stream_probe.dart';
import '../../features/player/data/extractors/youtube_extractor.dart';
import '../../features/player/data/repositories/fallback_media_repository.dart';
import '../../features/player/data/sources/piped_search_source.dart';
import '../../features/player/data/sources/search_source.dart';
import '../../features/player/data/sources/youtube_search_source.dart';
import '../../features/player/domain/media_repository.dart';
import '../config/app_config.dart';

/// Best-effort initializer for the JS-challenge solver `youtube_explode_dart`
/// optionally uses to decipher `sig`/`n` parameters.
///
/// The only solver the package ships ([DenoEJSSolver]) shells out to a `deno`
/// executable on `PATH`, so it can only ever work on a development machine —
/// never inside an app on a phone. This returns `null` on mobile platforms
/// and whenever Deno is not installed; the package then skips clients whose
/// URLs need deciphering, and our byte-probe rejects the unsolved URLs, so
/// those clients fall out of rotation instead of failing the track.
Future<BaseJSChallengeSolver?> initJsSolver() async {
  if (Platform.isAndroid || Platform.isIOS) return null;
  try {
    return await DenoEJSSolver.init();
  } catch (error) {
    debugPrint('YouTube JS solver unavailable (is deno on PATH?): $error');
    return null;
  }
}

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
  ///
  /// [jsSolver] is the optional `sig`/`n` decipherer; see [initJsSolver] for
  /// why it is null on devices.
  factory MediaStack.live({BaseJSChallengeSolver? jsSolver}) {
    final youtube = YoutubeExplode(jsSolver: jsSolver);
    final dio = Dio(
      BaseOptions(
        connectTimeout: AppConfig.connectTimeout,
        receiveTimeout: AppConfig.httpTimeout,
        responseType: ResponseType.json,
        headers: <String, dynamic>{'User-Agent': AppConfig.extractionUserAgent},
      ),
    );
    // One probe for every extractor: it borrows the same client pool the
    // providers use, so validating a URL costs a round trip, not a socket.
    final probe = HttpStreamProbe(dio);

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
          YoutubeExtractor(youtube, probe: probe),
          PipedExtractor(dio, probe: probe),
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
