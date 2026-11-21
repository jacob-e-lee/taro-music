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

## How injection works (read before editing inject.js)

- The script runs **twice per page load**: once as a document-start script (`WebViewCompat.addDocumentStartJavaScript`, before any page JS) and again in `onPageStarted` as a fallback.
- `window.__taroYtm` makes the second run a no-op. So **any exception thrown after line 5 on the first run silently disables everything below it**, including the ad hooks. Keep the top of the script exception-free.
- At document start, `document.documentElement` can be `null`. DOM writes must wait for it (see `addStyle()`).
- The ad hooks only work if they're installed before YouTube's first player response, which is why the document-start run matters.
- `HIDE_OPEN_APP` in `YtmWebView.kt` adds a stylesheet hiding the "Open app" button, independently of inject.js on purpose, so a stale override on the phone can't bring the button back. (YouTube Music uses no shadow roots, so CSS reaches it; it used to be a DOM walk twice a second, which cost ~4% CPU.)

## Working with YouTube's page (learned the hard way)

- **Clicking YouTube's buttons from script:** use `press()` in inject.js, not `el.click()`. Right after a touch, Polymer drops clicks outside the touched element as ghost clicks; `press()` marks the click as coming from a non-touch device, which Polymer lets through.
- **In-app navigation:** dispatch `yt-navigate` with a `browseEndpoint` (see `go()`). It doesn't reload, and playback continues.
- **No `innerHTML`:** YouTube enforces Trusted Types. Build DOM with `createElement` / `createElementNS`.
- **Overriding YouTube's CSS:** its rules are often more specific than a plain element selector. `ytmusic-app-layout` has `id="layout"`, so `#layout > …` outranks them. YouTube's CSS keyframes still apply after they finish and beat normal inline styles: use `setProperty(…, 'important')`. Its `transition: all` beats even `!important`, so turn transitions off where you drive a property per frame.
- **The player sheet** (`setP` / `settle` in inject.js) draws the player at progress 0 (mini player) to 1 (full player). Frames must only write `transform` and `opacity`: no layout reads, and no CSS variables on `<html>` (those restyle the whole page and dropped drags to ~10 fps). YouTube's open/close costs ~100 ms of main-thread work, so its state is flipped only while the sheet rests at an end, where a frozen frame looks identical. It's portrait-only; landscape keeps YouTube's own animations.
- **The art copy** (`measure`): YouTube's full-size art box isn't square (e.g. 296×285, cover cropped to fill), so the copy is a square trimmed with a `clip-path` that grows from none (the 48px mini thumbnail) to the box. The box is read only with the player at rest (`coverBox`, in `endSheet`): mid-open YouTube briefly makes it full width. Covers are drawn into a canvas once; a music video's copy is a live, muted `captureStream()` `<video>` (`videoCopy`, kept running while a video plays because a new one needs ~60 ms for its first frame), letterboxed in black like YouTube's box, so it keeps moving while YouTube's code blocks the page. The canvas, redrawn every frame, is its fallback.
- **Opens that don't come from the mini player** (picking a song) slide the whole page up instead of morphing (`taro-slide`): YouTube swaps in the new cover only after opening. Mini-player taps are detected on `pointerdown`, since YouTube cancels the click after a touch.
- **Art drag and the side panel:** with the up next / lyrics / related panel open, the player page has `player-page-ui-state=TABS_VIEW` and the art is a small thumbnail. The `touchstart` handler drops the `art` zone then, because dragging it down tears the page.
- **Dragging the tabs panel** is YouTube's own code, on `ytmusic-player-page`'s `polymerController` (`applyTransformStyles`, `setPlayerPosition`, `transition`). It works out the panel's travel and the art centre from `window.innerHeight`, as if there were no status or navigation bar. `fitTabs` wraps those two methods to feed it the real values (`moveableDistance`, `playerY`), and shows the list while dragging up (YouTube's full-view CSS hides it). The `--ytmusic-player-page-inner-height` override applies in the tabs view too, so the art doesn't jump when the state flips. The panel's bottom is pinned (`bottom: 0`), and its list is padded by `BOT`. With the panel open, the whole background behind it is the mini player's `rgb(3,3,3)` (status bar included): `#taro-band`, a full-page black layer inside `.content` just after `.background-gradient` (so the mini bar's content stays above it), is cross-faded by opacity with the drag (`shade`, same `a` as the panel colour blend; a `MutationObserver` on `player-page-ui-state` settles it with a transition). It must be one even fade, not a band at the top, which shows a hard edge mid-drag, and it needs `will-change: opacity`, or the first drag stalls ~100 ms. The mini bar's own background is `none`.
- **Taps right after a close:** a tap on a moving sheet opens it, and for 600 ms after YouTube flips its player state (`flippedAt`) a mini-player tap is handled by us, because YouTube ignores it.
- **Edge to edge:** the page runs under the status and navigation bars. inject.js keeps content clear with `TOP` (`env(safe-area-inset-top)`) and `BOT` (`--taro-bot`: the navigation-bar inset, remembered while the keyboard is down, since Android zeroes it while the keyboard is up). YouTube's menus are fitted between the bars via `#taro-fit`.
- **Song menu sheet:** the menu is a Polymer `tp-yt-iron-dropdown` in `ytmusic-popup-container`. `dd.opened` is a property (the `aria-hidden` attribute follows it); `watchMenu` observes that attribute, adds the `taro-menu` class, our own `#taro-scrim` and `#taro-mh` header (title and artist read from the row you pressed, tracked on `pointerdown`; like state from the toggle item's `data.isToggled`). The sheet is `65vh` tall at most and sits `BOT` above the screen bottom, with a `box-shadow` filling the strip under it (padding inside the scroller would leave the last item under the navigation bar). Close with `dd.close()` after our slide-down. Outside taps go to the scrim (`noCancelOnOutsideClick = true`). The scroller is `#contentWrapper`, so `ytmusic-menu-popup-renderer` must stay `overflow: visible` or the list scrolls in place. Drag is touch-based and starts only at `scrollTop` 0. Its touch listeners are on the document and read the latest `touchstart` lazily. A long press opens the menu under a finger that landed on the page; that touch is inert until lifted (its `touchmove`s are cancelled, and the pull-to-refresh and player-swipe ones skip while `sheet` is set), so only a touch that starts on the open sheet drags it. An upward swipe on an overflowing sheet grows `#contentWrapper`'s inline `max-height` with the finger (transition off), and on release either adds `taro-tall` (height `100vh - TOP`, no gap, or the handle gets cut off) or settles back. YouTube closes the menu after any item press, so the header's like button replaces `dd.close` with a no-op for 400 ms around its `press()`; `closeSheet` deletes that override first. YouTube's own `pressed` attribute on menu items can stick after a drag-away, so a CSS rule hides every item background unless `taro-pressed` is set: YouTube also focuses the first item when the menu opens and `:hover` sticks where a long press lifted, and both showed as a highlight on a finger-less screen. Items in the sheet show `taro-pressed` at once (0 ms, not 100 ms: the list rarely scrolls from a touch). A tap on any item (`pointerup`, same 16px tap test as the click guard) replaces `dd.close` with a no-op and calls `closeSheet`, so every item slides the sheet away (YouTube's own close is instant, and Start Mix, a navigation item, never closes it).
- **Press feedback and tap guards:** pressed state is a `taro-pressed` attribute set from `pointerdown` after 100 ms (a quick tap flashes it instead). YouTube's `tp-yt-paper-ripple` is hidden with `visibility` (never `display: none`: a 0×0 ripple's waves never finish and animate every frame forever, which slowed the app more with every tap). Row highlight is a `::before` sized by `--taro-t/-b/-l/-r`, using the row's same-column neighbours, since carousel rows are flat siblings. Carousels have `overflow: clip` with 8px `overflow-clip-margin` (plus cancelling padding/margin on `#items`) so the highlight isn't cut. YouTube fires taps from `touchend` (Polymer), not `click`, so the hold guard (a long press, i.e. a `contextmenu` during the touch, or a 16px drift) must stop `touchend` too. Never use a timer for the long press: a press released between the timer and Android's own long press (500 ms plus a little) did nothing at all. It calls the player sheet's `release()` first, since stopping the event hides it from that handler too (the sheet stayed stuck over the tabs). Pick the press target as `closest(BUTTON) || closest(CARD) || closest('a[href]')`; the inner play button and links must not win over the card.
- **Search box state:** `ytmusic-search-box` has `[opened]` and `[has-query]`; closed, its `.search-button` is the search icon, open it's the back arrow. On a results page YouTube puts the query back into the bar when search closes; setting the element's `hasQuery = false` shows the plain bar while keeping the query in the box. The open box is fixed below the status bar (`top: TOP`), where the page's tinted backdrop would show, so a `::before` extends its `rgb(3,3,3)` up over that strip.
- **Empty home page:** for some accounts YouTube answers the signed-in home (`browseId: FEmusic_home`) with 400 "invalid argument", also in desktop browsers. Other pages, other accounts and signed-out requests work, so it's YouTube's bug. The `fetch` hook retries such a request with `credentials: 'omit'` and shows that signed-out home; the first page's home comes inside the HTML, past the hook, so `homeCheck` navigates home again when that data is an error. YouTube's `fetch` calls pass `Request` objects whose body is gzipped (`content-encoding: gzip`): read it through `DecompressionStream`, and clone before calling fetch, which consumes it.
- **Measure, don't eyeball:** time frames with `requestAnimationFrame` deltas and a `longtask` `PerformanceObserver`. The display runs at 120 Hz while touched. For where time goes, use the DevTools protocol's `Profiler` (CPU by function) or `Tracing` (style/layout/paint vs script) on the live page. For slowdowns that build up over time, loop the same actions with `Input.dispatchTouchEvent` (real touches) and log `Performance.getMetrics` after each round. Then run the loop again with an empty `inject.js` override, which tells our code apart from YouTube's. YouTube's own heap and DOM grow and then level off (pages it caches): that isn't ours.
- **Pull to refresh** (Home / Explore / Library only, from `scrollY` 0): a spinner (`#taro-ptr`) follows the finger below the header; releasing past `PTR_AT` calls `go()` with the current tab's browse id, which makes YouTube refetch the page without a reload (playback continues). Dragging back up shrinks the pull instead of ending it. The `touchmove` listener is non-passive and calls `preventDefault()` from the first downward move: Chromium drops the downward scroll delta at the top, so without it the page scrolls as soon as the finger reverses, and a scroll the browser has already started can't be cancelled later. `overscroll-behavior-y: none` removes the stretch effect.
- **Premium promo makes the page dead:** YouTube opens its mealbar promo in a `tp-yt-paper-dialog`, which makes `ytmusic-app-layout` `inert`, so no tap registers. Our CSS hides the promo, so the 300 ms timer in `buildNav` closes that dialog.
- **Selector check:** 15 s after load, `console.warn("TARO selectors missing: …")` in logcat if a core element is gone (YouTube DOM change).
- **Keep idle cost near zero:** no timers that search the whole page (~13k elements) or walk the DOM; check a known element instead (e.g. `#movie_player`'s classes for ads). No `body:has(...)` rules: they make every DOM change re-check styles; mirror state onto `<html>` classes instead (`taro-open`, `taro-playing`).
- **Don't disable YouTube's IntersectionObservers.** Seven `rootMargin: -0.1px` observers (~3.6k targets) cost ~180 ms per tab switch, but they're YouTube's general visibility service, which any feature may rely on; switching them off was tested and rejected.

## Agent loop (autonomous improvement)

`agent` (repo root `agent.cmd`) starts it and opens a status window; `agent off` stops it in ~3 s and prints SAFE TO UNPLUG; `agent toggle`, `agent status`. `tool/agent-loop.ps1` runs one fresh `claude -p` per iteration with `tool/agent-prompt.md` (never asks a human; the prompt holds the rules). It waits out token limits (sleeps to the reset time, one haiku probe, resumes) and unplugged phones (`waiting-for-phone`, resumes on replug). `tool/human.ps1` drives sloppy human touches, `tool/gate.ps1` must pass before any push (exit 1 revert, exit 2 no device: docs only), `tool/probe.mjs` checks the live page. Work list: `docs/BACKLOG.md` (finished items go to `docs/DONE.md`). Generated and git-ignored: `tool/state.json`, `tool/agent.log`, `tool/STOP`. Test the loop without spending tokens by pointing `AGENT_CLAUDE` at a stub.

## Gotchas

- Git Bash rewrites `/sdcard/...` arguments into Windows paths. Prefix adb commands with `MSYS_NO_PATHCONV=1`.
- PowerShell 5.1: redirecting a native command's stderr (`2>$null`, `2>&1`) turns its output into error records. With `$ErrorActionPreference = 'Stop'` that throws. `adb shell monkey` writes to stderr, so the scripts use `am start -n` instead.
- Android 17 silently drops `KeepAliveService`'s foreground state some time after the app goes to the background (NouTube saw ~18 min), and then mutes the audio (`AudioHardening background playback would be muted` in logcat) while the notification stays up. `MediaControls.keepForeground` re-calls `startForegroundService` on each play and every minute while playing. Check with `dumpsys activity lru`: the process should read `FGS`, not `LAST`.
- Expected noise in logcat: CORS errors for `googleads.g.doubleclick.net` (it's blocked on purpose) and the `LegacyDataMixin` log line.
- Check whether an override is still on the device: `adb shell ls /sdcard/Android/data/io.github.jacob_e_lee.taro_music/files/`.
