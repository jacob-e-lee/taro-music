# Taro Music

**YouTube Music for Android, without the ads.**

Taro Music turns the YouTube Music website into a proper music app. No ads,
music keeps playing when the screen is off, and it feels like an app instead of
a web page.

Free and open source (GPL-3.0). Android only.

## What you get

- **No ads.** Ads and promoted items are removed before you see or hear them.
- **Plays with the screen off.** Lock your phone or switch apps and the music
  keeps going.
- **Lock screen and notification controls.** See the cover, seek, play, pause
  and skip from the notification shade, the lock screen, or your headphone and
  Bluetooth buttons.
- **Made for your thumb.**
  - Home, Explore and Library tabs along the bottom, with the mini player above.
  - Swipe the mini player or the album art left or right to skip a song.
  - Drag the player up to open it and down to close it. The album art follows
    your finger.
  - Song menus slide up as a bottom sheet. Drag down to close.
  - Buttons and rows react when you press them.
- **Quick start.** The page begins loading while the app is still opening, and
  a breathing logo covers the wait until music appears.
- **Full screen.** The app draws behind the status bar and navigation buttons.
- **No "Get the app" nags.** Upsell banners and "Open app" buttons are hidden.
- **Your account works.** Sign in with Google as usual and stay signed in.

## Install

Taro Music is not on the Play Store, and there is no download yet. Until there
is one, [build it yourself](#build-from-source).

You need an Android phone. Allow installs from your browser or file manager
when Android asks (only needed for an APK you download).

## Good to know

- Taro Music is an unofficial app. It is not made by, or affiliated with,
  Google or YouTube. It shows the YouTube Music website; you use your own
  account and YouTube's terms still apply.
- It depends on how YouTube Music's page is built today. If YouTube redesigns
  the site, some gestures or the tab bar may break until the app is updated.
- With the keyboard open, text boxes low on the screen (such as the "New
  playlist" box) can end up behind it.

## Build from source

You need Flutter 3.x (Dart ^3.13), the Android SDK, and a phone connected over
USB with USB debugging on.

```sh
flutter pub get
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

`install -r` keeps your data, so you stay signed in. Before publishing a build
anywhere, change the placeholder `applicationId` (`io.github.jacob_e_lee.taro_music`).

## For developers

Taro Music is a Flutter shell around one native `WebView`. Almost everything
lives in three files:

- [`YtmWebView.kt`](android/app/src/main/kotlin/io/github/jacob_e_lee/taro_music/YtmWebView.kt):
  WebView setup, ad request blocking, visibility spoofing, script injection.
- [`assets/ytm/inject.js`](assets/ytm/inject.js): the CSS and JS injected into
  every music.youtube.com page (ad stripping, gestures, player sheet, media
  controls bridge).
- [`MediaControls.kt`](android/app/src/main/kotlin/io/github/jacob_e_lee/taro_music/MediaControls.kt):
  the Android media session and notification.

Debug builds load `inject.js` from the phone when it exists, so JS changes need
no rebuild:

```sh
powershell -ExecutionPolicy Bypass -File tool/dev-js.ps1          # push inject.js, restart the app
powershell -ExecutionPolicy Bypass -File tool/dev-js.ps1 -Reset   # remove the override
```

Debug builds also send page `console.*` output to logcat
(`adb logcat -s TaroMusic`) and enable remote DevTools (`edge://inspect` or
`chrome://inspect`). See [CLAUDE.md](CLAUDE.md) for the full on-device
debugging workflow and the quirks of YouTube's page.

## License

[GNU General Public License v3.0](LICENSE): free software, copyleft. If you
distribute builds (including on a store), the GPL requires you to make the
corresponding source available under the same license.
