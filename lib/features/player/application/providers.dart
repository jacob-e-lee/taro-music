import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/media_stack.dart';
import '../domain/media_repository.dart';
import 'webview_audio_handler.dart';

/// Everything network-backed hangs off this one object so there is a single
/// teardown path.
final mediaStackProvider = Provider<MediaStack>((ref) {
  final stack = MediaStack.live();
  ref.onDispose(stack.dispose);
  return stack;
});

/// The search + stream-resolution facade used by both the UI and the audio
/// handler.
final mediaRepositoryProvider = Provider<MediaRepository>(
  (ref) => ref.watch(mediaStackProvider).repository,
);

/// Created in `main()` *before* `runApp`, because `AudioService.init` must
/// register the handler with the platform media session before any widget can
/// ask it to play. `main()` injects that instance via `overrideWithValue`.
final audioHandlerProvider = Provider<WebViewAudioHandler>(
  (_) => throw UnimplementedError(
    'audioHandlerProvider must be overridden in main()',
  ),
);
