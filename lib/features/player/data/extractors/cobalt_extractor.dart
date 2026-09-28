import 'package:dio/dio.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/errors/failures.dart';
import '../../domain/playback_source.dart';
import '../../domain/track.dart';
import 'stream_extractor.dart';
import 'stream_probe.dart';

/// The stream extractor: resolves a track through a Cobalt instance's
/// `/api/json` endpoint and hands the proxy's own media URL to the player.
///
/// This is the *only* extraction path. Two earlier approaches are gone:
/// `youtube_explode_dart` cannot produce the PO token YouTube now demands on
/// stream manifests, and the Piped instances sit behind Cloudflare that
/// hard-blocks non-browser clients. Cobalt runs the token exchange
/// server-side and answers a single, stable JSON shape, so its failure mode is
/// a plain HTTP status we can loop over.
///
/// Resilience: [extract] sweeps every instance in [instances] within one call,
/// and the [ExtractorChain] retries the extractor on top of that.
///
/// Cobalt chooses the upstream client, so the returned URL is not bound to a UA
/// this app can name — a browser string plus the [StreamProbe] check is what
/// stands between a stale proxy URL and ExoPlayer.
class CobaltExtractor implements StreamExtractor {
  CobaltExtractor(
    this._dio, {
    this._probe,
    this.instances = AppConfig.cobaltInstances,
  }) : assert(instances.isNotEmpty, 'at least one Cobalt instance is required');

  final Dio _dio;

  /// Optional: without a probe the extractor trusts the instance's answer.
  final StreamProbe? _probe;

  /// The Cobalt instances in rotation, most-trusted first.
  final List<String> instances;

  @override
  MediaSourceKind get kind => MediaSourceKind.cobalt;

  @override
  String get label => 'Cobalt';

  @override
  void noteRefused(Track track) {
    // The player refused a URL this extractor had already probe-verified, so
    // the instance is handing out bad media. There is no cursor to advance —
    // [extract] walks the whole list per call — but the diagnostic still shows
    // as a Cobalt failure, which is the useful part.
  }

  @override
  Future<PlaybackSource> extract(Track track) async {
    final failures = <String>[];

    for (final base in instances) {
      final host = Uri.parse(base).host;

      final Response<dynamic> response;
      try {
        response = await _dio.post<dynamic>(
          '$base/api/json',
          data: <String, dynamic>{
            'url': 'https://www.youtube.com/watch?v=${track.id}',
            'isAudioOnly': true,
            'aFormat': 'best',
          },
          options: Options(
            // Without this, dio throws on every 403/429/5xx and the sweep never
            // reaches the next instance. Refusals are the answer we are looking
            // for, not an exception.
            validateStatus: (_) => true,
            headers: const <String, String>{
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              // These instances are picky about client identity. The app's own
              // name is honest and specific, where a spoofed browser string
              // would only attract the same bot checks Piped did.
              'User-Agent': AppConfig.cobaltUserAgent,
            },
          ),
        );
      } on DioException catch (error) {
        // `validateStatus` covers HTTP statuses, not transport: a refused
        // connection, DNS failure or timeout still throws, and letting that
        // escape would abandon the remaining instances.
        failures.add('$host: ${error.message ?? error.type.name}');
        continue;
      }

      final status = response.statusCode ?? 0;
      if (status != 200) {
        failures.add('$host: HTTP $status${_errorOf(response.data)}');
        continue;
      }

      final url = _audioUrlOf(response.data);
      if (url == null) {
        failures.add('$host: HTTP 200 without an audio URL');
        continue;
      }

      final source = PlaybackSource(
        url: Uri.parse(url),
        source: kind,
        // Cobalt does not report a codec or a bitrate for `aFormat: best`; these
        // describe what its audio-only output actually is and only feed the
        // player's decoder choice and the UI's bitrate label.
        codec: AppConfig.cobaltCodec,
        bitrate: AppConfig.cobaltBitrate,
        qualityLabel: 'Audio',
        userAgent: AppConfig.browserUserAgent,
      );

      final probe = _probe;
      if (probe == null) return source;
      switch (await probe.check(source)) {
        case StreamProbeOk():
          return source;
        case StreamProbeRejected(:final detail):
        case StreamProbeUnreachable(:final detail):
          // Another instance resolves through a different upstream, so it gets
          // a genuinely different URL. Never hand ExoPlayer this one.
          failures.add('$host: unplayable ($detail)');
          continue;
      }
    }

    if (failures.any((failure) => failure.contains('unplayable'))) {
      throw NoPlayableStreamFailure(
        '$label offered no playable stream for "${track.title}" '
        '(${failures.join(', ')})',
        source: kind,
      );
    }
    throw ExtractionFailure(
      'All $label proxy instances failed to extract "${track.title}" '
      '(${failures.join(', ')})',
      source: kind,
    );
  }

  /// The one field we need out of a successful body. Some deployments answer
  /// `200` with an `error` key, so the URL is checked rather than trusting the
  /// status alone.
  static String? _audioUrlOf(Object? data) {
    if (data is! Map) return null;
    final url = data['url'];
    if (url is! String || url.isEmpty) return null;
    return Uri.tryParse(url)?.hasScheme == true ? url : null;
  }

  /// Keeps the proxy's own explanation in our failure message: it is usually
  /// the difference between "rate limited, try again" and "no such video".
  static String _errorOf(Object? data) {
    if (data is! Map) return '';
    final error = data['error'];
    if (error is String && error.isNotEmpty) return ' ($error)';
    if (error is Map && error['code'] is String) return ' (${error['code']})';
    return '';
  }
}
