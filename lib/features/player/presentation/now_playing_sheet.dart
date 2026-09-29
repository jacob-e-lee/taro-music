import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/webview_audio_handler.dart';
import '../application/providers.dart';
import '../domain/track.dart';
import 'player_sheet_controller.dart';
import 'player_tabs.dart';
import 'queue_tab.dart';

/// The player, as **one surface**.
///
/// Collapsed it is the mini player band; dragging up stretches that same
/// surface into the full-screen player. There is no second widget, no cross
/// fade and no hand-off: the top edge of the band *becomes* the top edge of
/// the player, and the artwork in it grows into the hero artwork.
///
/// - Prominent hero album artwork with swipe-to-skip gestures (physics-animated)
/// - Clear visual hierarchy: dominant artwork, extra bold headline track title, secondary artist text
/// - Fallback high-contrast dark scrim overlay ensuring WCAG 2.1 AA (>= 4.5:1) contrast
/// - Fully interactive physical transport buttons (48x48 min touch targets) with zero visual latency
/// - "Up Next" queue component with drag-and-drop reordering
class NowPlayingSheet extends ConsumerStatefulWidget {
  const NowPlayingSheet({super.key, required this.sheet});

  /// The persistent player layer, owned by the shell. It starts collapsed to
  /// the chrome's height and follows the finger 1:1.
  final PlayerSheetController sheet;

  /// Height of the collapsed band - the surface's "mini player" state.
  ///
  /// 48dp of artwork plus the 6dp of padding above and below it, which is what
  /// the standalone mini player used to be. The shell adds the navigation bar's
  /// measured height on top of this to get the surface's collapsed height, so
  /// the surface stands exactly where the chrome it replaces did.
  static const double collapsedBarHeight = 60;

  @override
  ConsumerState<NowPlayingSheet> createState() => _NowPlayingSheetState();
}

class _NowPlayingSheetState extends ConsumerState<NowPlayingSheet>
    with SingleTickerProviderStateMixin {
  /// Drives the full-player <-> peek morph. The value itself lives on the
  /// controller so the tab bar can drag it directly.
  late final AnimationController _morphAnimation;

  /// How far the panel's top edge travels across a full morph, in pixels.
  ///
  /// The same measurement handed to the tab bar, cached so the body's
  /// under-scroll handler divides by the number the bar's own drag uses -
  /// two gestures writing into one scalar must agree on its scale.
  double _morphTravelPx = 1;

  /// Whether the gesture in progress took over the morph from a pull-down
  /// inside the panel body.
  ///
  /// Armed by the first under-scroll, or by the body's own pull recognizer;
  /// cleared when that gesture ends, or when the panel reaches morph 0 and the
  /// body unmounts beneath it - so an ordinary scroll never gets a release it
  /// did not ask for.
  bool _panelPulling = false;

  /// Whether the panel's scroll view is at the top of its content.
  ///
  /// The "back at the top" gate, tracked from the body's scroll metrics. The
  /// overscroll path gets this for free (a top under-scroll is the only way one
  /// is reported), but the pull recognizer has to ask *before* it claims a
  /// gesture, so it is kept here rather than inferred.
  bool _bodyAtTop = true;

  /// The tab whose scroll view `_bodyAtTop` describes, so a swap starts at the
  /// top without waiting for the new view's first scroll notification.
  PlayerTab? _lastTab;

  @override
  void initState() {
    super.initState();
    _morphAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    )..addListener(() => widget.sheet.setMorph(_morphAnimation.value));
  }

  @override
  void dispose() {
    _morphAnimation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final handler = ref.watch(audioHandlerProvider);
    final sheet = widget.sheet;

    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      builder: (context, itemSnapshot) {
        final item = itemSnapshot.data;
        if (item == null) {
          // Nothing loaded: the surface stands in for the chrome, but there is
          // no band to stand in for. Returning empty keeps the surface from
          // painting over the shell - and keeps the old "mini player stays
          // hidden until the first track loads" behaviour, now by construction
          // rather than by a separate widget deciding to hide itself.
          return const SizedBox.shrink();
        }
        final track = Track.fromExtras(item.extras);
        final isOffline = track?.isDownloaded ?? false;

        // The surface paints its background through a decorated container, so a
        // transparent Material must sit directly beneath it or ink splashes
        // paint under the decoration.
        //
        // The background itself lives in [_SurfaceFill] rather than here: it
        // only covers the part of the surface that actually paints, and a
        // `Positioned.fill` would spill over the navigation bar band that the
        // surface deliberately leaves transparent.
        return Material(
          type: MaterialType.transparency,
          child: AnimatedBuilder(
            animation: sheet,
            builder: (context, _) => _buildBody(
              context,
              handler: handler,
              item: item,
              isOffline: isOffline,
            ),
          ),
        );
      },
    );
  }

  /// Lays the player out as three stacked regions whose heights are driven by
  /// the single `morph` value:
  ///
  ///   * the player area - morphs from hero artwork to a mini strip
  ///   * the tab bar - always the drag handle, always the same widget
  ///   * the tab content - grows from nothing to filling the remainder
  ///
  /// Sizing the player area and letting the content take the remainder is what
  /// makes the tabs travel: at morph 0 the player area is full height so the
  /// tab bar is pushed to the bottom, and at morph 1 the player area has
  /// collapsed to the mini strip so the bar has docked under it.
  Widget _buildBody(
    BuildContext context, {
    required WebViewAudioHandler handler,
    required MediaItem item,
    required bool isOffline,
  }) {
    final sheet = widget.sheet;
    final morph = sheet.morph;
    final reveal = sheet.reveal;
    final revealEase = sheet.revealEase;
    final progress = sheet.progress;
    final chromeFade = sheet.chromeFade;

    // The surface is anchored to the bottom of the screen, so the tab bar would
    // otherwise sit underneath the Android navigation bar / gesture handle.
    //
    // Scaled by `chromeFade` rather than applied outright: at rest the surface
    // is standing in for the chrome and its own band already sits above the
    // navigation bar, so the inset is already accounted for. It is only needed
    // once the surface has taken the navigation bar's place, which is exactly
    // what `chromeFade` tracks.
    final systemInset = MediaQuery.paddingOf(context).bottom * chromeFade;

    return LayoutBuilder(
      builder: (context, constraints) {
        // How much of the surface actually paints.
        //
        // At rest this is the mini player band alone; the navigation bar's band
        // below it stays transparent, so the real navigation bar shows through
        // and keeps taking taps. The fill extends down to take that band over
        // within the first sliver of travel - the same window in which the
        // navigation bar fades - so the two swap rather than cross over.
        final contentHeight = ui.lerpDouble(
          _barHeight,
          constraints.maxHeight,
          chromeFade,
        )!;

        // The tab bar belongs to the *open* player, so it reserves no height
        // while collapsed, which is what leaves the band's full height for its
        // own row. Capped at the room available so a part-open surface cannot
        // overflow the column.
        final tabBarHeight = math.min(
          _tabBarHeight * reveal.clamp(0.0, 1.0),
          contentHeight,
        );
        // The inset comes off first: it is padding on the whole column, so
        // everything inside has to be measured against what is left after it.
        final usable = math.max(0.0, contentHeight - systemInset);
        final fullPlayerHeight = math.max(0.0, usable - tabBarHeight);
        // The peek state's strip is a fixed height too, so it is clamped into
        // whatever room is actually left over.
        final playerHeight = math.min(
          ui.lerpDouble(fullPlayerHeight, _miniStripHeight, morph) ??
              fullPlayerHeight,
          fullPlayerHeight,
        );
        // The tab content takes the remainder, computed rather than left to an
        // `Expanded`: an `Expanded` here would sit under a `Column`, which hands
        // its children *loose* height constraints, leaving the flex child with
        // an unbounded height to divide and throwing at layout.
        final tabContentHeight = math.max(
          0.0,
          usable - playerHeight - tabBarHeight,
        );
        // Cached for the body's under-scroll handler: the same travel the
        // bar is handed just below, so both gestures scale finger pixels
        // into morph identically.
        final morphTravelPx = math.max(
          1.0,
          fullPlayerHeight - _miniStripHeight,
        );
        _morphTravelPx = morphTravelPx;

        // The gate only describes a scroll view that exists: reset it when the
        // body unmounts and when the tab is swapped, so neither can inherit a
        // stale "not at the top" from a view that is gone.
        if (morph <= 0.001 || _lastTab != sheet.tab) {
          _bodyAtTop = true;
          _lastTab = sheet.tab;
        }

        return Align(
          // Top-anchored within the surface: the band's top edge *is* the
          // surface's top edge, which is the whole point of the merge.
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: contentHeight,
            child: _SurfaceFill(
              progress: progress,
              child: Column(
                children: <Widget>[
                  Padding(
                    // Inside the SizedBox, so the padding deflates the
                    // constraints and the column cannot overflow by the inset.
                    padding: EdgeInsets.only(bottom: systemInset),
                    child: Column(
                      children: <Widget>[
                        SizedBox(
                          height: playerHeight,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onVerticalDragStart: _onDragStart,
                            onVerticalDragUpdate: _onDragUpdate,
                            onVerticalDragEnd: _onDragEnd,
                            // A tap on the collapsed band opens the player. This
                            // used to live on the mini player's InkWell; the
                            // merged surface is its only drag/tap target now, so
                            // without it the band would be drag-only.
                            onTap: sheet.isOpen ? null : sheet.open,
                            child: _MorphingPlayer(
                              sheet: sheet,
                              morph: morph,
                              reveal: reveal,
                              revealEase: revealEase,
                              item: item,
                              isOffline: isOffline,
                              handler: handler,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: tabBarHeight,
                          child: _RevealSlide(
                            // The tabs ride up with the player and only
                            // materialise once it is meaningfully open, rather
                            // than sitting pinned in place from the first pixel.
                            progress: revealEase,
                            distance: _tabBarHeight,
                            child: PlayerTabBar(
                              controller: sheet,
                              // Measured from this layout: the bar sits right
                              // under the player body, so the morph carries it
                              // exactly as far as the body shrinks. Handing the
                              // real distance over is what lets the bar's drag
                              // track the finger 1:1 instead of racing across
                              // a fixed fraction of the screen height.
                              morphTravelPx: morphTravelPx,
                              onTabSelected: sheet.selectTab,
                              animateMorph: _animateMorph,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: tabContentHeight,
                          child: morph <= 0.001
                              ? const SizedBox.shrink()
                              : RawGestureDetector(
                                  // The body's own pull, sitting *above* the
                                  // scroll view in the hit path so it is the
                                  // first to be offered the pointer.
                                  //
                                  // The overscroll listener below only sees
                                  // rejected distance, which stops the moment
                                  // the finger comes back up - so a drag that
                                  // turned around half way used to hand the
                                  // gesture to the list and freeze the morph.
                                  // This recognizer claims the gesture up front
                                  // and maps both directions into the morph.
                                  behavior: HitTestBehavior.translucent,
                                  gestures: <Type, GestureRecognizerFactory>{
                                    _PanelPullRecognizer:
                                        GestureRecognizerFactoryWithHandlers<
                                          _PanelPullRecognizer
                                        >(
                                          _PanelPullRecognizer.new,
                                          (recognizer) {
                                            recognizer
                                              ..canPull = _canPullPanel
                                              ..onStart = _onPanelDragStart
                                              ..onUpdate = _onPanelDragUpdate
                                              ..onEnd = _onPanelDragEnd;
                                          },
                                        ),
                                  },
                                  child: NotificationListener<
                                    ScrollNotification
                                  >(
                                    // Catches what the recognizer does not: a
                                    // pull that began away from the top, where
                                    // the scroll view legitimately owns the
                                    // pointer and only gives the rejected
                                    // distance back as an under-scroll.
                                    onNotification:
                                        _onPanelScrollNotification,
                                    child: Opacity(
                                      opacity: morph.clamp(0.0, 1.0),
                                      child: switch (sheet.tab) {
                                        PlayerTab.queue => QueueTab(
                                          handler: handler,
                                        ),
                                        PlayerTab.lyrics => LyricsPane(
                                          trackId:
                                              Track.fromExtras(item.extras)
                                                  ?.id ??
                                              '',
                                        ),
                                      },
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------
  // One drag, two ends - and no locked-out direction.
  //
  // There is no hand-off event between "the mini player" and "the player"
  // because there is only one surface, and the finger writes its height
  // directly. So a drag that starts upward can turn around and come back down
  // mid-gesture, and one that starts downward can turn around and go back up.
  // Only the release has to choose between the two ends, and it chooses from
  // the direction the finger was *last* moving together with how far along the
  // travel it got.
  // ---------------------------------------------------------------------

  /// Finger travel in pixels when the current drag began, so updates stay
  /// relative rather than accumulating rounding error.
  double _dragBase = 0;

  /// Whether the finger was last moving upward.
  ///
  /// Re-read on every update rather than latched when the drag starts. Latching
  /// it is what used to make a drag's opening direction irreversible: it
  /// decided once that "this gesture opens" or "this gesture dismisses", then
  /// discarded every delta that disagreed with that answer, so a drag that
  /// turned around appeared to freeze until the finger was lifted.
  bool _movingUp = true;

  void _onDragStart(DragStartDetails details) {
    _morphAnimation.stop();
    _dragBase = widget.sheet.dragPx;
    // Seeded from where the surface already is, so a drag too short to register
    // a direction still settles the way a flick from that end would.
    _movingUp = !widget.sheet.isOpen;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final dy = details.delta.dy;
    if (dy == 0) return;
    _movingUp = dy < 0;
    // Applied whatever its sign, and at both ends of the travel: the controller
    // clamps, so dragging past an end parks the surface there and pulling back
    // the other way resumes from it immediately.
    widget.sheet.dragTo(_dragBase - dy);
    // Rebased on the *clamped* result, so travel banked up past an end is not
    // spent the instant the finger comes back.
    _dragBase = widget.sheet.dragPx;
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final sheet = widget.sheet;

    // A decisive flick settles on its own, without consulting where the finger
    // happened to stop.
    if (velocity <= _kFlingVelocity) {
      sheet.open();
      return;
    }
    if (velocity >= _dismissFlingVelocity) {
      sheet.close();
      return;
    }

    // A slow release settles by position, against the threshold belonging to
    // the direction the finger was last moving. A single shared threshold would
    // be wrong either way round: a drag *out* of the band only has to clear a
    // nudge before it counts, while a drag back down has to cover most of the
    // travel before it means "dismiss".
    final settleOpen = _movingUp
        ? sheet.dragPx >= _kOpenPx
        : sheet.dragPx >= sheet.maxDragPx * _dismissFraction;
    if (settleOpen) {
      sheet.open();
    } else {
      sheet.close();
    }
  }

  /// Travel past which a release opens the surface, in logical pixels.
  ///
  /// The drag is now strictly 1:1, so this is a real distance rather than a
  /// fraction of a gained one. It is small because a short flick still opens
  /// on intent, and a genuinely stray nudge is much shorter than this.
  static const double _kOpenPx = 56;

  /// An upward fling always opens, even from a very short drag.
  static const double _kFlingVelocity = -400;

  /// A release this fast counts as a deliberate flick towards dismissing.
  static const double _dismissFlingVelocity = 300;

  /// Below this fraction of the travel, letting go means "dismiss me".
  static const double _dismissFraction = 0.5;

  /// Springs the morph to [target]. The value lives on the controller so the
  /// tab bar can drag it directly while this owns the animation.
  void _animateMorph(double target) {
    _morphAnimation.stop();
    _morphAnimation.value = widget.sheet.morph;
    _morphAnimation.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  /// Lets a swipe-down anywhere in the panel body leave it.
  ///
  /// Whether the panel body may claim a downward drag right now: the panel
  /// exists and its scroll view is at the top.
  bool _canPullPanel() => _bodyAtTop && widget.sheet.morph > 0.001;

  void _onPanelDragStart(DragStartDetails details) {
    _morphAnimation.stop();
    _panelPulling = true;
  }

  /// Both directions, at both ends - the same rule the surface's own drag uses,
  /// so a pull that turns around half way drags the morph back up instead of
  /// handing the gesture to the list.
  void _onPanelDragUpdate(DragUpdateDetails details) {
    final dy = details.delta.dy;
    if (dy == 0) return;
    widget.sheet.setMorph(widget.sheet.morph - dy / _morphTravelPx);
    // Hit zero: the body is about to unmount, so settle the flag here rather
    // than waiting for an end that can no longer arrive.
    if (widget.sheet.morph <= 0.001) _panelPulling = false;
  }

  void _onPanelDragEnd(DragEndDetails details) {
    _settlePanelPull(details.primaryVelocity ?? 0);
  }

  /// Decides which end a finished panel pull springs to.
  ///
  /// One rule, shared by the recognizer and the overscroll path below, so the
  /// two ways of pulling the panel out cannot disagree about where it lands.
  void _settlePanelPull(double velocity) {
    _panelPulling = false;
    final flickedUp = velocity < -PlayerTabBar.flingThreshold;
    final flickedDown = velocity > PlayerTabBar.flingThreshold;
    final movedFar = widget.sheet.morph > PlayerTabBar.settleFraction;
    _animateMorph(flickedUp || (movedFar && !flickedDown) ? 1.0 : 0.0);
  }

  /// Keeps the top-of-list gate in step with the body's scroll view.
  void _noteScrollMetrics(ScrollNotification notification) {
    final metrics = notification.metrics;
    _bodyAtTop = metrics.pixels <= metrics.minScrollExtent + _kTopEpsilonPx;
  }

  /// Slack allowed on the "at the top" comparison, to absorb the sub-pixel
  /// rounding a scroll view reports after a fling lands on its boundary.
  static const double _kTopEpsilonPx = 0.5;

  /// The catch-all for pulls the recognizer cannot own: one that began away
  /// from the top, where the scroll view legitimately holds the pointer and
  /// only hands the rejected distance back as an under-scroll.
  ///
  /// The body is a scroll view, so when it is at the top of its content and
  /// the finger keeps pulling down, the list cannot move: it hands back the
  /// rejected distance as an [OverscrollNotification] whose `overscroll` is
  /// negative. That distance *is* finger travel, so it writes into the morph
  /// exactly as the tab bar's drag does - divided by the travel, 1:1 - and it
  /// only ever fires once the list is already at its top, which is the
  /// "back at the top" gate for free. Overscroll at the bottom (positive)
  /// belongs to the list's own bounce and is left alone.
  ///
  /// On release, the same rule as the bar decides: a flick back up, or more
  /// than half the travel still held, returns to the full player; anything
  /// less springs back to the panel. Velocity arrives on the scroll end's
  /// `dragDetails`, which the test suite's zero-timestamp events make zero -
  /// so position decides there, as it does for the bar.
  ///
  /// One limitation worth naming: this rides the clamping physics' rejected
  /// distance, so on the bouncing (iOS/macOS) physics - which swallow the
  /// drag into negative pixels instead of reporting it rejected - the gesture
  /// does not fire.
  bool _onPanelScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      // A fresh gesture begins: nothing left over to settle from the last.
      _panelPulling = false;
      _noteScrollMetrics(notification);
      return false;
    }

    if (notification is OverscrollNotification) {
      final overscroll = notification.overscroll;
      // Only the under-scroll at the top counts. The morph-0 guard is for
      // the notification arriving in the same instant the body unmounts:
      // re-arming after that would strand the flag with nobody to clear it.
      if (overscroll >= 0 || widget.sheet.morph <= 0.001) return false;
      if (!_panelPulling) {
        _panelPulling = true;
        // The finger has taken the morph over from any running animation.
        _morphAnimation.stop();
      }
      widget.sheet.setMorph(widget.sheet.morph + overscroll / _morphTravelPx);
      // Hit zero: the body is about to unmount, so settle the flag's fate
      // here rather than waiting for a scroll end that can no longer arrive.
      if (widget.sheet.morph <= 0.001) _panelPulling = false;
      return false;
    }

    if (notification is ScrollUpdateNotification) {
      _noteScrollMetrics(notification);
      // The finger came back off the top, so the list is scrolling again and
      // the under-scroll has stopped arriving. Without this the morph would
      // freeze wherever the reversal caught it.
      if (_panelPulling && notification.scrollDelta != null) {
        _settlePanelPull(0);
      }
      return false;
    }

    if (notification is ScrollEndNotification) {
      _noteScrollMetrics(notification);
      if (_panelPulling) {
        _settlePanelPull(notification.dragDetails?.primaryVelocity ?? 0);
      }
      return false;
    }

    return false;
  }

  static const double _tabBarHeight = 58;
  static const double _miniStripHeight = 64;

  /// Height of the collapsed band - the surface's "mini player" state.
  ///
  /// 48dp of artwork plus the 6dp of padding above and below it, which is what
  /// the standalone mini player used to be. The shell adds the navigation bar's
  /// measured height on top of this to get the surface's collapsed height.
  static const double _barHeight = NowPlayingSheet.collapsedBarHeight;

  /// Corner radius the open player rounds its top to. Zero while collapsed:
  /// the band keeps sharp corners, so it reads as one continuous strip with the
  /// navigation bar beneath rather than as a floating pill.
  static const double _topRadius = 24;
}

/// Claims a downward drag anywhere in the panel body, so it can be left without
/// reaching up to the tab bar - and keeps it, so the pull can be reversed.
///
/// The scroll view's own drag recognizer would otherwise win: it accepts at the
/// touch slop (18px), and the arena is closed on pointer-down, so the first
/// member to resolve `accepted` takes the gesture outright. Accepting earlier
/// than it and *only* for a downward pull while the list is at its top is what
/// makes the difference without taking the list's ordinary scrolling away.
///
/// `globalDistanceMoved` is signed - negative is upward - which is what lets
/// this refuse an upward swipe at the top and leave it to scroll the list.
class _PanelPullRecognizer extends VerticalDragGestureRecognizer {
  /// Whether the body is in a state where a pull may be claimed. Consulted per
  /// pointer move, so a gesture that starts at the top and scrolls into the
  /// list simply stops being accepted.
  bool Function()? canPull;

  @override
  String get debugDescription => 'panel pull';

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    if (canPull?.call() != true) return false;
    return globalDistanceMoved > _kPanelPullAcceptPx;
  }
}

/// Deliberately well under the 18px touch slop, so this recognizer resolves
/// before the scroll view's does. Large enough that a tap on a queue row - or
/// the long-press that starts a reorder - never reaches it.
const double _kPanelPullAcceptPx = 8;

/// The painted fill of the surface: background, shadow, and top corners.
///
/// Sized to whatever the surface is actually painting, which is the collapsed
/// band at rest and the whole surface once open. The navigation bar's band
/// below that is left transparent on purpose, so the real navigation bar shows
/// through and keeps taking taps.
class _SurfaceFill extends StatelessWidget {
  const _SurfaceFill({required this.progress, required this.child});

  /// 0 collapsed, 1 open. Drives the corner radius and the shadow only; the
  /// fill's own height is decided by the caller.
  final double progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface;
    final radius = Radius.circular(
      _NowPlayingSheetState._topRadius * progress.clamp(0.0, 1.0),
    );

    // The wash at the top is composited against the surface colour by hand
    // instead of being a translucent gradient stop.
    //
    // `BoxDecoration` hands the gradient to the paint as a *shader*, and a
    // shader replaces the colour rather than blending over it: `color` is
    // ignored outright once `gradient` is set. A stop at 40% alpha is therefore
    // 60% see-through, which is what made the open player look translucent.
    // Blending it down to an opaque colour gives the identical wash with
    // nothing showing through it.
    final shield = Color.alphaBlend(
      theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      surface,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        // A fallback for if the gradient is ever dropped. As noted above, this
        // colour is not actually painted while `gradient` is set.
        color: surface,
        // Square while collapsed. The band keeps sharp corners so it reads as
        // one continuous strip with the navigation bar beneath rather than as a
        // floating pill, and the corner grows in as the player opens.
        borderRadius: BorderRadius.vertical(top: radius),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25 * progress.clamp(0.0, 1.0)),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
        // Contrast shield, so text keeps its ratio whatever is behind. Both
        // stops are opaque, so the shell cannot show through the surface.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[shield, surface],
        ),
      ),
      child: // The queue's ListTiles paint their background and ink on the
      // nearest Material ancestor. Without one between them and this
      // DecoratedBox, its background colour hides those effects and Flutter
      // asserts. This is the same guard the pre-merge sheet needed, kept here
      // because the fill is now inside the surface rather than wrapping it.
      Material(type: MaterialType.transparency, child: child),
    );
  }
}

/// Fades and slides content in as the player opens.
///
/// Used for the transport row and the tab bar so they travel with the sheet
/// instead of being pinned in place the moment it exists. `progress` is the
/// controller's eased reveal; `distance` is roughly how far the content should
/// travel so it appears to be carried up by the player.
class _RevealSlide extends StatelessWidget {
  const _RevealSlide({
    required this.progress,
    required this.distance,
    required this.child,
  });

  final double progress;
  final double distance;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: progress.clamp(0.0, 1.0),
      child: IgnorePointer(
        ignoring: progress < 0.99,
        child: Transform.translate(
          offset: Offset(0, (1 - progress.clamp(0.0, 1.0)) * distance),
          child: child,
        ),
      ),
    );
  }
}

/// The player area, which morphs between the full player and the mini strip.
///
/// Everything is one widget tree whose geometry is interpolated, so the
/// artwork genuinely travels from a large centred square to a small
/// top-left thumbnail instead of one layout being cross-faded into another.
class _MorphingPlayer extends StatelessWidget {
  const _MorphingPlayer({
    required this.sheet,
    required this.morph,
    required this.reveal,
    required this.revealEase,
    required this.item,
    required this.isOffline,
    required this.handler,
  });

  final PlayerSheetController sheet;
  final double morph;

  /// How open the player is, 0 = collapsed, 1 = fully expanded. The artwork
  /// starts here at the shell mini player's size and position, so it grows
  /// into the hero artwork rather than being swapped for it.
  final double reveal;

  /// Eased form of [reveal], so the controls and tabs arrive late.
  final double revealEase;
  final MediaItem item;
  final bool isOffline;
  final WebViewAudioHandler handler;

  static const double _artSmall = 48;
  static const double _sidePad = 24;
  static const double _heroTop = 68;

  /// The compact state: the collapsed band, and the peek strip.
  ///
  /// These two are the same layout - a 48dp thumbnail with the title beside it
  /// and play/next on the right - differing only in how much room they sit in,
  /// which is the caller's business. The full player is the other end of the
  /// same axis.
  static const double _compactLeft = 8;
  static const double _compactTop = 6;
  static const double _compactTitleLeft = 68;
  static const double _compactTitleTop = 10;
  static const double _compactTitleRight = 116;

  /// Room reserved beneath the hero artwork for the title block and the
  /// transport row, so the artwork is never sized into them.
  static const double _artFootprintBelow = 190;

  /// How far the transport row travels as the player opens.
  static const double _controlsRevealDistance = 90;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final areaHeight = constraints.maxHeight;

        // One axis drives the whole layout, and it collapses the two former
        // axes into each other:
        //
        //  * `morph` (the full <-> peek morph) is 1 at the peek strip.
        //  * `reveal` (the surface opening) is 0 at the collapsed band, so
        //    1 - reveal is 1 at the band.
        //
        // Taking the max of the two gives 1 for *both* compact states and 0
        // only for the full player, which is precisely "how unlike the full
        // player is this". It is why the collapsed band and the peek strip can
        // share one layout, and why the band needs no second widget.
        final compact = math.max(morph, 1.0 - reveal.clamp(0.0, 1.0));

        // The hero size is capped by the area's own height as well as its
        // width, so the artwork is never a slab with its bottom sliced off; it
        // simply keeps growing as the surface does.
        final maxByHeight = math.max(
          _artSmall,
          areaHeight - _heroTop - _artFootprintBelow,
        );
        final heroSize = math.min(
          (width - 48).clamp(240.0, 320.0),
          maxByHeight,
        );

        // Anchored to the *top* of the area, which is the top of the surface,
        // which at rest is the top of the band. So at `reveal` 0 the artwork
        // sits exactly where the band puts it, and every pixel of drag carries
        // it up with everything else in here.
        final artSize =
            ui.lerpDouble(heroSize, _artSmall, compact) ?? heroSize;
        final centred = (width - artSize) / 2;
        final artLeft = ui.lerpDouble(centred, _compactLeft, compact) ?? centred;
        final artTop = ui.lerpDouble(_heroTop, _compactTop, compact) ?? _heroTop;

        // Title block: below the hero artwork when full, beside the thumbnail
        // when compact, leaving room for the mini transport on the right.
        final titleLeft =
            ui.lerpDouble(_sidePad, _compactTitleLeft, compact) ?? _sidePad;
        final titleRight =
            ui.lerpDouble(_sidePad, _compactTitleRight, compact) ?? _sidePad;
        final titleTop =
            ui.lerpDouble(artTop + artSize + 24, _compactTitleTop, compact) ??
            artTop + artSize + 24;

        // The hero-only chrome fades out as either compact state fades in.
        final heroOpacity = (1.0 - compact).clamp(0.0, 1.0);
        final miniOpacity = compact.clamp(0.0, 1.0);

        return Stack(
          children: <Widget>[
            // ---- header (hero only) ----
            Positioned(
              left: 0,
              top: 8,
              right: 0,
              height: 52,
              child: Opacity(
                opacity: heroOpacity,
                child: IgnorePointer(
                  ignoring: compact > 0.5,
                  child: _Header(onClose: sheet.close),
                ),
              ),
            ),

            // ---- the morphing artwork ----
            Positioned(
              left: artLeft,
              top: artTop,
              width: artSize,
              height: artSize,
              child: _SwipeableAlbumArt(
                size: artSize,
                artUri: item.artUri,
                onSwipeLeft: handler.skipToNext,
                onSwipeRight: handler.skipToPrevious,
                isOffline: isOffline,
              ),
            ),

            // ---- the morphing title/artist ----
            Positioned(
              left: titleLeft,
              top: titleTop,
              right: titleRight,
              child: _MorphingTitle(item: item, compact: compact),
            ),

            // ---- compact transport: play/next, for the band and the strip ----
            //
            // One widget for both compact states. At rest this is the band's
            // own transport, so the bar's controls are the player's controls
            // rather than a copy of them.
            Positioned(
              right: _compactLeft,
              top: 0,
              width: 112,
              // Clamped to the room available: the band is shorter than the
              // peek strip, and the buttons centre within it.
              height: math.min(_stripHeight, areaHeight),
              child: Opacity(
                opacity: miniOpacity,
                child: IgnorePointer(
                  ignoring: compact < 0.5,
                  child: Center(child: _MiniTransport(handler: handler)),
                ),
              ),
            ),

            // ---- seek bar + full transport (hero only) ----
            //
            // These slide up with the player and only appear once it is
            // meaningfully open, rather than being present and pinned from the
            // first frame. `heroOpacity` still fades them out in the compact
            // states, so the two axes compose.
            Positioned(
              left: _sidePad,
              right: _sidePad,
              bottom: 8,
              child: Opacity(
                opacity: heroOpacity,
                child: IgnorePointer(
                  ignoring: compact > 0.5 || reveal < 0.99,
                  child: _RevealSlide(
                    progress: revealEase,
                    distance: _controlsRevealDistance,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _SeekBar(
                          handler: handler,
                          // The same condition the `IgnorePointer` above uses:
                          // the clock only runs while the bar is in view.
                          enabled: compact <= 0.5 && reveal >= 0.99,
                        ),
                        const SizedBox(height: 12),
                        _PlayerControls(handler: handler),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static const double _stripHeight = 64;
}

/// Drag handle plus the close affordance. Hero state only.
class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        Container(
          width: 48,
          height: 5,
          decoration: BoxDecoration(
            color: theme.colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(2.5),
          ),
        ),
        Expanded(
          child: Row(
            children: <Widget>[
              Semantics(
                button: true,
                label: 'Close now playing sheet',
                child: IconButton(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  tooltip: 'Close',
                  icon: const Icon(Icons.keyboard_arrow_down, size: 30),
                  onPressed: onClose,
                ),
              ),
              Expanded(
                child: Text(
                  'NOW PLAYING',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelMedium?.copyWith(
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              // Balances the close button so the title stays centred.
              const SizedBox(width: 48, height: 48),
            ],
          ),
        ),
      ],
    );
  }
}

/// Track title and artist, interpolating from the hero treatment to the
/// compact one that sits beside the mini thumbnail.
class _MorphingTitle extends StatelessWidget {
  const _MorphingTitle({required this.item, required this.compact});

  final MediaItem item;
  final double compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleSize = ui.lerpDouble(24, 15, compact) ?? 24;
    final artistSize = ui.lerpDouble(16, 13, compact) ?? 13;
    final offline = Track.fromExtras(item.extras)?.isDownloaded ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          item.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontSize: titleSize,
            height: 1.15,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: <Widget>[
            if (offline) ...<Widget>[
              Icon(
                Icons.offline_pin,
                size: ui.lerpDouble(16, 12, compact)!,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text(
                item.artist ?? 'Unknown artist',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontSize: artistSize,
                  fontWeight: FontWeight.w400,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The peek-state transport: play/pause and next only.
///
/// Deliberately a subset of the hero row - no shuffle, no repeat, no previous.
/// It is the same set the shell mini player offers, so the two agree.
class _MiniTransport extends StatelessWidget {
  const _MiniTransport({required this.handler});

  final WebViewAudioHandler handler;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      initialData: handler.playbackState.value,
      builder: (context, snapshot) {
        final state = snapshot.data ?? handler.playbackState.value;
        final playing = state.playing;
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            Semantics(
              button: true,
              label: playing ? 'Pause track' : 'Play track',
              child: SizedBox(
                width: 48,
                height: 48,
                child: IconButton(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  tooltip: playing ? 'Pause' : 'Play',
                  iconSize: 28,
                  icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  onPressed: playing ? handler.pause : handler.play,
                ),
              ),
            ),
            Semantics(
              button: true,
              label: 'Skip to next track',
              child: SizedBox(
                width: 48,
                height: 48,
                child: IconButton(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  tooltip: 'Next track',
                  iconSize: 28,
                  icon: const Icon(Icons.skip_next),
                  onPressed: handler.skipToNext,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Swipeable album art featuring gesture physics and slide animation
class _SwipeableAlbumArt extends StatefulWidget {
  const _SwipeableAlbumArt({
    required this.size,
    required this.artUri,
    required this.onSwipeLeft,
    required this.onSwipeRight,
    required this.isOffline,
  });

  /// Edge length in logical pixels. Driven by the morph so this is a single
  /// widget that genuinely resizes from hero artwork to mini-strip thumbnail,
  /// rather than one large and one small widget being cross-faded.
  final double size;

  final Uri? artUri;
  final VoidCallback onSwipeLeft;
  final VoidCallback onSwipeRight;
  final bool isOffline;

  @override
  State<_SwipeableAlbumArt> createState() => _SwipeableAlbumArtState();
}

class _SwipeableAlbumArtState extends State<_SwipeableAlbumArt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _animation;
  double _dragExtent = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _animation =
        Tween<double>(begin: 0, end: 0).animate(
          CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
        )..addListener(() {
          setState(() {
            _dragExtent = _animation.value;
          });
        });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    _controller.stop();
    setState(() {
      _dragExtent += details.primaryDelta ?? 0;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    const threshold = 60.0;
    if (_dragExtent < -threshold) {
      widget.onSwipeLeft();
    } else if (_dragExtent > threshold) {
      widget.onSwipeRight();
    }

    _animation = Tween<double>(
      begin: _dragExtent,
      end: 0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artSize = widget.size;
    // Corners and shadow soften as the artwork shrinks into a thumbnail.
    final radius = (artSize * 0.05).clamp(6.0, 16.0);

    return GestureDetector(
      onHorizontalDragUpdate: _onHorizontalDragUpdate,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      child: Transform.translate(
        offset: Offset(_dragExtent.clamp(-80.0, 80.0), 0),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: artSize,
              height: artSize,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: radius * 1.2,
                    offset: Offset(0, radius * 0.5),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: widget.artUri != null
                    ? Image.network(
                        widget.artUri.toString(),
                        width: artSize,
                        height: artSize,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            _NowPlayingFallbackArt(size: artSize),
                      )
                    : _NowPlayingFallbackArt(size: artSize),
              ),
            ),
            if (widget.isOffline && artSize > 120)
              Positioned(
                right: 12,
                top: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withValues(
                      alpha: 0.9,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.offline_pin,
                        size: 14,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Offline',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.handler, required this.enabled});

  final WebViewAudioHandler handler;

  /// Whether the bar is on screen. A collapsed player has nothing to animate.
  final bool enabled;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  /// Where the finger is, while it is down. Null when it is not.
  ///
  /// The slider's value is otherwise owned by the engine's clock, which the
  /// ticker below re-reads every frame while playing — so without a value of our
  /// own to hold during a drag, the thumb would be yanked back to the playback
  /// position between one drag frame and the next and scrubbing would be
  /// impossible.
  Duration? _scrub;

  @override
  Widget build(BuildContext context) {
    final handler = widget.handler;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return StreamBuilder<Duration?>(
      stream: handler.durationStream,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? Duration.zero;
        final maxMs = duration.inMilliseconds.toDouble();
        // This builder repaints once per published *anchor*; `_PlaybackClock`
        // is what moves the bar between those.
        return StreamBuilder<Duration>(
          stream: handler.positionStream,
          initialData: Duration.zero,
          builder: (context, _) => _PlaybackClock(
            handler: handler,
            // Nothing to animate while the finger owns the value.
            enabled: widget.enabled && _scrub == null,
            builder: (context, clock) {
              final position = _scrub ?? clock;
              final value = position.inMilliseconds
                  .toDouble()
                  .clamp(0, maxMs <= 0 ? 1 : maxMs)
                  .toDouble();
              return Column(
                children: <Widget>[
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 16,
                      ),
                    ),
                    child: Slider(
                      min: 0,
                      max: maxMs <= 0 ? 1 : maxMs,
                      value: value,
                      onChanged: duration == Duration.zero
                          ? null
                          : (seekTo) {
                              final target = Duration(
                                milliseconds: seekTo.round(),
                              );
                              setState(() => _scrub = target);
                              handler.seek(target);
                            },
                      onChangeEnd: duration == Duration.zero
                          ? null
                          : (_) => setState(() => _scrub = null),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Text(_clock(position), style: style),
                        Text(_clock(duration), style: style),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

/// The seek bar's clock.
///
/// [`PlaybackState.position`] is already a live value — it is `updatePosition`
/// plus the wall clock since `updateTime`, while playing — so all it ever needed
/// was somebody reading it again. This reads it once per display frame, which is
/// what turns the engine's slow anchor updates into motion at the refresh rate
/// the screen actually has.
///
/// That is affordable because of how little it does. It is gated on the engine
/// reporting playback *and* the bar being on screen, so a paused or collapsed
/// player costs nothing at all; and it touches no platform channel, which is
/// exactly what publishing a state per engine frame would have done.
///
/// Worth knowing before writing a test against it: while this is ticking the
/// tree has a frame scheduled indefinitely, so `pumpAndSettle` will not return.
/// Pump with an explicit duration instead — the rule the loading spinner in this
/// file already imposes.
class _PlaybackClock extends StatefulWidget {
  const _PlaybackClock({
    required this.handler,
    required this.enabled,
    required this.builder,
  });

  final WebViewAudioHandler handler;

  /// Whether the bar is on screen.
  final bool enabled;

  final Widget Function(BuildContext context, Duration position) builder;

  @override
  State<_PlaybackClock> createState() => _PlaybackClockState();
}

class _PlaybackClockState extends State<_PlaybackClock>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onFrame);

  /// A paused engine has a frozen position, so there is nothing to re-read and
  /// no reason to keep asking for frames.
  bool get _running =>
      widget.enabled && widget.handler.playbackState.value.playing;

  void _onFrame(Duration _) {
    if (!_running) {
      _ticker.stop();
      return;
    }
    setState(() {});
  }

  void _sync() {
    if (_running && !_ticker.isActive) {
      _ticker.start();
    } else if (!_running && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_PlaybackClock oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Everything that changes the answer — a new anchor, play or pause, the bar
    // sliding into view — arrives here as a rebuild from the streams above.
    _sync();
  }

  @override
  void dispose() {
    // Stopped before disposal: a Ticker that is still active when its state is
    // disposed trips the provider mixin's own assertion, and this sheet is torn
    // down mid-playback every time the app is closed.
    _ticker
      ..stop()
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, widget.handler.playbackState.value.position);
}

class _PlayerControls extends StatefulWidget {
  const _PlayerControls({required this.handler});

  final WebViewAudioHandler handler;

  @override
  State<_PlayerControls> createState() => _PlayerControlsState();
}

/// The single horizontal transport row:
/// shuffle | previous | play/pause | next | repeat
///
/// Every control is an inline, always-visible physical button (no stop button)
/// with a WCAG 2.1 compliant 48x48dp minimum touch target.
class _PlayerControlsState extends State<_PlayerControls> {
  bool? _optimisticPlaying;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = theme.colorScheme.primary;

    return StreamBuilder<PlaybackState>(
      stream: widget.handler.playbackState,
      initialData: widget.handler.playbackState.value,
      builder: (context, snapshot) {
        final state = snapshot.data ?? widget.handler.playbackState.value;
        final isPlaying = _optimisticPlaying ?? state.playing;
        if (_optimisticPlaying != null && _optimisticPlaying == state.playing) {
          _optimisticPlaying = null;
        }

        final busy =
            state.processingState == AudioProcessingState.loading ||
            state.processingState == AudioProcessingState.buffering;
        final shuffling = state.shuffleMode == AudioServiceShuffleMode.all;
        final repeatMode = state.repeatMode;

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            // Shuffle
            Semantics(
              button: true,
              label: 'Toggle shuffle',
              child: SizedBox(
                width: 48,
                height: 48,
                child: IconButton(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  tooltip: 'Shuffle',
                  color: shuffling
                      ? active
                      : theme.colorScheme.onSurfaceVariant,
                  icon: const Icon(Icons.shuffle_rounded),
                  onPressed: () => widget.handler.setShuffleMode(
                    shuffling
                        ? AudioServiceShuffleMode.none
                        : AudioServiceShuffleMode.all,
                  ),
                ),
              ),
            ),
            // Previous
            Semantics(
              button: true,
              label: 'Skip to previous track',
              child: SizedBox(
                width: 48,
                height: 48,
                child: IconButton(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  tooltip: 'Previous track',
                  iconSize: 30,
                  color: theme.colorScheme.onSurface,
                  icon: const Icon(Icons.skip_previous_rounded),
                  onPressed: widget.handler.skipToPrevious,
                ),
              ),
            ),
            // Play / Pause (zero visual latency, buffers in the background)
            Semantics(
              button: true,
              label: isPlaying ? 'Pause track' : 'Play track',
              child: SizedBox(
                width: 64,
                height: 64,
                child: IconButton.filled(
                  constraints: const BoxConstraints(
                    minWidth: 64,
                    minHeight: 64,
                  ),
                  tooltip: isPlaying ? 'Pause' : 'Play',
                  iconSize: 36,
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 30,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                  onPressed: () {
                    setState(() {
                      _optimisticPlaying = !isPlaying;
                    });
                    if (isPlaying) {
                      widget.handler.pause();
                    } else {
                      widget.handler.play();
                    }
                  },
                ),
              ),
            ),
            // Next
            Semantics(
              button: true,
              label: 'Skip to next track',
              child: SizedBox(
                width: 48,
                height: 48,
                child: IconButton(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  tooltip: 'Next track',
                  iconSize: 30,
                  color: theme.colorScheme.onSurface,
                  icon: const Icon(Icons.skip_next_rounded),
                  onPressed: widget.handler.skipToNext,
                ),
              ),
            ),
            // Repeat
            Semantics(
              button: true,
              label: 'Toggle repeat mode',
              child: SizedBox(
                width: 48,
                height: 48,
                child: IconButton(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  tooltip: 'Repeat: ${repeatMode.name}',
                  color: repeatMode == AudioServiceRepeatMode.none
                      ? theme.colorScheme.onSurfaceVariant
                      : active,
                  icon: Icon(
                    repeatMode == AudioServiceRepeatMode.one
                        ? Icons.repeat_one_rounded
                        : Icons.repeat_rounded,
                  ),
                  onPressed: () => widget.handler.setRepeatMode(
                    switch (repeatMode) {
                      AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
                      AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
                      _ => AudioServiceRepeatMode.none,
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

String _clock(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class _NowPlayingFallbackArt extends StatelessWidget {
  const _NowPlayingFallbackArt({this.size = 280});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.music_note, size: size * 0.4),
    );
  }
}
