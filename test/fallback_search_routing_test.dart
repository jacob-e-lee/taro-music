import 'package:flutter_test/flutter_test.dart';
import 'package:taro_music/core/errors/failures.dart';
import 'package:taro_music/features/player/data/extractors/extractor_chain.dart';
import 'package:taro_music/features/player/data/extractors/stream_extractor.dart';
import 'package:taro_music/features/player/data/repositories/fallback_media_repository.dart';
import 'package:taro_music/features/player/data/sources/search_source.dart';
import 'package:taro_music/features/player/domain/search_results.dart';
import 'package:taro_music/features/player/domain/track.dart';

/// A [SearchSource] that records every call and answers with a fixed outcome.
class _RecordingSource implements SearchSource {
  _RecordingSource(this.kind, {required this.scopes, this.error})
    : label = kind.name;

  @override
  final MediaSourceKind kind;
  @override
  final String label;
  final Set<SearchScope> scopes;
  final Object? error;

  /// One entry per call: `(query, continuation, scope)`.
  final List<_Call> calls = <_Call>[];

  @override
  bool supportsScope(SearchScope scope) => scopes.contains(scope);

  @override
  Future<SearchResults> search(
    String query, {
    String? continuation,
    SearchScope filter = SearchScope.songs,
  }) async {
    calls.add(_Call(query, continuation, filter));
    if (error != null) throw error!;
    return SearchResults(
      tracks: const <Track>[],
      source: kind,
      continuation: 'next-${kind.name}',
    );
  }
}

class _Call {
  const _Call(this.query, this.continuation, this.scope);
  final String query;
  final String? continuation;
  final SearchScope scope;
}

/// The songs chain as wired in `MediaStack.live()`: catalogue first, YouTube
/// answers only videos, Piped catches both.
class _Chain {
  _Chain({Object? ytmusicError, Object? youtubeError, Object? pipedError})
    : ytmusic = _RecordingSource(
        MediaSourceKind.ytmusic,
        scopes: const {SearchScope.songs},
        error: ytmusicError,
      ),
      youtube = _RecordingSource(
        MediaSourceKind.youtube,
        scopes: const {SearchScope.videos},
        error: youtubeError,
      ),
      piped = _RecordingSource(
        MediaSourceKind.piped,
        scopes: const {SearchScope.songs, SearchScope.videos},
        error: pipedError,
      ) {
    repository = FallbackMediaRepository(
      searchSources: <SearchSource>[ytmusic, youtube, piped],
      extractorChain: ExtractorChain(<StreamExtractor>[]),
      attemptsPerSource: 1,
      baseDelay: Duration.zero,
      maxDelay: Duration.zero,
    );
  }

  final _RecordingSource ytmusic;
  final _RecordingSource youtube;
  final _RecordingSource piped;
  late final FallbackMediaRepository repository;
}

void main() {
  group('FallbackMediaRepository scope routing', () {
    test('Songs are served by YouTube Music and never reach YouTube', () async {
      final chain = _Chain();
      final results = await chain.repository.search('daftpunk');
      expect(results.source, MediaSourceKind.ytmusic);
      expect(chain.ytmusic.calls.single.scope, SearchScope.songs);
      expect(chain.youtube.calls, isEmpty);
      expect(chain.piped.calls, isEmpty);
    });

    test('Songs fall back to Piped when the catalogue fails', () async {
      final chain = _Chain(
        ytmusicError: const NetworkFailure('catalogue down'),
      );
      final results = await chain.repository.search('daftpunk');
      expect(results.source, MediaSourceKind.piped);
      expect(chain.piped.calls.single.scope, SearchScope.songs);
      expect(chain.youtube.calls, isEmpty);
    });

    test(
      'Songs failing on both strict sources report both, and never '
      'degrade to regular YouTube search',
      () async {
        final chain = _Chain(
          ytmusicError: const NetworkFailure(
            'catalogue down',
            source: MediaSourceKind.ytmusic,
          ),
          pipedError: const NetworkFailure(
            'piped down',
            source: MediaSourceKind.piped,
          ),
        );
        await expectLater(
          chain.repository.search('daftpunk'),
          throwsA(
            isA<AllSourcesFailedFailure>().having(
              (f) => f.failures.map((failure) => failure.source).toSet(),
              'sources tried',
              {MediaSourceKind.ytmusic, MediaSourceKind.piped},
            ),
          ),
        );
        expect(chain.youtube.calls, isEmpty);
      },
    );

    test('Videos go to YouTube search and never reach the catalogue', () async {
      final chain = _Chain();
      final results = await chain.repository.search(
        'daftpunk',
        filter: SearchScope.videos,
      );
      expect(results.source, MediaSourceKind.youtube);
      expect(chain.youtube.calls.single.scope, SearchScope.videos);
      expect(chain.ytmusic.calls, isEmpty);
    });

    test('Videos fall through to Piped when YouTube search fails', () async {
      final chain = _Chain(youtubeError: const NetworkFailure('bot check'));
      final results = await chain.repository.search(
        'daftpunk',
        filter: SearchScope.videos,
      );
      expect(results.source, MediaSourceKind.piped);
      expect(chain.piped.calls.single.scope, SearchScope.videos);
      expect(chain.ytmusic.calls, isEmpty);
    });

    test('a continuation replays only with its issuer', () async {
      final chain = _Chain();
      await chain.repository.search(
        'daftpunk',
        continuation: 'piped:nextpage123',
      );
      expect(chain.piped.calls.single.continuation, 'nextpage123');
      expect(chain.ytmusic.calls, isEmpty);
      expect(chain.youtube.calls, isEmpty);
    });

    test(
      'a continuation from a source that cannot serve the scope fails',
      () async {
        final chain = _Chain();
        // A songs continuation can never come from YouTube search; routing it
        // back to its issuer must not silently answer from another provider.
        await expectLater(
          chain.repository.search(
            'daftpunk',
            continuation: 'youtube:stale',
            filter: SearchScope.songs,
          ),
          throwsA(isA<InvalidStateFailure>()),
        );
      },
    );

    test('an empty query short-circuits without touching any source', () async {
      final chain = _Chain();
      final results = await chain.repository.search('   ');
      expect(results.tracks, isEmpty);
      expect(chain.ytmusic.calls, isEmpty);
      expect(chain.youtube.calls, isEmpty);
      expect(chain.piped.calls, isEmpty);
    });
  });
}