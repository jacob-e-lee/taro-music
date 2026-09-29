import 'package:dart_ytmusic_api/types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taro_music/core/errors/failures.dart';
import 'package:taro_music/features/player/data/sources/search_source.dart';
import 'package:taro_music/features/player/data/sources/ytmusic_search_source.dart';
import 'package:taro_music/features/player/domain/search_results.dart';
import 'package:taro_music/features/player/domain/track.dart';

SongDetailed _song({
  String videoId = 'dQw4w9WgXcQ',
  String name = 'Never Gonna Give You Up',
  String artist = 'Rick Astley',
  String? album,
  int? duration = 213,
  List<ThumbnailFull> thumbnails = const <ThumbnailFull>[],
}) => SongDetailed(
  type: 'SONG',
  videoId: videoId,
  name: name,
  artist: ArtistBasic(artistId: 'UCuwP9PbrqQJyQNSG0Bb0vsQ', name: artist),
  album: album == null
      ? null
      : AlbumBasic(albumId: 'MPRE_b', name: album),
  duration: duration,
  thumbnails: thumbnails,
);

void main() {
  group('YTMusicSearchSource identity', () {
    final source = YTMusicSearchSource();

    test('is the ytmusic kind and only answers the songs scope', () {
      expect(source.kind, MediaSourceKind.ytmusic);
      expect(source.label, 'YouTube Music');
      expect(source.supportsScope(SearchScope.songs), isTrue);
      expect(source.supportsScope(SearchScope.videos), isFalse);
    });

    test('a videos-scope request is refused before any network work', () async {
      await expectLater(
        source.search('beethoven', filter: SearchScope.videos),
        throwsA(isA<InvalidStateFailure>()),
      );
    });

    test('a continuation is refused — song search never issues one', () async {
      await expectLater(
        source.search('beethoven', continuation: 'stale-token'),
        throwsA(isA<InvalidStateFailure>()),
      );
    });
  });

  group('YTMusicSearchSource.trackFrom', () {
    test('maps a full catalogue entry', () {
      final track = YTMusicSearchSource.trackFrom(
        _song(album: 'Whenever You Need Somebody'),
      );
      expect(track, isNotNull);
      expect(track!.id, 'dQw4w9WgXcQ');
      expect(track.title, 'Never Gonna Give You Up');
      expect(track.artist, 'Rick Astley');
      expect(track.album, 'Whenever You Need Somebody');
      expect(track.duration, const Duration(seconds: 213));
      expect(track.source, MediaSourceKind.ytmusic);
      expect(track.isLive, isFalse);
    });

    test('drops entries without a playable id', () {
      expect(YTMusicSearchSource.trackFrom(_song(videoId: '')), isNull);
    });

    test('missing duration becomes Duration.zero (unknown length)', () {
      final track = YTMusicSearchSource.trackFrom(_song(duration: null))!;
      expect(track.duration, Duration.zero);
      expect(track.isLiveOrUnknownLength, isTrue);
    });

    test('an empty title still yields a listable track', () {
      final track = YTMusicSearchSource.trackFrom(_song(name: ''))!;
      expect(track.title, 'Unknown title');
    });

    test('the largest thumbnail wins', () {
      final track = YTMusicSearchSource.trackFrom(
        _song(
          thumbnails: <ThumbnailFull>[
            ThumbnailFull(url: 'https://img/small.jpg', width: 60, height: 60),
            ThumbnailFull(url: 'https://img/max.jpg', width: 600, height: 600),
            ThumbnailFull(url: 'https://img/mid.jpg', width: 320, height: 320),
          ],
        ),
      )!;
      expect(track.artworkUrl, 'https://img/max.jpg');
    });

    test('no thumbnails means no artwork', () {
      final track = YTMusicSearchSource.trackFrom(_song())!;
      expect(track.hasArtwork, isFalse);
    });

    test('mapped tracks survive the media-item extras round trip', () {
      final track = YTMusicSearchSource.trackFrom(
        _song(album: 'Whenever You Need Somebody'),
      )!;
      final restored = Track.fromExtras(track.toExtras());
      expect(restored, track);
    });
  });

  test('implements the SearchSource contract', () {
    expect(YTMusicSearchSource(), isA<SearchSource>());
  });
}
