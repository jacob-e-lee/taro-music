import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Which tab's content sits beneath the player.
enum PlayerTab {
  queue('Queue', Icons.queue_music),
  lyrics('Lyrics', Icons.lyrics_outlined);

  const PlayerTab(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Drives the player as a **single persistent surface** in the app shell rather
/// than a mini bar plus a separate sheet.
///
/// The surface is bottom-anchored and its height is
/// `collapsedHeight + dragPx`, where [collapsedHeight] is the height of the
/// bottom chrome (the mini player band plus the navigation bar) and [dragPx] is
/// how far the finger has travelled. At rest the surface is exactly the chrome
/// tall, so **its top edge *is* the mini player's top edge**; dragging up N
/// pixels moves that edge up N pixels and everything inside rides with it. The
/// mini player and the full player are two states of one widget on one scalar,
/// not two widgets kept in alignment by hand.
///
/// The controller owns the geometry and nothing visual, so the surface and the
/// shell agree on the state without either owning the other.
class PlayerSheetController extends ChangeNotifier {
  PlayerSheetController({required TickerProvider vsync, this.maxSize = 0.96})
    : _animation = AnimationController(
        vsync: vsync,
        duration: const Duration(milliseconds: 260),
      ) {
    _animation.addListener(() {
      final value = _tween?.value;
      if (value != null) _setDragPx(value);
    });
  }

  /// Fraction of the screen the fully expanded player occupies.
  final double maxSize;

  final AnimationController _animation;
  Animation<double>? _tween;

  bool _disposed = false;
  double _screenHeight = 0;

  /// Height of the bottom chrome the surface stands in for: the mini player
  /// band plus the navigation bar. Pushed in by the shell once measured.
  double _collapsedHeight = 0;

  /// How far the finger has travelled, in logical pixels. Zero when collapsed.
  ///
  /// The primary value - everything else derives from it - so the surface
  /// cannot disagree with itself.
  double _dragPx = 0;

  /// Publishes the viewport.
  ///
  /// Deliberately does no change detection: the shell only calls this when the
  /// measurement has actually moved, which keeps this free to notify listeners
  /// without risking doing so during a build.
  void setViewport({
    required double screenHeight,
    required double collapsedHeight,
  }) {
    if (_disposed) return;
    _screenHeight = screenHeight;
    _collapsedHeight = collapsedHeight;
    final cap = maxDragPx;
    if (cap > 0 && _dragPx > cap) _dragPx = cap;
    notifyListeners();
  }

  /// Height of the surface in logical pixels: the chrome, plus the drag.
  double get surfaceHeight => _collapsedHeight + _dragPx;

  /// How far the finger may travel before the surface is fully open.
  double get maxDragPx {
    if (_screenHeight <= 0) return 0;
    return math.max(0.0, maxSize * _screenHeight - _collapsedHeight);
  }

  /// Finger travel in logical pixels: what gestures write into, 1:1.
  double get dragPx => _dragPx;

  /// Fraction of the screen the surface occupies. Never zero now that the
  /// surface stands in for the chrome.
  double get size {
    if (_screenHeight <= 0) return 0;
    return (surfaceHeight / _screenHeight).clamp(0.0, maxSize);
  }

  /// 0 when collapsed, 1 when fully open.
  double get progress {
    final max = maxDragPx;
    if (max <= 0) return isOpen ? 1.0 : 0.0;
    return (_dragPx / max).clamp(0.0, 1.0);
  }

  /// How open the surface is, 0..1. The player's own content rides on this.
  static double revealFor(double progress) => progress.clamp(0.0, 1.0);

  /// Reveals content over the last [revealEaseFraction] of the transition, so
  /// it is carried up by the surface rather than pinned the moment it exists.
  static const double revealEaseFraction = 0.55;
  static const double revealEaseBias = 1 / revealEaseFraction;

  /// Eased [revealFor], which lags it so content arrives late in the opening.
  static double revealEaseFor(double progress) =>
      (revealFor(progress) * revealEaseBias).clamp(0.0, 1.0);

  double get reveal => revealFor(progress);
  double get revealEase => revealEaseFor(progress);

  /// How far through the opening the bottom-band hand-off has got.
  ///
  /// The navigation bar and the surface's own fill have to swap over in the
  /// first sliver of travel, well before the player's content arrives, so this
  /// is deliberately much faster than [reveal]. Two curves on one scalar
  /// because the two have different jobs: this one is a cover-up, [reveal] is
  /// the content arriving.
  static const double chromeFadeFraction = 0.12;
  double get chromeFade => (progress / chromeFadeFraction).clamp(0.0, 1.0);

  /// Sets the finger position outright, clamped, with no animation.
  void _setDragPx(double value) {
    if (_disposed) return;
    final next = value.clamp(0.0, math.max(0.0, maxDragPx)).toDouble();
    if ((_dragPx - next).abs() < 0.01) return;
    _dragPx = next;
    notifyListeners();
  }

  /// Called on every frame of a drag, in logical pixels, strictly 1:1 with the
  /// finger: no gain is applied, so the surface's top edge tracks it exactly.
  void dragTo(double pixels) => _setDragPx(pixels);

  /// Springs the surface to [target] pixels.
  void _animateDragTo(
    double target, {
    required Duration duration,
    required Curve curve,
  }) {
    _animation.stop();
    _tween = Tween<double>(
      begin: _dragPx,
      end: target.clamp(0.0, math.max(0.0, maxDragPx)),
    ).animate(CurvedAnimation(parent: _animation, curve: curve));
    _animation
      ..duration = duration
      ..forward(from: 0);
  }

  /// Animates the surface open to its full height.
  void open() => _animateDragTo(
    maxDragPx,
    duration: const Duration(milliseconds: 280),
    curve: Curves.easeOutCubic,
  );

  /// Animates the surface back down into the mini player band.
  void close() => _animateDragTo(
    0,
    duration: const Duration(milliseconds: 240),
    curve: Curves.easeInCubic,
  );

  // ---------------------------------------------------------------------
  // Morph axis: 0 = full player, 1 = the "peek" state.
  //
  // Independent of [progress]. The surface stays fully open in both states;
  // what changes is its internal layout, so that the artwork can shrink to a
  // mini strip while the tab content appears beneath.
  // ---------------------------------------------------------------------

  double _morph = 0;
  PlayerTab _tab = PlayerTab.queue;

  /// 0 = full player, 1 = peek (mini strip + tabs + tab content).
  double get morph => _morph;

  /// The tab whose content is showing.
  PlayerTab get tab => _tab;

  void selectTab(PlayerTab value) {
    if (value == _tab) return;
    _tab = value;
    notifyListeners();
  }

  /// Sets the morph directly, with no animation.
  ///
  /// The player sheet owns an [AnimationController] for this: it ticks the
  /// value so that a drag can track the finger 1:1 while a release can spring
  /// to an end. Keeping the number here (rather than in the widget) lets the
  /// shell and the sheet agree on the state without either owning the other.
  void setMorph(double value) {
    if (_disposed) return;
    final next = value.clamp(0.0, 1.0);
    if ((_morph - next).abs() < 0.0005) return;
    _morph = next;
    notifyListeners();
  }

  /// True while the player is in the peek state.
  bool get isPeeking => _morph > 0.5;

  /// True while the player has been pulled off the bottom at all.
  ///
  /// The surface is never truly "closed" - at rest it is standing in for the
  /// bottom chrome - so this keys off the finger, not off its height.
  bool get isOpen => _dragPx > 0.5;

  /// True while the surface should swallow taps meant for the shell underneath.
  ///
  /// False at rest, which matters: the surface spans the whole bottom chrome,
  /// but only its collapsed band paints anything, so the navigation bar's band
  /// has to stay clickable through it.
  bool get isModal => _dragPx > 0.5;

  @override
  void dispose() {
    _disposed = true;
    _animation.dispose();
    super.dispose();
  }
}
