import 'dart:async';

import 'package:dio/dio.dart';

import '../../../../core/config/app_config.dart';
import '../../domain/playback_source.dart';

/// What a media URL answered when it was asked for its first byte.
sealed class StreamProbeResult {
  const StreamProbeResult();

  /// Human readable explanation, safe to embed in a failure message.
  String get detail;
}

/// The bytes came back: a player can open this URL.
final class StreamProbeOk extends StreamProbeResult {
  const StreamProbeOk(this.statusCode);

  final int statusCode;

  @override
  String get detail => 'HTTP $statusCode';
}

/// The server answered but refused to serve the media (`403`, `404`, `410`…).
///
/// This is the case the probe exists for: YouTube signs each stream URL for one
/// specific Innertube client, and when it decides that client is not welcome it
/// keeps handing out URLs that look completely well formed — the refusal only
/// shows up when something actually tries to download one. `youtube_explode_dart`
/// cannot see that on its own: it checks candidate streams with a `HEAD`
/// request, and googlevideo answers `200` to a `HEAD` for URLs it refuses to
/// `GET`.
final class StreamProbeRejected extends StreamProbeResult {
  const StreamProbeRejected(this.statusCode);

  final int statusCode;

  @override
  String get detail => 'HTTP $statusCode';
}

/// The URL never answered: DNS, TLS, connection or read timeout.
final class StreamProbeUnreachable extends StreamProbeResult {
  const StreamProbeUnreachable(this.reason);

  final String reason;

  @override
  String get detail => reason;
}

/// Decides whether a resolved URL can really be played.
///
/// `StreamExtractor` implementations ask this before handing a URL to the
/// player, which turns "the player shows a spinner forever" into "this source
/// failed, try the next one".
abstract interface class StreamProbe {
  Future<StreamProbeResult> check(PlaybackSource source);
}

/// Probes a URL with the same request the player is about to make, minus the
/// payload: `Range: bytes=0-0` and the source's own headers.
///
/// Sharing the headers matters — the probe is only meaningful if it fails for
/// the same reason the player would.
class HttpStreamProbe implements StreamProbe {
  HttpStreamProbe(this._dio, {this.timeout = AppConfig.streamProbeTimeout});

  final Dio _dio;

  /// Budget for the whole exchange: connecting, the status line, and the first
  /// byte of the body.
  final Duration timeout;

  @override
  Future<StreamProbeResult> check(PlaybackSource source) async {
    final cancel = CancelToken();
    try {
      final response = await _dio
          .getUri<ResponseBody>(
            source.url,
            cancelToken: cancel,
            options: Options(
              responseType: ResponseType.stream,
              receiveTimeout: timeout,
              // Refusals are the answer we are looking for, not an exception.
              validateStatus: (_) => true,
              headers: <String, dynamic>{
                ...source.headers,
                AppConfig.streamProbeRangeHeader: AppConfig.streamProbeRange,
              },
            ),
          )
          .timeout(timeout);
      final statusCode = response.statusCode;
      // Read the single byte that was asked for so the connection is not left
      // half-open, then let the subscription cancel the rest of the body. A
      // server that ignores `Range` therefore costs one chunk, not a download.
      final body = response.data;
      if (body != null) {
        await body.stream.first.timeout(timeout);
      }

      if (statusCode == null) {
        return const StreamProbeUnreachable('no status code');
      }
      return statusCode == 200 || statusCode == 206
          ? StreamProbeOk(statusCode)
          : StreamProbeRejected(statusCode);
    } on DioException catch (error) {
      return StreamProbeUnreachable(error.message ?? error.type.name);
    } on TimeoutException {
      return StreamProbeUnreachable('no answer within ${timeout.inSeconds}s');
    } on StateError {
      // An empty body: the server closed the connection without sending the
      // byte it promised.
      return const StreamProbeUnreachable('empty response');
    } finally {
      cancel.cancel();
    }
  }
}
