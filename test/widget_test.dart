import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:taro_music/app/taro_music_app.dart';
import 'package:taro_music/features/player/application/audio_handler.dart';
import 'package:taro_music/features/player/application/providers.dart';
import 'package:taro_music/features/player/domain/media_repository.dart';
import 'package:taro_music/features/player/domain/playback_source.dart';
import 'package:taro_music/features/player/domain/search_results.dart';
import 'package:taro_music/features/player/domain/track.dart';

/// A stub repository: the widget tests below never trigger search or stream
/// resolution (they only pump the empty state and push a [MediaItem]
/// directly), so every call just throws. Constructing the real handler is
/// safe — `AudioPlayer()` only touches platform channels once playback
/// starts, which these tests never do.
class _StubRepository implements MediaRepository {
  @override
  Future<SearchResults> search(String query, {String? continuation}) =>
      throw UnimplementedError('not used in widget tests');

  @override
  Future<PlaybackSource> resolveSource(Track track) =>
      throw UnimplementedError('not used in widget tests');
}

MusicAudioHandler _handler() =>
    MusicAudioHandler(repository: _StubRepository());

Widget _app() => ProviderScope(
  overrides: [audioHandlerProvider.overrideWithValue(_handler())],
  child: const TaroMusicApp(),
);

void main() {
  testWidgets('App boots to search prompt', (WidgetTester tester) async {
    await tester.pumpWidget(_app());

    expect(find.text('Search for music to start listening'), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
  });

  testWidgets('Mini player stays hidden until the first track loads', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app());

    expect(find.text('Search for music to start listening'), findsOneWidget);
    // No media item yet, so the mini player renders nothing tappable.
    expect(find.byIcon(Icons.play_arrow), findsNothing);
  });

  testWidgets('Mini player appears once a track is loaded', (
    WidgetTester tester,
  ) async {
    final handler = _handler();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [audioHandlerProvider.overrideWithValue(handler)],
        child: const TaroMusicApp(),
      ),
    );

    handler.mediaItem.add(
      const MediaItem(
        id: 'video-id',
        title: 'Test Song',
        artist: 'Test Artist',
      ),
    );
    await tester.pump();

    expect(find.text('Test Song'), findsOneWidget);
  });
}
