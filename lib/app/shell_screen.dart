import 'package:flutter/material.dart';

import '../features/home/presentation/home_screen.dart';
import '../features/library/presentation/library_screen.dart';
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

  /// The player surface, mounted as a persistent layer rather than pushed as a
  /// modal route. This is what lets an upward drag on the collapsed band pull
  /// the real player up with the finger in one motion.
  late final PlayerSheetController _player = PlayerSheetController(vsync: this);

  /// Measures the navigation bar so the surface knows how tall the chrome it
  /// stands in for actually is.
  final GlobalKey _navBarKey = GlobalKey();

  double _publishedNavHeight = 0;
  double _publishedScreenHeight = 0;

  /// Pushes the measured viewport into the controller.
  ///
  /// Called from a post-frame callback rather than inline, because reading a
  /// [GlobalKey]'s size mid-build would mean notifying listeners during a
  /// build. Only fires when a measurement has actually moved, so a steady
  /// stream of frames costs one float compare.
  void _publishViewport() {
    if (!mounted) return;
    // `hasSize` rather than reading `.size` directly: this can fire while a
    // render object is still awaiting layout - notably during a route
    // transition, as the deep-link startup test does - and asking an unlaid-out
    // render object for its size throws.
    final box = _navBarKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final navHeight = box.size.height;
    final screenHeight = MediaQuery.sizeOf(context).height;
    if (navHeight <= 0 || screenHeight <= 0) return;
    if ((navHeight - _publishedNavHeight).abs() < 0.5 &&
        (screenHeight - _publishedScreenHeight).abs() < 0.5) {
      return;
    }
    _publishedNavHeight = navHeight;
    _publishedScreenHeight = screenHeight;
    _player.setViewport(
      screenHeight: screenHeight,
      // The surface covers the whole chrome band: the navigation bar plus the
      // collapsed player band that used to be a separate widget.
      collapsedHeight: navHeight + NowPlayingSheet.collapsedBarHeight,
    );
  }

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
          // The navigation bar and nothing else. The mini player that used to
          // sit above it is now the *collapsed state of the player surface*, so
          // there is no second bar to keep aligned with the player - and no
          // hand-off between them.
          //
          // The bar itself fades out over `chromeFade`, the same short window
          // in which the surface's fill extends down to take over its band.
          bottomNavigationBar: AnimatedBuilder(
            animation: _player,
            builder: (context, child) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _publishViewport();
              });
              final opacity = 1.0 - _player.chromeFade;
              return Opacity(
                opacity: opacity.clamp(0.0, 1.0),
                child: IgnorePointer(ignoring: opacity <= 0.01, child: child),
              );
            },
            child: KeyedSubtree(
              key: _navBarKey,
              child: NavigationBar(
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
            ),
          ),
        ),
        // The player surface lives *above* the whole shell, not inside the
        // Scaffold body: it has to be able to cover the navigation bar while it
        // expands. It is always mounted so the band's drag can drive it frame by
        // frame.
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
          // Nothing to lay out until the shell has measured the chrome, which
          // happens in a post-frame callback after the first layout.
          if (controller.surfaceHeight <= 0) {
            return const SizedBox.shrink();
          }

          return Stack(
            children: <Widget>[
              // Scrim, dimming the shell behind. Fades in over `chromeFade` so
              // the background is already darkened by the time the surface has
              // covered any of it.
              Positioned.fill(
                child: IgnorePointer(
                  // Transparent at rest, so it must not eat a single tap meant
                  // for the band or the navigation bar beneath it.
                  ignoring: !controller.isModal,
                  child: ColoredBox(
                    color: Colors.black.withValues(
                      alpha: controller.chromeFade * 0.5,
                    ),
                  ),
                ),
              ),
              // The surface itself: a bottom-anchored box whose height is the
              // chrome plus however far the finger has dragged. At rest that is
              // exactly the chrome, so its top edge is the band's top edge.
              Positioned.fill(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    height: controller.surfaceHeight.clamp(
                      0.0,
                      constraints.maxHeight,
                    ),
                    child: NowPlayingSheet(sheet: controller),
                  ),
                ),
              ),
            ],
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
