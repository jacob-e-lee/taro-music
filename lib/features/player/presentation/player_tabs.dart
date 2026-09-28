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
class PlayerTabBar extends StatelessWidget {
  const PlayerTabBar({
    super.key,
    required this.controller,
    required this.onTabSelected,
    required this.animateMorph,
  });

  final PlayerSheetController controller;
  final ValueChanged<PlayerTab> onTabSelected;
  final void Function(double target) animateMorph;

  /// How far a drag must travel to complete the whole morph. Short, because
  /// the content it reveals is large and should not need a long pull.
  static const double _flingThreshold = 300;
  static const double _settleFraction = 0.5;

  void _onDragUpdate(DragUpdateDetails details, double travel) {
    // Dragging up pushes towards peek; the divisor is the travel needed for a
    // full morph, so the bar tracks the finger proportionally.
    final delta = -details.delta.dy / travel;
    controller.setMorph(controller.morph + delta);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) =>
          _onDragUpdate(details, MediaQuery.sizeOf(context).height * 0.35),
      onVerticalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        final flickedUp = velocity < -_flingThreshold;
        final flickedDown = velocity > _flingThreshold;
        final movedFar = controller.morph > _settleFraction;
        final target = flickedUp || (movedFar && !flickedDown) ? 1.0 : 0.0;
        animateMorph(target);
      },
      // A cancel means the gesture was interrupted, not that the user asked to
      // go back. Snapping to 0 here would yank the player out from under them
      // mid-drag, so settle to whichever end is nearer instead.
      onVerticalDragCancel: () =>
          animateMorph(controller.morph > _settleFraction ? 1.0 : 0.0),
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
                onTap: () => onTabSelected(tab),
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
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _Message(
        icon: Icons.cloud_off,
        title: 'Could not load lyrics',
        detail: '$error',
      ),
      data: (data) => switch (data) {
        LyricsLoaded(:final lyrics) when !lyrics.isEmpty => ListView.builder(
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
    return Center(
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
    );
  }
}
