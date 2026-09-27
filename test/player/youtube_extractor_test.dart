import 'package:flutter_test/flutter_test.dart';
import 'package:http_parser/http_parser.dart';
import 'package:taro_music/core/errors/failures.dart';
import 'package:taro_music/features/player/data/extractors/stream_probe.dart';
import 'package:taro_music/features/player/data/extractors/youtube_extractor.dart';
import 'package:taro_music/features/player/domain/playback_source.dart';
import 'package:taro_music/features/player/domain/track.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const Track _track = Track(
  id: 'dQw4w9WgXcQ',
  title: 'Test Song',
  artist: 'Test Artist',
  source: MediaSourceKind.youtube,
);

const String _vrUrl =
    'https://rr1---sn-vr.googlevideo.com/videoplayback?c=ANDROID_VR';
const String _sdklessUrl =
    'https://rr1---sn-sdkless.googlevideo.com/videoplayback?c=ANDROID';

/// The probe, scripted per URL: anything unscripted is treated as unreachable
/// so a test can never silently pass a URL it did not expect.
class _ScriptedProbe implements StreamProbe {
  _ScriptedProbe(this._answers);

  final Map<String, StreamProbeResult> _answers;
  final List<Uri> checked = <Uri>[];

  @override
  Future<StreamProbeResult> check(PlaybackSource source) async {
    checked.add(source.url);
    return _answers[source.url.toString()] ??
        const StreamProbeUnreachable('not scripted');
  }
}

/// Stands in for `YoutubeExplode`, which cannot be faked: it records which
/// client each manifest was asked for.
class _RecordingLoader {
  _RecordingLoader(this._manifests);

  final Map<YoutubeApiClient, StreamManifest> _manifests;
  final List<YoutubeApiClient> clients = <YoutubeApiClient>[];

  Future<StreamManifest> call(String videoId, YoutubeApiClient client) async {
    clients.add(client);
    final scripted = _manifests[client];
    if (scripted == null) {
      throw StateError('no manifest scripted for ${client.payload}');
    }
    return scripted;
  }
}

AudioOnlyStreamInfo _audio(String url, int tag, String codec, int kbps) =>
    AudioOnlyStreamInfo(
      VideoId(_track.id),
      tag,
      Uri.parse(url),
      StreamContainer.mp4,
      FileSize(1024),
      Bitrate(kbps * 1000),
      codec,
      'medium',
      const [],

      MediaType.parse('audio/mp4'),
      null,
    );

StreamManifest _manifest(List<AudioOnlyStreamInfo> streams) =>
    StreamManifest(<StreamInfo>[...streams]);

final AudioOnlyStreamInfo _aacOnVr = _audio(_vrUrl, 140, 'mp4a.40.2', 130);
final AudioOnlyStreamInfo _aacOnSdkless =
    _audio(_sdklessUrl, 140, 'mp4a.40.2', 130);

void main() {
  late YoutubeExplode youtube;

  setUp(() => youtube = YoutubeExplode());
  tearDown(() => youtube.close());

  YoutubeExtractor extractor(_ScriptedProbe probe, _RecordingLoader loader) =>
      YoutubeExtractor(youtube, probe: probe, loadManifest: loader.call);

  test('returns the first client whose URL really downloads', () async {
    final loader = _RecordingLoader(<YoutubeApiClient, StreamManifest>{
      YoutubeApiClient.androidVr: _manifest(<AudioOnlyStreamInfo>[_aacOnVr]),
      YoutubeApiClient.androidSdkless: _manifest(
        <AudioOnlyStreamInfo>[_aacOnSdkless],
      ),
    });
    final probe = _ScriptedProbe(<String, StreamProbeResult>{
      _vrUrl: const StreamProbeOk(206),
    });

    final source = await extractor(probe, loader).extract(_track);

    expect(source.url.toString(), _vrUrl);
    expect(source.source, MediaSourceKind.youtube);
    // The second client is never even asked.
    expect(loader.clients, <YoutubeApiClient>[YoutubeApiClient.androidVr]);
  });

  test('retries with the next client when YouTube refuses the first', () async {
    final loader = _RecordingLoader(<YoutubeApiClient, StreamManifest>{
      YoutubeApiClient.androidVr: _manifest(<AudioOnlyStreamInfo>[_aacOnVr]),
      YoutubeApiClient.androidSdkless: _manifest(
        <AudioOnlyStreamInfo>[_aacOnSdkless],
      ),
    });
    final probe = _ScriptedProbe(<String, StreamProbeResult>{
      _vrUrl: const StreamProbeRejected(403),
      _sdklessUrl: const StreamProbeOk(206),
    });

    final source = await extractor(probe, loader).extract(_track);

    expect(source.url.toString(), _sdklessUrl);
    expect(loader.clients, <YoutubeApiClient>[
      YoutubeApiClient.androidVr,
      YoutubeApiClient.androidSdkless,
    ]);
  });

  test('the client that worked is tried first next time', () async {
    final loader = _RecordingLoader(<YoutubeApiClient, StreamManifest>{
      YoutubeApiClient.androidVr: _manifest(<AudioOnlyStreamInfo>[_aacOnVr]),
      YoutubeApiClient.androidSdkless: _manifest(
        <AudioOnlyStreamInfo>[_aacOnSdkless],
      ),
    });
    final probe = _ScriptedProbe(<String, StreamProbeResult>{
      _vrUrl: const StreamProbeRejected(403),
      _sdklessUrl: const StreamProbeOk(206),
    });
    final subject = extractor(probe, loader);

    await subject.extract(_track);
    expect(subject.preferredClient.label, 'android_sdkless');

    loader.clients.clear();
    await subject.extract(_track);

    expect(loader.clients, <YoutubeApiClient>[YoutubeApiClient.androidSdkless]);
  });

  test('prefers AAC over a higher-bitrate Opus rendition', () async {
    final opus = _audio(
      '$_vrUrl&itag=251',
      251,
      'opus',
      160,
    );
    final loader = _RecordingLoader(<YoutubeApiClient, StreamManifest>{
      YoutubeApiClient.androidVr: _manifest(<AudioOnlyStreamInfo>[
        opus,
        _aacOnVr,
      ]),
    });
    final probe = _ScriptedProbe(<String, StreamProbeResult>{
      _vrUrl: const StreamProbeOk(206),
    });

    final source = await extractor(probe, loader).extract(_track);

    expect(source.url.toString(), _vrUrl);
    expect(source.codec, 'mp4a.40.2');
    expect(probe.checked, <Uri>[Uri.parse(_vrUrl)]);
  });

  test('reports every refusal when no client can serve the track', () async {
    final loader = _RecordingLoader(<YoutubeApiClient, StreamManifest>{
      YoutubeApiClient.androidVr: _manifest(<AudioOnlyStreamInfo>[_aacOnVr]),
      YoutubeApiClient.androidSdkless: _manifest(
        <AudioOnlyStreamInfo>[_aacOnSdkless],
      ),
    });
    final probe = _ScriptedProbe(<String, StreamProbeResult>{
      _vrUrl: const StreamProbeRejected(403),
      _sdklessUrl: const StreamProbeRejected(403),
    });

    await expectLater(
      extractor(probe, loader).extract(_track),
      throwsA(
        isA<NoPlayableStreamFailure>()
            .having((e) => e.message, 'message', contains('android_vr'))
            .having((e) => e.message, 'message', contains('HTTP 403')),
      ),
    );
  });

  test('a URL that never answers is a network failure, not a refusal', () async {
    final loader = _RecordingLoader(<YoutubeApiClient, StreamManifest>{
      YoutubeApiClient.androidVr: _manifest(<AudioOnlyStreamInfo>[_aacOnVr]),
      YoutubeApiClient.androidSdkless: _manifest(
        <AudioOnlyStreamInfo>[_aacOnSdkless],
      ),
    });
    final probe = _ScriptedProbe(<String, StreamProbeResult>{
      _vrUrl: const StreamProbeUnreachable('timed out'),
      _sdklessUrl: const StreamProbeUnreachable('timed out'),
    });

    await expectLater(
      extractor(probe, loader).extract(_track),
      throwsA(isA<NetworkFailure>()),
    );
  });

  test('a client that cannot even produce a manifest is skipped', () async {
    final loader = _RecordingLoader(<YoutubeApiClient, StreamManifest>{
      YoutubeApiClient.androidSdkless: _manifest(
        <AudioOnlyStreamInfo>[_aacOnSdkless],
      ),
    });
    final probe = _ScriptedProbe(<String, StreamProbeResult>{
      _sdklessUrl: const StreamProbeOk(206),
    });

    final source = await extractor(probe, loader).extract(_track);

    expect(source.url.toString(), _sdklessUrl);
  });
}
