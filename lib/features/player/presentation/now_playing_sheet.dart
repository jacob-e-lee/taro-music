import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/webview_audio_handler.dart';
import '../application/providers.dart';
import '../domain/track.dart';
import 'player_sheet_controller.dart';
import 'player_tabs.dart';
import 'queue_tab.dart';

/// Full-screen player sheet:
/// - Prominent hero album artwork with swipe-to-skip gestures (physics-animated)
/// - Clear visual hierarchy: dominant artwork, extra bold headline track title, secondary artist text
/// - Fallback high-contrast dark scrim overlay ensuring WCAG 2.1 AA (>= 4.5:1) contrast
/// - Fully interactive physical transport buttons (48x48 min touch targets) with zero visual latency
/// - "Up Next" queue component with drag-and-drop reordering
class NowPlayingSheet extends ConsumerStatefulWidget {
  const NowPlayingSheet({super.key, required this.sheet});

  /// The persistent player layer, owned by the shell. It starts fully
  /// collapsed and follows the mini player's drag 1:1.
  final PlayerSheetController sheet;

  @override
  ConsumerState<NowPlayingSheet> createState() => _NowPlayingSheetState();
}

class _NowPlayingSheetState extends ConsumerState<NowPlayingSheet>
    with SingleTickerProviderStateMixin {
  /// Drives the full-player <-> peek morph. The value itself lives on the
  /// controller so the tab bar can drag it directly.
  late final AnimationController _morphAnimation;

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

  /// Decides whether a drag on the player should leave it open or minimised.
  ///
  /// Reads the *direction of release* rather than snapping to the nearest end,
  /// which is what makes swipe-down-to-minimise work: dragging down even a

  @override
  Widget build(BuildContext context) {
    final handler = ref.watch(audioHandlerProvider);
    final theme = Theme.of(context);
    final sheet = widget.sheet;

    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      builder: (context, itemSnapshot) {
        final item = itemSnapshot.data;
        if (item == null) {
          return const Center(child: Text('Nothing playing'));
        }
        final track = Track.fromExtras(item.extras);
        final isOffline = track?.isDownloaded ?? false;

        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Colors.black45,
                blurRadius: 20,
                offset: Offset(0, -4),
              ),
            ],
          ),
          child: Stack(
            children: <Widget>[
              // Contrast shield, so text keeps its ratio whatever is behind.
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        theme.colorScheme.surfaceContainerHighest.withValues(
                          alpha: 0.4,
                        ),
                        theme.colorScheme.surface,
                      ],
                    ),
                  ),
                ),
              ),
              // The sheet paints its background through a decorated
              // Container, so a transparent Material must sit directly
              // beneath it or ink splashes paint under the decoration.
              Material(
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
              ),
            ],
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
    // Build nothing until the sheet is tall enough to hold the layout. The
    // body is a fixed-height column (player area + tab bar + content), so
    // laying it out inside a short sheet overflows; and while the sheet is
    // barely open there is nothing worth drawing anyway. It is also what keeps
    // the queue unbuilt on every frame the player spends near-closed.
    final screenHeight = MediaQuery.sizeOf(context).height;
    if (widget.sheet.size * screenHeight < _minUsableHeight) {
      return const SizedBox.shrink();
    }

    final morph = widget.sheet.morph;
    // How open the sheet is. The body reacts to this rather than to `morph`,
    // so the controls and tabs arrive with the player instead of being
    // present from the very first pixel of it.
    final reveal = widget.sheet.reveal;
    final revealEase = widget.sheet.revealEase;
    // The sheet is anchored to the bottom of the screen, so the tab bar would
    // otherwise sit underneath the Android navigation bar / gesture handle.
    //
    // The LayoutBuilder is deliberately *inside* the Padding: Padding deflates
    // the constraints handed to its child, so measuring the height outside it
    // would size the player area to the full sheet and overflow by the inset.
    final systemInset = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: systemInset),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fullPlayerHeight = math.max(
            0.0,
            constraints.maxHeight - _tabBarHeight,
          );
          final playerHeight =
              ui.lerpDouble(fullPlayerHeight, _miniStripHeight, morph) ??
              fullPlayerHeight;

          return Column(
            children: <Widget>[
              SizedBox(
                height: playerHeight,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: _onAreaDragStart,
                  onVerticalDragUpdate: _onAreaDragUpdate,
                  onVerticalDragEnd: _onAreaDragEnd,
                  child: _MorphingPlayer(
                    sheet: widget.sheet,
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
                height: _tabBarHeight,
                child: _RevealSlide(
                  // The tabs ride up with the player and only materialise once
                  // it is meaningfully open, rather than sitting pinned in
                  // place the instant the sheet exists.
                  progress: revealEase,
                  distance: _tabBarHeight,
                  child: PlayerTabBar(
                    controller: widget.sheet,
                    onTabSelected: widget.sheet.selectTab,
                    animateMorph: _animateMorph,
                  ),
                ),
              ),
              Expanded(
                // Not built at all while collapsed. Fading it in from nothing
                // would still build every queue row on the first frame of the
                // drag, which is exactly the cost this split was meant to
                // avoid.
                child: morph <= 0.001
                    ? const SizedBox.shrink()
                    : Opacity(
                        opacity: morph.clamp(0.0, 1.0),
                        child: switch (widget.sheet.tab) {
                          PlayerTab.queue => QueueTab(handler: handler),
                          PlayerTab.lyrics => LyricsPane(
                            trackId: Track.fromExtras(item.extras)?.id ?? '',
                          ),
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------
  // The two gestures, kept on separate widgets so they never contend.
  // ---------------------------------------------------------------------

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

  void _onAreaDragStart(DragStartDetails details) {
    _morphAnimation.stop();
    _dismissBase = widget.sheet.size;
  }

  /// Dragging down anywhere above the tab bar dismisses the player. Upward
  /// drags are ignored here: growing the player is the mini player's job, and
  /// the tab bar owns the morph.
  void _onAreaDragUpdate(DragUpdateDetails details) {
    if (details.delta.dy <= 0) return;
    final height = MediaQuery.sizeOf(context).height;
    if (height <= 0) return;
    widget.sheet.jumpToSize(_dismissBase - details.delta.dy / height);
    _dismissBase = widget.sheet.size;
  }

  void _onAreaDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final sheet = widget.sheet;
    // Direction decides, not proximity: a flick down always dismisses, and a
    // slow drag only dismisses once it is genuinely most of the way down.
    if (velocity > _dismissFlingVelocity ||
        sheet.size < sheet.maxSize * _dismissSizeFraction) {
      sheet.close();
    } else {
      sheet.open();
    }
  }

  /// A release this fast counts as a deliberate flick towards dismissing.
  static const double _dismissFlingVelocity = 300;

  /// Below this fraction of the full height, letting go means "dismiss me".
  static const double _dismissSizeFraction = 0.5;

  /// Shortest sheet that can host the player layout without overflowing.
  static const double _minUsableHeight = 220;

  static const double _tabBarHeight = 58;
  static const double _miniStripHeight = 64;

  /// Sheet size when the current area drag started, so updates stay relative
  /// rather than accumulating rounding error.
  double _dismissBase = 0;
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
  static const double _miniPad = 16;
  static const double _heroTop = 68;

  /// Mirrors the shell mini player's artwork so the two line up during the
  /// hand-off. Kept here rather than imported to avoid a cycle between the
  /// shell and the player.
  static const double _shellMiniArtSize = 48;
  static const double _shellMiniArtLeft = 8;

  /// Distance from the bottom of the screen to the top of the shell mini
  /// player's artwork (mini player padding plus the navigation bar).
  static const double _shellMiniArtBottomGap = 96;

  /// How far the transport row travels as the player opens.
  static const double _controlsRevealDistance = 90;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;

        // Two axes compose here:
        //
        //  * `reveal` (the sheet opening) takes the artwork from the shell mini
        //    player's 48dp thumbnail to the hero artwork, so the bar's artwork
        //    grows into the player's rather than being swapped for it.
        //  * `morph` (the full <-> peek morph) then takes the hero artwork
        //    back down to the in-player mini strip.
        final heroSize = (width - 48).clamp(240.0, 320.0);

        // Collapse toward the mini player's artwork position, then morph.
        final fromMiniSize =
            ui.lerpDouble(_shellMiniArtSize, heroSize, reveal) ?? heroSize;
        final fromMiniLeft =
            ui.lerpDouble(_shellMiniArtLeft, (width - heroSize) / 2, reveal) ??
            _shellMiniArtLeft;
        // The player area is the bottom `reveal` fraction of the screen, so the
        // shell mini player's artwork - which sits just above the navigation
        // bar - is, in this area's coordinates, its own height minus the
        // distance from that artwork to the bottom of the screen.
        final areaHeight = constraints.maxHeight;
        final miniTopInArea = areaHeight - _shellMiniArtBottomGap;
        final fromMiniTop =
            ui.lerpDouble(miniTopInArea, _heroTop, reveal) ?? _heroTop;

        final artSize =
            ui.lerpDouble(fromMiniSize, _artSmall, morph) ?? fromMiniSize;
        final artLeft =
            ui.lerpDouble(fromMiniLeft, _miniPad, morph) ?? fromMiniLeft;
        // From the mini player the artwork sits low in the sheet; as the sheet
        // opens, that offset is expressed relative to the sheet's own height.
        final artTop = ui.lerpDouble(fromMiniTop, 8, morph) ?? fromMiniTop;

        // Title block: below the hero artwork when full, beside the thumbnail
        // when peeked, leaving room for the mini transport on the right.
        final titleLeft =
            ui.lerpDouble(_sidePad, _miniPad + _artSmall + 12, morph) ??
            _sidePad;
        final titleRight = ui.lerpDouble(_sidePad, 116, morph) ?? _sidePad;
        final titleTop =
            ui.lerpDouble(artTop + artSize + 24, 10, morph) ??
            artTop + artSize + 24;

        // The hero-only chrome fades out as the mini strip fades in.
        final heroOpacity = (1.0 - morph).clamp(0.0, 1.0);
        final miniOpacity = morph.clamp(0.0, 1.0);

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
                  ignoring: morph > 0.5,
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
              child: _MorphingTitle(item: item, morph: morph),
            ),

            // ---- mini transport (peek only) ----
            Positioned(
              right: _miniPad - 8,
              top: 0,
              width: 112,
              height: _MorphingPlayer._stripHeight,
              child: Opacity(
                opacity: miniOpacity,
                child: IgnorePointer(
                  ignoring: morph < 0.5,
                  child: _MiniTransport(handler: handler),
                ),
              ),
            ),

            // ---- seek bar + full transport (hero only) ----
            //
            // These slide up with the player and only appear once it is
            // meaningfully open, rather than being present and pinned from the
            // first frame. `heroOpacity` still fades them out in the peek
            // state, so the two axes compose.
            Positioned(
              left: _sidePad,
              right: _sidePad,
              bottom: 8,
              child: Opacity(
                opacity: heroOpacity,
                child: IgnorePointer(
                  ignoring: morph > 0.5 || reveal < 0.99,
                  child: _RevealSlide(
                    progress: revealEase,
                    distance: _controlsRevealDistance,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _SeekBar(handler: handler),
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
  const _MorphingTitle({required this.item, required this.morph});

  final MediaItem item;
  final double morph;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleSize = ui.lerpDouble(24, 15, morph) ?? 24;
    final artistSize = ui.lerpDouble(16, 13, morph) ?? 16;
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
                size: ui.lerpDouble(16, 12, morph)!,
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

class _SeekBar extends StatelessWidget {
  const _SeekBar({required this.handler});

  final WebViewAudioHandler handler;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return StreamBuilder<Duration?>(
      stream: handler.durationStream,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? Duration.zero;
        final maxMs = duration.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: handler.positionStream,
          initialData: Duration.zero,
          builder: (context, positionSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
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
                        : (v) =>
                              handler.seek(Duration(milliseconds: v.round())),
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
        );
      },
    );
  }
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
