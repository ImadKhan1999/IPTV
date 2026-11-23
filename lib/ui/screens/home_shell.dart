import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/sources/iptv_source.dart';
import '../../data/library_store.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'favorites_screen.dart';
import 'live_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
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

  Widget _page(Section s) => switch (s) {
    Section.live => const SessionGate(child: LiveScreen()),
    Section.movies => const SessionGate(child: VodScreen(type: ContentType.movie)),
    Section.series => const SessionGate(child: VodScreen(type: ContentType.series)),
    Section.favorites => const SessionGate(child: FavoritesScreen()),
    Section.search => const SessionGate(child: SearchScreen()),
    Section.settings => const SettingsScreen(),
  };

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final session = context.watch<Session>();
    final features = session.source?.features ?? const <SourceFeature>{};
    final sections = Section.values.where((s) {
      if (s == Section.movies && session.source != null) return features.contains(SourceFeature.movies);
      if (s == Section.series && session.source != null) return features.contains(SourceFeature.series);
      return true;
    }).toList();
    if (!sections.contains(_section)) _section = Section.live;

    final page = KeyedSubtree(key: ValueKey(_section), child: _page(_section));

    if (!wide) {
      return Scaffold(
        body: SafeArea(bottom: false, child: page),
        bottomNavigationBar: NavigationBar(
          backgroundColor: Brand.slateObsidian,
          indicatorColor: Brand.cyberMint.withValues(alpha: 0.18),
          selectedIndex: sections.indexOf(_section),
          onDestinationSelected: (i) => setState(() => _section = sections[i]),
          destinations: [for (final s in sections) NavigationDestination(icon: Icon(s.icon), label: s.label)],
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          _SideRail(sections: sections, current: _section, onSelect: (s) => setState(() => _section = s)),
          const VerticalDivider(width: 1),
          Expanded(child: page),
        ],
      ),
    );
  }
}

class _SideRail extends StatelessWidget {
  const _SideRail({required this.sections, required this.current, required this.onSelect});

  final List<Section> sections;
  final Section current;
  final ValueChanged<Section> onSelect;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LibraryStore>();
    return Container(
      width: 220,
      color: Brand.slateObsidian,
      child: SafeArea(
        right: false,
        child: FocusTraversalGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(padding: EdgeInsets.fromLTRB(20, 24, 20, 8), child: AppLogo(size: 36)),
              if (store.activeProfile != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: Text(
                    store.activeProfile!.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Brand.textMuted, fontSize: 12),
                  ),
                ),
              for (final s in sections)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                  child: TvFocusable(
                    autofocus: s == current,
                    selected: s == current,
                    borderRadius: 12,
                    scale: 1.02,
                    // On TV, moving focus onto an item switches section like a TV launcher.
                    onFocus: (f) {
                      if (f && s != current && s != Section.search && s != Section.settings) onSelect(s);
                    },
                    onSelect: () => onSelect(s),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      color: s == current ? Brand.cyberMint.withValues(alpha: 0.12) : Colors.transparent,
                      child: Row(
                        children: [
                          Icon(s.icon, color: s == current ? Brand.cyberMint : Brand.textSecondary),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              s.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: s == current ? Brand.textPrimary : Brand.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              const Padding(padding: EdgeInsets.all(20), child: _Clock()),
              const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 20), child: ImadLabsMark(size: 22)),
            ],
          ),
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
    style: const TextStyle(fontFamily: Brand.headingFont, fontSize: 28, fontWeight: FontWeight.w700),
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
