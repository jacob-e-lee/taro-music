import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/taro_music_app.dart';
import 'core/config/app_config.dart';
import 'core/di/media_stack.dart';
import 'features/player/application/audio_handler.dart';
import 'features/player/application/providers.dart';

/// Boot order matters, so read this top to bottom:
///
/// 1. The audio session is configured first: Android grants (or denies) audio
///    focus according to it, and the player misbehaves when it is missing.
/// 2. `AudioService.init` registers the *single* [MusicAudioHandler] with the
///    platform media session. Everything else (UI, notification, headset
///    buttons) talks to that instance, so it must exist before `runApp`.
/// 3. `MediaStack.live()` owns the network clients the handler borrows.
/// 4. `ProviderScope` injects both, so no widget or provider ever constructs
///    its own handler, `YoutubeExplode` or `Dio`.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());

  final stack = MediaStack.live(jsSolver: await initJsSolver());
  final handler = await AudioService.init(
    builder: () => MusicAudioHandler(repository: stack.repository),
    config: const AudioServiceConfig(
      androidNotificationChannelId: AppConfig.notificationChannelId,
      androidNotificationChannelName: AppConfig.notificationChannelName,
      androidNotificationChannelDescription:
          AppConfig.notificationChannelDescription,
      androidNotificationOngoing: true,
      androidShowNotificationBadge: false,
      androidStopForegroundOnPause: true,
      artDownscaleWidth: 512,
      artDownscaleHeight: 512,
    ),
  );

  runApp(
    ProviderScope(
      overrides: [
        mediaStackProvider.overrideWithValue(stack),
        mediaRepositoryProvider.overrideWithValue(stack.repository),
        audioHandlerProvider.overrideWithValue(handler),
      ],
      child: const TaroMusicApp(),
    ),
  );
}
