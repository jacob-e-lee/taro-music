import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/errors/failures.dart';
import '../../domain/playback_source.dart';
import '../../domain/track.dart';
import 'stream_extractor.dart';
import 'stream_probe.dart';

/// Fallback extractor: asks a Piped instance (a privacy proxy in front of
/// YouTube) for the same track.
///
/// Public instances are run by volunteers and die often, so the extractor holds
/// a cursor into [instances] and advances it on every network-level failure.
/// Combined with the chain's retry, that means each attempt hits a *different*
/// mirror, which is what actually makes Piped usable in practice.
///
/// Piped hands back `googlevideo.com` URLs minted by whichever client *it*
/// chose, so those URLs are subject to the same silent `403` as YouTube's own —
/// [StreamProbe] therefore guards this path too, with the instance rotated out
/// when it offers something unplayable.
class PipedExtractor implements StreamExtractor {
  PipedExtractor(
    this._dio, {
    required this._probe,
    this.instances = AppConfig.pipedInstances,
  }) : assert(instances.isNotEmpty, 'at least one Piped instance is required');

  final Dio _dio;
  final StreamProbe _probe;
  final List<String> instances;

  int _cursor = 0;

  @override
  MediaSourceKind get kind => MediaSourceKind.piped;

  @override
  String get label => 'Piped';

  /// Host of the instance currently in rotation.
  String get activeHost => Uri.parse(currentInstance).host;

  String get currentInstance =>
      instances[_cursor % instances.length].replaceAll(RegExp(r'/+$'), '');

  @visibleForTesting
  void rotateInstance() => _cursor++;

  @override
  void noteRefused(Track track) {
    // The player was refused a URL this instance had already verified, so move
    // to the next mirror on the next extraction.
    rotateInstance();
  }

  @override
  Future<PlaybackSource> extract(Track track) async {
    final base = currentInstance;
    final host = Uri.parse(base).host;

    final Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        '$base/streams/${Uri.encodeComponent(track.id)}',
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

    final data = response.data;
    if (data is! Map) {
      rotateInstance();
      throw ExtractionFailure(
        '$label@$host returned an unexpected payload',
        source: kind,
        cause: data?.runtimeType,
      );
    }

    final streams =
        (data['audioStreams'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        const <Map<String, dynamic>>[];
    if (streams.isEmpty) {
      throw NoPlayableStreamFailure(
        '$label@$host has no audio stream for this track',
        source: kind,
      );
    }

    final best = streams.reduce(
      (a, b) => _bitrateOf(a) >= _bitrateOf(b) ? a : b,
    );
    final url = best['url'];
    if (url is! String || url.isEmpty) {
      throw NoPlayableStreamFailure(
        '$label@$host reported a stream without a URL',
        source: kind,
      );
    }

    final source = PlaybackSource(
      url: Uri.parse(url),
      source: kind,
      codec: best['codec'] as String? ?? best['mimeType'] as String?,
      bitrate: _bitrateOf(best),
      qualityLabel: best['quality'] as String?,
    );

    switch (await _probe.check(source)) {
      case StreamProbeOk():
        return source;
      case StreamProbeRejected(:final detail):
        rotateInstance();
        throw NoPlayableStreamFailure(
          '$label@$host offered an unplayable stream ($detail)',
          source: kind,
        );
      case StreamProbeUnreachable(:final detail):
        rotateInstance();
        throw NetworkFailure(
          '$label@$host stream never answered ($detail)',
          source: kind,
        );
    }
  }

  static int _bitrateOf(Map<String, dynamic> stream) {
    final value = stream['bitrate'];
    return value is int
        ? value
        : value is num
        ? value.toInt()
        : 0;
  }
}
