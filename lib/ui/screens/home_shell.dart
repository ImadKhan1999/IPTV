import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/sources/iptv_source.dart';
import '../../data/library_store.dart';
import '../../state/session.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'favorites_screen.dart';
import 'live_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'tv_home.dart';
import '../player/live_overlay.dart';
import 'vod_screen.dart';

enum Section { live, movies, series, favorites, search, settings }

extension on Section {
  String get label => switch (this) {
    Section.live => 'Live TV',
    Section.movies => 'Movies',
    Section.series => 'Series',
    Section.favorites => 'Favorites',
    Section.search => 'Search',
    Section.settings => 'Settings',
  };

  IconData get icon => switch (this) {
    Section.live => Icons.live_tv_rounded,
    Section.movies => Icons.movie_rounded,
    Section.series => Icons.video_library_rounded,
    Section.favorites => Icons.favorite_rounded,
    Section.search => Icons.search_rounded,
    Section.settings => Icons.settings_rounded,
  };
}

/// Main layout: a side rail on TV / desktop / tablets, a bottom bar on phones.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  Section _section = Section.live;
  bool _voiceSearch = false;

  /// TV / desktop: the big-tile home screen is showing instead of a section.
  late bool _home = _startOnHome();

  /// The section the home screen should focus when it comes back.
  Section? _lastOpened;

  bool _startOnHome() {
    // Opening straight into the last channel skips the home screen, like before.
    final store = context.read<LibraryStore>();
    if (liveFullscreenMode(store.player)) return true; // the player opens over Home instead
    final profileId = store.activeProfile?.id;
    final resume = store.player.startOnLastChannel && profileId != null && store.lastChannel(profileId) != null;
    return !resume;
  }

  @override
  void initState() {
    super.initState();
    // Set-top box mode: start on the last channel, full screen, once the playlist is ready.
    final store = context.read<LibraryStore>();
    final profileId = store.activeProfile?.id;
    if (liveFullscreenMode(store.player) &&
        store.player.startOnLastChannel &&
        profileId != null &&
        store.lastChannel(profileId) != null &&
        !_autoStarted) {
      _autoStarted = true;
      _whenReady(() => openLiveFullscreen(context));
    }
  }

  static bool _autoStarted = false;

  void _whenReady(VoidCallback run) {
    final session = context.read<Session>();
    if (session.state == SessionState.ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) run();
      });
      return;
    }
    void listener() {
      if (session.state == SessionState.ready) {
        session.removeListener(listener);
        if (mounted) run();
      } else if (session.state == SessionState.error) {
        session.removeListener(listener);
      }
    }

    session.addListener(listener);
  }

  void _open(Section s) {
    final store = context.read<LibraryStore>();
    if (s == Section.live && _wideLayout && liveFullscreenMode(store.player)) {
      // Set-top box style: Live TV is the picture itself, with the channel list over it.
      setState(() => _lastOpened = s);
      _whenReady(() => openLiveFullscreen(context, showList: true));
      return;
    }
    setState(() {
      _section = s;
      _home = false;
      _lastOpened = s;
    });
  }

  void _goHome() => setState(() => _home = true);

  /// The remote's search key (or Ctrl+F) jumps to Search, listening right away on TV.
  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final ctrlF = k == LogicalKeyboardKey.keyF && HardwareKeyboard.instance.isControlPressed;
    if (k == LogicalKeyboardKey.browserSearch || k == LogicalKeyboardKey.find || ctrlF) {
      setState(() {
        _voiceSearch = !ctrlF && AppPlatform.voiceSupported;
        _section = Section.search;
        _home = false;
      });
      return KeyEventResult.handled;
    }
    // Back / Esc from any section returns to the home screen (TV and desktop).
    if ((k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape) && !_home && _wideLayout) {
      _goHome();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _page(Section s) => switch (s) {
    Section.live => const SessionGate(child: LiveScreen()),
    Section.movies => const SessionGate(child: VodScreen(type: ContentType.movie)),
    Section.series => const SessionGate(child: VodScreen(type: ContentType.series)),
    Section.favorites => const SessionGate(child: FavoritesScreen()),
    Section.search => SessionGate(child: SearchScreen(startWithVoice: _voiceSearch)),
    Section.settings => const SettingsScreen(),
  };

  bool _wideLayout = false;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    _wideLayout = wide;
    final session = context.watch<Session>();
    final features = session.source?.features ?? const <SourceFeature>{};
    final sections = Section.values.where((s) {
      if (s == Section.movies && session.source != null) return features.contains(SourceFeature.movies);
      if (s == Section.series && session.source != null) return features.contains(SourceFeature.series);
      return true;
    }).toList();
    if (!sections.contains(_section)) _section = Section.live;

    final page = KeyedSubtree(key: ValueKey(_section), child: _page(_section));
    if (_section != Section.search) _voiceSearch = false;

    if (!wide) {
      return Focus(onKeyEvent: _onKey, child: _phone(page, sections));
    }
    // Android's Back button pops the route; on a section it should go home instead.
    return PopScope(
      canPop: _home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_home) _goHome();
      },
      child: Focus(onKeyEvent: _onKey, child: _home ? _homeScreen(sections) : _wide(page, sections)),
    );
  }

  Widget _homeScreen(List<Section> sections) {
    final store = context.watch<LibraryStore>();
    final session = context.watch<Session>();
    HomeTile tile(Section s, List<Color> colors, {bool big = false, String? subtitle}) => HomeTile(
      id: s,
      label: s.label,
      icon: s.icon,
      colors: colors,
      big: big,
      subtitle: subtitle,
      count: switch (s) {
        Section.live => session.total(ContentType.live),
        Section.movies => session.total(ContentType.movie),
        Section.series => session.total(ContentType.series),
        Section.favorites => session.profile == null ? null : store.favorites(session.profile!.id).length,
        _ => null,
      },
    );
    return TvHome(
      focusId: _lastOpened,
      onOpen: (id) => _open(id as Section),
      tiles: [
        tile(
          Section.live,
          TileColors.live,
          big: true,
          subtitle: lastChannelLine(store, session) ?? 'Channels and TV guide',
        ),
        if (sections.contains(Section.movies))
          tile(Section.movies, TileColors.movies, big: true, subtitle: 'Films on demand'),
        if (sections.contains(Section.series))
          tile(Section.series, TileColors.series, big: true, subtitle: 'Shows and episodes'),
        tile(Section.favorites, TileColors.favorites, subtitle: 'Your starred channels and titles'),
        tile(Section.search, TileColors.search, subtitle: 'Channels, movies, series, guide'),
        tile(Section.settings, TileColors.settings, subtitle: 'Playlists, player, updates'),
      ],
    );
  }

  Widget _phone(Widget page, List<Section> sections) => Scaffold(
    body: SafeArea(bottom: false, child: page),
    bottomNavigationBar: NavigationBar(
      backgroundColor: Brand.slateObsidian,
      indicatorColor: Brand.cyberMint.withValues(alpha: 0.18),
      selectedIndex: sections.indexOf(_section),
      onDestinationSelected: (i) => setState(() => _section = sections[i]),
      destinations: [for (final s in sections) NavigationDestination(icon: Icon(s.icon), label: s.label)],
    ),
  );

  Widget _wide(Widget page, List<Section> sections) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(sections: sections, current: _section, onHome: _goHome, onSelect: _open),
            const Divider(height: 1),
            Expanded(child: page),
          ],
        ),
      ),
    );
  }
}

/// Slim bar above a section on TV / desktop: Home, the sections as tabs, and the clock.
/// The tabs only switch section when chosen with OK, so moving the focus never loads
/// a heavy screen by accident.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.sections, required this.current, required this.onHome, required this.onSelect});

  final List<Section> sections;
  final Section current;
  final VoidCallback onHome;
  final ValueChanged<Section> onSelect;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    int? countFor(Section s) => switch (s) {
      Section.live => session.total(ContentType.live),
      Section.movies => session.total(ContentType.movie),
      Section.series => session.total(ContentType.series),
      _ => null,
    };
    Widget tab(Section s) {
      final sel = s == current;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: TvFocusable(
          selected: sel,
          borderRadius: 10,
          scale: 1.03,
          onSelect: () => onSelect(s),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: sel ? Brand.cyberMint.withValues(alpha: 0.14) : Colors.transparent,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(s.icon, size: 18, color: sel ? Brand.cyberMint : Brand.textSecondary),
                const SizedBox(width: 8),
                Text(
                  s.label,
                  style: TextStyle(fontWeight: FontWeight.w600, color: sel ? Brand.textPrimary : Brand.textSecondary),
                ),
                if (countFor(s) case final n?) ...[const SizedBox(width: 8), CountBadge(count: n, selected: sel)],
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      color: Brand.slateObsidian,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: FocusTraversalGroup(
        child: Row(
          children: [
            TvFocusable(
              borderRadius: 10,
              scale: 1.03,
              onSelect: onHome,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.home_rounded, color: Brand.cyberMint),
                    SizedBox(width: 8),
                    Text('Home', style: TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [for (final s in sections) tab(s)]),
              ),
            ),
            const SizedBox(width: 12),
            const _Clock(),
          ],
        ),
      ),
    );
  }
}

class _Clock extends StatefulWidget {
  const _Clock();

  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  late Timer _t;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 15), (_) => setState(() => _now = DateTime.now()));
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    formatClock(_now),
    style: const TextStyle(fontFamily: Brand.headingFont, fontSize: 22, fontWeight: FontWeight.w700),
  );
}

/// Shows connection progress or errors instead of a section until the playlist is ready.
class SessionGate extends StatelessWidget {
  const SessionGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final store = context.read<LibraryStore>();
    switch (session.state) {
      case SessionState.ready:
        return child;
      case SessionState.connecting:
        return LoadingView(message: 'Connecting to ${store.activeProfile?.name ?? 'your playlist'}…');
      case SessionState.error:
        return MessageView(
          icon: Icons.cloud_off_rounded,
          title: 'Could not connect',
          subtitle: session.error,
          action: FilledButton.icon(
            autofocus: true,
            onPressed: () {
              final p = store.activeProfile;
              if (p != null) session.connect(p);
            },
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        );
      case SessionState.idle:
        final p = store.activeProfile;
        if (p != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (session.state == SessionState.idle) session.connect(p);
          });
        }
        return const LoadingView();
    }
  }
}
