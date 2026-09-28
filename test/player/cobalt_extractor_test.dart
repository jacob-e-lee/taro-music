import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taro_music/core/config/app_config.dart';
import 'package:taro_music/core/errors/failures.dart';
import 'package:taro_music/features/player/data/extractors/cobalt_extractor.dart';
import 'package:taro_music/features/player/data/extractors/stream_probe.dart';
import 'package:taro_music/features/player/domain/playback_source.dart';
import 'package:taro_music/features/player/domain/track.dart';

const Track _track = Track(
  id: 'dQw4w9WgXcQ',
  title: 'Test Song',
  artist: 'Test Artist',
  source: MediaSourceKind.youtube,
);

const String _audioUrl = 'https://cdn.test/audio.m4a';

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

ResponseBody _json(Object? body, [int status = 200]) => ResponseBody.fromBytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: <String, List<String>>{
    Headers.contentTypeHeader: <String>[Headers.jsonContentType],
  },
);

class _ScriptedProbe implements StreamProbe {
  _ScriptedProbe([this.result = const StreamProbeOk(206)]);

  final StreamProbeResult result;
  final List<Uri> checked = <Uri>[];

  @override
  Future<StreamProbeResult> check(PlaybackSource source) async {
    checked.add(source.url);
    return result;
  }
}

const List<String> _threeInstances = <String>[
  'https://one.test',
  'https://two.test',
  'https://three.test',
];

CobaltExtractor _extractor({
  required Future<ResponseBody> Function(RequestOptions options) respond,
  StreamProbe? probe,
  List<String> instances = _threeInstances,
}) {
  final dio = Dio(BaseOptions(responseType: ResponseType.json))
    ..httpClientAdapter = _ScriptedAdapter(respond);
  return CobaltExtractor(
    dio,
    probe: probe ?? _ScriptedProbe(),
    instances: instances,
  );
}

List<String> _hosts(List<RequestOptions> requests) =>
    requests.map((request) => request.uri.host).toList();

void main() {
  test(
    'posts the YouTube URL and returns the audio URL it answers with',
    () async {
      late RequestOptions sent;
      final extractor = _extractor(
        respond: (options) async {
          sent = options;
          return _json(<String, dynamic>{'url': _audioUrl, 'picker': 'best'});
        },
      );

      final source = await extractor.extract(_track);

      expect(source.url.toString(), _audioUrl);
      expect(source.source, MediaSourceKind.cobalt);
      expect(source.codec, 'mp4a');
      expect(source.bitrate, 128000);
      expect(source.headers['user-agent'], AppConfig.browserUserAgent);

      // The request shape Cobalt requires.
      expect(sent.method, 'POST');
      expect(sent.uri.toString(), 'https://one.test/api/json');
      expect(sent.data, <String, dynamic>{
        'url': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'isAudioOnly': true,
        'aFormat': 'best',
      });
      expect(sent.headers['User-Agent'], 'TaroMusic/1.0.0 (Android)');
      expect(sent.headers['Accept'], 'application/json');
    },
  );

  test('a 429 on the first instance does not throw, it advances', () async {
    // The exact bug being fixed: `validateStatus` has to keep dio from
    // throwing so the loop reaches the next instance.
    final requests = <RequestOptions>[];
    final dio = Dio(BaseOptions(responseType: ResponseType.json))
      ..httpClientAdapter = _ScriptedAdapter((options) async {
        requests.add(options);
        return options.uri.host == 'one.test'
            ? _json(<String, dynamic>{'error': 'Rate limit reached'}, 429)
            : _json(<String, dynamic>{'url': _audioUrl});
      });
    final extractor = CobaltExtractor(
      dio,
      instances: _threeInstances,
      probe: _ScriptedProbe(),
    );

    final source = await extractor.extract(_track);

    expect(source.url.toString(), _audioUrl);
    expect(_hosts(requests), <String>['one.test', 'two.test']);
  });

  test('a transport failure is caught and the loop continues', () async {
    // `validateStatus` covers HTTP statuses only; a refused connection still
    // throws, and that must not abandon the remaining instances.
    final requests = <RequestOptions>[];
    final dio = Dio(BaseOptions(responseType: ResponseType.json))
      ..httpClientAdapter = _ScriptedAdapter((options) async {
        requests.add(options);
        if (options.uri.host == 'one.test') {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            message: 'connection refused',
          );
        }
        return _json(<String, dynamic>{'url': _audioUrl});
      });
    final extractor = CobaltExtractor(
      dio,
      instances: _threeInstances,
      probe: _ScriptedProbe(),
    );

    final source = await extractor.extract(_track);

    expect(source.url.toString(), _audioUrl);
    expect(_hosts(requests), <String>['one.test', 'two.test']);
  });

  test('every instance failing reports all of them', () async {
    final extractor = _extractor(
      respond: (_) async => _json(<String, dynamic>{'error': 'nope'}, 500),
    );

    await expectLater(
      extractor.extract(_track),
      throwsA(
        isA<ExtractionFailure>()
            .having((f) => f.message, 'message', contains('one.test'))
            .having((f) => f.message, 'message', contains('two.test'))
            .having((f) => f.message, 'message', contains('three.test'))
            .having((f) => f.message, 'message', contains('All Cobalt')),
      ),
    );
  });

  test('a 200 with no url is not a success', () async {
    // Cobalt deployments exist that answer 200 alongside an error key.
    final extractor = _extractor(
      respond: (_) async => _json(<String, dynamic>{'error': 'no video found'}),
    );

    await expectLater(
      extractor.extract(_track),
      throwsA(
        isA<ExtractionFailure>().having(
          (failure) => failure.message,
          'message',
          contains('without an audio URL'),
        ),
      ),
    );
  });

  test('a probe-refused url rotates instead of reaching the player', () async {
    final extractor = _extractor(
      probe: _ScriptedProbe(const StreamProbeRejected(403)),
      respond: (_) async => _json(<String, dynamic>{'url': _audioUrl}),
    );

    await expectLater(
      extractor.extract(_track),
      throwsA(
        isA<NoPlayableStreamFailure>().having(
          (failure) => failure.message,
          'message',
          contains('unplayable'),
        ),
      ),
    );
  });

  test('the default instance list leads with the primary mirror', () {
    expect(AppConfig.cobaltInstances.first, 'https://co.wuk.sh');
    expect(AppConfig.cobaltInstances, hasLength(3));
  });
}
