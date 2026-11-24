import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../data/library_store.dart';
import '../../state/session.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/parental.dart';
import 'player_screen.dart';

/// "Set-top box" Live TV: true when Live TV should open straight into full-screen video
/// with the see-through channel list, instead of the three-column screen.
bool liveFullscreenMode(PlayerSettings s) => s.liveStyle == 'fullscreen' || (s.liveStyle == 'auto' && AppPlatform.isTv);

/// Opens Live TV full screen on the last channel (or the first one), like a set-top box.
/// [showList] opens the channel list straight away.
Future<void> openLiveFullscreen(BuildContext context, {bool showList = false}) async {
  final session = context.read<Session>();
  final store = context.read<LibraryStore>();
  final profileId = session.profile?.id;
  final src = session.source;
  if (profileId == null || src == null) return;
  final hidden = store.hiddenIds(profileId);
  final last = store.lastChannel(profileId);
  var list = <Channel>[];
  var index = 0;
  try {
    if (last != null) {
      // Play it within its own category, so up/down zaps through its neighbours.
      final cats = await src.categories(ContentType.live);
      final cat = cats.where((c) => c.id == last.categoryId).firstOrNull;
      if (cat != null && !Parental.isLocked(store, profileId, cat)) {
        list = (await src.channels(cat.id)).where((c) => !hidden.contains(c.id)).toList();
        index = list.indexWhere((c) => c.id == last.id);
      }
    }
    if (index < 0 || list.isEmpty) {
      list = (await src.channels(Category.allId)).where((c) => !hidden.contains(c.id)).toList();
      index = last == null ? 0 : list.indexWhere((c) => c.id == last.id);
    }
  } catch (_) {
    list = const [];
  }
  if (!context.mounted) return;
  if (list.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No channels in this playlist.')));
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          PlayerScreen(request: PlayRequest.live(list, index < 0 ? 0 : index), startWithList: showList || last == null),
    ),
  );
}

/// See-through channel browser drawn over the playing video: categories on the left,
/// channels on the right with what's on now. OK switches channel and keeps the list open,
/// so you can flick through channels without ever leaving the picture.
class LiveOverlay extends StatefulWidget {
  const LiveOverlay({super.key, required this.controller, required this.onClose});

  final LiveTarget controller;
  final VoidCallback onClose;

  @override
  State<LiveOverlay> createState() => _LiveOverlayState();
}

class _LiveOverlayState extends State<LiveOverlay> {
  static const _favoritesId = '__favorites__';

  /// Category the list showed last time, so reopening it lands in the same place.
  static String? _lastCategory;

  final _catScope = FocusScopeNode(debugLabel: 'overlay categories');
  final _listScope = FocusScopeNode(debugLabel: 'overlay channels');
  final _catScroll = ScrollController();
  late final ScrollController _listScroll;

  List<Category>? _categories;
  String _categoryId = Category.allId;
  List<Channel>? _channels;
  Channel? _focused;
  List<EpgProgram> _focusedEpg = const [];
  Timer? _idle;
  Timer? _epgDebounce;

  LiveTarget get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    // Start on the list that is playing, with the playing channel focused.
    _channels = _c.request.channels;
    _focused = _c.channel;
    final at = (_c.index * _rowHeight - 160).clamp(0, double.infinity).toDouble();
    _listScroll = ScrollController(initialScrollOffset: at);
    final playing = _c.request.channels;
    final uniform = playing.isNotEmpty && playing.every((c) => c.categoryId == playing.first.categoryId);
    _categoryId = uniform ? playing.first.categoryId : (_lastCategory == _favoritesId ? _favoritesId : Category.allId);
    _loadCategories();
    _touch();
    _loadEpg(_focused);
  }

  @override
  void dispose() {
    _idle?.cancel();
    _epgDebounce?.cancel();
    _toastTimer?.cancel();
    _catScope.dispose();
    _listScope.dispose();
    _catScroll.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  static const _rowHeight = 64.0;

  /// Hides the list after a while without key presses, like a set-top box.
  void _touch() {
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 12), () {
      if (mounted) widget.onClose();
    });
  }

  Future<void> _loadCategories() async {
    final session = context.read<Session>();
    try {
      final cats = await session.source!.categories(ContentType.live);
      if (!mounted) return;
      setState(() => _categories = cats);
      if (_categoryId != Category.allId && _categoryId != _favoritesId && !cats.any((c) => c.id == _categoryId)) {
        setState(() => _categoryId = Category.allId);
      }
    } catch (_) {}
  }

  Future<void> _openCategory(String id, {bool focusList = true}) async {
    final session = context.read<Session>();
    final store = context.read<LibraryStore>();
    final profileId = session.profile!.id;
    final cat = _categories?.where((c) => c.id == id).firstOrNull;
    if (cat != null && !await Parental.unlock(context, profileId, cat)) return;
    setState(() {
      _categoryId = id;
      _channels = null;
    });
    _lastCategory = id;
    List<Channel> list;
    try {
      if (id == _favoritesId) {
        list = store.favorites(profileId, ContentType.live).map((f) => f.toChannel()).toList();
      } else {
        final hidden = store.hiddenIds(profileId);
        list = (await session.source!.channels(id)).where((c) => !hidden.contains(c.id)).toList();
        if (id == Category.allId) {
          final blocked = {
            for (final c in _categories ?? const <Category>[])
              if (Parental.isLocked(store, profileId, c) || (!store.hasPin && store.hideAdult && c.isAdult)) c.id,
          };
          list = list.where((c) => !blocked.contains(c.categoryId)).toList();
        }
      }
    } catch (_) {
      list = const [];
    }
    if (!mounted || _categoryId != id) return;
    setState(() => _channels = list);
    if (_listScroll.hasClients) _listScroll.jumpTo(0);
    if (focusList && list.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) PaneKeys.focusPane(_listScope, first: true);
      });
    }
  }

  void _pick(List<Channel> list, int i) {
    _touch();
    final c = list[i];
    if (_c.channel?.id == c.id) {
      widget.onClose(); // OK on the playing channel: back to the picture
      return;
    }
    _c.replace(PlayRequest.live(list, i));
    setState(() {});
  }

  void _loadEpg(Channel? c) {
    _epgDebounce?.cancel();
    if (c == null) return;
    _epgDebounce = Timer(const Duration(milliseconds: 350), () async {
      final list = await context.read<Session>().epgFor(c, limit: 2);
      if (mounted && _focused?.id == c.id) setState(() => _focusedEpg = list);
    });
  }

  Future<void> _toggleFavorite(Channel c) async {
    final store = context.read<LibraryStore>();
    final profileId = context.read<Session>().profile!.id;
    final was = store.isFavorite(profileId, ContentType.live, c.id);
    await store.toggleFavorite(SavedItem.channel(profileId, c));
    _toast(was ? '${c.name} removed from favorites' : '${c.name} added to favorites');
  }

  Future<void> _togglePin(Category c) async {
    final store = context.read<LibraryStore>();
    final profileId = context.read<Session>().profile!.id;
    final was = store.isFavoriteCategory(profileId, ContentType.live, c.id);
    await store.toggleFavoriteCategory(profileId, ContentType.live, c.id);
    _toast(was ? '"${c.name}" unpinned' : '"${c.name}" pinned to the top');
  }

  String? _toastText;
  Timer? _toastTimer;

  void _toast(String text) {
    _toastTimer?.cancel();
    setState(() => _toastText = text);
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toastText = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LibraryStore>();
    final session = context.read<Session>();
    final profileId = session.profile!.id;
    final counts = session.counts[ContentType.live];
    final cats = _categories;
    final entries = <(String, String, Category?, int?)>[
      (Category.allId, 'All channels', null, counts?[Category.allId]),
      (_favoritesId, 'Favorites', null, store.favorites(profileId, ContentType.live).length),
      if (cats != null)
        for (final c in store.favoriteCategoriesFirst(
          profileId,
          ContentType.live,
          Parental.visible(store, profileId, cats),
        ))
          (c.id, c.name, c, counts?[c.id]),
    ];
    final size = MediaQuery.sizeOf(context);
    final panelWidth = (size.width * 0.52).clamp(420.0, 760.0);
    final catWidth = (panelWidth * 0.36).clamp(150.0, 250.0);
    final channels = _channels;
    final playingId = _c.channel?.id;

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, _) {
        _touch();
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          // Tap outside the list to close it (touch / mouse).
          Positioned.fill(
            child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: widget.onClose),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: panelWidth + 80,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.black.withValues(alpha: 0.74),
                      Colors.black.withValues(alpha: 0.6),
                      Colors.black.withValues(alpha: 0),
                    ],
                    stops: [0, panelWidth / (panelWidth + 80), 1],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: panelWidth,
            child: SafeArea(
              right: false,
              child: PaneKeys(
                panes: [_catScope, _listScope],
                backToFirst: false,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: catWidth,
                      child: FocusScope(
                        node: _catScope,
                        child: ListView.builder(
                          controller: _catScroll,
                          padding: const EdgeInsets.fromLTRB(10, 16, 4, 16),
                          itemCount: entries.length,
                          itemExtent: 46,
                          itemBuilder: (_, i) {
                            final (id, name, cat, count) = entries[i];
                            final sel = id == _categoryId;
                            final pinned = cat != null && store.isFavoriteCategory(profileId, ContentType.live, id);
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: TvFocusable(
                                selected: sel,
                                borderRadius: 10,
                                scale: 1.0,
                                onSelect: () => _openCategory(id),
                                onLongPress: cat == null ? null : () => _togglePin(cat),
                                child: Container(
                                  color: sel ? Brand.cyberMint.withValues(alpha: 0.16) : Colors.transparent,
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                  child: Row(
                                    children: [
                                      if (id == _favoritesId)
                                        const Padding(
                                          padding: EdgeInsets.only(right: 6),
                                          child: Icon(Icons.star_rounded, size: 16, color: Brand.warning),
                                        )
                                      else if (pinned)
                                        const Padding(
                                          padding: EdgeInsets.only(right: 6),
                                          child: Icon(Icons.push_pin_rounded, size: 14, color: Brand.warning),
                                        ),
                                      Expanded(
                                        child: Text(
                                          name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                                            color: sel ? Brand.textPrimary : Brand.textSecondary,
                                          ),
                                        ),
                                      ),
                                      if (count != null)
                                        Text(
                                          formatCount(count),
                                          style: const TextStyle(color: Brand.textMuted, fontSize: 11),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    Container(width: 1, color: Colors.white.withValues(alpha: 0.08)),
                    Expanded(
                      child: FocusScope(
                        node: _listScope,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(14, 16, 14, 6),
                              child: Text(
                                entries.where((e) => e.$1 == _categoryId).firstOrNull?.$2 ?? 'Channels',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: Brand.headingFont,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 18,
                                ),
                              ),
                            ),
                            Expanded(
                              child: channels == null
                                  ? const Center(child: CircularProgressIndicator())
                                  : channels.isEmpty
                                  ? const Center(
                                      child: Text('No channels here', style: TextStyle(color: Brand.textSecondary)),
                                    )
                                  : ListView.builder(
                                      controller: _listScroll,
                                      padding: const EdgeInsets.fromLTRB(8, 0, 10, 12),
                                      itemCount: channels.length,
                                      itemExtent: _rowHeight,
                                      itemBuilder: (_, i) {
                                        final c = channels[i];
                                        final playing = c.id == playingId;
                                        final fav = store.isFavorite(profileId, ContentType.live, c.id);
                                        return Padding(
                                          padding: const EdgeInsets.symmetric(vertical: 2),
                                          child: TvFocusable(
                                            autofocus: playing,
                                            selected: playing,
                                            borderRadius: 10,
                                            scale: 1.0,
                                            onSelect: () => _pick(channels, i),
                                            onLongPress: () => _toggleFavorite(c),
                                            onFocus: (f) {
                                              if (!f) return;
                                              setState(() {
                                                _focused = c;
                                                _focusedEpg = const [];
                                              });
                                              _loadEpg(c);
                                            },
                                            child: Container(
                                              color: playing
                                                  ? Brand.cyberMint.withValues(alpha: 0.16)
                                                  : Colors.white.withValues(alpha: 0.03),
                                              padding: const EdgeInsets.symmetric(horizontal: 10),
                                              child: Row(
                                                children: [
                                                  SizedBox(
                                                    width: 38,
                                                    child: Text(
                                                      '${c.number ?? i + 1}',
                                                      style: const TextStyle(
                                                        color: Brand.textMuted,
                                                        fontSize: 13,
                                                        fontFeatures: [FontFeature.tabularFigures()],
                                                      ),
                                                    ),
                                                  ),
                                                  SizedBox(
                                                    width: 52,
                                                    height: 34,
                                                    child: NetImage(c.logo, fit: BoxFit.contain, cacheWidth: 104),
                                                  ),
                                                  const SizedBox(width: 10),
                                                  Expanded(
                                                    child: Text(
                                                      c.name,
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        fontWeight: playing ? FontWeight.w700 : FontWeight.w500,
                                                      ),
                                                    ),
                                                  ),
                                                  if (fav)
                                                    const Icon(Icons.star_rounded, size: 16, color: Brand.warning),
                                                  if (playing)
                                                    const Padding(
                                                      padding: EdgeInsets.only(left: 6),
                                                      child: Icon(
                                                        Icons.graphic_eq_rounded,
                                                        size: 18,
                                                        color: Brand.cyberMint,
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                            _NowNext(channel: _focused, programs: _focusedEpg),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_toastText != null)
            Positioned(
              left: panelWidth + 24,
              bottom: 32,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(_toastText!),
              ),
            ),
          Positioned(
            right: 24,
            bottom: 20,
            child: Text(
              'OK  play   ·   hold OK  favorite   ·   ◀ ▶  categories   ·   Back  close',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// What's on now (with progress) and next, for the focused channel.
class _NowNext extends StatelessWidget {
  const _NowNext({required this.channel, required this.programs});

  final Channel? channel;
  final List<EpgProgram> programs;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final current = programs.where((p) => !p.start.isAfter(now) && p.end.isAfter(now)).firstOrNull;
    final next = programs.where((p) => p.start.isAfter(now)).firstOrNull;
    final progress = current == null
        ? null
        : now.difference(current.start).inSeconds / current.end.difference(current.start).inSeconds.clamp(1, 1 << 30);
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 10, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            channel?.name ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            current == null ? 'No guide for this channel' : 'Now  ${formatClock(current.start)}  ${current.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Brand.textSecondary, fontSize: 13),
          ),
          if (progress != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress.clamp(0, 1),
                minHeight: 3,
                backgroundColor: Colors.white12,
                color: Brand.cyberMint,
              ),
            ),
          ],
          if (next != null) ...[
            const SizedBox(height: 6),
            Text(
              'Next  ${formatClock(next.start)}  ${next.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Brand.textMuted, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

/// Keys that open the overlay from the bare picture on TV.
bool isOverlayKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.select ||
    k == LogicalKeyboardKey.enter ||
    k == LogicalKeyboardKey.numpadEnter ||
    k == LogicalKeyboardKey.arrowLeft;
