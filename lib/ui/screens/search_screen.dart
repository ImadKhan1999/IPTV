import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/search.dart';
import '../../core/sources/iptv_source.dart';
import '../../data/library_store.dart';
import '../../state/session.dart';
import '../platform.dart';
import '../player/player_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/parental.dart';
import 'vod_screen.dart';

/// Searches channels, movies, series and the TV guide of the active playlist at once.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.startWithVoice = false});

  /// Opened with the remote's search / mic key: start listening right away.
  final bool startWithVoice;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  Timer? _debounce;
  bool _loading = false;
  bool _indexed = false;
  List<Channel> _allChannels = const [];
  List<Movie> _allMovies = const [];
  List<Series> _allSeries = const [];
  List<Channel> _channels = const [];
  List<Movie> _movies = const [];
  List<Series> _series = const [];
  List<(EpgProgram, Channel)> _programs = const [];
  Map<String, Channel> _byEpgId = const {};

  @override
  void initState() {
    super.initState();
    if (widget.startWithVoice) WidgetsBinding.instance.addPostFrameCallback((_) => _voice());
  }

  Future<void> _voice() async {
    final text = await AppPlatform.voiceSearch(prompt: 'Say a channel, movie or show');
    if (text == null || text.trim().isEmpty || !mounted) return;
    _query.text = text;
    _search(text, immediate: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  /// Loads every list once; providers' "all" endpoints make this a few requests.
  Future<void> _index() async {
    if (_indexed) return;
    setState(() => _loading = true);
    final session = context.read<Session>();
    final store = context.read<LibraryStore>();
    final s = session.source!;
    final profileId = s.profile.id;
    Future<Set<String>> blocked(ContentType t) async {
      try {
        final cats = await s.categories(t);
        return {
          for (final c in cats)
            if (Parental.isLocked(store, profileId, c) || (!store.hasPin && store.hideAdult && c.isAdult)) c.id,
        };
      } catch (_) {
        return {};
      }
    }

    Future<List<T>> safe<T>(Future<List<T>> f) async {
      try {
        return await f;
      } catch (_) {
        return <T>[];
      }
    }

    final f = s.features;
    final results = await Future.wait([
      safe(s.channels(Category.allId)),
      f.contains(SourceFeature.movies) ? safe(s.movies(Category.allId)) : Future.value(<Movie>[]),
      f.contains(SourceFeature.series) ? safe(s.series(Category.allId)) : Future.value(<Series>[]),
      blocked(ContentType.live),
      blocked(ContentType.movie),
      blocked(ContentType.series),
    ]);
    if (!mounted) return;
    final bl = results[3] as Set<String>, bm = results[4] as Set<String>, bs = results[5] as Set<String>;
    final hidden = store.hiddenIds(profileId);
    _allChannels = (results[0] as List<Channel>)
        .where((c) => !bl.contains(c.categoryId) && !hidden.contains(c.id))
        .toList();
    _byEpgId = {
      for (final c in _allChannels)
        if (c.epgId != null && c.epgId!.isNotEmpty) c.epgId!: c,
    };
    _allMovies = (results[1] as List<Movie>).where((m) => !bm.contains(m.categoryId)).toList();
    _allSeries = (results[2] as List<Series>).where((x) => !bs.contains(x.categoryId)).toList();
    _indexed = true;
    setState(() => _loading = false);
  }

  void _search(String q, {bool immediate = false}) {
    _debounce?.cancel();
    _debounce = Timer(Duration(milliseconds: immediate ? 0 : 300), () async {
      await _index();
      if (!mounted) return;
      final query = SearchQuery(q);
      final guide = context.read<Session>().guide;
      setState(() {
        if (query.isEmpty || query.words.join().length < 2) {
          _channels = const [];
          _movies = const [];
          _series = const [];
          _programs = const [];
          return;
        }
        _channels = query.filter(_allChannels, (c) => c.name, limit: 60);
        _movies = query.filter(_allMovies, (m) => m.name, limit: 60);
        _series = query.filter(_allSeries, (x) => x.name, limit: 60);
        _programs = [
          for (final p in guide.search(query.matches, limit: 120))
            if (_byEpgId[p.channelId] case final c?) (p, c),
        ].take(40).toList();
      });
    });
  }

  void _playChannel(Channel c, List<Channel> list) {
    final i = list.indexWhere((x) => x.id == c.id);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerScreen(request: PlayRequest.live(list, i))));
  }

  @override
  Widget build(BuildContext context) {
    final empty = _channels.isEmpty && _movies.isEmpty && _series.isEmpty && _programs.isEmpty;
    final now = DateTime.now();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TvTextKeys(
                  child: TextField(
                    controller: _query,
                    autofocus: !widget.startWithVoice,
                    onChanged: _search,
                    onSubmitted: (q) => _search(q, immediate: true),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded),
                      hintText: 'Search channels, movies, series and TV guide',
                    ),
                  ),
                ),
              ),
              if (AppPlatform.voiceSupported) ...[
                const SizedBox(width: 10),
                IconButton.filledTonal(
                  tooltip: 'Voice search',
                  iconSize: 28,
                  onPressed: _voice,
                  icon: const Icon(Icons.mic_rounded),
                ),
              ],
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(),
        Expanded(
          child: empty
              ? MessageView(
                  icon: Icons.manage_search_rounded,
                  title: _query.text.trim().length < 2 ? 'Type to search' : 'No results',
                  subtitle: _query.text.trim().length < 2
                      ? 'Words can be in any order: "news bbc" finds BBC World News.'
                            '${AppPlatform.voiceSupported ? ' Or press the mic to speak.' : ''}'
                      : null,
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    if (_channels.isNotEmpty) ...[
                      const _Header('Channels'),
                      for (final (i, c) in _channels.indexed)
                        ListTile(
                          leading: SizedBox(width: 56, height: 36, child: NetImage(c.logo, fit: BoxFit.contain)),
                          title: Text(c.name),
                          autofocus: i == 0 && widget.startWithVoice,
                          onTap: () => _playChannel(c, _channels),
                        ),
                    ],
                    if (_programs.isNotEmpty) ...[
                      const _Header('On TV'),
                      for (final (p, c) in _programs)
                        ListTile(
                          leading: SizedBox(width: 56, height: 36, child: NetImage(c.logo, fit: BoxFit.contain)),
                          title: Text(p.title),
                          subtitle: Text(
                            '${p.isLiveAt(now) ? 'Now' : formatClock(p.start)} · ${c.name}',
                            style: TextStyle(color: p.isLiveAt(now) ? Brand.cyberMint : Brand.textSecondary),
                          ),
                          onTap: () => _playChannel(c, [c, ..._channels.where((x) => x.id != c.id)]),
                        ),
                    ],
                    if (_movies.isNotEmpty) ...[const _Header('Movies'), _Grid(items: _movies)],
                    if (_series.isNotEmpty) ...[const _Header('Series'), _Grid(items: _series)],
                  ],
                ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Brand.cyberMint)),
  );
}

class _Grid extends StatelessWidget {
  const _Grid({required this.items});

  final List<Object> items;

  @override
  Widget build(BuildContext context) => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    padding: const EdgeInsets.symmetric(horizontal: 16),
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 160,
      childAspectRatio: 0.58,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
    ),
    itemCount: items.length,
    itemBuilder: (_, i) => PosterCard(item: items[i]),
  );
}
