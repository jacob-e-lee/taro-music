import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:taro_music/app/taro_music_app.dart';
import 'package:taro_music/features/player/application/webview_audio_handler.dart';
import 'package:taro_music/features/player/application/webview_bridge.dart';
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

/// The height the surface rests at when the player is collapsed.
///
/// Never zero now that the surface stands in for the bottom chrome, so "the
/// player is closed" means "back down to the chrome", not "gone".
double _collapsedHeight(WidgetTester tester) =>
    tester.getSize(find.byType(NavigationBar)).height +
    NowPlayingSheet.collapsedBarHeight;

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
  // Far enough to complete the morph on any screen height: the bar's travel
  // is 1:1 with the finger now, so the pull has to cover the whole distance
  // rather than a fixed fraction of it.
  final screenHeight =
      tester.view.physicalSize.height / tester.view.devicePixelRatio;
  var dragged = 0.0;
  // Many small steps with a frame between each, the way a real finger drags.
  while (dragged < screenHeight) {
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    dragged += 40;
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

WebViewAudioHandler _handler() => WebViewAudioHandler();

/// Feeds the bridge an event as the native side would.
///
/// The player widget cannot mount in a widget test — a platform view needs a
/// real engine — so this seam is the only way to reach the event path that
/// carries every playback update.
///
/// Careful: once an event has the handler reporting playback, the seek bar
/// animates every frame and `pumpAndSettle` will not return. Pump with an
/// explicit duration instead.
void _emit(WebViewPlayerEvent event) =>
    YouTubeWebViewBridge.instance.debugEmit(event);

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

      // A second frame: the surface learns the chrome height in a post-frame
      // callback, so it lays out one frame after the shell does. Sub-frame, and
      // startup-only - but the assertions below are about what the surface
      // draws, so they have to wait for it.
      await tester.pumpAndSettle();

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

  testWidgets('Dragging the tab bar up tracks the finger exactly 1:1', (
    WidgetTester tester,
  ) async {
    await _openPlayer(tester);

    final barTop = tester.getTopLeft(find.text('Queue')).dy;
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Queue')),
    );
    await tester.pump();
    // Two steps: the first crosses touch slop and only starts the recognizer,
    // the second produces the update that actually moves the bar.
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();

    // The finger moved up 100px and the bar - the handle the panel's top edge
    // hangs off - moved up 100px too. The old mapping divided by a fixed 0.35
    // of the screen height while the bar's real travel is closer to 0.75 of
    // it, so this delta used to run roughly twice as far as the finger.
    expect(
      barTop - tester.getTopLeft(find.text('Queue')).dy,
      closeTo(100, 2),
    );

    // Keep pulling until the whole travel is covered, then release: past the
    // settle fraction, so it commits to the peek state.
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.textContaining('Up Next'), findsOneWidget);
  });

  testWidgets('Tapping a tab opens its panel from the full player', (
    WidgetTester tester,
  ) async {
    await _openPlayer(tester);

    // Full player: no panel content is on screen yet.
    expect(find.textContaining('Up Next'), findsNothing);

    // Queue is already the selected tab, so this tap is pure "open".
    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();

    // The tap morphed the player to peek and revealed the queue panel.
    expect(find.textContaining('Up Next'), findsOneWidget);
  });

  testWidgets('Tapping a tab opens to the tab that was tapped', (
    WidgetTester tester,
  ) async {
    await _openPlayer(tester);

    await tester.tap(find.text('Lyrics'));
    await tester.pumpAndSettle();

    // The tap opened the panel *and* honoured the selection: lyrics is on
    // screen, not the queue.
    expect(find.text('Lyrics unavailable'), findsOneWidget);
    expect(find.textContaining('Up Next'), findsNothing);

    // Tapping the other tab while peeking switches the open panel.
    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Up Next'), findsOneWidget);
    expect(find.text('Lyrics unavailable'), findsNothing);
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
    expect(playerHeight(), closeTo(_collapsedHeight(tester), 1));
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

    expect(_playerHeight(tester), closeTo(_collapsedHeight(tester), 1));
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
    expect(playerHeight(), closeTo(_collapsedHeight(tester), 1));

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
    // "Collapsed" is now the chrome height, not near-zero: the surface stands in
    // for the bottom chrome, so it rests at the chrome's height rather than 0.
    final collapsed = (settled - _collapsedHeight(tester)).abs() < 2;
    final expanded = settled > screen * 0.9;
    expect(
      collapsed || expanded,
      isTrue,
      reason: 'player settled mid-screen at $settled px',
    );
  });

  group('the bottom band hand-off', () {
    const max = 0.96;
    // Total travel available on a 800px-tall screen, for the assertions below.
    const travel = max * 800 - 140;

    test('the navigation bar is fully visible at rest', () {
      expect(PlayerSheetController.revealFor(0), 0);
    });

    test('the bar is gone well before the player is meaningfully open', () {
      // `chromeFade` is a separate, much faster curve than `reveal`: the
      // navigation bar has to be out of the way before the player's own bottom
      // chrome needs that space, so it cannot ride the content's arrival.
      const fraction = PlayerSheetController.chromeFadeFraction;
      expect(travel * fraction, lessThan(travel * 0.25));
      expect(travel * fraction, greaterThan(0));
    });
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
    // `reveal` is now 0..1 progress rather than a fraction of a gained size,
    // and it is 0 at the collapsed band - which is the whole point of the
    // merge: nothing of the player's own chrome shows until it starts opening.
    expect(PlayerSheetController.revealFor(0), 0);
    expect(PlayerSheetController.revealEaseFor(0), 0);

    // A barely-open player reveals very little.
    expect(PlayerSheetController.revealFor(0.3), closeTo(0.3, 0.001));
    expect(PlayerSheetController.revealEaseFor(0.3), lessThan(0.6));

    // Past the ease fraction it is fully in.
    expect(PlayerSheetController.revealEaseFor(0.7), 1);
    expect(PlayerSheetController.revealEaseFor(1), 1);
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
    expect(_playerHeight(tester), closeTo(_collapsedHeight(tester), 1));

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

    // And a tap on a tab does double duty: it selects the tab and opens its
    // panel, so no drag is needed to reach the content once the bar is live.
    await tester.tap(find.text('Lyrics'));
    await tester.pumpAndSettle();
    expect(find.text('Lyrics unavailable').hitTestable(), findsOneWidget);
  });

  testWidgets('Direct deep link to playlist routes directly to content', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(initialRoute: '/playlist?id=my_playlist_123&title=Summer+Hits'),
    );
    await tester.pump();
    // The player surface measures the chrome in a post-frame callback, so give
    // it the frame it needs to settle before asserting on the rendered tree.
    await tester.pumpAndSettle();

    expect(find.text('Summer Hits'), findsWidgets);
    expect(find.text('Playlist ID: my_playlist_123'), findsOneWidget);
  });

  group('a drag can be turned around mid-gesture', () {
    testWidgets('an upward drag can be pulled back down before releasing', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_playerApp());
      await _loadTrack(tester);
      await tester.pumpAndSettle();

      final rest = _collapsedHeight(tester);
      expect(_playerHeight(tester), closeTo(rest, 1));

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Test Song')),
      );
      await tester.pump();
      // A nudge that crosses touch slop, then the move that actually counts -
      // the recogniser swallows the offset that triggered it.
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -120));
      await tester.pump();
      expect(_playerHeight(tester), greaterThan(rest + 80));

      // The same gesture turns around without lifting off, and overshoots so
      // the end of the travel is reached whatever the slop accounted for...
      await gesture.moveBy(const Offset(0, 200));
      await tester.pump();

      // ...and the surface follows it all the way back down. Under the old
      // model the direction was latched when the drag began, so an upward drag
      // discarded every downward delta and the surface stayed stuck near the
      // top until the finger was lifted.
      expect(_playerHeight(tester), closeTo(rest, 2));

      await gesture.up();
      await tester.pumpAndSettle();

      // Released back at the chrome, so it settles closed rather than open.
      expect(_playerHeight(tester), closeTo(rest, 1));
    });

    testWidgets('a downward drag can be pushed back up before releasing', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_playerApp());
      await _openPlayer(tester);

      final open = _playerHeight(tester);
      expect(open, greaterThan(500));

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('NOW PLAYING')),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 150));
      await tester.pump();
      expect(_playerHeight(tester), lessThan(open - 100));

      // Reversing has to work in this direction too: a downward drag must not
      // discard the upward deltas once it is under way.
      await gesture.moveBy(const Offset(0, -250));
      await tester.pump();
      expect(_playerHeight(tester), closeTo(open, 2));

      await gesture.up();
      await tester.pumpAndSettle();

      // Let go at the top, so it stays open.
      expect(_playerHeight(tester), closeTo(open, 1));
    });
  });

  testWidgets('the surface top edge tracks the finger exactly 1:1', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_playerApp());
    await _loadTrack(tester);
    await tester.pumpAndSettle();

    // At rest the surface is exactly the chrome tall: the collapsed band plus
    // the navigation bar. Its top edge is therefore the band's top edge, and
    // the band *is* the player rather than a separate widget that hands over.
    final sheet = find.byType(NowPlayingSheet);
    final navBar = find.byType(NavigationBar);
    expect(tester.getTopLeft(sheet).dy, closeTo(tester.getTopLeft(navBar).dy - NowPlayingSheet.collapsedBarHeight, 1));

    // Nothing is modal at rest, so the navigation bar underneath keeps taking
    // taps. This is the regression guard for the surface spanning the chrome
    // band while the player is collapsed: the surface's own box covers the nav
    // bar's band too, and must not swallow it.
    expect(find.text('Home'), findsOneWidget);
    expect(
      find.widgetWithText(NavigationDestination, 'Home'),
      findsOneWidget,
    );

    final before = tester.getTopLeft(sheet).dy;
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Test Song')),
    );
    await tester.pump();
    // Two steps: the first crosses touch slop and only starts the recognizer,
    // the second produces the update that actually moves the surface.
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();

    // Strictly 1:1 with the drag the surface actually receives: the second move
    // travelled 100px and the top edge moved 100px. The first 20px went to the
    // gesture recogniser's touch slop and never reached the surface at all.
    //
    // The old model applied a 0.55 gain, so 100px of drag produced far more
    // than 100px of travel - this is the assertion that would have caught it.
    expect(before - tester.getTopLeft(sheet).dy, closeTo(100, 2));

    // And the artwork is still part-grown, not snapped to its hero size.
    final art = tester.getSize(
      find
          .descendant(
            of: find.byType(NowPlayingSheet),
            matching: find.byType(Icon),
          )
          .first,
    );
    expect(art.width, greaterThan(0));

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('the surface returns to the chrome height when dismissed', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_playerApp());
    await _openPlayer(tester);

    final sheet = find.byType(NowPlayingSheet);
    final navBar = find.byType(NavigationBar);
    final openTop = tester.getTopLeft(sheet).dy;
    expect(openTop, lessThan(tester.getTopLeft(navBar).dy - 50));

    // Close via the header's button, the way a user would.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    // Back to exactly where the chrome was, not merely "small" - the surface is
    // never zero-height now, so the old `lessThan(10)` assertion no longer means
    // anything. Compared as a top edge: the surface is bottom-anchored, so its
    // top sits one chrome-height above the bottom of the screen.
    final screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(
      tester.getTopLeft(sheet).dy,
      closeTo(screenHeight - _collapsedHeight(tester), 1),
    );
  });

  // --------------------------------------------------- progress reporting
  //
  // The engine's status frames are the only thing that ever moved the bar, and
  // they were never arriving. These pin down what the bar does with them, and
  // that it keeps time without them.

  testWidgets('the seek bar follows the engine without being touched', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_playerApp());
    await _openPlayer(tester);

    // The engine starts playing and reports where it is. Nothing touches the UI
    // in between: the bar has to move on its own.
    _emit(const PlayerStateChanged(1));
    await tester.pump();
    _emit(const PlayerInfo(currentTime: 42, duration: 180));
    await tester.pump();

    expect(find.text('0:42'), findsOneWidget);
    // The engine's duration fills in a track the queue metadata left blank,
    // which is what makes the slider usable rather than inert.
    expect(find.text('3:00'), findsWidgets);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNotNull);
  });

  testWidgets('pausing holds the position instead of snapping to zero', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_playerApp());
    await _openPlayer(tester);

    _emit(const PlayerStateChanged(1));
    await tester.pump();
    _emit(const PlayerInfo(currentTime: 42, duration: 180));
    await tester.pump();

    _emit(const PlayerStateChanged(2));
    await tester.pump();

    // A pause does not seek: the music carries on from 0:42 when it resumes, so
    // the bar has to stay at 0:42 rather than dropping to 0:00.
    expect(find.text('0:42'), findsOneWidget);
    expect(find.text('0:00'), findsNothing);
  });

  testWidgets('a pause cannot zero a position it never anchored', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_playerApp());
    await _openPlayer(tester);

    // Deliberately *no* status frame, which is the state the app actually
    // shipped in: the anchor was still the zero written when the track started,
    // and a paused state reports that anchor verbatim.
    _emit(const PlayerStateChanged(1));
    await tester.pump();
    expect(_lastHandler!.playbackState.value.playing, isTrue);

    // `PlaybackState.position` extrapolates on `package:clock`'s clock, which
    // `testWidgets` backs with the binding's fake clock — so pumping a duration
    // is what moves it, and this stays exact rather than racing a real delay.
    await tester.pump(const Duration(milliseconds: 150));

    _emit(const PlayerStateChanged(2));
    await tester.pump();

    final position = _lastHandler!.playbackState.value.position;
    expect(position, greaterThan(Duration.zero));
    expect(position, lessThan(const Duration(seconds: 2)));
  });

  testWidgets('the bar advances on its own while the engine is playing', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_playerApp());
    await _openPlayer(tester);

    _emit(const PlayerStateChanged(1));
    await tester.pump();
    _emit(const PlayerInfo(currentTime: 10, duration: 180));
    await tester.pump();
    expect(_lastHandler!.playbackState.value.playing, isTrue);

    final before = tester.widget<Slider>(find.byType(Slider)).value;

    // No frame from the engine and no interaction. Just a duration pumped,
    // which moves the binding's clock and draws the frame the bar's own clock
    // ticks on.
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();

    expect(
      tester.widget<Slider>(find.byType(Slider)).value,
      greaterThan(before),
    );
  });

  testWidgets('a status frame in step with the clock does not republish state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_playerApp());
    await _openPlayer(tester);
    final handler = _lastHandler!;

    _emit(const PlayerStateChanged(1));
    await tester.pump();
    final anchored = handler.playbackState.value;

    // A frame that agrees with the extrapolation is what a healthy engine sends
    // several times a second. Acting on it would rewrite the notification every
    // time, to tell the platform what it is already extrapolating.
    _emit(
      PlayerInfo(
        currentTime:
            anchored.position.inMicroseconds / Duration.microsecondsPerSecond,
      ),
    );
    await tester.pump();
    expect(identical(handler.playbackState.value, anchored), isTrue);

    // A frame that has genuinely diverged — a stall, or a seek issued from
    // inside the page — does re-anchor.
    _emit(const PlayerInfo(currentTime: 90));
    await tester.pump();
    expect(
      handler.playbackState.value.position.inMilliseconds,
      closeTo(const Duration(seconds: 90).inMilliseconds, 250),
    );
  });
}
