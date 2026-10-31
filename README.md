# Taro Music

A free (GPL-3.0) Android app that wraps the [YouTube Music](https://music.youtube.com)
website in a WebView and makes it behave like a native music app: no ads, audio
keeps playing with the screen locked, and mobile gestures on top of the site's
own UI.

It is a Flutter shell around a single native `WebView`. Almost everything lives
in a few files:

- [`YtmWebView.kt`](android/app/src/main/kotlin/com/example/taro_music/YtmWebView.kt):
  WebView setup, ad request blocking, visibility spoofing, script injection.
- [`assets/ytm/inject.js`](assets/ytm/inject.js): CSS/JS injected into every
  music.youtube.com page.
- [`MediaControls.kt`](android/app/src/main/kotlin/com/example/taro_music/MediaControls.kt):
  the Android media session and notification.

> **Platform status:** Android only. There are no iOS, desktop or web targets.

## Features

- **Ad blocking.** Ad requests are refused natively (DoubleClick, ad syndication,
  `/pagead/` and similar). YouTube's own JSON (`JSON.parse`, `fetch`, `XHR`, and
  the server-rendered `ytInitialData`/`ytInitialPlayerResponse`) is rewritten to
  drop ad slots and promoted items. A fallback mutes and skips any video ad that
  still slips through.
- **Background playback.** YouTube pauses on the `visibilitychange` event when
  the screen locks. The WebView always reports itself visible, and a foreground
  service keeps the process alive.
- **No upsells.** "Get the app" banners and "Open app" buttons are hidden.
- **Media controls.** The notification shade and lock screen show the current
  track with its cover and a seekable progress bar; play/pause, next, previous and
  headset or Bluetooth buttons control the app.
- **Sign-in works.** The WebView's `wv` user-agent token, which Google uses to
  refuse sign-in, is stripped. Cookies persist across restarts.
- **Mobile UX:**
  - A Home / Explore / Library bottom tab bar, with the mini player above it.
  - Swipe the mini player or the full player's artwork left or right to skip.
  - Drag the player up from the mini player (or its art) and down to close it.
    The page follows your finger at the display's refresh rate, and the album art
    (or the live picture, for music videos) morphs between the thumbnail and full
    size. Tapping the mini player, the chevron and the Back button use the same
    animation (portrait only); picking a song slides the whole player up. While
    the up next / lyrics / related panel is open, the art is not a drag handle.
  - The app draws edge to edge: the page's colours continue behind the status bar
    and the navigation buttons.
  - A slimmer top bar and tab bar; the hamburger menu is replaced by the tabs and a
    "New playlist" button on Library.
  - Search: the back arrow stays visible; it first clears the box (reopening the
    keyboard), then closes search. The keyboard covers the page instead of
    shrinking it, so nothing jumps.
  - The song menu (3-dots or long-press) is a bottom sheet: it slides up over a
    dimmed page, shows the song, artist, a like button and a close button, and
    closes by dragging down from anywhere on it. Liking from it leaves it open.
    Swiping up on a long menu grows the panel with your finger to the top of the
    screen, then the whole panel scrolls as one.
  - Touch feedback on buttons, cards, rows, chips and menu items: they dim or
    highlight while pressed, even if the finger then drags away. Song rows get a
    rounded highlight reaching halfway to the next row.
  - Input feels native: no text selection or link dragging, and a long hold or a
    drifting finger is not a tap.
  - No blue tap-highlight flash.

## How it works

- **Injection.** `inject.js` runs as a document-start script
  (`WebViewCompat.addDocumentStartJavaScript`), so the ad hooks are installed
  before YouTube's first player response. It runs again from `onPageStarted` as
  a fallback, guarded so the second run is a no-op.
- **Gestures and the player sheet.** The swipes drive a sheet that draws the
  player anywhere between mini (0) and full (1), touching only `transform` and
  `opacity` each frame. YouTube's own open/close does roughly 100 ms of
  main-thread work, so it is flipped only once the sheet has come to rest, where
  a frozen frame is invisible.
- **Media controls.** The WebView has no Media Session API, so `inject.js`
  reports the track and playback state to `MediaControls.kt` through an
  origin-restricted web message listener, and runs the commands that come back.
- **Back button.** Flutter forwards Back to the WebView's history, and only exits
  the app when there is none left.

## Getting started

Requires Flutter 3.x (Dart ^3.13) and the Android SDK, with a phone connected
over USB (USB debugging on).

```sh
flutter pub get
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

`install -r` keeps app data, so you stay signed in.

### Iterating on `inject.js`

Debug builds load `/sdcard/Android/data/com.example.taro_music/files/inject.js`
instead of the bundled asset when that file exists, so JS changes need no
rebuild:

```sh
powershell -ExecutionPolicy Bypass -File tool/dev-js.ps1          # push inject.js, restart the app
powershell -ExecutionPolicy Bypass -File tool/dev-js.ps1 -Reset   # remove the override
```

Debug builds also send page `console.*` output to logcat (`adb logcat -s TaroMusic`)
and enable remote DevTools (`edge://inspect` or `chrome://inspect`). See
[CLAUDE.md](CLAUDE.md) for the full on-device debugging workflow and the
gotchas of working with YouTube's page.

## Known gaps

- The gestures and tab bar rely on YouTube Music's current page structure, so a
  site redesign can break them.
- With the keyboard covering the page, text fields low on the screen (such as
  the "New playlist" dialog's) can end up behind it.
- The Android `applicationId` is still the template placeholder
  `com.example.taro_music`. Change it before any release.

## License

[GNU General Public License v3.0](LICENSE): free software, copyleft. If you
distribute builds (including on a store), the GPL requires you to make the
corresponding source available under the same license.
