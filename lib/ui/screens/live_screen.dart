import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../data/library_store.dart';
import '../../state/session.dart';
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

  List<Category>? _categories;
  String _categoryId = Category.allId;
  List<Channel>? _channels;
  Channel? _focused;
  String? _error;
  final _filter = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    final session = context.read<Session>();
    try {
      final cats = await session.source!.categories(ContentType.live);
      if (!mounted) return;
      setState(() => _categories = cats);
      await _openCategory(Category.allId);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _openCategory(String id) async {
    final session = context.read<Session>();
    final store = context.read<LibraryStore>();
    final profileId = session.profile!.id;
    if (id != Category.allId && id != _favoritesId) {
      final cat = _categories!.firstWhere((c) => c.id == id);
      if (!await Parental.unlock(context, profileId, cat)) return;
    }
    setState(() {
      _categoryId = id;
      _channels = null;
    });
    try {
      List<Channel> list;
      if (id == _favoritesId) {
        list = store.favorites(profileId, ContentType.live).map((f) => f.toChannel()).toList();
      } else {
        list = await session.source!.channels(id);
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
      setState(() => _channels = list);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  List<Channel> get _visibleChannels {
    final q = _filter.text.trim().toLowerCase();
    final list = _channels ?? const [];
    return q.isEmpty ? list : list.where((c) => c.name.toLowerCase().contains(q)).toList();
  }

  void _play(Channel c) {
    final list = _visibleChannels;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(request: PlayRequest.live(list, list.indexOf(c).clamp(0, list.length - 1))),
      ),
    );
  }

  void _toggleFavorite(Channel c) {
    final store = context.read<LibraryStore>();
    final profileId = context.read<Session>().profile!.id;
    store.toggleFavorite(SavedItem.channel(profileId, c));
    final fav = store.isFavorite(profileId, ContentType.live, c.id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(fav ? 'Added to favorites' : 'Removed from favorites'),
        duration: const Duration(seconds: 1),
      ),
    );
    if (_categoryId == _favoritesId) _openCategory(_favoritesId);
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return MessageView(icon: Icons.error_outline_rounded, title: 'Could not load channels', subtitle: _error);
    }
    final cats = _categories;
    if (cats == null) return const LoadingView(message: 'Loading channels…');

    final store = context.watch<LibraryStore>();
    final profileId = context.read<Session>().profile!.id;
    final visibleCats = Parental.visible(store, profileId, cats);
    final entries = <(String, String, bool)>[
      (Category.allId, 'All channels', false),
      (_favoritesId, 'Favorites', false),
      for (final c in visibleCats) (c.id, c.name, Parental.isLocked(store, profileId, c)),
    ];

    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 900;
    final channelList = _ChannelList(
      channels: _visibleChannels,
      loading: _channels == null,
      profileId: profileId,
      onPlay: _play,
      onFavorite: _toggleFavorite,
      onFocus: (c) => setState(() => _focused = c),
    );

    if (!wide) {
      return Column(
        children: [
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
                for (final (id, name, locked) in entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(locked ? '🔒 $name' : name),
                      selected: id == _categoryId,
                      onSelected: (_) => _openCategory(id),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: channelList),
        ],
      );
    }

    return Row(
      children: [
        SizedBox(
          width: 260,
          child: FocusTraversalGroup(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10),
              itemCount: entries.length,
              itemBuilder: (_, i) {
                final (id, name, locked) = entries[i];
                final sel = id == _categoryId;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: TvFocusable(
                    selected: sel,
                    borderRadius: 10,
                    scale: 1.02,
                    onSelect: () => _openCategory(id),
                    child: Container(
                      color: sel ? Brand.cyberMint.withValues(alpha: 0.12) : Colors.transparent,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      child: Row(
                        children: [
                          if (id == _favoritesId)
                            const Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: Icon(Icons.star_rounded, size: 18, color: Brand.warning),
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
                          if (locked) const Icon(Icons.lock_rounded, size: 16, color: Brand.textMuted),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 5,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: _SearchField(controller: _filter, onChanged: () => setState(() {})),
              ),
              Expanded(child: FocusTraversalGroup(child: channelList)),
            ],
          ),
        ),
        if (width >= 1150) ...[
          const VerticalDivider(width: 1),
          SizedBox(width: 380, child: _GuidePanel(channel: _focused)),
        ],
      ],
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    onChanged: (_) => onChanged(),
    decoration: const InputDecoration(
      isDense: true,
      prefixIcon: Icon(Icons.search_rounded),
      hintText: 'Filter channels',
    ),
  );
}

class _ChannelList extends StatelessWidget {
  const _ChannelList({
    required this.channels,
    required this.loading,
    required this.profileId,
    required this.onPlay,
    required this.onFavorite,
    required this.onFocus,
  });

  final List<Channel> channels;
  final bool loading;
  final String profileId;
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
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: TvFocusable(
            autofocus: i == 0,
            borderRadius: 12,
            scale: 1.015,
            onSelect: () => onPlay(c),
            onLongPress: () => onFavorite(c),
            onFocus: (f) {
              if (f) onFocus(c);
            },
            child: Container(
              color: Brand.surfaceCard,
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
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
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
  const _GuidePanel({required this.channel});

  final Channel? channel;

  @override
  Widget build(BuildContext context) {
    final c = channel;
    if (c == null) {
      return const MessageView(icon: Icons.tv_rounded, title: 'Pick a channel', subtitle: 'Its TV guide shows here.');
    }
    final session = context.read<Session>();
    return FutureBuilder<List<EpgProgram>>(
      key: ValueKey(c.id),
      future: session.epgFor(c, limit: 8),
      builder: (context, snap) {
        final programs = snap.data ?? const [];
        final now = DateTime.now();
        return ListView(
          padding: const EdgeInsets.all(20),
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
