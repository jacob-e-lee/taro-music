import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import '../../../core/errors/failures.dart';
import '../domain/track.dart';
import 'track_mapping.dart';
import 'webview_bridge.dart';

/// Single source of truth for playback, driven by a YouTube IFrame player that
/// lives in the widget tree behind [YoutubeWebviewPlayer].
///
/// The handler deliberately owns no WebView of its own: a WebView has to be a
/// widget, so [YouTubeWebViewBridge] is the seam between the two. The queue and
/// the media-session bookkeeping stay here, where the rest of the app already
/// expects them; the engine stays in the widget, where the platform requires it.
///
/// This replaces a `just_audio` + signed-URL pipeline that could not be made to
/// work: YouTube demands a PO token on client-side manifest requests, and the
/// proxies that used to mint URLs for us moved behind bot checks.
///
/// What the rest of the app sees is unchanged: this extends [BaseAudioHandler],
/// so the notification, the media session, headset buttons and every widget keep
/// talking to the same streams they always did.
class WebViewAudioHandler extends BaseAudioHandler with QueueHandler {
  WebViewAudioHandler({math.Random? random})
    : _random = random ?? math.Random() {
    // The player widget may mount before or after this handler, so the
    // subscription is what makes the two order-independent.
    _playerEvents = YouTubeWebViewBridge.instance.events.listen(_onPlayerEvent);
  }

  final math.Random _random;

  late final StreamSubscription<WebViewPlayerEvent> _playerEvents;
  YouTubeWebViewBridge get _player => YouTubeWebViewBridge.instance;

  final List<Track> _tracks = <Track>[];

  /// Indices into [_tracks], in playback order.
  List<int> _playOrder = <int>[];
  int _orderPosition = -1;
  double _speed = 1.0;
  bool _handlingEndOfTrack = false;
  bool _repeatOne = false;

  final Set<String> _startedTrackIds = <String>{};

  /// How many status frames the player has sent, so a failure can be reported
  /// as "the bridge never spoke" versus "the player spoke and refused".
  int _infoEvents = 0;

  /// Fires if a loaded track never reaches PLAYING. A player parked in CUED is
  /// the common failure, and an endless spinner tells the user nothing.
  Timer? _startupWatchdog;

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

  /// The seek bar's two streams. `BaseAudioHandler` does not supply these as
  /// instance getters (only the deprecated static `AudioHandler.positionStream`
  /// exists), so they are derived from the state published here.
  ///
  /// Held rather than computed: as getters these built a fresh `map`ped stream
  /// on every call, so a `StreamBuilder` tore its subscription down and put a
  /// new one up on every rebuild of the sheet.
  ///
  /// [positionStream] carries the *anchor* cadence — one value per published
  /// state, which [`PlaybackState.position`] then extrapolates between. The seek
  /// bar re-reads that extrapolation once a frame rather than waiting for this;
  /// see `_PlaybackClock` in `now_playing_sheet.dart`.
  late final Stream<Duration> positionStream = playbackState.stream.map(
    (state) => state.position,
  );

  late final Stream<Duration?> durationStream = mediaItem.stream.map(
    (item) => item?.duration,
  );

  // ------------------------------------------------------- player events

  void _onPlayerEvent(WebViewPlayerEvent event) {
    switch (event) {
      case PlayerIsReady():
        // A track may have been queued before the widget mounted, in which case
        // `_startCurrent` bailed out before the engine existed. Do not gate this
        // on `processingState == loading`: the unattached branch deliberately
        // publishes `ready` (so a widget test does not spin forever), which
        // meant the gate never matched and the queued track was silently
        // dropped. "There is a current track" is the real condition.
        if (currentTrack != null) {
          unawaited(_startCurrent(autoplay: true));
        }
      case PlayerStateChanged(:final state):
        _onPlayerState(state);
      case PlayerFailed(:final message):
        _reportError(message);
      case PlayerInfo():
        _onInfo(event);
    }
  }

  /// How far the engine's own clock has to sit from the one the media session
  /// is extrapolating before it is worth spending a state update on it.
  ///
  /// `updatePosition` + `updateTime` is an *anchor*: the platform extrapolates
  /// forward from it by itself, so republishing it for every status frame would
  /// rewrite the notification four times a second to say what it already knows.
  /// A fifth of a second is far below what a seek bar can show and comfortably
  /// above the jitter between two frames, so in steady playback this stays
  /// silent and only speaks up when the anchor is genuinely wrong: a stall, a
  /// rate change, or a seek issued from inside the page.
  static const Duration _anchorTolerance = Duration(milliseconds: 200);

  void _onInfo(PlayerInfo info) {
    _infoEvents++;
    if (info.playabilityStatus == 'ERROR' ||
        info.playabilityStatus == 'UNPLAYABLE') {
      _reportError(
        'YouTube will not play this track '
        '(${info.reason ?? info.playabilityStatus})',
      );
      return;
    }
    final currentTime = info.currentTime;
    if (currentTime == null || currentTime < 0) return;

    final position = Duration(milliseconds: (currentTime * 1000).round());
    _fillInDuration(info.duration);

    // One rule covers both steady states, and it is silent in both: while
    // playing the extrapolation tracks the engine, and while paused the engine
    // is frozen at the same place the anchor is. So this neither churns the
    // media session during playback nor re-publishes a motionless position for
    // every frame of a pause.
    if ((playbackState.value.position - position).abs() > _anchorTolerance) {
      _publish(playbackPosition: position);
    }
  }

  /// Names a track's length once the engine knows it, for the times the search
  /// provider did not.
  ///
  /// The engine reports a real duration, and it was being parsed and thrown
  /// away, which left `durationStream` — and so the seek bar's total, and
  /// whether the slider is usable at all — reading whatever the provider said.
  /// `Track.duration` is `Duration.zero` when the provider was silent, and a
  /// zero duration makes the slider inert. Only a *missing* length is filled:
  /// the provider stays the source of truth when it has an answer, so this
  /// cannot argue with it, and it stops after one write per track.
  void _fillInDuration(double? seconds) {
    if (seconds == null || seconds <= 0) return;
    final index = _currentQueueIndex;
    if (index == null || index >= _tracks.length) return;
    final track = _tracks[index];
    if (track.duration != Duration.zero) return;
    _tracks[index] = track.copyWith(
      duration: Duration(milliseconds: (seconds * 1000).round()),
    );
    mediaItem.add(_tracks[index].toMediaItem());
  }

  /// The player's state codes, mapped onto the media session's vocabulary.
  void _onPlayerState(int code) {
    debugPrint('player state: $code');
    switch (code) {
      case 1: // playing
        _startupWatchdog?.cancel();
        _startupWatchdog = null;
        final track = currentTrack;
        if (track != null) _startedTrackIds.add(track.id);
        _publish(processing: AudioProcessingState.ready, playing: true);
      case 2: // paused
        _publish(playing: false);
      case 3: // buffering
        _publish(processing: AudioProcessingState.loading);
      case 0: // ended
        _onTrackEnded();
      case 5: // cued: loaded, not playing. Reporting `ready` beats an endless
        // spinner.
        _startupWatchdog?.cancel();
        _startupWatchdog = null;
        _publish(processing: AudioProcessingState.ready, playing: false);
      case -1: // not started
        break;
      default:
        debugPrint('Unknown player state: $code');
    }
  }

  // ------------------------------------------------------------------ queue

  Future<void> playQueue(
    List<Track> tracks, {
    int startIndex = 0,
    bool autoplay = true,
  }) async {
    if (tracks.isEmpty) return;
    _tracks
      ..clear()
      ..addAll(tracks);
    _rebuildOrder();
    _orderPosition = startIndex.clamp(0, _playOrder.length - 1);
    await _publishQueue();
    await _startCurrent(autoplay: autoplay);
  }

  /// Reads a [Track] out of a [MediaItem], falling back to a minimal one built
  /// from the item's own fields. Items without `extras` â€” a notification click,
  /// a test, anything hand-built â€” would otherwise vanish from the queue.
  static Track? _trackOf(MediaItem? item) {
    if (item == null) return null;
    final track = TrackMediaItem.fromMediaItem(item);
    if (track != null) return track;
    return Track(
      id: item.id,
      title: item.title.isEmpty ? 'Unknown title' : item.title,
      artist: item.artist ?? '',
      duration: item.duration ?? Duration.zero,
      artworkUrl: item.artUri?.toString(),
      source: MediaSourceKind.youtube,
    );
  }

  /// Appends to the queue, starting playback if this is the first batch.
  @override
  Future<void> addQueueItems(List<MediaItem> items) async {
    if (items.isEmpty) return;
    final wasEmpty = _tracks.isEmpty;
    for (final item in items) {
      final track = _trackOf(item);
      if (track != null) _tracks.add(track);
    }
    _rebuildOrder();
    // Before publishing, not after: the position is part of what gets
    // published, and leaving it at the `-1` it starts on meant the very first
    // queue was published with no row marked as playing. It then only got
    // corrected by whichever call moved the position afterwards.
    if (wasEmpty && _tracks.isNotEmpty) _orderPosition = 0;
    await _publishQueue();
    if (wasEmpty && _tracks.isNotEmpty) {
      await _startCurrent(autoplay: true);
    }
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) =>
      addQueueItems(<MediaItem>[mediaItem]);

  /// Removes by *visible* index, which is what the queue list speaks.
  Future<void> removeTrackAt(int visibleIndex) async {
    if (visibleIndex < 0 || visibleIndex >= _playOrder.length) return;
    final trackIndex = _playOrder[visibleIndex];
    final wasCurrent = visibleIndex == _orderPosition;

    _tracks.removeAt(trackIndex);
    _rebuildOrder();
    if (wasCurrent) {
      _orderPosition = (_orderPosition - 1).clamp(
        0,
        _playOrder.isEmpty ? 0 : _playOrder.length - 1,
      );
    } else if (visibleIndex < _orderPosition) {
      // Removing something *above* the playing track shifts everything below it
      // up a slot, so the position has to come down with it. Without this the
      // index was left pointing past the end of the shorter list, and the
      // queue showed no current row at all.
      _orderPosition -= 1;
    }
    await _publishQueue();

    if (wasCurrent) {
      if (_playOrder.isEmpty) {
        await _player.send('stopVideo');
        _publish(processing: AudioProcessingState.idle, playing: false);
      } else {
        await _startCurrent(autoplay: true);
      }
    }
  }

  @override
  Future<void> removeQueueItemAt(int index) => removeTrackAt(index);

  /// `ReorderableListView` reports the destination index *before* the item is
  /// removed, so it is adjusted to match the post-removal list.
  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex < 0 || oldIndex >= _playOrder.length) return;
    if (newIndex < 0 || newIndex >= _playOrder.length) return;
    if (oldIndex == newIndex) return;

    final wasCurrent = oldIndex == _orderPosition;
    // Which *track* is playing, captured before the list is disturbed. The
    // position alone is not enough to put it back afterwards, because the move
    // relocates whichever rows sat between the two indices - including the
    // playing one, if the user dropped a different track onto it.
    final playingTrack = _currentQueueIndex;

    final moved = _playOrder.removeAt(oldIndex);
    _playOrder.insert(newIndex, moved);
    // Re-derive the position from the track rather than adopting `newIndex`.
    // Setting it to the drop slot made the highlight follow the *slot*, so
    // dragging any other track onto the currently playing row made the app look
    // like it had switched songs - while playback, quite correctly, carried on
    // with the same track. Reordering is a change to the queue, not a play
    // command, so the playing track must survive it unchanged.
    _orderPosition = playingTrack == null
        ? newIndex
        : _playOrder.indexOf(playingTrack);
    await _publishQueue();

    // Restart only when the track that was playing is itself the one that
    // moved. Otherwise playback is untouched and the engine does not need to
    // be told anything at all.
    if (wasCurrent) await _startCurrent(autoplay: true);
  }

  Future<void> reorder(List<MediaItem> newQueue) => playQueue(
    newQueue.map(_trackOf).nonNulls.toList(),
    autoplay: playbackState.value.playing,
  );

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _playOrder.length) return;
    _orderPosition = index;
    await _publishQueue();
    await _startCurrent(autoplay: true);
  }

  @override
  Future<void> skipToNext() async {
    if (_playOrder.isEmpty) return;
    final next = _orderPosition + 1;
    if (next < _playOrder.length) {
      _orderPosition = next;
      await _publishQueue();
      await _startCurrent(autoplay: true);
      return;
    }
    if (playbackState.value.repeatMode != AudioServiceRepeatMode.none) {
      await skipToQueueItem(0);
      return;
    }
    _publish(processing: AudioProcessingState.ready, playing: false);
  }

  @override
  Future<void> skipToPrevious() async {
    if (_playOrder.isEmpty) return;
    if (playbackState.value.position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    final previous = _orderPosition - 1;
    if (previous < 0) {
      await seek(Duration.zero);
      return;
    }
    _orderPosition = previous;
    await _publishQueue();
    await _startCurrent(autoplay: true);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final current = _currentQueueIndex;
    _rebuildOrder(shuffle: shuffleMode != AudioServiceShuffleMode.none);
    if (current != null && _playOrder.isNotEmpty) {
      _playOrder
        ..remove(current)
        ..insert(0, current);
      _orderPosition = 0;
    }
    await _publishQueue();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _repeatOne = repeatMode == AudioServiceRepeatMode.one;
    _publish();
  }

  void _rebuildOrder({bool? shuffle}) {
    final shuffling =
        shuffle ??
        (playbackState.value.shuffleMode != AudioServiceShuffleMode.none);
    final indices = List<int>.generate(_tracks.length, (index) => index);
    if (shuffling && indices.length > 1) {
      final current = _currentQueueIndex;
      final rest = indices.where((index) => index != current).toList()
        ..shuffle(_random);
      _playOrder = <int>[?current, ...rest];
    } else {
      _playOrder = indices;
    }
  }

  Future<void> _publishQueue() async {
    queue.add(
      _playOrder
          .where((index) => index < _tracks.length)
          .map((index) => _tracks[index].toMediaItem())
          .toList(),
    );
    final index = _currentQueueIndex;
    if (index != null && index < _tracks.length) {
      mediaItem.add(_tracks[index].toMediaItem());
    }
    // The queue's own highlight rides on the *visible* position, not on
    // `_currentQueueIndex`: the latter is an index into `_tracks` (an index
    // into `_playOrder`, once shuffled or reordered), while the list the user
    // is looking at is indexed by play order. They coincide only while the
    // order is the identity permutation, which is exactly why a shuffled or
    // reordered queue used to highlight the wrong row.
    //
    // This has to be written here, once, rather than in each of the dozen
    // places that move `_orderPosition`: they all already call this, so
    // `skipToNext`, `skipToPrevious`, `skipToQueueItem`, reordering, removal
    // and `playMediaItem` cannot drift apart.
    //
    // A `_orderPosition` of `-1` is the handler's "nothing is playing", but the
    // platform wants a `null` index there rather than a negative one it could
    // index a list with — hence the sentinel instead of passing the value
    // straight through.
    _publish(queueIndex: _orderPosition < 0 ? _noQueueIndex : _orderPosition);
  }

  /// `_publish`'s way of saying "clear the current index", which has to be
  /// distinguishable from "leave the index alone" (a `null` `queueIndex`).
  static const int _noQueueIndex = -1;

  // ------------------------------------------------------------- transport

  @override
  Future<void> play() => _player.send('playVideo');

  @override
  Future<void> pause() => _player.send('pauseVideo');

  @override
  Future<void> seek(Duration position) {
    final target = position < Duration.zero ? Duration.zero : position;
    _publish(playbackPosition: target);
    return _player.send('seekTo', <Object?>[
      target.inMilliseconds / 1000.0,
      true,
    ]);
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    _publish();
    await _player.send('setPlaybackRate', <Object?>[speed]);
  }

  @override
  Future<void> stop() async {
    await _player.send('stopVideo');
    _publish(
      processing: AudioProcessingState.idle,
      playing: false,
      playbackPosition: Duration.zero,
    );
  }

  Future<void> stopAll() async {
    await stop();
    _tracks.clear();
    _playOrder = <int>[];
    _orderPosition = -1;
    await _publishQueue();
  }

  /// `audio_service` routes notification and headset "play this item" here.
  @override
  Future<void> playMediaItem(MediaItem item) async {
    final track = _trackOf(item);
    if (track == null) return;
    final index = _tracks.indexWhere((candidate) => candidate.id == track.id);
    if (index >= 0) {
      final position = _playOrder.indexOf(index);
      if (position >= 0 && position != _orderPosition) {
        _orderPosition = position;
        await _publishQueue();
      }
    } else {
      _tracks.add(track);
      _rebuildOrder();
      _playOrder.add(_tracks.length - 1);
      _orderPosition = _playOrder.length - 1;
      await _publishQueue();
    }
    await _startCurrent(autoplay: true);
  }

  // ------------------------------------------------------- track lifecycle

  Future<void> _startCurrent({required bool autoplay}) async {
    final track = currentTrack;
    if (track == null) return;
    _repeatOne = false;
    mediaItem.add(track.toMediaItem());

    if (!_player.isAttached) {
      // The player widget has not mounted yet. Queue the track; the
      // `PlayerIsReady` handler picks it up as soon as it does.
      //
      // "Loading" is only honest while there is an engine that can resolve it.
      // With no engine — a widget test — nothing ever would, and the progress
      // indicator would spin forever and hang `pumpAndSettle`.
      _publish(
        processing: AudioProcessingState.ready,
        playing: false,
        playbackPosition: Duration.zero,
        controls: _controlsFor(false),
      );
      return;
    }

    _publish(
      processing: AudioProcessingState.loading,
      playing: false,
      playbackPosition: Duration.zero,
      controls: _controlsFor(false),
    );
    _armStartupWatchdog(track);
    await _player.loadVideo(track.id, autoplay: autoplay);
  }

  /// Names the failure instead of spinning forever.
  ///
  /// The frame count in the message separates the two causes we cannot
  /// otherwise tell apart: no frames at all (the bridge never spoke) versus
  /// frames with a player that stays CUED (autoplay policy, or a gated video).
  void _armStartupWatchdog(Track track) {
    _startupWatchdog?.cancel();
    _startupWatchdog = Timer(const Duration(seconds: 12), () {
      if (playbackState.value.playing) return;
      _reportError(
        'The player loaded "${track.title}" but never started '
        '($_infoEvents status frames)',
      );
    });
  }

  void _onTrackEnded() {
    if (_handlingEndOfTrack) return;
    _handlingEndOfTrack = true;
    try {
      final track = currentTrack;
      if (track != null) _startedTrackIds.remove(track.id);
      if (_repeatOne && track != null) {
        unawaited(seek(Duration.zero));
        unawaited(_player.send('playVideo'));
        return;
      }
      unawaited(skipToNext());
    } finally {
      _handlingEndOfTrack = false;
    }
  }

  void _reportError(String message) {
    debugPrint('Playback failure: $message');
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
    Duration? playbackPosition,
    double? speed,
    List<MediaControl>? controls,
    int? queueIndex,
  }) {
    final current = playbackState.value;
    playbackState.add(
      current.copyWith(
        processingState: processing ?? current.processingState,
        playing: playing ?? current.playing,
        queueIndex: queueIndex == null
            ? current.queueIndex
            : (queueIndex == _noQueueIndex ? null : queueIndex),
        // `current.position`, not `current.updatePosition`: the latter is the
        // raw snapshot the last publish happened to carry, while the former is
        // that snapshot *plus* the wall clock since `updateTime`, which is the
        // actual current time. Carrying the snapshot forward is what made
        // pausing zero the bar — nothing had refreshed it, so it was still the
        // `Duration.zero` written when the track started, and a paused state
        // reports `updatePosition` verbatim.
        updatePosition: playbackPosition ?? current.position,
        speed: speed ?? _speed,
        controls: controls ?? _controlsFor(playing ?? current.playing),
        androidCompactActionIndices: const <int>[0, 1, 2],
        systemActions: const <MediaAction>{MediaAction.seek},
      ),
    );
  }

  static List<MediaControl> _controlsFor(bool playing) => <MediaControl>[
    MediaControl.skipToPrevious,
    playing ? MediaControl.pause : MediaControl.play,
    MediaControl.skipToNext,
  ];

  /// Releases the handler's side of the bridge. There is no `dispose` on
  /// `BaseAudioHandler`, so this is called from `AudioService`'s own teardown.
  Future<void> dispose() async {
    _startupWatchdog?.cancel();
    await _playerEvents.cancel();
  }
}
