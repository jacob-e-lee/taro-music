import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taro_music/core/config/app_config.dart';
import 'package:taro_music/core/errors/failures.dart';
import 'package:taro_music/features/player/data/extractors/stream_probe.dart';
import 'package:taro_music/features/player/domain/playback_source.dart';

/// Answers every request with whatever the test scripted, and records what it
/// was asked for.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this._respond);

  final Future<ResponseBody> Function(RequestOptions options) _respond;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return _respond(options);
  }

  @override
  void close({bool force = false}) {}
}

/// A never-ending body: the server accepted the request and then went quiet.
ResponseBody _stalledResponse() {
  final controller = StreamController<Uint8List>();
  addTearDown(controller.close);
  return ResponseBody(controller.stream, 206);
}

HttpStreamProbe _probe(
  Future<ResponseBody> Function(RequestOptions options) respond, {
  Duration timeout = const Duration(seconds: 5),
}) {
  final dio = Dio();
  dio.httpClientAdapter = _ScriptedAdapter(respond);
  return HttpStreamProbe(dio, timeout: timeout);
}

PlaybackSource _source({String? userAgent}) => PlaybackSource(
  url: Uri.parse('https://rr1---sn-test.googlevideo.com/videoplayback?id=1'),
  source: MediaSourceKind.youtube,
  userAgent: userAgent,
);

void main() {
  test('a 206 answer proves the URL is playable', () async {
    final probe = _probe((_) async => ResponseBody.fromBytes(<int>[0], 206));

    final result = await probe.check(_source());

    expect(result, isA<StreamProbeOk>());
    expect((result as StreamProbeOk).statusCode, 206);
  });

  test('a plain 200 also counts: not every host honours Range', () async {
    final probe = _probe((_) async => ResponseBody.fromBytes(<int>[0], 200));

    expect(await probe.check(_source()), isA<StreamProbeOk>());
  });

  test('a 403 is reported as a refusal, with its status code', () async {
    final probe = _probe((_) async => ResponseBody.fromBytes(<int>[], 403));

    final result = await probe.check(_source());

    expect(result, isA<StreamProbeRejected>());
    expect((result as StreamProbeRejected).statusCode, 403);
    expect(result.detail, 'HTTP 403');
  });

  test('accepts-but-never-answers becomes an unreachable result', () async {
    final probe = _probe(
      (_) async => _stalledResponse(),
      timeout: const Duration(milliseconds: 50),
    );

    expect(await probe.check(_source()), isA<StreamProbeUnreachable>());
  });

  test('a transport error becomes an unreachable result', () async {
    final probe = _probe(
      (options) async => throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'no route to host',
      ),
    );

    final result = await probe.check(_source());

    expect(result, isA<StreamProbeUnreachable>());
    expect(result.detail, contains('no route to host'));
  });

  test(
    'asks for one byte only, with the headers the player will send',
    () async {
      late RequestOptions sent;
      final probe = _probe((options) async {
        sent = options;
        return ResponseBody.fromBytes(<int>[0], 206);
      });

      await probe.check(_source(userAgent: 'test-agent'));

      expect(
        sent.headers[AppConfig.streamProbeRangeHeader],
        AppConfig.streamProbeRange,
      );
      expect(sent.responseType, ResponseType.stream);
      expect(sent.headers['user-agent'], 'test-agent');
    },
  );
}
