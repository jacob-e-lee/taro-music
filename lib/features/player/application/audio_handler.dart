import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/errors/failures.dart';
import '../domain/media_repository.dart';
import '../domain/playback_source.dart';
import '../domain/track.dart';
import 'track_mapping.dart';

/// Single source of truth for playback.
///
/// Registered with `AudioService.init` in `main()`, so one instance serves both
/// the UI and the background media service: the notification, headset buttons
/// and Android Auto all drive the same queue.
///
/// Queue design: YouTube stream URLs expire after a few hours, so they are
/// resolved *lazily*, one track at a time, rather than up front for the whole
/// queue. [_playOrder] holds indices into [_tracks] in the order they will be
/// played, which makes shuffle cheap without mutating the visible queue.
class MusicAudioHandler extends BaseAudioHandler with QueueHandler {
  MusicAudioHandler({
    required this._repository,
    AudioPlayer? player,
    math.Random? random,
  }) : _player = player ?? AudioPlayer(),
       _random = random ?? math.Random() {
    _subscribe();
  }

  final MediaRepository _repository;
  final AudioPlayer _player;
  final math.Random _random;

  /// Test-only binding: no `AudioPlayer`, so no `just_audio` platform
  /// channels are touched. Stream getters fall back to empty streams.

  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];
  final List<Track> _tracks = <Track>[];

  /// Indices into [_tracks], in playback order.
  List<int> _playOrder = <int>[];
  int _orderPosition = -1;
  double _speed = 1.0;
  bool _handlingEndOfTrack = false;

  AudioPlayer get player => _player;

  /// The player's own clocks: finer grained than [playbackState] (which only
  /// moves on discontinuities) and what the seek bar should bind to.
  Stream<Duration> get positionStream => _player.positionStream;

  Stream<Duration?> get durationStream => _player.durationStream;

  Stream<Duration> get bufferedPositionStream => _player.bufferedPositionStream;

  List<Track> get tracks => List<Track>.unmodifiable(_tracks);

  int? get _currentQueueIndex =>
      _orderPosition >= 0 && _orderPosition < _playOrder.length
      ? _playOrder[_orderPosition]
      : null;

  Track? get currentTrack {
    final index = _currentQueueIndex;
    if (index == null || index >= _tracks.length) return null;
    return _tracks[index];
  }

  // --------------------------------------------------------------- wiring ----

  void _subscribe() {
    _subscriptions.add(
      _player.playerStateStream.listen((PlayerState state) async {
        _publish(
          processing: _mapProcessingState(state.processingState),
          playing: state.playing,
        );
        if (state.processingState == ProcessingState.completed &&
            !_handlingEndOfTrack) {
          _handlingEndOfTrack = true;
          try {
            await _handleEndOfTrack();
          } finally {
            _handlingEndOfTrack = false;
          }
        }
      }),
    );

    _subscriptions.add(
      _player.positionStream.listen((Duration position) {
        playbackState.add(
          playbackState.value.copyWith(
            updatePosition: position,
            bufferedPosition: _player.bufferedPosition,
          ),
        );
      }),
    );

    // just_audio reports asynchronous player failures on this stream.
    _subscriptions.add(
      _player.playbackEventStream.listen(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('just_audio error: $error');
          _reportFailure(error);
        },
      ),
    );
  }

  // ------------------------------------------------------------- queue API ---

  /// Replaces the queue and starts (or prepares) [startIndex].
  Future<void> playQueue(
    List<Track> queue, {
    int startIndex = 0,
    bool autoplay = true,
  }) async {
    _tracks
      ..clear()
      ..addAll(queue);
    _playOrder = List<int>.generate(_tracks.length, (index) => index);

    await updateQueue(
      _tracks.map((track) => track.toMediaItem()).toList(growable: false),
    );
    queueTitle.add('Taro Music');

    if (_tracks.isEmpty) {
      await stop();
      return;
    }
    final safeIndex = startIndex.clamp(0, _tracks.length - 1);
    _orderPosition = _playOrder.indexOf(safeIndex);
    await _loadAt(_orderPosition, autoplay: autoplay);
  }

  /// Appends without interrupting the current track.
  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    for (final item in mediaItems) {
      final track = TrackMediaItem.fromMediaItem(item);
      if (track == null) continue;
      _tracks.add(track);
      _playOrder.add(_tracks.length - 1);
    }
    await super.addQueueItems(mediaItems);
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) =>
      addQueueItems(<MediaItem>[mediaItem]);

  /// Removes the queue entry at [index] and keeps playback consistent.
  Future<void> removeTrackAt(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final wasCurrent = _currentQueueIndex == index;
    _tracks.removeAt(index);
    _playOrder = <int>[
      for (final value in _playOrder)
        if (value != index)
          if (value < index) value else value - 1,
    ];
    await updateQueue(
      _tracks.map((track) => track.toMediaItem()).toList(growable: false),
    );
    if (wasCurrent) {
      if (_playOrder.isEmpty) {
        _orderPosition = -1;
        await stop();
      } else {
        _orderPosition = _orderPosition.clamp(0, _playOrder.length - 1);
        await _loadAt(_orderPosition, autoplay: playbackState.value.playing);
      }
    } else if (_orderPosition >= _playOrder.length) {
      _orderPosition = _playOrder.length - 1;
    }
  }

  // ------------------------------------------------------------- transport ---

  @override
  Future<void> play() async {
    if (_tracks.isEmpty) return;
    final index = _currentQueueIndex;
    if (index == null) {
      _orderPosition = _playOrder.isEmpty ? -1 : 0;
      await _loadAt(_orderPosition, autoplay: true);
      return;
    }
    if (_player.processingState == ProcessingState.completed) {
      await _loadAt(_orderPosition, autoplay: true);
      return;
    }
    _publish(playing: true);
    await _player.play();
  }

  @override
  Future<void> pause() async {
    _publish(playing: false);
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.idle,
        playing: false,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
      ),
    );
  }

  @override
  Future<void> seek(Duration position) async {
    _publish(position: position);
    await _player.seek(position);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (_playOrder.isEmpty) return;
    final position = _playOrder.indexOf(index);
    if (position < 0) return;
    await _loadAt(position, autoplay: true);
  }

  @override
  Future<void> skipToNext() => _advance(1);

  @override
  Future<void> skipToPrevious() async {
    // Tapping "previous" shortly into a track restarts it instead of jumping
    // back a whole song.
    if (_player.position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    await _advance(-1);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
    await _player.setLoopMode(switch (repeatMode) {
      AudioServiceRepeatMode.one => LoopMode.one,
      _ => LoopMode.off,
    });
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final current = _currentQueueIndex;
    if (shuffleMode == AudioServiceShuffleMode.all) {
      final rest = <int>[
        for (final index in _playOrder)
          if (index != current) index,
      ]..shuffle(_random);
      _playOrder = current == null
          ? <int>[..._playOrder]
          : <int>[current, ...rest];
      _orderPosition = current == null ? -1 : 0;
    } else {
      _playOrder = List<int>.generate(_tracks.length, (index) => index);
      _orderPosition = current ?? -1;
    }
    playbackState.add(
      playbackState.value.copyWith(
        shuffleMode: shuffleMode,
        queueIndex: _currentQueueIndex,
      ),
    );
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    _publish(speed: speed);
    await _player.setSpeed(speed);
  }

  @override
  Future<void> onTaskRemoved() async {
    await stop();
    await dispose();
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _player.dispose();
  }

  // -------------------------------------------------------------- internal ---

  Future<void> _advance(int step) async {
    if (_playOrder.isEmpty) return;
    var next = _orderPosition + step;
    final repeat = playbackState.value.repeatMode;
    if (next >= _playOrder.length) {
      if (repeat == AudioServiceRepeatMode.all ||
          repeat == AudioServiceRepeatMode.group) {
        next = 0;
      } else {
        await _endOfQueue();
        return;
      }
    }
    if (next < 0) next = _playOrder.length - 1;
    await _loadAt(next, autoplay: true);
  }

  /// Reached the end of the queue with repeat off: rewind the last track and
  /// park it, so pressing play starts the queue again instead of leaving a dead
  /// notification behind.
  Future<void> _endOfQueue() async {
    await _player.pause();
    await _player.seek(Duration.zero);
    _publish(
      playing: false,
      processing: AudioProcessingState.ready,
      position: Duration.zero,
    );
  }

  Future<void> _handleEndOfTrack() async {
    if (playbackState.value.repeatMode == AudioServiceRepeatMode.one) {
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }
    await _advance(1);
  }

  /// Resolves the stream for the track at playback-order slot [position] and
  /// hands it to the player. This is the only place the audio side talks to the
  /// repository.
  Future<void> _loadAt(int position, {required bool autoplay}) async {
    if (position < 0 || position >= _playOrder.length) return;
    final index = _playOrder[position];
    if (index < 0 || index >= _tracks.length) return;
    _orderPosition = position;

    final track = _tracks[index];
    mediaItem.add(track.toMediaItem());
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.loading,
        playing: autoplay,
        queueIndex: index,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
      ),
    );

    final PlaybackSource source;
    try {
      source = await _repository.resolveSource(track);
    } catch (error) {
      debugPrint('Stream resolution failed for ${track.id}: $error');
      _reportFailure(error, track: track);
      return;
    }

    debugPrint('Playing ${track.id} via $source');
    try {
      await _player.setUrl(
        source.url.toString(),
        headers: source.headers.isEmpty ? null : source.headers,
      );
    } catch (error) {
      debugPrint('Player rejected ${source.url}: $error');
      _reportFailure(error, track: track);
      return;
    }

    if (autoplay) {
      await _player.play();
    } else {
      await _player.pause();
    }
  }

  void _reportFailure(Object error, {Track? track}) {
    final message = switch (error) {
      final TaroFailure failure when track != null =>
        '${track.title}: ${failure.message}',
      final TaroFailure failure => failure.message,
      final Object other => 'Playback failed: $other',
    };
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.error,
        playing: false,
        errorMessage: message,
      ),
    );
    customEvent.add(<String, dynamic>{'type': 'error', 'message': message});
  }

  void _publish({
    AudioProcessingState? processing,
    bool? playing,
    Duration? position,
    double? speed,
  }) {
    final current = playbackState.value;
    playbackState.add(
      current.copyWith(
        processingState: processing ?? current.processingState,
        playing: playing ?? current.playing,
        speed: speed ?? _speed,
        updatePosition: position ?? current.updatePosition,
        controls: _controlsFor(playing ?? current.playing),
        androidCompactActionIndices: const <int>[0, 1, 2],
        systemActions: const <MediaAction>{MediaAction.seek},
      ),
    );
  }

  static List<MediaControl> _controlsFor(bool playing) => <MediaControl>[
    MediaControl.skipToPrevious,
    playing ? MediaControl.pause : MediaControl.play,
    MediaControl.skipToNext,
    MediaControl.stop,
  ];

  /// just_audio's `completed` is folded into [AudioProcessingState.ready]: the
  /// handler advances the queue itself, and parking the state at `completed`
  /// freezes the notification.
  static AudioProcessingState _mapProcessingState(ProcessingState state) =>
      switch (state) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.ready,
      };
}
