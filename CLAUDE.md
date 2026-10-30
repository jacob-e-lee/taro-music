# taro-music

An Android-only app that wraps the YouTube Music website (music.youtube.com) in a WebView. It's a Flutter shell, but almost all behaviour lives in:

- `android/app/src/main/kotlin/com/example/taro_music/YtmWebView.kt`: WebView setup, ad request blocking, visibility spoofing (keeps audio playing when the screen locks), script injection.
- `assets/ytm/inject.js`: CSS/JS injected into the page: ad stripping (JSON.parse / fetch / XHR hooks), hiding upsells, and the mobile UX layer (bottom tab bar, swipe gestures, draggable player sheet, search bar behaviour, the media-controls bridge).
- `MediaControls.kt`: the native `MediaSession` and media notification (lock screen, quick settings, headset / Bluetooth buttons). The WebView has no Media Session API, so inject.js reports the track through a web message listener (`TaroMedia`, YouTube Music origin only) and commands come back as `__taroMedia(command, arg)`.
- `KeepAliveService.kt`: foreground service that keeps the process alive; its notification is the media notification, and that notification's buttons come back to it. `YtmWebViewPlugin.kt` registers the WebView as a Flutter platform view (`ytm_webview`).
- `lib/main.dart`: hosts that platform view and forwards Android Back to the WebView's history over the `com.example.taro_music/ytm_webview/<id>` channel. The view type and channel name must match `YtmWebViewPlugin.kt`. The page draws edge to edge under both system bars, and the keyboard covers it rather than resizing it (`resizeToAvoidBottomInset: false`).

There is no desktop build. The app only runs on a real Android phone over USB, so all debugging goes through `adb`.

## Environment (Windows)

- `adb` is **not on PATH**. Use `"$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"` (PowerShell) or `"$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe"` (bash).
- `flutter` is **not on PATH**. Use `C:\Users\jelee\develop\flutter\bin\flutter.bat`.
- App id / package: `com.example.taro_music`. Launch activity: `.MainActivity`.
- Run `adb devices` first. If no device is listed, ask the user to plug in the phone and accept the USB debugging prompt. Don't guess.

## Debug-only hooks (active when the APK is debuggable)

The hooks check `ApplicationInfo.FLAG_DEBUGGABLE`, not `BuildConfig`.

1. **Console → logcat.** Page `console.*` output and uncaught JS errors go to logcat with tag `TaroMusic`.
2. **Remote DevTools.** `WebView.setWebContentsDebuggingEnabled(true)`. The user opens `edge://inspect` or `brave://inspect` (they have no Chrome) to get Elements, Console and Network for the live page.
3. **inject.js override.** If `/sdcard/Android/data/com.example.taro_music/files/inject.js` exists, the app loads it instead of the bundled asset. Release builds ignore it.

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
adb forward tcp:9222 localabstract:webview_devtools_remote_$(adb shell pidof com.example.taro_music)
curl -s localhost:9222/json/list
```
Then connect to `ws://localhost:9222/devtools/browser` (Node 22 has a global `WebSocket`), `Target.attachToTarget` the `page` target with `flatten: true`, and use `Runtime.evaluate` to query the DOM. `Page.startScreencast` captures the frames actually painted, which is the way to catch one-frame flickers that screenshots miss. The pid changes on every restart, so re-forward afterwards. If `/json/list` is empty, restart the app.

**Verify a JS change ran:** push a scratch copy of `inject.js` (not the real file) with a `console.log('MARKER …')` before the closing `})();`, restart, and grep logcat. Afterwards run `dev-js.ps1` with the real file or `-Reset`, so a scratch copy never stays on the phone.

## How injection works (read before editing inject.js)

- The script runs **twice per page load**: once as a document-start script (`WebViewCompat.addDocumentStartJavaScript`, before any page JS) and again in `onPageStarted` as a fallback.
- `window.__taroYtm` makes the second run a no-op. So **any exception thrown after line 5 on the first run silently disables everything below it**, including the ad hooks. Keep the top of the script exception-free.
- At document start, `document.documentElement` can be `null`. DOM writes must wait for it (see `addStyle()`).
- The ad hooks only work if they're installed before YouTube's first player response, which is why the document-start run matters.
- "Open app" buttons inside shadow roots (which inject.js's CSS can't reach) are hidden only by `HIDE_OPEN_APP` in `YtmWebView.kt`. It runs independently of inject.js on purpose, so a stale override on the phone can't bring the button back.

## Working with YouTube's page (learned the hard way)

- **Clicking YouTube's buttons from script:** use `press()` in inject.js, not `el.click()`. Right after a touch, Polymer drops clicks outside the touched element as ghost clicks; `press()` marks the click as coming from a non-touch device, which Polymer lets through.
- **In-app navigation:** dispatch `yt-navigate` with a `browseEndpoint` (see `go()`). It doesn't reload, and playback continues.
- **No `innerHTML`:** YouTube enforces Trusted Types. Build DOM with `createElement` / `createElementNS`.
- **Overriding YouTube's CSS:** its rules are often more specific than a plain element selector. `ytmusic-app-layout` has `id="layout"`, so `#layout > …` outranks them. YouTube's CSS keyframes still apply after they finish and beat normal inline styles: use `setProperty(…, 'important')`. Its `transition: all` beats even `!important`, so turn transitions off where you drive a property per frame.
- **The player sheet** (`setP` / `settle` in inject.js) draws the player at progress 0 (mini player) to 1 (full player). Frames must only write `transform` and `opacity`: no layout reads, and no CSS variables on `<html>` (those restyle the whole page and dropped drags to ~10 fps). YouTube's open/close costs ~100 ms of main-thread work, so its state is flipped only while the sheet rests at an end, where a frozen frame looks identical. It's portrait-only; landscape keeps YouTube's own animations.
- **Edge to edge:** the page runs under the status and navigation bars. inject.js keeps content clear with `TOP` (`env(safe-area-inset-top)`) and `BOT` (`--taro-bot`: the navigation-bar inset, remembered while the keyboard is down, since Android zeroes it while the keyboard is up). YouTube's menus are fitted between the bars via `#taro-fit`.
- **Search box state:** `ytmusic-search-box` has `[opened]` and `[has-query]`; closed, its `.search-button` is the search icon, open it's the back arrow. On a results page YouTube puts the query back into the bar when search closes; setting the element's `hasQuery = false` shows the plain bar while keeping the query in the box.
- **Measure, don't eyeball:** time frames with `requestAnimationFrame` deltas and a `longtask` `PerformanceObserver`. The display runs at 120 Hz while touched.

## Gotchas

- Git Bash rewrites `/sdcard/...` arguments into Windows paths. Prefix adb commands with `MSYS_NO_PATHCONV=1`.
- PowerShell 5.1: redirecting a native command's stderr (`2>$null`, `2>&1`) turns its output into error records. With `$ErrorActionPreference = 'Stop'` that throws. `adb shell monkey` writes to stderr, so the scripts use `am start -n` instead.
- Expected noise in logcat: CORS errors for `googleads.g.doubleclick.net` (it's blocked on purpose) and the `LegacyDataMixin` log line.
- Check whether an override is still on the device: `adb shell ls /sdcard/Android/data/com.example.taro_music/files/`.
