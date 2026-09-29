import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/lyrics.dart';
import 'player_sheet_controller.dart';

/// The Queue / Lyrics switcher.
///
/// It doubles as the drag handle for the peek morph, so the user has the same
/// affordance under their finger in both states: in the full player it sits at
/// the bottom, and in the peek state it has docked itself under the mini strip.
/// Keeping it in one place is what makes that hand-off continuous.
///
/// A tap and a drag mean different things here: a drag morphs the player, and
/// a tap selects a tab and springs the morph open, so clicking Queue or Lyrics
/// opens that panel directly instead of only moving the highlight.
class PlayerTabBar extends StatelessWidget {
  const PlayerTabBar({
    super.key,
    required this.controller,
    required this.morphTravelPx,
    required this.onTabSelected,
    required this.animateMorph,
  });

  final PlayerSheetController controller;

  /// Pixel distance the tab bar - and the panel's top edge, which sits
  /// directly below it - travels across the full morph from full player to
  /// peek.
  ///
  /// Measured by the sheet from its own layout: it is however far the player
  /// body shrinks, not a fraction of the screen. The drag divides by it so
  /// one pixel of finger is one pixel of movement.
  final double morphTravelPx;

  final ValueChanged<PlayerTab> onTabSelected;
  final void Function(double target) animateMorph;

  /// Release velocity (px/s) past which the morph commits to its end
  /// regardless of how far the finger actually travelled.
  ///
  /// Public because the panel body's swipe-down release settles by the same
  /// rule: two ends of one interaction must not disagree about what a flick
  /// means.
  static const double flingThreshold = 300;

  /// Fraction of the travel past which letting go commits to that end.
  ///
  /// Shared with the panel body's release for the same reason as
  /// [flingThreshold].
  static const double settleFraction = 0.5;

  void _onDragUpdate(DragUpdateDetails details) {
    // Dragging up pushes towards peek. The delta is divided by the distance
    // the bar travels over the whole morph, so the panel opens strictly 1:1
    // with the finger instead of racing ahead of it.
    final delta = -details.delta.dy / morphTravelPx;
    controller.setMorph(controller.morph + delta);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        final flickedUp = velocity < -flingThreshold;
        final flickedDown = velocity > flingThreshold;
        final movedFar = controller.morph > settleFraction;
        final target = flickedUp || (movedFar && !flickedDown) ? 1.0 : 0.0;
        animateMorph(target);
      },
      // A cancel means the gesture was interrupted, not that the user asked to
      // go back. Snapping to 0 here would yank the player out from under them
      // mid-drag, so settle to whichever end is nearer instead.
      onVerticalDragCancel: () =>
          animateMorph(controller.morph > settleFraction ? 1.0 : 0.0),
      child: Container(
        padding: const EdgeInsets.only(top: 6, bottom: 4),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            for (final tab in PlayerTab.values)
              _TabButton(
                tab: tab,
                selected: controller.tab == tab,
                // Select the tab *and* reveal it: the tab body only exists in
                // the peek state, so a tap that only selected would change
                // the highlight with nothing to show for it. Once already
                // peeking, the morph call settles where it is and the tap
                // simply switches which panel is open.
                onTap: () {
                  onTabSelected(tab);
                  animateMorph(1.0);
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// One of the two tab buttons, with a 48dp minimum touch target.
class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final PlayerTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: '${tab.label} tab',
      child: SizedBox(
        height: 48,
        child: TextButton.icon(
          onPressed: onTap,
          icon: Icon(tab.icon, size: 20, color: color),
          label: Text(
            tab.label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: color,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// A panel body with no scrolling content of its own.
///
/// Still a scroll view: the panel closes from a swipe-down at the top of its
/// body, and that pull is read from the body's own scroll view reporting the
/// distance it could not scroll - a bare [Center] never sees one. The
/// always-scrollable physics matter on top of that: with nothing to overflow,
/// the default physics refuse the drag outright, before it can report
/// anything.
Widget _staticPane(Widget child) {
  return CustomScrollView(
    physics: const AlwaysScrollableScrollPhysics(),
    slivers: <Widget>[
      SliverFillRemaining(hasScrollBody: false, child: child),
    ],
  );
}

/// The Lyrics tab body.
///
/// UI-only: the backing lyrics source reports "unavailable" today, so this
/// renders an empty state. When a source is implemented the same widget shows
/// the lines, and only the empty state goes away.
class LyricsPane extends ConsumerWidget {
  const LyricsPane({super.key, required this.trackId});

  final String trackId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final result = ref.watch(lyricsProvider(trackId));

    return result.when(
      loading: () => _staticPane(
        const Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => _Message(
        icon: Icons.cloud_off,
        title: 'Could not load lyrics',
        detail: '$error',
      ),
      data: (data) => switch (data) {
        LyricsLoaded(:final lyrics) when !lyrics.isEmpty => ListView.builder(
          // Always draggable, even when the lyrics fit without scrolling:
          // the panel's swipe-down-to-leave gesture rides this view's
          // under-scroll at the top, and the default physics would refuse
          // the drag outright when there is nothing to scroll to.
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          itemCount: lyrics.lines.length,
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              lyrics.lines[index],
              style: theme.textTheme.titleMedium?.copyWith(
                height: 1.4,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ),
        LyricsLoaded() => const _Message(
          icon: Icons.lyrics_outlined,
          title: 'No lyrics',
          detail: 'This track has no lyrics.',
        ),
        LyricsUnavailable() => const _Message(
          icon: Icons.lyrics_outlined,
          title: 'Lyrics unavailable',
          detail:
              'Lyrics are not being fetched yet. '
              'The lyrics source has not been implemented.',
        ),
        LyricsFailed(:final message) => _Message(
          icon: Icons.cloud_off,
          title: 'Could not load lyrics',
          detail: message,
        ),
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _staticPane(
      Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
