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

/// Drives the full-screen player as a **persistent layer** in the app shell
/// instead of a modal route.
///
/// Why not `showModalBottomSheet`: a modal route can only be pushed once the
/// gesture has finished, so the mini player tracked the finger while the real
/// player only appeared on release. Keeping the sheet mounted at size 0 lets
/// the drag write into the sheet extent on every frame, so the player's top
/// edge follows the finger in one continuous motion and no route transition
/// ever competes with the gesture.
class PlayerSheetController extends ChangeNotifier {
  PlayerSheetController({required TickerProvider vsync, this.maxSize = 0.96})
    : _sizeAnimation = AnimationController(
        vsync: vsync,
        duration: const Duration(milliseconds: 260),
      ) {
    // The controller owns the sheet's height outright. It used to delegate to
    // a DraggableScrollableController, but that only reports itself attached
    // while its scroll controller is driving a live Scrollable - and the player
    // no longer contains one, because the queue moved behind a tab and the
    // dismiss gesture is handled explicitly.
    _sizeAnimation.addListener(() {
      final value = _sizeTween?.value;
      if (value != null) setSize(value);
    });
  }

  /// Fraction of the screen the fully expanded player occupies.
  final double maxSize;

  final AnimationController _sizeAnimation;

  bool _disposed = false;
  double _size = 0;

  /// How far the finger has travelled, as a fraction of screen height. Kept
  /// separately from the sheet size because the reveal gain makes the two
  /// diverge quickly, and the mini player needs the *finger's* position in
  /// order to follow it.
  double _dragFraction = 0;

  /// How fast the player reveals itself relative to the finger.
  ///
  /// 1.0 would be strictly 1:1, which feels sluggish: you have to drag most of
  /// the screen before anything meaningful is on screen. An exponent below 1
  /// makes the player race ahead of the finger, so a short flick is enough.
  static const double revealExponent = 0.55;

  /// How far the finger must travel (as a fraction of screen height) before the
  /// mini player has fully dissolved into the player.
  ///
  /// This is measured against the *drag*, not against the revealed size. Sizing
  /// the fade against the revealed size made the bar vanish within a few
  /// pixels, because the reveal gain expands a small drag into a much larger
  /// sheet - which is exactly the "it just disappears" feel.
  static const double chromeFadeRange = 0.18;

  /// The player becomes fully opaque over this much of its own travel, so it is
  /// revealed rather than popped into existence.
  static const double playerRevealRange = 0.10;

  /// Opacity of the full-screen player itself.
  static double playerOpacity(double size) =>
      (size / playerRevealRange).clamp(0.0, 1.0);

  /// Opacity of the bottom chrome (mini player + navigation bar).
  ///
  /// Driven by [dragFraction] so the bar is seen travelling with the finger
  /// before it dissolves, and by the player's [size] so that once the sheet has
  /// taken over (including on release) the bar stays out of the way instead of
  /// springing back.
  static double chromeOpacity(
    double size,
    double dragFraction,
    double maxSize,
  ) {
    // Two different clocks, deliberately:
    //
    //  * While a finger is on the bar, it dissolves over `chromeFadeRange` of
    //    *drag distance*, so the bar visibly travels with the finger and fades
    //    gradually - the same way the artwork resizes inside the player.
    //  * Otherwise there is no finger to follow, so it tracks how much of the
    //    player is showing. This keeps the bar hidden while the player is open
    //    and brings it back as the player closes.
    //
    // Mixing the two (taking the minimum) made the bar vanish within a couple
    // of percent of a drag, because the reveal gain inflates a small drag into
    // a large sheet almost immediately.
    final value = dragFraction > 0
        ? 1.0 - (dragFraction / chromeFadeRange)
        : 1.0 - (size / maxSize);
    return value.clamp(0.0, 1.0);
  }

  /// Converts a raw drag distance (fraction of screen height) into the size the
  /// player should actually be at, applying [revealExponent] so the player
  /// opens quickly instead of crawling up in lockstep with the finger.
  static double revealSize(double dragFraction, double maxSize) {
    if (dragFraction <= 0) return 0;
    if (dragFraction >= 1) return maxSize;
    return math.pow(dragFraction, revealExponent).toDouble() * maxSize;
  }

  /// Sets the sheet height outright, clamped, with no animation.
  void setSize(double value) {
    if (_disposed) return;
    final next = value.clamp(0.0, maxSize);
    if ((_size - next).abs() < 0.0005) return;
    _size = next;
    notifyListeners();
  }

  /// Snaps the player to the size implied by a raw drag distance, with no
  /// animation.
  ///
  /// This is what makes the drag feel attached to the finger: the mini player
  /// calls it on every drag update.
  void dragTo(double dragFraction) {
    _dragFraction = dragFraction.clamp(0.0, 1.0);
    setSize(revealSize(_dragFraction, maxSize));
  }

  /// Snaps the sheet to an absolute [value] with no animation.
  ///
  /// Used by the player's own drag-down-to-dismiss, which works in absolute
  /// pixels rather than in the mini player's finger-relative fractions.
  void jumpToSize(double value) {
    _sizeAnimation.stop();
    setSize(value);
  }

  Animation<double>? _sizeTween;

  /// Animates the sheet from its current height to [target].
  ///
  /// The tween carries the begin/end values: the controller is driven as a
  /// 0..1 progress, so animating `value` directly would animate the *size* to
  /// be 0..1 rather than interpolating between where the sheet is and where it
  /// is going.
  void animateSizeTo(
    double target, {
    Duration duration = const Duration(milliseconds: 260),
    Curve curve = Curves.easeOutCubic,
  }) {
    if (_disposed) return;
    final destination = target.clamp(0.0, maxSize);
    _sizeAnimation.stop();
    _sizeTween = Tween<double>(
      begin: _size,
      end: destination,
    ).animate(CurvedAnimation(parent: _sizeAnimation, curve: curve));
    _sizeAnimation.duration = duration;
    _sizeAnimation.forward(from: 0);
  }

  /// Current height of the player as a fraction of the screen (0 = hidden).
  double get size => _size;

  /// How open the player is, 0 = collapsed, 1 = fully expanded.
  ///
  /// This is the axis the *body* reacts to, and it is deliberately distinct
  /// from [morph] (the full <-> peek morph) and from [dragFraction] (where the
  /// finger is). The player's contents fade and slide in on this, so they appear
  /// only once the sheet is meaningfully open and travel with it.
  double get reveal => revealFor(_size, maxSize);

  /// How far the finger has travelled as a fraction of screen height.
  double get dragFraction => _dragFraction;

  /// Eased [reveal] for content that should arrive late in the transition.
  ///
  /// The controls and the tab bar look wrong if they are fully opaque while the
  /// sheet is still only a sliver, so they are driven by a curve that holds
  /// them back and then brings them in decisively.
  double get revealEase => revealEaseFor(_size, maxSize);

  /// Reveals content over the last [revealEaseFraction] of the transition.
  static const double revealEaseFraction = 0.55;

  /// Shift applied to [reveal] so content appears "once the player is more
  /// open" rather than immediately.
  static const double revealEaseBias = 1 / revealEaseFraction;

  /// How open the player is, given its [size] and the [max] it can reach.
  static double revealFor(double size, double max) =>
      max <= 0 ? 0 : (size / max).clamp(0.0, 1.0);

  /// Eased [revealFor], which lags it so content arrives late in the opening.
  static double revealEaseFor(double size, double max) =>
      (revealFor(size, max) * revealEaseBias).clamp(0.0, 1.0);

  // ---------------------------------------------------------------------
  // Morph axis: 0 = full player, 1 = the "peek" state.
  //
  // This is deliberately independent of [size]. The sheet stays fully open in
  // both states; what changes is the player's internal layout, so that the
  // artwork can shrink to a mini strip while the tab content appears beneath.
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

  /// True while the player is even slightly on screen.
  bool get isOpen => size > 0.001;

  /// True while the player is tall enough to act as a modal surface that
  /// should swallow taps meant for the shell underneath.
  bool get isModal => size > 0.02;

  /// Animates the player open to its full height.
  ///
  /// Clears [dragFraction] for the same reason [close] does. Without this the
  /// mini player kept its `dragFraction`-driven vertical offset after the drag
  /// that opened it, so dismissing the player left the bar stranded part way
  /// up the screen instead of returning to the bottom.
  void open() {
    _dragFraction = 0;
    animateSizeTo(
      maxSize,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  /// Animates the player back down into the mini player.
  void close() {
    _dragFraction = 0;
    animateSizeTo(
      0,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeInCubic,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _sizeAnimation.dispose();
    super.dispose();
  }
}
