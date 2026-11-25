# Taro Music

Taro Music is an Android app that puts the YouTube Music website (music.youtube.com) inside a WebView and changes the page until it behaves like a phone app. It blocks ads, keeps playing when the screen is off, shows lock screen controls, and replaces the desktop-style layout with a bottom tab bar, swipe gestures and a draggable player.

It is unofficial. Google and YouTube have nothing to do with it. You sign in with your own account, and YouTube's terms still apply.

## Why it exists

The project began as something else. The first commits (up to `e4b0997`) built a native Flutter music player that searched several sources, extracted audio streams and played them itself. That broke whenever YouTube changed how streams were served, and one commit exists only to work around 403 playback failures. Commit `7244b75` threw that UI out and wrapped the real YouTube Music site instead.

The reasoning: YouTube Music already has the catalog, the account, the recommendations and the player. What it lacks on a phone browser is background playback, a good layout, and an ad-free experience. Fixing those on top of the real site is less work and less fragile than reimplementing playback. The cost is that the app depends on the shape of YouTube's page, so a YouTube redesign can break parts of it.

## How it is put together

Flutter is only a shell. Nearly everything happens in four places.

| Part | Job |
| --- | --- |
| `YtmWebView.kt` | Builds the WebView, blocks ad requests, fakes page visibility, injects the script |
| `assets/ytm/inject.js` | CSS and JavaScript that run inside the page: ad stripping, hiding upsells, the mobile interface |
| `MediaControls.kt`, `KeepAliveService.kt` | Native media session, notification and foreground service |
| `lib/main.dart` | Hosts the WebView as a platform view, forwards Back, draws the loading screen |

`YtmWebViewPlugin.kt` registers the WebView with Flutter as a platform view called `ytm_webview`. The view type and channel name in `lib/main.dart` must match it.

## What we changed, and why

### Ads

- **Blocking requests.** `YtmWebView.kt` refuses requests to known ad hosts. This is cheap and catches most ad traffic before it loads. The CORS errors for `googleads.g.doubleclick.net` in logcat are the block working, so ignore them.
- **Stripping ads from responses.** `inject.js` hooks `JSON.parse`, `fetch` and `XMLHttpRequest` and removes ad data from player responses. Some ads arrive inside responses from YouTube's own servers, where host blocking can't touch them. The hooks must be installed before YouTube's first player response, which is why the script runs as a document-start script and again in `onPageStarted` as a fallback.
- **Hiding upsells.** CSS hides the "Open app" button and the Premium promo. The Open app rule lives in `YtmWebView.kt` on purpose, so an old `inject.js` override on a test phone can't bring the button back. The Premium promo opens a dialog that makes the whole page `inert`, so a timer closes it, since a hidden dialog still blocks every tap.

### Background playback

- **Visibility spoofing.** YouTube pauses on the `visibilitychange` event, which fires when the screen locks. The WebView always reports itself as visible, so audio keeps going.
- **Foreground service.** `KeepAliveService` stops Android from killing the process in the background. On Android 17 the system silently drops a service's foreground state after a while and then mutes the audio, with the notification still showing. `MediaControls.keepForeground` calls `startForegroundService` again on each play and every minute while playing, which keeps the process listed as foreground.

### Lock screen and notification controls

A WebView has no Media Session API, so Android knew nothing about what was playing. `inject.js` now reports the track to native code through a web message listener (`TaroMedia`, accepted from the YouTube Music origin only). `MediaControls.kt` turns that into a `MediaSession` and a media notification, which gives lock screen controls, quick settings controls, and headset and Bluetooth buttons. Commands travel back as `__taroMedia(command, arg)`. The foreground service's notification is the media notification, so its buttons route to the service.

### Mobile interface

YouTube Music's mobile web layout is a stripped-down version of the desktop one. `inject.js` adds what a native app would have:

- **Bottom tab bar and slimmer top bar** (48px each). The hamburger menu became a "New playlist" button on Library.
- **Swipe gestures** between tabs.
- **Draggable player sheet.** The player follows the finger between mini player and full player. Only `transform` and `opacity` change per frame, because anything that forces layout dropped drags to about 10 fps. The cover art is copied and morphed onto YouTube's real art box (which we make square: YouTube's is slightly wider than tall), and music videos get a live muted copy so motion doesn't freeze while YouTube's code blocks the page.
- **Song menu as a bottom sheet** with title, artist, a like button, drag-to-close and swipe-up to grow. YouTube's menu is a small floating popup, hard to use with a thumb.
- **Pull to refresh** on Home, Explore and Library. It refetches the page through YouTube's own navigation, so playback continues.
- **Touch feedback and tap guards.** Press highlights replace YouTube's ripples (a hidden zero-size ripple animates forever, so they are hidden with `visibility`, never `display: none`). Long presses and drifting touches no longer count as taps. Text selection and link dragging are off.
- **Larger touch targets.** Small YouTube buttons are grown to 44 to 48 px.
- **Search box.** The back arrow clears the query first, then closes the box.
- **Stretch overscroll off**, so the fixed header, tab bar and mini player don't deform.

### Edge to edge

The page draws under the status bar and navigation bar. `inject.js` keeps content clear of them with `TOP` and `BOT`, and the keyboard covers the page instead of resizing it. Android reports a zero navigation inset while the keyboard is up, so the last good value is remembered. The tabs panel (up next, lyrics, related) needed its own fixes, because YouTube computes its drag travel from `window.innerHeight` as if no bars existed.

### Startup and the loading screen

`MainActivity.onCreate` builds the WebView immediately instead of waiting for Flutter to create the platform view, which starts the page load about 0.3 s earlier. Measured on a phone: page load starts roughly 0.24 s after process start and the first contentful paint arrives at about 1.95 s. The remaining time is YouTube's own scripts and data, and most resources already come from Chromium's cache. Flutter draws a loading screen (a breathing logo over a purple glow) on top and polls whether the page has painted, then fades it out. The launch background is black to match.

### Offline

A failed main-frame load shows Taro Music's own "No connection" page, which retries every 4 seconds, instead of Chromium's error page. It has not been tested offline on a device.

### Fixes for YouTube bugs

For some accounts YouTube answers the signed-in home request with 400 "invalid argument", also in desktop browsers. The `fetch` hook retries that request signed out so Home isn't empty.

Closing the player with Android Back while up next / lyrics / related is open leaves YouTube's tabs-view layout on the closed player, which hid the mini player's cover. CSS undoes it while the player is closed.

### Performance

Idle work was cut from about 850 ms to under 20 ms of main-thread time per 10 seconds by removing timers that walked the whole page. Rules that came out of it: no timers that scan the DOM, no `body:has(...)` selectors, and state mirrored onto `<html>` classes. Disabling YouTube's IntersectionObservers was tested and rejected, since other features may rely on them.

### Selector check

Fifteen seconds after load, the script logs a warning to logcat if a core element is missing, which usually means YouTube changed its page.

## Releases

- **Package:** `io.github.jacob_e_lee.taro_music`.
- **Signing:** release builds are signed with the project's own key. A GitHub Actions workflow (`.github/workflows/release.yml`) builds the APK on Linux when a `v*` tag is pushed and attaches `taro-music-<version>.apk` to the release. Linux matches F-Droid's build environment, so the two builds can be compared.
- **F-Droid metadata** lives in `fastlane/metadata/android/en-US`.
- **Updating:** installing a newer APK over the old one keeps the user signed in.

## Development

There is no desktop build. The app runs on a real Android phone and all debugging goes through `adb`.

- A JS-only change needs no rebuild: `tool/dev-js.ps1` pushes `inject.js` to the phone and restarts the app in about 3 seconds. Debug builds read that override instead of the bundled asset.
- Kotlin, Dart or asset changes need a rebuild with `flutter build apk --debug` and `adb install -r`, which keeps app data.
- Debug builds send page `console.*` output to logcat (tag `TaroMusic`) and enable remote DevTools, so the live page can be inspected from `edge://inspect` or driven over the DevTools protocol (`tool/probe.mjs` does a basic check that the script ran).
- Never uninstall or clear data without asking, since that signs the user out.

The page-level lessons (Trusted Types, Polymer ghost clicks, why the player sheet only writes `transform`) are in [inject-notes.md](../inject-notes.md). Project working rules are in [CLAUDE.md](../../CLAUDE.md).

## Known limits

- The app follows YouTube's current page. A redesign can break gestures or the tab bar until the app is updated.
- With the keyboard open, text boxes low on the screen (such as the "New playlist" box) can end up behind it.
- Portrait only for the custom player sheet. Landscape keeps YouTube's own animations.
- Android only.
