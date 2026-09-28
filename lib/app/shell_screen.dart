import 'package:flutter/material.dart';

import '../features/home/presentation/home_screen.dart';
import '../features/library/presentation/library_screen.dart';
import '../features/player/presentation/mini_player.dart';
import '../features/player/presentation/now_playing_sheet.dart';
import '../features/player/presentation/player_sheet_controller.dart';
import '../features/search/presentation/search_screen.dart';

/// App shell mounting the strict 3-tab structure (Home, Search, Library) with
/// swipe-to-navigate between screens and a persistent mini-player placed
/// directly above the bottom navigation bar.
class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen>
    with SingleTickerProviderStateMixin {
  late int _currentIndex;
  late final PageController _pageController;

  /// The full-screen player, mounted as a persistent layer rather than
  /// pushed as a modal route. This is what lets an upward drag on the mini
  /// player pull the real player up with the finger in one motion.
  late final PlayerSheetController _player = PlayerSheetController(vsync: this);

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _player.dispose();
    super.dispose();
  }

  void _onSelectTab(int index) {
    if (_currentIndex == index) return;
    setState(() {
      _currentIndex = index;
    });
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
    );
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      _KeepAliveTab(child: HomeScreen(onSelectQuery: (_) => _onSelectTab(1))),
      const _KeepAliveTab(child: SearchScreen()),
      const _KeepAliveTab(child: LibraryScreen()),
    ];

    return Stack(
      children: <Widget>[
        Scaffold(
          body: SafeArea(
            bottom: false,
            child: PageView(
              controller: _pageController,
              onPageChanged: _onPageChanged,
              children: tabs,
            ),
          ),
          // Persistent bottom structure: MiniPlayer mounted directly above
          // NavigationBar. Both fade out almost immediately once the player
          // starts rising, so the hand-off reads as one surface transforming
          // rather than the player sliding up over a second bar.
          bottomNavigationBar: AnimatedBuilder(
            animation: _player,
            builder: (context, child) {
              final opacity = PlayerSheetController.chromeOpacity(
                _player.size,
                _player.dragFraction,
                _player.maxSize,
              );
              return Opacity(
                opacity: opacity,
                child: IgnorePointer(ignoring: opacity <= 0.01, child: child),
              );
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                MiniPlayer(sheetController: _player),
                NavigationBar(
                  selectedIndex: _currentIndex,
                  onDestinationSelected: _onSelectTab,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.home_outlined),
                      selectedIcon: Icon(Icons.home),
                      label: 'Home',
                      tooltip: 'Home tab',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.search_outlined),
                      selectedIcon: Icon(Icons.search),
                      label: 'Search',
                      tooltip: 'Search tab',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.library_music_outlined),
                      selectedIcon: Icon(Icons.library_music),
                      label: 'Library',
                      tooltip: 'Library tab',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        // The full-screen player lives *above* the whole shell, not inside the
        // Scaffold body: it has to be able to cover the navigation bar and the
        // mini player while it expands. It is always mounted (at size 0) so the
        // mini player's drag can drive it frame by frame.
        Positioned.fill(child: _PlayerLayer(controller: _player)),
      ],
    );
  }
}

/// Renders the persistent full-screen player: a scrim that tracks the sheet's
/// height, plus the sheet itself, plus the tap-blocking switch that stops the
/// shell underneath stealing touches while the player is up.
class _PlayerLayer extends StatelessWidget {
  const _PlayerLayer({required this.controller});

  final PlayerSheetController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final size = controller.size;
          return IgnorePointer(
            // At size 0 the layer is fully transparent and must not eat any
            // gesture meant for the mini player or the tabs below.
            ignoring: !controller.isModal,
            child: Stack(
              children: <Widget>[
                // Scrim fading in fast, so the shell behind is already dimmed by
                // the time the player has covered any of it.
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Colors.black.withValues(
                        alpha: (size / 0.15).clamp(0.0, 1.0) * 0.5,
                      ),
                    ),
                  ),
                ),
                // Opacity ramp so the player is revealed over the first sliver
                // of travel rather than popping in as a hard rectangle.
                // The player is sized by the controller, so it is laid out as a
                // bottom-anchored box rather than a DraggableScrollableSheet:
                // the sheet contains no scrollable of its own any more (the
                // queue moved behind a tab), so there is nothing for a
                // DraggableScrollableController to drive.
                Positioned.fill(
                  child: Opacity(
                    opacity: PlayerSheetController.playerOpacity(size),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: SizedBox(
                        height: size * constraints.maxHeight,
                        child: NowPlayingSheet(sheet: controller),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _KeepAliveTab extends StatefulWidget {
  const _KeepAliveTab({required this.child});

  final Widget child;

  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
