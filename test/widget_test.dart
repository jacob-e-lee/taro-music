import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:taro_music/app/taro_music_app.dart';
import 'package:taro_music/features/player/application/webview_audio_handler.dart';
import 'package:taro_music/features/player/application/providers.dart';
import 'package:taro_music/features/player/presentation/now_playing_sheet.dart';
import 'package:taro_music/features/player/presentation/player_sheet_controller.dart';

/// A shell with no media loaded yet.
///
/// The handler is constructed but never `start()`ed: a real WebView needs
/// platform channels that a widget test does not have, and the handler is
/// inert without it — queue commands issued early are simply dropped. That
/// keeps these tests about the UI rather than about the audio engine.
WebViewAudioHandler? _lastHandler;

/// A shell with no media loaded yet.
Widget _playerApp() {
  final handler = _handler();
  _lastHandler = handler;
  return ProviderScope(
    overrides: [audioHandlerProvider.overrideWithValue(handler)],
    child: const TaroMusicApp(),
  );
}

/// The rendered height of the player sheet.
double _playerHeight(WidgetTester tester) => tester
    .getSize(
      find
          .descendant(
            of: find.byType(NowPlayingSheet),
            matching: find.byType(Material),
          )
          .first,
    )
    .height;

/// Loads a track and queues a second entry, without opening the player.
Future<void> _loadTrack(WidgetTester tester) async {
  final handler = _lastHandler!;
  handler.mediaItem.add(
    const MediaItem(id: 'v', title: 'Test Song', artist: 'Test Artist'),
  );
  await handler.addQueueItems(<MediaItem>[
    const MediaItem(id: 'v', title: 'Test Song', artist: 'Test Artist'),
    const MediaItem(id: 'v2', title: 'Second', artist: 'Second Artist'),
  ]);
  await tester.pump();
  await tester.pumpAndSettle();
}

/// Loads a track and opens the player with a tap.
Future<void> _openOn(WidgetTester tester) async {
  await _loadTrack(tester);
  await tester.tap(find.text('Test Song'));
  await tester.pumpAndSettle();
}

/// Pumps a shell, loads a track, and opens the player.
Future<void> _openPlayer(WidgetTester tester) async {
  await tester.pumpWidget(_playerApp());
  await _openOn(tester);
}

/// Drags the tab bar upwards to reach the peek state.
Future<void> _peek(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.text('Queue')),
  );
  await tester.pump();
  // Many small steps with a frame between each, the way a real finger drags.
  for (var i = 0; i < 8; i++) {
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

WebViewAudioHandler _handler() => WebViewAudioHandler();

Widget _app({String? initialRoute}) => ProviderScope(
  overrides: [audioHandlerProvider.overrideWithValue(_handler())],
  child: TaroMusicApp(initialRoute: initialRoute),
);

void main() {
  testWidgets('App boots to 3-tab shell with Home, Search, and Library', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app());

    // Navigation bar destinations present
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);

    // Switches to Search tab via navigation bar
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();

    expect(find.text('Search for music to start listening'), findsOneWidget);
  });

  testWidgets('Swiping left and right navigates smoothly between screens', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app());

    // Starts on Home tab
    expect(find.text('Quick Picks'), findsOneWidget);

    // Swipe left: from Home -> Search
    await tester.fling(find.byType(PageView), const Offset(-500, 0), 1000);
    await tester.pumpAndSettle();

    // Now on Search tab
    expect(find.text('Search for music to start listening'), findsOneWidget);

    // Swipe left: from Search -> Library
    await tester.fling(find.byType(PageView), const Offset(-500, 0), 1000);
    await tester.pumpAndSettle();

    // Now on Library tab
    expect(find.text('Your Library'), findsOneWidget);

    // Swipe right: from Library -> Search
    await tester.fling(find.byType(PageView), const Offset(500, 0), 1000);
    await tester.pumpAndSettle();

    expect(find.text('Search for music to start listening'), findsOneWidget);

    // Swipe right: from Search -> Home
    await tester.fling(find.byType(PageView), const Offset(500, 0), 1000);
    await tester.pumpAndSettle();

    expect(find.text('Quick Picks'), findsOneWidget);
  });

  testWidgets('Mini player stays hidden until the first track loads', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app());

    // No media item yet, so the mini player renders nothing tappable.
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
  });

  testWidgets(
    'Mini player appears and persists across tab switches once a track is loaded',
    (WidgetTester tester) async {
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

      // Mini player visible on Home tab
      expect(find.text('Test Song'), findsOneWidget);

      // Switch to Search tab
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();

      // Mini player still visible uninterrupted on Search tab
      expect(find.text('Test Song'), findsOneWidget);

      // Switch to Library tab
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();

      // Mini player still visible uninterrupted on Library tab
      expect(find.text('Test Song'), findsOneWidget);
    },
  );

  testWidgets('Search scope toggle switches between Songs and Videos', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app());

    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();

    // Both scope options sit directly under the search bar.
    expect(find.text('Songs'), findsOneWidget);
    expect(find.text('Videos'), findsOneWidget);

    // Flipping to Videos must not clear the query.
    await tester.tap(find.text('Videos'));
    await tester.pumpAndSettle();

    expect(find.text('Videos'), findsOneWidget);
    expect(find.text('Search for music to start listening'), findsOneWidget);
  });

  testWidgets(
    'Dragging the mini player up pulls the real player with the finger',
    (WidgetTester tester) async {
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
      await tester.pumpAndSettle();

      // The player's scrim is the only black, partially transparent box in the
      // shell; its opacity tracks the sheet height frame-for-frame.
      double scrimOpacity() {
        final matches = find
            .byWidgetPredicate(
              (w) =>
                  w is ColoredBox &&
                  w.color.r == 0 &&
                  w.color.g == 0 &&
                  w.color.b == 0 &&
                  w.color.a < 1,
            )
            .evaluate();
        if (matches.isEmpty) return 0;
        return matches
            .map((e) => (e.widget as ColoredBox).color.a)
            .reduce((a, b) => a > b ? a : b);
      }

      expect(scrimOpacity(), 0);

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Test Song')),
      );
      await tester.pump();
      // Two steps: the first crosses touch slop and only starts the recognizer,
      // the second produces the update that actually moves the player.
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -200));
      await tester.pump();

      // The key assertion: the real player is already coming up *before* the
      // finger lifts, rather than popping into view on release.
      expect(scrimOpacity(), greaterThan(0));

      await gesture.up();
      await tester.pumpAndSettle();

      // Released past the threshold, so it settles fully open.
      expect(scrimOpacity(), closeTo(0.5, 0.01));
    },
  );
  testWidgets('The queue sits behind a tab, not in the player page', (
    WidgetTester tester,
  ) async {
    await _openPlayer(tester);

    // Both tabs are present, and the queue is not on the page.
    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('Lyrics'), findsOneWidget);
    expect(find.textContaining('Up Next'), findsNothing);
    // The old "scroll for queue" affordance is gone.
    expect(find.text('Scroll for queue'), findsNothing);
  });

  testWidgets('Dragging the tab bar up reveals the tab content', (
    WidgetTester tester,
  ) async {
    await _openPlayer(tester);

    await _peek(tester);

    expect(find.textContaining('Up Next'), findsOneWidget);
  });

  testWidgets('The lyrics tab shows the unavailable state', (
    WidgetTester tester,
  ) async {
    await _openPlayer(tester);
    await _peek(tester);

    await tester.tap(find.text('Lyrics'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Up Next'), findsNothing);
  });

  testWidgets('Peeking drops shuffle and repeat, keeps play and next', (
    WidgetTester tester,
  ) async {
    await _openPlayer(tester);

    // Full state: the full transport row is live.
    expect(find.byIcon(Icons.shuffle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.repeat_rounded), findsOneWidget);

    await _peek(tester);

    // Peek: no shuffle, no repeat. They are faded out rather than removed, so
    // the assertion is about being reachable, not about being in the tree.
    expect(find.byIcon(Icons.shuffle_rounded).hitTestable(), findsNothing);
    expect(find.byIcon(Icons.repeat_rounded).hitTestable(), findsNothing);
    expect(find.byIcon(Icons.play_arrow).hitTestable(), findsWidgets);
  });

  testWidgets('Swiping down on the player minimises it', (
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
      const MediaItem(id: 'v', title: 'Test Song', artist: 'Test Artist'),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    double playerHeight() => tester
        .getSize(
          find
              .descendant(
                of: find.byType(NowPlayingSheet),
                matching: find.byType(Material),
              )
              .first,
        )
        .height;

    await tester.tap(find.text('Test Song'));
    await tester.pumpAndSettle();
    expect(playerHeight(), greaterThan(500));

    // A decisive downward flick must dismiss, not spring back open.
    await tester.fling(find.text('NOW PLAYING'), const Offset(0, 300), 2000);
    await tester.pumpAndSettle();
    expect(playerHeight(), lessThan(10));
  });

  testWidgets('A downward drag past halfway minimises the player', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_playerApp());
    await _openOn(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('NOW PLAYING')),
    );
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(_playerHeight(tester), lessThan(10));
  });

  testWidgets('A small downward drag springs back open', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_playerApp());
    await _openOn(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('NOW PLAYING')),
    );
    await tester.pump();
    for (var i = 0; i < 2; i++) {
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(_playerHeight(tester), greaterThan(500));
  });

  testWidgets('Scrolling the queue does not dismiss the player', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_playerApp());
    await _openOn(tester);
    await _peek(tester);

    final openHeight = _playerHeight(tester);
    expect(find.textContaining('Up Next'), findsOneWidget);

    // The queue has its own scroll view. Scrolling it must not be mistaken
    // for a swipe-down-to-dismiss.
    await tester.drag(find.textContaining('Up Next'), const Offset(0, -120));
    await tester.pumpAndSettle();
    await tester.drag(find.textContaining('Up Next'), const Offset(0, 120));
    await tester.pumpAndSettle();

    expect(_playerHeight(tester), closeTo(openHeight, 1));
  });

  testWidgets('Letting go mid-screen always snaps the player to an end', (
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
    await tester.pumpAndSettle();

    // The Material directly inside the sheet is sized to the sheet, so its
    // height is a direct read of where the player actually is. Opacity cannot
    // be used here: it saturates, and a stranded half-height player looks
    // exactly as opaque as a fully open one.
    double playerHeight() => tester
        .getSize(
          find
              .descendant(
                of: find.byType(NowPlayingSheet),
                matching: find.byType(Material),
              )
              .first,
        )
        .height;

    const screen = 600.0;
    expect(playerHeight(), lessThan(1));

    await tester.tap(find.text('Test Song'));
    await tester.pumpAndSettle();
    expect(playerHeight(), greaterThan(screen * 0.9));

    // Drag a long way down and let go well short of closing. Without snapping
    // the player would be left stranded around the middle of the screen.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('NOW PLAYING')),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final settled = playerHeight();
    final collapsed = settled < screen * 0.1;
    final expanded = settled > screen * 0.9;
    expect(
      collapsed || expanded,
      isTrue,
      reason: 'player settled mid-screen at $settled px',
    );
  });

  test('The mini player fades gradually, tracking the finger', () {
    const range = PlayerSheetController.chromeFadeRange;

    // At rest it is fully visible.
    expect(PlayerSheetController.chromeOpacity(0, 0, 0.96), 1);

    // Mid-drag it dissolves in proportion to how far the finger has travelled,
    // rather than vanishing: a value strictly between 0 and 1 is the whole
    // point, because previously it hit zero within a couple of percent.
    final mid = PlayerSheetController.chromeOpacity(0.4, range / 2, 0.96);
    expect(mid, closeTo(0.5, 0.01));
    expect(
      PlayerSheetController.chromeOpacity(0.4, range / 4, 0.96),
      closeTo(0.75, 0.01),
    );

    // Gone once the finger has travelled the full range.
    expect(PlayerSheetController.chromeOpacity(0.4, range, 0.96), 0);
    expect(PlayerSheetController.chromeOpacity(0.4, 0.5, 0.96), 0);
  });

  test('With no finger down the mini player tracks the reveal', () {
    // dragFraction 0 means we are not dragging, so the bar follows how much of
    // the player is showing. This is what keeps it hidden while the player is
    // open and brings it back as the player closes.
    expect(PlayerSheetController.chromeOpacity(0, 0, 0.96), 1);
    expect(PlayerSheetController.chromeOpacity(0.96, 0, 0.96), 0);
    expect(
      PlayerSheetController.chromeOpacity(0.48, 0, 0.96),
      closeTo(0.5, 0.01),
    );
  });

  testWidgets('The tab bar clears the system navigation bar', (
    WidgetTester tester,
  ) async {
    // A gesture-handle / 3-button inset at the bottom of the screen.
    tester.view.padding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.resetPadding);

    await _openPlayer(tester);

    // Whatever inset the platform actually reports, the tab bar must sit that
    // far above the bottom of the screen rather than underneath it.
    final sheet = find.byType(NowPlayingSheet);
    final inset = MediaQuery.paddingOf(tester.element(sheet)).bottom;
    expect(inset, greaterThan(0));

    final screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final sheetBottom = tester.getBottomLeft(sheet).dy;
    final tabBarBottom = tester.getBottomLeft(find.text('Queue')).dy;

    expect(sheetBottom - tabBarBottom, greaterThanOrEqualTo(inset - 1));
    expect(tabBarBottom, lessThanOrEqualTo(screenHeight - inset));
  });

  test('The reveal axis holds content back until the player is open', () {
    const max = 0.96;

    // Nothing is revealed while collapsed, and the eased form lags the raw
    // reveal so the controls and tabs do not appear the instant the sheet does.
    expect(PlayerSheetController.revealFor(0, max), 0);
    expect(PlayerSheetController.revealEaseFor(0, max), 0);

    // A barely-open player reveals very little.
    expect(
      PlayerSheetController.revealFor(max * 0.3, max),
      closeTo(0.3, 0.001),
    );
    expect(PlayerSheetController.revealEaseFor(max * 0.3, max), lessThan(0.6));

    // Past the ease fraction it is fully in.
    expect(PlayerSheetController.revealEaseFor(max * 0.7, max), 1);
    expect(PlayerSheetController.revealEaseFor(max, max), 1);
  });

  testWidgets('Dismissing returns the mini player to the bottom', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_playerApp());
    await _loadTrack(tester);

    // Open by dragging the mini player up and releasing, which is what used to
    // leave the drag state behind.
    final open = await tester.startGesture(
      tester.getCenter(find.text('Test Song')),
    );
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await open.moveBy(const Offset(0, -40));
      await tester.pump();
    }
    await open.up();
    await tester.pumpAndSettle();
    expect(_playerHeight(tester), greaterThan(400));

    // Now dismiss it from the player surface.
    final dismiss = await tester.startGesture(
      tester.getCenter(find.text('NOW PLAYING')),
    );
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await dismiss.moveBy(const Offset(0, 60));
      await tester.pump();
    }
    await dismiss.up();
    await tester.pumpAndSettle();

    // The player is gone...
    expect(_playerHeight(tester), lessThan(10));

    // ...and the mini player is back down at the bottom, not stranded part way
    // up the screen.
    final screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(
      tester.getBottomLeft(find.text('Test Song')).dy,
      greaterThan(screenHeight - 140),
    );
  });

  testWidgets('Controls and tabs are usable once the player is fully open', (
    WidgetTester tester,
  ) async {
    // Guards the reveal gating against being left permanently disabled: the
    // transport and the tab bar ignore pointers until `revealEase` reaches 1,
    // so a fully open player must still hand them back.
    await _openPlayer(tester);

    expect(find.byIcon(Icons.shuffle_rounded).hitTestable(), findsOneWidget);
    expect(find.text('Queue').hitTestable(), findsOneWidget);
    expect(find.text('Lyrics').hitTestable(), findsOneWidget);

    // Tapping a tab still switches the content once the content region is
    // revealed (the tab body only exists in the peek state).
    await tester.tap(find.text('Lyrics'));
    await tester.pumpAndSettle();
    await _peek(tester);
    expect(find.text('Lyrics unavailable').hitTestable(), findsOneWidget);
  });

  testWidgets('Direct deep link to playlist routes directly to content', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(initialRoute: '/playlist?id=my_playlist_123&title=Summer+Hits'),
    );
    await tester.pump();

    expect(find.text('Summer Hits'), findsWidgets);
    expect(find.text('Playlist ID: my_playlist_123'), findsOneWidget);
  });
}
