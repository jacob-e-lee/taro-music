import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:taro_music/core/errors/failures.dart';
import 'package:taro_music/features/player/application/audio_handler.dart';
import 'package:taro_music/features/player/application/track_mapping.dart';
import 'package:taro_music/features/player/domain/media_repository.dart';
import 'package:taro_music/features/player/domain/playback_source.dart';
import 'package:taro_music/features/player/domain/search_results.dart';
import 'package:taro_music/features/player/domain/track.dart';

const Track _track = Track(
  id: 'track-1',
  title: 'Track 1',
  artist: 'Artist 1',
  source: MediaSourceKind.youtube,
);

PlaybackSource _source(String hostPath) => PlaybackSource(
  url: Uri.parse('https://example.com/$hostPath'),
  source: MediaSourceKind.youtube,
);

/// Scripted repository: hands out one URL per `resolveSource` call and
/// records refusals, so tests can assert rotation happened.
class _ScriptedRepo implements MediaRepository {
  _ScriptedRepo(this._hosts) : resolveError = null;

  _ScriptedRepo.withError(this.resolveError) : _hosts = const <String>[];

  final List<String> _hosts;
  final List<Track> refused = <Track>[];
  int resolves = 0;
  final Object? resolveError;

  @override
  Future<SearchResults> search(
    String query, {
    String? continuation,
    SearchScope filter = SearchScope.songs,
  }) => throw UnimplementedError();

  @override
  void noteRefused(Track track) {
    refused.add(track);
  }

  @override
  Future<PlaybackSource> resolveSource(Track track) async {
    if (resolveError != null) throw resolveError!;
    resolves++;
    final host = _hosts[(resolves - 1) % _hosts.length];
    return _source(host);
  }
}

/// Stands in for `AudioPlayer` without touching platform channels: `setUrl`
/// records its URLs and can be scripted to throw, and `play`/`pause` just
/// complete. The platform channel is only hit on `dispose`, so tests must
/// avoid disposing through the real player.
class _FakePlayer extends AudioPlayer {
  _FakePlayer({this.setUrlError});

  Object? setUrlError;
  final List<String> urls = <String>[];

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    urls.add(url);
    final error = setUrlError;
    if (error != null) {
      // Reject once, then accept, so a test can observe the retry succeed.
      setUrlError = null;
      throw error;
    }
    return Duration.zero;
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> dispose() async {}
}

MusicAudioHandler _handlerWithTracks({
  required _ScriptedRepo repo,
  required _FakePlayer player,
}) {
  final handler = MusicAudioHandler(repository: repo, player: player);
  return handler;
}

Future<void> _enqueue(MusicAudioHandler handler) async {
  await handler.addQueueItems([_track.toMediaItem()]);
}

void main() {
  // These tests never pump widgets. The binding only has to exist so
  // `AudioPlayer` can register its platform handlers; using plain `test`s
  // keeps the real event loop, because `testWidgets`' fake clock never
  // flushes the deep await chains in `MusicAudioHandler.dispose`.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reorderQueue moves items and keeps track order consistent', () async {
    final handler = MusicAudioHandler(
      repository: _ScriptedRepo(const <String>[]),
      player: _FakePlayer(),
    );

    final tracks = [
      const Track(
        id: '1',
        title: 'Track 1',
        artist: 'Artist 1',
        source: MediaSourceKind.youtube,
      ),
      const Track(
        id: '2',
        title: 'Track 2',
        artist: 'Artist 2',
        source: MediaSourceKind.youtube,
      ),
      const Track(
        id: '3',
        title: 'Track 3',
        artist: 'Artist 3',
        source: MediaSourceKind.youtube,
      ),
    ];

    // Add items to queue via addQueueItems (which doesn't invoke setUrl)
    await handler.addQueueItems(tracks.map((t) => t.toMediaItem()).toList());

    expect(handler.tracks.map((t) => t.id).toList(), ['1', '2', '3']);

    // Move item at index 0 down after item 1 (index 2 for ReorderableListView semantics)
    await handler.reorderQueue(0, 2);

    expect(handler.tracks.map((t) => t.id).toList(), ['2', '1', '3']);

    // Move item at index 2 to top (index 0)
    await handler.reorderQueue(2, 0);

    expect(handler.tracks.map((t) => t.id).toList(), ['3', '2', '1']);

    await handler.dispose();
  });

  group('async ExoPlayer refusal recovery', () {
    test(
      'a just_audio PlayerException is a source failure, '
      'an arbitrary error is not',
      () {
        expect(
          MusicAudioHandler.isSourceFailureForTest(
            PlayerException(0, 'Source error', 0),
          ),
          isTrue,
        );
        expect(
          MusicAudioHandler.isSourceFailureForTest(StateError('boom')),
          isFalse,
        );
      },
    );

    test(
      'a refused URL rotates the source and retries, '
      'starting from a fresh URL',
      () async {
        final repo = _ScriptedRepo(const <String>['first.mp3', 'second.mp3']);
        final player = _FakePlayer();
        final handler = _handlerWithTracks(repo: repo, player: player);
        await _enqueue(handler);

        await handler.playQueue([_track], autoplay: false);
        expect(player.urls, ['https://example.com/first.mp3']);

        await handler.recoverFromPlayerErrorForTest(
          PlayerException(0, 'Source error', 0),
        );

        expect(repo.refused, [_track]);
        expect(player.urls, [
          'https://example.com/first.mp3',
          'https://example.com/second.mp3',
        ]);
        await handler.dispose();
      },
    );

    test(
      'a URL rejected by setUrl rotates synchronously and retries',
      () async {
        final repo = _ScriptedRepo(const <String>['first.mp3', 'second.mp3']);
        final player = _FakePlayer(
          setUrlError: PlayerException(0, 'Source error', 0),
        );
        final handler = _handlerWithTracks(repo: repo, player: player);

        await handler.playQueue([_track], autoplay: false);

        expect(player.urls, [
          'https://example.com/first.mp3',
          'https://example.com/second.mp3',
        ]);
        expect(repo.refused, [_track]);
        expect(repo.resolves, 2);
        await handler.dispose();
      },
    );

    test('a non-source error surfaces without retrying', () async {
      final repo = _ScriptedRepo(const <String>['first.mp3']);
      final player = _FakePlayer();
      final handler = _handlerWithTracks(repo: repo, player: player);
      await _enqueue(handler);

      await handler.playQueue([_track], autoplay: false);

      await handler.recoverFromPlayerErrorForTest(StateError('boom'));

      expect(repo.refused, isEmpty);
      expect(player.urls, ['https://example.com/first.mp3']);
      expect(handler.playbackState.value.errorMessage, contains('Playback failed'));
      await handler.dispose();
    });

    test('a resolution failure reports without retrying', () async {
      final repo = _ScriptedRepo.withError(StateError('resolve failed'));
      final player = _FakePlayer();
      final handler = _handlerWithTracks(repo: repo, player: player);
      await _enqueue(handler);

      await handler.playQueue([_track], autoplay: false);

      // The chain already exhausted its sources, so nothing rotates: the
      // failure surfaces and the player was never handed a URL.
      expect(player.urls, isEmpty);
      expect(repo.refused, isEmpty);
      expect(
        handler.playbackState.value.errorMessage,
        contains('Playback failed'),
      );
      await handler.dispose();
    });

    test(
      'recovery gives up after the budget and reports the failure',
      () async {
        final repo = _ScriptedRepo(
          const <String>['a.mp3', 'b.mp3', 'c.mp3', 'd.mp3'],
        );
        final player = _FakePlayer();
        final handler = _handlerWithTracks(repo: repo, player: player);
        await _enqueue(handler);

        await handler.playQueue([_track], autoplay: false);
        for (var i = 0; i < MusicAudioHandler.maxStreamAttempts; i++) {
          await handler.recoverFromPlayerErrorForTest(
            PlayerException(0, 'Source error', 0),
          );
        }

        expect(repo.resolves, MusicAudioHandler.maxStreamAttempts);
        expect(
          handler.playbackState.value.errorMessage,
          contains('Playback failed'),
        );
        await handler.dispose();
      },
    );

    test('a started track surfaces the failure instead of retrying', () async {
      final repo = _ScriptedRepo(const <String>['first.mp3', 'second.mp3']);
      final player = _FakePlayer();
      final handler = _handlerWithTracks(repo: repo, player: player);
      await _enqueue(handler);

      await handler.playQueue([_track], autoplay: false);
      handler.markTrackStartedForTest(_track.id);

      await handler.recoverFromPlayerErrorForTest(
        PlayerException(0, 'Source error', 0),
      );

      // Mid-track failure: no rotation, no second URL, surfaced instead.
      expect(repo.refused, isEmpty);
      expect(player.urls, ['https://example.com/first.mp3']);
      expect(
        handler.playbackState.value.errorMessage,
        contains('Playback failed'),
      );
      await handler.dispose();
    });
  });
}
