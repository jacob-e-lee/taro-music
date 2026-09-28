import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// Something the player told us.
sealed class WebViewPlayerEvent {
  const WebViewPlayerEvent();
}

/// The IFrame player's state code (1 playing, 2 paused, 0 ended, 5 cued, 3 buffering).
final class PlayerStateChanged extends WebViewPlayerEvent {
  const PlayerStateChanged(this.state);
  final int state;
}

/// The player refused the video, with YouTube's own wording.
final class PlayerFailed extends WebViewPlayerEvent {
  const PlayerFailed(this.message);
  final String message;
}

/// The periodic status frame.
final class PlayerInfo extends WebViewPlayerEvent {
  const PlayerInfo({
    this.currentTime,
    this.duration,
    this.playabilityStatus,
    this.reason,
  });

  final double? currentTime;
  final double? duration;
  final String? playabilityStatus;
  final String? reason;
}

/// The page finished booting and the player object exists.
final class PlayerIsReady extends WebViewPlayerEvent {
  const PlayerIsReady();
}

/// Dart half of the native audio engine.
///
/// The WebView itself is an Android platform view (`RiPlayWebView`), because
/// the visibility lies it needs cannot be expressed through a Flutter plugin â€”
/// it has to be Kotlin overriding `onVisibilityChanged` and friends. This class
/// only speaks to it over a [MethodChannel], so the queue code above never
/// touches platform details.
///
/// A singleton rather than a provider, because the audio handler is built in
/// `main()` (AudioService must own it before `runApp`) while the platform view
/// is built by the widget tree afterwards.
class YouTubeWebViewBridge {
  YouTubeWebViewBridge._();

  static final YouTubeWebViewBridge instance = YouTubeWebViewBridge._();

  /// Whether to mount the player at all.
  ///
  /// `main()` turns this on. A widget test cannot create a platform view, and
  /// the root widget must not try.
  static bool enabled = false;

  /// The channel name must match `RiPlayWebViewFactory.CHANNEL_NAME`.
  static const String channelName = 'com.example.taro_music/riplay';

  /// The `viewType` must match `RiPlayPlugin.VIEW_TYPE`.
  static const String viewType = 'riplay_webview';

  final StreamController<WebViewPlayerEvent> _events =
      StreamController<WebViewPlayerEvent>.broadcast();

  MethodChannel? _channel;
  bool _playerReady = false;
  bool _autoplayPending = false;
  String? _loadedVideoId;

  Stream<WebViewPlayerEvent> get events => _events.stream;

  /// False until the player widget has mounted.
  bool get isAttached => _channel != null;

  bool get playerReady => _playerReady;

  /// The id currently loaded, so a redundant request does not restart it.
  String? get loadedVideoId => _loadedVideoId;

  /// Called by the player widget once its platform view exists.
  void attach(MethodChannel channel) {
    _channel = channel;
    _playerReady = false;
    channel.setMethodCallHandler(_handle);
  }

  /// Called by the player widget on unmount.
  void detach() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    _playerReady = false;
    _loadedVideoId = null;
  }

  Future<void> _handle(MethodCall call) async {
    switch (call.method) {
      case 'onPlayerReady':
        _playerReady = true;
        _emit(const PlayerIsReady());
        // Replay whatever the queue asked for while the page was loading.
        if (_autoplayPending) {
          _autoplayPending = false;
          await send('playVideo');
        }
      case 'onStateChange':
        final state = call.arguments;
        if (state is int) _emit(PlayerStateChanged(state));
      case 'onPlayerError':
        _emit(PlayerFailed('${call.arguments}'));
      case 'onPlayerInfo':
        final raw = call.arguments;
        if (raw is! String) return;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) _onInfo(decoded);
        } on FormatException {
          // A malformed frame is not worth failing playback over.
        }
    }
  }

  void _onInfo(Map<Object?, Object?> info) {
    final currentTime = info['currentTime'];
    final duration = info['duration'];
    String? status;
    String? reason;
    final response = info['playerResponse'];
    if (response is Map) {
      final playability = response['playabilityStatus'];
      if (playability is Map) {
        final raw = playability['status'];
        if (raw is String) status = raw;
        final why = playability['reason'];
        if (why is String) reason = why;
      }
    }
    _emit(
      PlayerInfo(
        currentTime: currentTime is num ? currentTime.toDouble() : null,
        duration: duration is num ? duration.toDouble() : null,
        playabilityStatus: status,
        reason: reason,
      ),
    );
  }

  void _emit(WebViewPlayerEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  /// Loads [videoId] into the player. The same id twice is a no-op, so
  /// re-selecting the current track resumes rather than restarting.
  Future<void> loadVideo(String videoId, {required bool autoplay}) async {
    if (_loadedVideoId == videoId) {
      if (autoplay) await send('playVideo');
      return;
    }
    _loadedVideoId = videoId;
    _autoplayPending = autoplay;
    await _channel?.invokeMethod<void>('loadVideo', <String, Object?>{
      'videoId': videoId,
      'autoplay': autoplay,
    });
  }

  /// Sends a `YT.Player` method call. The page queues these until the player
  /// exists, so this is safe before the API script has loaded.
  Future<void> send(String method, [List<Object?> args = const []]) =>
      _channel?.invokeMethod<void>('call', <String, Object?>{
        'method': method,
        'args': args,
      }) ??
      Future<void>.value();
}
