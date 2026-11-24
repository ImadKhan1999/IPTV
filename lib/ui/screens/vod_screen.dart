import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../data/library_store.dart';
import '../../state/session.dart';
import '../player/player_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/parental.dart';
import 'series_screen.dart';

/// Movies or Series: category list plus a poster grid.
class VodScreen extends StatefulWidget {
  const VodScreen({super.key, required this.type});

  final ContentType type;

  @override
  State<VodScreen> createState() => _VodScreenState();
}

class _VodScreenState extends State<VodScreen> {
  List<Category>? _categories;
  String? _categoryId;
  List<Object>? _items; // Movie or Series
  String? _error;
  final _filter = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final cats = await context.read<Session>().source!.categories(widget.type);
      if (!mounted) return;
      setState(() => _categories = cats);
      if (cats.isNotEmpty) {
        final store = context.read<LibraryStore>();
        final profileId = context.read<Session>().profile!.id;
        final first = Parental.visible(
          store,
          profileId,
          cats,
        ).where((c) => !Parental.isLocked(store, profileId, c)).firstOrNull;
        await _open(first?.id ?? Category.allId);
      } else {
        await _open(Category.allId);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _open(String id) async {
    final session = context.read<Session>();
    if (id != Category.allId) {
      final cat = _categories!.firstWhere((c) => c.id == id);
      if (!await Parental.unlock(context, session.profile!.id, cat)) return;
    }
    setState(() {
      _categoryId = id;
      _items = null;
    });
    try {
      final items = widget.type == ContentType.movie
          ? await session.source!.movies(id)
          : await session.source!.series(id);
      if (mounted && _categoryId == id) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  List<Object> get _visibleItems {
    final q = _filter.text.trim().toLowerCase();
    final items = _items ?? const [];
    if (q.isEmpty) return items;
    return items.where((i) => _name(i).toLowerCase().contains(q)).toList();
  }

  static String _name(Object i) => i is Movie ? i.name : (i as Series).name;

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return MessageView(icon: Icons.error_outline_rounded, title: 'Could not load', subtitle: _error);
    }
    final cats = _categories;
    if (cats == null) return const LoadingView();
    final store = context.watch<LibraryStore>();
    final session = context.watch<Session>();
    final profileId = session.profile!.id;
    final visible = Parental.visible(store, profileId, cats);
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final counts = session.counts[widget.type];
    final noun = widget.type == ContentType.movie ? 'movies' : 'series';
    final total = counts?[Category.allId];
    final shown = _items == null ? null : _visibleItems.length;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              visible.where((c) => c.id == _categoryId).firstOrNull?.name ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, fontFamily: Brand.headingFont, fontSize: 16),
            ),
          ),
          Text(
            [
              if (shown != null) '${formatCount(shown)} $noun here',
              if (total != null) '${formatCount(total)} in total',
            ].join('  ·  '),
            style: const TextStyle(color: Brand.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );

    final grid = _PosterGrid(items: _visibleItems, loading: _items == null, type: widget.type);
    final search = TextField(
      controller: _filter,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.search_rounded),
        hintText: widget.type == ContentType.movie ? 'Filter movies' : 'Filter series',
      ),
    );

    if (!wide) {
      return Column(
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4), child: search),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final c in visible)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        '${Parental.isLocked(store, profileId, c) ? '🔒 ' : ''}${c.name}'
                        '${counts?[c.id] != null ? '  ${formatCount(counts![c.id]!)}' : ''}',
                      ),
                      selected: c.id == _categoryId,
                      onSelected: (_) => _open(c.id),
                    ),
                  ),
              ],
            ),
          ),
          header,
          Expanded(child: grid),
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
              itemCount: visible.length,
              itemBuilder: (_, i) {
                final c = visible[i];
                final sel = c.id == _categoryId;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: TvFocusable(
                    selected: sel,
                    borderRadius: 10,
                    scale: 1.02,
                    onSelect: () => _open(c.id),
                    child: Container(
                      color: sel ? Brand.cyberMint.withValues(alpha: 0.12) : Colors.transparent,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: sel ? Brand.textPrimary : Brand.textSecondary),
                            ),
                          ),
                          if (Parental.isLocked(store, profileId, c))
                            const Icon(Icons.lock_rounded, size: 16, color: Brand.textMuted)
                          else if (counts?[c.id] case final n?)
                            CountBadge(count: n, selected: sel),
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
          child: Column(
            children: [
              Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 0), child: search),
              header,
              Expanded(child: FocusTraversalGroup(child: grid)),
            ],
          ),
        ),
      ],
    );
  }
}

class _PosterGrid extends StatelessWidget {
  const _PosterGrid({required this.items, required this.loading, required this.type});

  final List<Object> items;
  final bool loading;
  final ContentType type;

  @override
  Widget build(BuildContext context) {
    if (loading) return const LoadingView();
    if (items.isEmpty) return const MessageView(icon: Icons.movie_filter_rounded, title: 'Nothing here yet');
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 170,
        childAspectRatio: 0.58,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => PosterCard(item: items[i], autofocus: i == 0),
    );
  }
}

/// Poster tile for a movie or series, with watch progress and a favorite star.
class PosterCard extends StatelessWidget {
  const PosterCard({super.key, required this.item, this.autofocus = false});

  final Object item;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final session = context.read<Session>();
    final store = context.watch<LibraryStore>();
    final profileId = session.profile!.id;
    final isMovie = item is Movie;
    final id = isMovie ? (item as Movie).id : (item as Series).id;
    final name = isMovie ? (item as Movie).name : (item as Series).name;
    final poster = isMovie ? (item as Movie).poster : (item as Series).poster;
    final rating = isMovie ? (item as Movie).rating : (item as Series).rating;
    final type = isMovie ? ContentType.movie : ContentType.series;
    final fav = store.isFavorite(profileId, type, id);
    final progress = store.historyItem(profileId, type, id)?.progress ?? 0;

    void toggleFav() => store.toggleFavorite(
      isMovie ? SavedItem.movie(profileId, item as Movie) : SavedItem.series(profileId, item as Series),
    );

    return TvFocusable(
      autofocus: autofocus,
      scale: 1.07,
      onSelect: () => isMovie ? openMovie(context, item as Movie) : openSeries(context, item as Series),
      onLongPress: toggleFav,
      child: Container(
        color: Brand.surfaceCard,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NetImage(poster, icon: isMovie ? Icons.movie_rounded : Icons.video_library_rounded),
                  if (rating != null && rating > 0)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star_rounded, size: 13, color: Brand.warning),
                            const SizedBox(width: 2),
                            Text(
                              rating.toStringAsFixed(1),
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (fav)
                    const Positioned(
                      top: 6,
                      right: 6,
                      child: Icon(Icons.favorite_rounded, color: Brand.error, size: 18),
                    ),
                  if (progress > 0.01)
                    Positioned(left: 0, right: 0, bottom: 0, child: BrandProgress(value: progress, height: 3)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
              child: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, height: 1.25),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> openMovie(BuildContext context, Movie movie) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Brand.slateObsidian,
    builder: (_) => MovieDetailSheet(movie: movie),
  );
}

void openSeries(BuildContext context, Series series) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => SeriesScreen(series: series)));
}

class MovieDetailSheet extends StatelessWidget {
  const MovieDetailSheet({super.key, required this.movie});

  final Movie movie;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LibraryStore>();
    final profileId = context.read<Session>().profile!.id;
    final hist = store.historyItem(profileId, ContentType.movie, movie.id);
    final fav = store.isFavorite(profileId, ContentType.movie, movie.id);
    final resumeAt = hist != null && hist.progress > 0.02 && hist.progress < 0.95
        ? Duration(milliseconds: hist.positionMs)
        : null;

    void play({required bool resume}) {
      Navigator.of(context).pop();
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(request: PlayRequest.movie(movie, startAt: resume ? resumeAt : null)),
        ),
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(width: 140, height: 210, child: NetImage(movie.poster, icon: Icons.movie_rounded)),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(movie.name, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    children: [
                      if (movie.year != null) Text(movie.year!, style: const TextStyle(color: Brand.textSecondary)),
                      if (movie.rating != null && movie.rating! > 0)
                        Text('★ ${movie.rating!.toStringAsFixed(1)}', style: const TextStyle(color: Brand.warning)),
                    ],
                  ),
                  if (movie.plot != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      movie.plot!,
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Brand.textSecondary),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      if (resumeAt != null)
                        FilledButton.icon(
                          autofocus: true,
                          onPressed: () => play(resume: true),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: Text('Resume ${formatDuration(resumeAt)}'),
                        ),
                      if (resumeAt == null)
                        FilledButton.icon(
                          autofocus: true,
                          onPressed: () => play(resume: false),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('Play'),
                        )
                      else
                        OutlinedButton.icon(
                          onPressed: () => play(resume: false),
                          icon: const Icon(Icons.replay_rounded),
                          label: const Text('From start'),
                        ),
                      OutlinedButton.icon(
                        onPressed: () => store.toggleFavorite(SavedItem.movie(profileId, movie)),
                        icon: Icon(fav ? Icons.favorite_rounded : Icons.favorite_border_rounded),
                        label: Text(fav ? 'In favorites' : 'Add to favorites'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
