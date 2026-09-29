# Taro Music

A free (GPL-3.0) music player for Android, built with Flutter. Search YouTube for
music, play it in the background, and control it from the notification, the lock
screen, or a headset — without ever showing a video.

Playback is driven by a hidden YouTube IFrame player living inside an Android
`WebView`. The WebView [lies about its own visibility](android/app/src/main/kotlin/com/example/taro_music/RiPlayWebView.kt)
(the "RiPlay trick"), so Chromium never fires the `visibilitychange` event that
would otherwise pause audio the moment the screen locks.

> **Platform status:** Android is the only working target. The audio engine is an
> Android platform view (`RiPlayWebView`); the `ios/`, `macos/`, `windows/`,
> `linux/` and `web/` directories are unmodified Flutter template output and the
> player will not function there.

## Features

- **Search** YouTube directly (`youtube_explode_dart`), with a Piped proxy as
  automatic fallback when YouTube bot-checks or rate-limits.
- **Background playback** with a media notification, lock-screen controls, and
  headset-button support via `audio_service`.
- **Full queue model** — shuffle, repeat one/all, skip next/previous, seek,
  playback speed, and drag-to-reorder "Up Next".
- **Now-playing sheet** that morphs continuously from the mini-player band into
  the full player with one drag gesture; the seek bar re-reads the engine clock
  once per display frame, so motion is smooth without polling the WebView.
- **Queue and Lyrics tabs** in the full player (the lyrics source is not
  implemented yet, so that tab currently renders an empty state).
- **Deep links** — `/track` and `/playlist` routes open shared content directly.
- Exponential-backoff retries across every provider, with per-attempt failures
  preserved so the UI can say exactly what was tried.

## Architecture

```
lib/
├── main.dart                  Boot order: audio session → AudioService →
│                              network stack → runApp
├── app/                       TaroMusicApp, ShellScreen (3-tab shell),
│                              deep-link routes
├── core/
│   ├── config/                AppConfig: every tunable in one place
│   │                          (Piped/Cobalt instance lists, timeouts, UAs)
│   ├── di/                    MediaStack: one YoutubeExplode + one Dio,
│   │                          created once, single teardown path
│   ├── errors/                TaroFailure hierarchy, MediaSourceKind
│   └── utils/                 Retry policy
└── features/
    ├── home/                  Home tab (currently sample content)
    ├── search/                Search tab (Riverpod, paged results)
    ├── library/               Library tab (currently sample offline tracks)
    └── player/
        ├── domain/            Track, MediaRepository, PlaybackSource, Lyrics
        ├── data/              Search sources (YouTube, Piped), stream
        │                      extractors (Cobalt chain), fallback repository
        ├── application/       WebViewAudioHandler, YouTubeWebViewBridge,
        │                      Riverpod providers
        └── presentation/      Now-playing sheet, queue tab, hidden engine
```

### How playback works

1. The UI talks only to `WebViewAudioHandler` (an `audio_service`
   `BaseAudioHandler`) — queue, play/pause/seek/skip/shuffle/repeat. It is the
   single source of truth for playback state.
2. The handler owns no WebView. The engine is `YoutubeWebviewPlayer`, a 1×1
   invisible widget mounted above the navigator, which hosts the Android
   platform view `RiPlayWebView`.
3. The two halves communicate over a `MethodChannel`
   (`com.example.taro_music/riplay`): Dart sends `loadVideo` / `playVideo` /
   `pauseVideo` / `seekTo`; Kotlin pushes back `onPlayerReady`,
   `onStateChange`, `onPlayerError`, and a 250 ms `onPlayerInfo` status frame
   (current time + duration, used as a drift check and to fill in unknown
   durations).
4. Search/metadata still go through `MediaStack` (`YoutubeExplode` + Piped);
   the engine resolves its own streams from YouTube, so playback no longer goes
   through the extractor chain.

### Cross-language contracts

The Dart ↔ Kotlin ↔ JS seam has names that must match on both sides:

- `YouTubeWebViewBridge.channelName` ↔ `RiPlayWebViewFactory.CHANNEL_NAME`
- `YouTubeWebViewBridge.viewType` ↔ `RiPlayPlugin.VIEW_TYPE`
- The IFrame `playerVars.origin` must match the page's `EMBED_ORIGIN`
- The page's `events` map recognises only the six documented IFrame API names —
  position tracking is done by polling `getCurrentTime()`/`getDuration()`, not
  an `onInfoDelivery` callback (which is silently ignored)

These are documented at each call site. Note the player page itself lives as a
Kotlin string inside `RiPlayWebView.kt`, so neither `flutter analyze` nor the
Dart test suite can see it — on-device verification is the real check for any
change there. Moving it to a Flutter asset is a known follow-up.

## Getting started

Requires Flutter 3.x (developed against 3.47 / Dart 3.13) and the Android SDK.

```sh
flutter pub get
flutter run                 # debug build on a connected device
flutter build apk --debug   # debug APK
```

Codegen (Riverpod providers, Drift):

```sh
dart run build_runner build --delete-conflicting-outputs
```

### Tests

```sh
flutter analyze
flutter test                # widget tests + Cobalt/probe extractor unit tests
```

Two conventions for tests in this repo:

- `YouTubeWebViewBridge.enabled` stays `false` in tests (a widget test cannot
  create a platform view); drive the event path with `debugEmit(...)` instead.
- While the player is open **and** playing, a ticker schedules frames
  indefinitely, so use `tester.pump(...)` with an explicit duration rather than
  `pumpAndSettle(...)`.

## Configuration

All tunables live in `lib/core/config/app_config.dart`: the ordered Piped and
Cobalt instance lists (first entry is primary, the rest are fallbacks), HTTP
timeouts, retry counts/backoff, user-agent strings, and the notification
channel. A settings screen overriding these defaults is planned, not built.

The Android `applicationId` is still the template placeholder
`com.example.taro_music` — change it before any release.

## Roadmap / known gaps

- Home and Library tabs show sample content; no real recommendations, persisted
  library, playlists, or downloads yet (`drift`, `shared_preferences`,
  `path_provider` are declared as dependencies but not wired up).
- Lyrics tab renders an empty state; no lyrics source is implemented.
- No in-app update flow (`github_release_apk_updater`, `package_info_plus`
  declared but unused).
- Player page should move from the Kotlin string into a Flutter asset so it
  becomes testable and lintable.

## License

[GNU General Public License v3.0](LICENSE) — free software, copyleft. If you
distribute builds (including on a store), the GPL requires you to make the
corresponding source available under the same license.
