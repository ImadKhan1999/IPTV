import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../data/library_store.dart';
import '../../state/session.dart';
import '../platform.dart';
import '../player/player_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/parental.dart';

/// Live TV: categories, channel list and a now/next guide panel for the focused channel.
class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  static const _favoritesId = '__favorites__';
  static const _groupPrefix = 'grp:';

  /// The last channel opens by itself once per app launch, not every time Live TV is shown.
  static bool _autoStarted = false;

  List<Category>? _categories;
  String _categoryId = Category.allId;
  List<Channel>? _channels;
  Channel? _focused;
  String? _error;
  final _filter = TextEditingController();

  /// Plays the picked channel in the preview pane; full screen reuses it.
  PlayerController? _preview;

  // Remote navigation: categories | channels | preview + guide.
  final _catScope = FocusScopeNode(debugLabel: 'live categories');
  final _listScope = FocusScopeNode(debugLabel: 'live channels');
  final _sideScope = FocusScopeNode(debugLabel: 'live preview');

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  @override
  void dispose() {
    _filter.dispose();
    _preview?.dispose();
    _catScope.dispose();
    _listScope.dispose();
    _sideScope.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    final session = context.read<Session>();
    try {
      final cats = await session.source!.categories(ContentType.live);
      if (!mounted) return;
      setState(() => _categories = cats);
      await _openCategory(Category.allId);
      await _resumeLastChannel();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _openCategory(String id) async {
    final session = context.read<Session>();
    final store = context.read<LibraryStore>();
    final profileId = session.profile!.id;
    final cat = _categories!.where((c) => c.id == id).firstOrNull;
    if (cat != null && !await Parental.unlock(context, profileId, cat)) return;
    if (!mounted) return;
    setState(() {
      _categoryId = id;
      _channels = null;
    });
    try {
      List<Channel> list;
      if (id == _favoritesId) {
        list = store.favorites(profileId, ContentType.live).map((f) => f.toChannel()).toList();
      } else if (id.startsWith(_groupPrefix)) {
        final g = store.group(id.substring(_groupPrefix.length));
        final byId = {for (final c in await session.source!.channels(Category.allId)) c.id: c};
        list = [
          for (final cid in g?.channelIds ?? const <String>[])
            if (byId[cid] != null) byId[cid]!,
        ];
      } else {
        list = await session.source!.channels(id);
        final hiddenChannels = store.hiddenIds(profileId);
        if (hiddenChannels.isNotEmpty) list = list.where((c) => !hiddenChannels.contains(c.id)).toList();
        if (id == Category.allId) {
          // Hide channels from locked / hidden categories in the "All" list.
          final hidden = {
            for (final c in _categories ?? const <Category>[])
              if (Parental.isLocked(store, profileId, c) || (!store.hasPin && store.hideAdult && c.isAdult)) c.id,
          };
          list = list.where((c) => !hidden.contains(c.categoryId)).toList();
        }
      }
      if (!mounted || _categoryId != id) return;
      final fromRemote = _catScope.hasFocus && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
      setState(() => _channels = list);
      // Picking a category with OK takes you straight to its first channel.
      if (fromRemote && list.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) PaneKeys.focusPane(_listScope, first: true);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  List<Channel> get _visibleChannels {
    final q = _filter.text.trim().toLowerCase();
    final list = _channels ?? const [];
    return q.isEmpty ? list : list.where((c) => c.name.toLowerCase().contains(q)).toList();
  }

  /// First pick plays the channel in the preview; picking the playing channel again
  /// (OK twice on a remote) opens it full screen.
  void _play(Channel c) {
    final p = _preview;
    if (p != null && p.channel?.id == c.id) {
      _openFullscreen();
      return;
    }
    final list = _visibleChannels;
    final request = PlayRequest.live(list, list.indexOf(c).clamp(0, list.length - 1));
    if (p == null) {
      setState(() {
        _preview = PlayerController(
          session: context.read<Session>(),
          store: context.read<LibraryStore>(),
          request: request,
        );
      });
    } else {
      p.replace(request);
    }
    setState(() => _focused = c);
  }

  void _openFullscreen() {
    final p = _preview;
    if (p == null) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerScreen(controller: p)));
  }

  void _stopPreview() {
    final p = _preview;
    setState(() => _preview = null);
    p?.dispose();
  }

  /// Opens the channel watched last, full screen, when the app starts (Settings can turn it off).
  Future<void> _resumeLastChannel() async {
    if (_autoStarted) return;
    _autoStarted = true;
    final store = context.read<LibraryStore>();
    final profileId = context.read<Session>().profile!.id;
    if (!store.player.startOnLastChannel) return;
    final last = store.lastChannel(profileId);
    if (last == null) return;
    final list = _visibleChannels;
    final c = list.where((c) => c.id == last.id).firstOrNull;
    if (c == null || !mounted) return; // hidden, locked or gone from the playlist
    _play(c);
    _openFullscreen();
  }

  Future<void> _toggleStar(String categoryId, String name) async {
    final store = context.read<LibraryStore>();
    final profileId = context.read<Session>().profile!.id;
    final was = store.isFavoriteCategory(profileId, ContentType.live, categoryId);
    await store.toggleFavoriteCategory(profileId, ContentType.live, categoryId);
    _snack(was ? '"$name" unpinned' : '"$name" pinned to the top');
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 1)));

  /// Long-press OK / right-click: favorites, groups, order and hiding.
  Future<void> _channelMenu(Channel c) async {
    final store = context.read<LibraryStore>();
    final profileId = context.read<Session>().profile!.id;
    final fav = store.isFavorite(profileId, ContentType.live, c.id);
    final group = _categoryId.startsWith(_groupPrefix) ? store.group(_categoryId.substring(_groupPrefix.length)) : null;
    final reorderable = _categoryId == _favoritesId || group != null;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Brand.slateObsidian,
      isScrollControlled: true,
      builder: (ctx) {
        Widget item(String value, IconData icon, String label, {bool autofocus = false}) => ListTile(
          autofocus: autofocus,
          leading: Icon(icon, color: Brand.cyberMint),
          title: Text(label),
          onTap: () => Navigator.pop(ctx, value),
        );
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(c.name, style: Theme.of(ctx).textTheme.titleMedium),
                ),
                item(
                  'fav',
                  fav ? Icons.star_outline_rounded : Icons.star_rounded,
                  fav ? 'Remove from favorites' : 'Add to favorites',
                  autofocus: true,
                ),
                item('group', Icons.playlist_add_rounded, 'Add to a group…'),
                if (group != null) item('ungroup', Icons.playlist_remove_rounded, 'Remove from "${group.name}"'),
                if (reorderable) ...[
                  item('up', Icons.arrow_upward_rounded, 'Move up'),
                  item('down', Icons.arrow_downward_rounded, 'Move down'),
                ],
                item('hide', Icons.visibility_off_rounded, 'Hide this channel'),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'fav':
        await store.toggleFavorite(SavedItem.channel(profileId, c));
        _snack(fav ? 'Removed from favorites' : 'Added to favorites');
      case 'group':
        await _addToGroup(c);
      case 'ungroup':
        await store.toggleInGroup(group!, c.id);
        _snack('Removed from "${group.name}"');
      case 'up' || 'down':
        final delta = action == 'up' ? -1 : 1;
        group != null
            ? await store.moveInGroup(group, c.id, delta)
            : await store.moveFavorite(profileId, ContentType.live, c.id, delta);
      case 'hide':
        await store.setHidden(profileId, c.id, true);
        _snack('Hidden. Show it again in Settings > Hidden channels.');
    }
    if (mounted) await _openCategory(_categoryId);
  }

  Future<void> _addToGroup(Channel c) async {
    final store = context.read<LibraryStore>();
    final profileId = context.read<Session>().profile!.id;
    final groups = store.groups(profileId);
    final picked = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: Brand.slateObsidian,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Add to group', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            for (final (i, g) in groups.indexed)
              ListTile(
                autofocus: i == 0,
                leading: Icon(
                  g.channelIds.contains(c.id) ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                  color: Brand.cyberMint,
                ),
                title: Text(g.name),
                trailing: Text('${g.channelIds.length}', style: const TextStyle(color: Brand.textMuted)),
                onTap: () => Navigator.pop(ctx, g),
              ),
            ListTile(
              autofocus: groups.isEmpty,
              leading: const Icon(Icons.add_rounded, color: Brand.cyberMint),
              title: const Text('New group…'),
              onTap: () => Navigator.pop(ctx, 'new'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) return;
    var g = picked is ChannelGroup ? picked : null;
    if (picked == 'new') {
      final name = await askText(context, title: 'New group', hint: 'e.g. Sports, News, Kids');
      if (name == null || name.trim().isEmpty || !mounted) return;
      g = await store.createGroup(profileId, name);
    }
    if (g == null) return;
    final had = g.channelIds.contains(c.id);
    await store.toggleInGroup(g, c.id);
    _snack(had ? 'Removed from "${g.name}"' : 'Added to "${g.name}"');
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return MessageView(icon: Icons.error_outline_rounded, title: 'Could not load channels', subtitle: _error);
    }
    final cats = _categories;
    if (cats == null) return const LoadingView(message: 'Loading channels…');

    final store = context.watch<LibraryStore>();
    final session = context.watch<Session>();
    final profileId = session.profile!.id;
    final counts = session.counts[ContentType.live];
    final visibleCats = store.favoriteCategoriesFirst(
      profileId,
      ContentType.live,
      Parental.visible(store, profileId, cats),
    );
    bool starred(String id) => store.isFavoriteCategory(profileId, ContentType.live, id);
    final realCats = {for (final c in cats) c.id};
    final entries = <(String, String, bool, int?)>[
      (Category.allId, 'All channels', false, counts?[Category.allId]),
      (_favoritesId, 'Favorites', false, store.favorites(profileId, ContentType.live).length),
      for (final g in store.groups(profileId)) ('$_groupPrefix${g.id}', g.name, false, g.channelIds.length),
      for (final c in visibleCats) (c.id, c.name, Parental.isLocked(store, profileId, c), counts?[c.id]),
    ];

    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 900;
    final preview = _preview;
    final visible = _visibleChannels;
    final channelList = ListenableBuilder(
      listenable: preview ?? ValueNotifier(0),
      builder: (_, _) => _ChannelList(
        channels: visible,
        loading: _channels == null,
        profileId: profileId,
        playingId: preview?.channel?.id,
        onPlay: _play,
        onFavorite: _channelMenu,
        onFocus: (c) => setState(() => _focused = c),
      ),
    );
    final header = _ListHeader(
      title: entries.firstWhere((e) => e.$1 == _categoryId, orElse: () => entries.first).$2,
      count: _channels == null ? null : visible.length,
    );
    final previewPane = preview == null
        ? null
        : _LivePreview(controller: preview, onFullscreen: _openFullscreen, onClose: _stopPreview);

    if (!wide) {
      return Column(
        children: [
          if (previewPane != null) AspectRatio(aspectRatio: 16 / 9, child: previewPane),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: _SearchField(controller: _filter, onChanged: () => setState(() {})),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final (id, name, locked, count) in entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onLongPress: realCats.contains(id) ? () => _toggleStar(id, name) : null,
                      child: ChoiceChip(
                        label: Text(
                          '${starred(id) ? '★ ' : ''}${locked ? '🔒 ' : ''}$name${count != null ? '  ${formatCount(count)}' : ''}',
                        ),
                        selected: id == _categoryId,
                        onSelected: (_) => _openCategory(id),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          header,
          Expanded(child: channelList),
        ],
      );
    }

    final showSide = preview != null || width >= 1150;
    final playing = preview?.channel;
    return PaneKeys(
      panes: [_catScope, _listScope, _sideScope],
      child: Row(
        children: [
          SizedBox(
            width: width >= 1300 ? 260 : 220,
            child: FocusScope(
              node: _catScope,
              child: FocusTraversalGroup(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10),
                  itemCount: entries.length,
                  itemBuilder: (_, i) {
                    final (id, name, locked, count) = entries[i];
                    final sel = id == _categoryId;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: TvFocusable(
                        selected: sel,
                        borderRadius: 10,
                        scale: 1.02,
                        onSelect: () => _openCategory(id),
                        // Hold OK (or press the menu key) to star a category and keep it at the top.
                        onLongPress: realCats.contains(id) ? () => _toggleStar(id, name) : null,
                        child: Container(
                          color: sel ? Brand.cyberMint.withValues(alpha: 0.12) : Colors.transparent,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                          child: Row(
                            children: [
                              if (id == _favoritesId)
                                const Padding(
                                  padding: EdgeInsets.only(right: 8),
                                  child: Icon(Icons.star_rounded, size: 18, color: Brand.warning),
                                )
                              else if (id.startsWith(_groupPrefix))
                                const Padding(
                                  padding: EdgeInsets.only(right: 8),
                                  child: Icon(Icons.folder_special_rounded, size: 18, color: Brand.sky),
                                )
                              else if (starred(id))
                                const Padding(
                                  padding: EdgeInsets.only(right: 8),
                                  child: Icon(Icons.push_pin_rounded, size: 16, color: Brand.warning),
                                ),
                              Expanded(
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: sel ? Brand.textPrimary : Brand.textSecondary,
                                    fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
                                  ),
                                ),
                              ),
                              if (locked)
                                const Icon(Icons.lock_rounded, size: 16, color: Brand.textMuted)
                              else if (count != null)
                                CountBadge(count: count, selected: sel),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: FocusScope(
              node: _listScope,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: _SearchField(controller: _filter, onChanged: () => setState(() {})),
                  ),
                  header,
                  Expanded(child: FocusTraversalGroup(child: channelList)),
                ],
              ),
            ),
          ),
          if (showSide) ...[
            const VerticalDivider(width: 1),
            SizedBox(
              width: width >= 1400 ? 520 : (width >= 1150 ? 440 : 380),
              child: FocusScope(
                node: _sideScope,
                child: Column(
                  children: [
                    if (previewPane != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: AspectRatio(aspectRatio: 16 / 9, child: previewPane),
                        ),
                      ),
                    Expanded(
                      child: _GuidePanel(channel: _focused ?? playing, compact: previewPane != null),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Category title with the number of channels in it.
class _ListHeader extends StatelessWidget {
  const _ListHeader({required this.title, required this.count});

  final String title;
  final int? count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 10, 18, 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontFamily: Brand.headingFont, fontSize: 16),
          ),
        ),
        if (count != null)
          Text(
            '${formatCount(count!)} ${count == 1 ? 'channel' : 'channels'}',
            style: const TextStyle(color: Brand.textSecondary, fontSize: 13),
          ),
      ],
    ),
  );
}

/// The small player beside the channel list. Tap or the full screen button to go big.
class _LivePreview extends StatefulWidget {
  const _LivePreview({required this.controller, required this.onFullscreen, required this.onClose});

  final PlayerController controller;
  final VoidCallback onFullscreen;
  final VoidCallback onClose;

  @override
  State<_LivePreview> createState() => _LivePreviewState();
}

class _LivePreviewState extends State<_LivePreview> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final channel = c.channel;
        final showBar = _hover || !AppPlatform.isDesktop || c.stage != PlayStage.playing;
        return MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onFullscreen,
            onDoubleTap: widget.onFullscreen,
            child: Container(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // While the full screen player shows this stream, only it draws the video.
                  if (!c.fullscreenActive) PlayerVideo(controller: c),
                  if (!c.fullscreenActive) PlayerStatusOverlay(controller: c, compact: true),
                  if (c.fullscreenActive)
                    const Center(
                      child: Text('Playing full screen', style: TextStyle(color: Brand.textMuted)),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: AnimatedOpacity(
                      opacity: showBar ? 1 : 0,
                      duration: const Duration(milliseconds: 160),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(12, 18, 4, 2),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x00000000), Color(0xCC000000)],
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(color: Brand.error, borderRadius: BorderRadius.circular(4)),
                              child: const Text('LIVE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                channel?.name ?? c.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                              ),
                            ),
                            _PreviewButton(
                              icon: c.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                              tooltip: c.muted ? 'Unmute' : 'Mute',
                              onPressed: c.toggleMute,
                            ),
                            _PreviewButton(icon: Icons.close_rounded, tooltip: 'Stop', onPressed: widget.onClose),
                            _PreviewButton(
                              icon: Icons.fullscreen_rounded,
                              tooltip: 'Full screen',
                              onPressed: widget.onFullscreen,
                            ),
                          ],
                        ),
                      ),
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
}

class _PreviewButton extends StatelessWidget {
  const _PreviewButton({required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    iconSize: 22,
    visualDensity: VisualDensity.compact,
    onPressed: onPressed,
    style: ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.focused) ? Brand.cyberMint : Colors.transparent,
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.focused) ? Brand.deepVoid : Colors.white,
      ),
    ),
    icon: Icon(icon),
  );
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => TvTextKeys(
    child: TextField(
      controller: controller,
      onChanged: (_) => onChanged(),
      decoration: const InputDecoration(
        isDense: true,
        prefixIcon: Icon(Icons.search_rounded),
        hintText: 'Filter channels',
      ),
    ),
  );
}

class _ChannelList extends StatelessWidget {
  const _ChannelList({
    required this.channels,
    required this.loading,
    required this.profileId,
    this.playingId,
    required this.onPlay,
    required this.onFavorite,
    required this.onFocus,
  });

  final List<Channel> channels;
  final bool loading;
  final String profileId;
  final String? playingId;
  final ValueChanged<Channel> onPlay;
  final ValueChanged<Channel> onFavorite;
  final ValueChanged<Channel> onFocus;

  @override
  Widget build(BuildContext context) {
    if (loading) return const LoadingView();
    if (channels.isEmpty) {
      return const MessageView(icon: Icons.tv_off_rounded, title: 'No channels here');
    }
    final store = context.watch<LibraryStore>();
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: channels.length,
      itemExtent: 72,
      itemBuilder: (_, i) {
        final c = channels[i];
        final fav = store.isFavorite(profileId, ContentType.live, c.id);
        final playing = c.id == playingId;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: TvFocusable(
            autofocus: i == 0,
            selected: playing,
            borderRadius: 12,
            scale: 1.015,
            onSelect: () => onPlay(c),
            onLongPress: () => onFavorite(c),
            onFocus: (f) {
              if (f) onFocus(c);
            },
            child: Container(
              color: playing ? Brand.cyberMint.withValues(alpha: 0.10) : Brand.surfaceCard,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(
                      c.number?.toString() ?? '${i + 1}',
                      style: const TextStyle(color: Brand.textMuted, fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 72,
                      height: 44,
                      child: NetImage(c.logo, fit: BoxFit.contain, cacheWidth: 144),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w600, color: playing ? Brand.cyberMint : null),
                    ),
                  ),
                  if (playing)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.equalizer_rounded, size: 18, color: Brand.cyberMint),
                    ),
                  if (c.hasCatchup)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.history_rounded, size: 18, color: Brand.sky),
                    ),
                  if (fav)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.star_rounded, size: 18, color: Brand.warning),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Now / next guide for the focused channel.
class _GuidePanel extends StatelessWidget {
  const _GuidePanel({required this.channel, this.compact = false});

  final Channel? channel;

  /// Under the preview there is less room, so the header is smaller.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = channel;
    if (c == null) {
      return const MessageView(
        icon: Icons.tv_rounded,
        title: 'Pick a channel',
        subtitle: 'It plays here, with its TV guide below. Pick it again for full screen.',
      );
    }
    final session = context.read<Session>();
    return FutureBuilder<List<EpgProgram>>(
      key: ValueKey(c.id),
      future: session.epgFor(c, limit: 8),
      builder: (context, snap) {
        final programs = snap.data ?? const [];
        final now = DateTime.now();
        return ListView(
          padding: EdgeInsets.all(compact ? 16 : 20),
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(width: 96, height: 60, child: NetImage(c.logo, fit: BoxFit.contain, cacheWidth: 192)),
                ),
                const SizedBox(width: 14),
                Expanded(child: Text(c.name, style: Theme.of(context).textTheme.titleLarge, maxLines: 2)),
              ],
            ),
            const SizedBox(height: 20),
            if (snap.connectionState == ConnectionState.waiting) const LinearProgressIndicator(),
            if (snap.connectionState == ConnectionState.done && programs.isEmpty)
              Text(
                session.guideLoading ? 'Loading TV guide…' : 'No guide data for this channel.',
                style: const TextStyle(color: Brand.textSecondary),
              ),
            for (final p in programs)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '${formatClock(p.start)} – ${formatClock(p.end)}',
                          style: TextStyle(
                            color: p.isLiveAt(now) ? Brand.cyberMint : Brand.textMuted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (p.isLiveAt(now)) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(color: Brand.error, borderRadius: BorderRadius.circular(4)),
                            child: const Text('LIVE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(p.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (p.isLiveAt(now)) ...[const SizedBox(height: 6), BrandProgress(value: p.progressAt(now))],
                    if (p.description.isNotEmpty && p.isLiveAt(now)) ...[
                      const SizedBox(height: 6),
                      Text(
                        p.description,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Brand.textSecondary),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
