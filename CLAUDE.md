# taro-music

An Android-only app that wraps the YouTube Music website (music.youtube.com) in a WebView. It's a Flutter shell, but almost all behaviour lives in:

- `android/app/src/main/kotlin/io/github/jacob_e_lee/taro_music/YtmWebView.kt`: WebView setup, ad request blocking, visibility spoofing (keeps audio playing when the screen locks), script injection.
- `assets/ytm/inject.js`: CSS/JS injected into the page: ad stripping (JSON.parse / fetch / XHR hooks), hiding upsells, and the mobile UX layer (bottom tab bar, swipe gestures, draggable player sheet, search bar behaviour, the media-controls bridge).
- `MediaControls.kt`: the native `MediaSession` and media notification (lock screen, quick settings, headset / Bluetooth buttons). The WebView has no Media Session API, so inject.js reports the track through a web message listener (`TaroMedia`, YouTube Music origin only) and commands come back as `__taroMedia(command, arg)`.
- `KeepAliveService.kt`: foreground service that keeps the process alive; its notification is the media notification, and that notification's buttons come back to it. `YtmWebViewPlugin.kt` registers the WebView as a Flutter platform view (`ytm_webview`).
- `lib/main.dart`: hosts that platform view and talks to it over the `io.github.jacob_e_lee.taro_music/ytm_webview/<id>` channel: `back` forwards Android Back to the WebView's history, `ready` answers whether the page has painted. The view type and channel name must match `YtmWebViewPlugin.kt`. It also draws the loading screen (breathing logo over a purple glow) on top of the WebView; it polls `ready` every 100 ms, fades out when true, and gives up after 10 s. The page draws edge to edge under both system bars, and the keyboard covers it rather than resizing it (`resizeToAvoidBottomInset: false`).

**Startup.** `MainActivity.onCreate` builds the `YtmWebView` straight away (`prewarmedWebView` in `YtmWebViewPlugin.kt`), so `loadUrl` runs ~0.3 s earlier than if it waited for Flutter to create the platform view; the factory hands that instance over, or builds one if none exists. `YtmWebView.visible` is set from `onPageCommitVisible` and read through `ready`. It is polled rather than pushed, because a push can land before Dart has set up its channel. Measured on the phone (cold start, `am start -W` only times the Flutter activity, so read page timings over DevTools): page load starts ~0.24 s after process start, first contentful paint ~1.95 s. The remaining ~1.6 s is YouTube's JS and data, and 33 of 49 resources already come from Chromium's cache, so there is nothing more to cache. A failed main-frame load (offline) shows our own "No connection" page (`OFFLINE_PAGE`, retries every 4 s); not tested offline, since the agent must not toggle phone network. The launch background is black (`launch_background.xml`, both copies) to match the loading screen.

There is no desktop build. The app only runs on a real Android phone over USB, so all debugging goes through `adb`.

## Environment (Windows)

- `adb` is **not on PATH**. Use `"$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"` (PowerShell) or `"$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe"` (bash).
- `flutter` is **not on PATH**. Use `C:\Users\jelee\develop\flutter\bin\flutter.bat`.
- App id / package: `io.github.jacob_e_lee.taro_music`. Launch activity: `.MainActivity`.
- Run `adb devices` first. If no device is listed, ask the user to plug in the phone and accept the USB debugging prompt. Don't guess.

## Debug-only hooks (active when the APK is debuggable)

The hooks check `ApplicationInfo.FLAG_DEBUGGABLE`, not `BuildConfig`.

1. **Console → logcat.** Page `console.*` output and uncaught JS errors go to logcat with tag `TaroMusic`.
2. **Remote DevTools.** `WebView.setWebContentsDebuggingEnabled(true)`. The user opens `edge://inspect` or `brave://inspect` (they have no Chrome) to get Elements, Console and Network for the live page.
3. **inject.js override.** If `/sdcard/Android/data/io.github.jacob_e_lee.taro_music/files/inject.js` exists, the app loads it instead of the bundled asset. Release builds ignore it.

## Loops

**JS change** (most work). No rebuild needed:
```
powershell -ExecutionPolicy Bypass -File tool/dev-js.ps1          # push assets/ytm/inject.js, restart app (~3 s)
powershell -ExecutionPolicy Bypass -File tool/dev-js.ps1 -Reset   # delete override, back to bundled asset
```
`-ExecutionPolicy Bypass` is needed because script execution is disabled on this machine.
The app reads the script once, when the WebView is constructed, so a restart is required: reloading the page isn't enough. Restarting stops playback. Sign-in survives the restart because cookies persist.

**Kotlin / Dart / asset change:** rebuild and install:
```
flutter.bat build apk --debug      # ~2 min
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```
`install -r` keeps app data, so the user stays signed in. **Never `adb uninstall`** or clear data without asking, because it signs the user out.

**Read logs:**
```
adb logcat -c                      # clear before reproducing
adb logcat -d -s TaroMusic         # dump page console output
```

**See and drive the screen:**
```
adb shell screencap -p /sdcard/s.png ; adb pull /sdcard/s.png <scratchpad>/s.png   # then Read the png
adb shell input tap X Y
adb shell input swipe X1 Y1 X2 Y2 300
```
Don't use `adb exec-out screencap > file` in PowerShell 5.1: its pipeline corrupts binary output.

Before tapping by coordinates, check the phone is still in portrait (`adb shell dumpsys window displays | grep mCurrentRotation`) and that the page is in the state you expect. Auto-rotate is on, and blind taps in the wrong layout hit real UI (one opened the "New playlist" dialog). For anything that matters, read state through DevTools (below) instead of guessing from a screenshot.

**Typing:** only `adb shell input text` after confirming via DevTools that a text field has focus (`document.activeElement`). Otherwise the keys go to YouTube's keyboard shortcuts (one stray search muted and paused the player). The user's phone is live: if it leaves the app (`dumpsys window | grep mCurrentFocus`), stop and ask before driving it.

**Media controls:** `adb shell dumpsys media_session` shows the session's state and metadata; `adb shell input keyevent KEYCODE_MEDIA_PAUSE` (`_PLAY`, `_NEXT`, `_PREVIOUS`) exercises it like a headset.

**Drive the page from the CLI (DevTools protocol):** the remote-DevTools hook also works without a browser:
```
adb forward tcp:9222 localabstract:webview_devtools_remote_$(adb shell pidof io.github.jacob_e_lee.taro_music)
curl -s localhost:9222/json/list
```
Then connect to `ws://localhost:9222/devtools/browser` (Node 22 has a global `WebSocket`), `Target.attachToTarget` the `page` target with `flatten: true`, and use `Runtime.evaluate` to query the DOM. `Page.startScreencast` captures the frames actually painted, which is the way to catch one-frame flickers that screenshots miss. The pid changes on every restart, so re-forward afterwards. If `/json/list` is empty, restart the app.

**Verify a JS change ran:** push a scratch copy of `inject.js` (not the real file) with a `console.log('MARKER …')` before the closing `})();`, restart, and grep logcat. Afterwards run `dev-js.ps1` with the real file or `-Reset`, so a scratch copy never stays on the phone.

## Editing inject.js

Read [docs/inject-notes.md](docs/inject-notes.md) first (how injection works, YouTube page lessons). Hard rules:

- The script runs twice per page load; `window.__taroYtm` makes the second run a no-op. An exception after line 5 on the first run silently disables the ad hooks. Keep the top exception-free.
- At document start `document.documentElement` can be `null`; wait before DOM writes.
- No `innerHTML` (Trusted Types). Click YouTube buttons with `press()`, not `el.click()`.

**Saving tokens:** `inject.js` is ~78 KB. Grep it or read by line range, never whole. Check page state with DevTools `Runtime.evaluate` or logcat; take a screenshot only when the look is the question.

## Gotchas

- Git Bash rewrites `/sdcard/...` arguments into Windows paths. Prefix adb commands with `MSYS_NO_PATHCONV=1`.
- PowerShell 5.1: redirecting a native command's stderr (`2>$null`, `2>&1`) turns its output into error records. With `$ErrorActionPreference = 'Stop'` that throws. `adb shell monkey` writes to stderr, so the scripts use `am start -n` instead.
- Android 17 silently drops `KeepAliveService`'s foreground state some time after the app goes to the background (NouTube saw ~18 min), and then mutes the audio (`AudioHardening background playback would be muted` in logcat) while the notification stays up. `MediaControls.keepForeground` re-calls `startForegroundService` on each play and every minute while playing. Check with `dumpsys activity lru`: the process should read `FGS`, not `LAST`.
- Expected noise in logcat: CORS errors for `googleads.g.doubleclick.net` (it's blocked on purpose) and the `LegacyDataMixin` log line.
- Check whether an override is still on the device: `adb shell ls /sdcard/Android/data/io.github.jacob_e_lee.taro_music/files/`.
