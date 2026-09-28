import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/webview_bridge.dart';

/// The hidden audio engine: a real YouTube IFrame player, mounted in the widget
/// tree but never shown.
///
/// The engine is an Android platform view rather than a Flutter WebView plugin,
/// because of one thing a plugin cannot do: keep playing when the screen goes
/// off. YouTube's player listens for the `visibilitychange` DOM event and
/// pauses when the page reports itself hidden, which happens the moment the
/// device locks. `RiPlayWebView` (Kotlin, in this app's Android source)
/// overrides `onVisibilityChanged` and friends to always report `VISIBLE`, so
/// that event never fires.
///
/// The widget is kept in the tree rather than built on demand because removing
/// it would destroy the view — and the audio with it.
class YoutubeWebviewPlayer extends StatefulWidget {
  const YoutubeWebviewPlayer({super.key});

  @override
  State<YoutubeWebviewPlayer> createState() => _YoutubeWebviewPlayerState();
}

class _YoutubeWebviewPlayerState extends State<YoutubeWebviewPlayer> {
  @override
  void dispose() {
    // Tell the handler the engine is gone, or it will keep issuing commands
    // into a channel with no native end.
    YouTubeWebViewBridge.instance.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // `Positioned`, not a bare child: the enclosing `Stack` uses
    // `StackFit.expand`, which hands non-positioned children *tight* full-screen
    // constraints — and a `SizedBox` cannot shrink below those, so the player
    // silently became full-screen and its platform-view surface swallowed every
    // tap in the app. `Positioned` children are exempt from the stack's fit.
    //
    // `IgnorePointer` is the belt to that braces: the player is driven entirely
    // from Dart (the JS bridge and `evaluateJavascript`), so it never needs a
    // touch, and must never receive one.
    //
    // `Opacity` rather than `Offstage`: an offstage subtree is not painted, and
    // an unpainted platform view can stop compositing, which is the very thing
    // this engine exists to prevent. A zero-alpha layer is still composed.
    return Positioned(
      left: 0,
      top: 0,
      width: 1,
      height: 1,
      child: IgnorePointer(
        child: Opacity(
          opacity: 0,
          child: AndroidView(
            viewType: YouTubeWebViewBridge.viewType,
            // The native factory names its channel `$name/$viewId` so two
            // players could coexist, so the id has to be part of the name here
            // too. Using the bare name silently gets `MissingPluginException`
            // on every call, because the engine has no handler registered for
            // it — which is exactly the failure that shipped.
            //
            // This callback is also the only correct moment to attach: the id
            // does not exist until the view is created, and the native side
            // installs its method handler in the platform view's `init`.
            onPlatformViewCreated: (int viewId) {
              if (!mounted) return;
              YouTubeWebViewBridge.instance.attach(
                MethodChannel(
                  '${YouTubeWebViewBridge.channelName}/$viewId',
                  const StandardMethodCodec(),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
