import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../data/library_store.dart';
import '../../state/session.dart';
import '../player/player_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'vod_screen.dart';

/// Continue watching, recently watched channels, and favorites in rows.
class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LibraryStore>();
    final profileId = context.read<Session>().profile!.id;

    final continueWatching = store
        .history(profileId)
        .where((h) => h.type != ContentType.live && h.progress > 0.02 && h.progress < 0.95)
        .take(20)
        .toList();
    final recentChannels = store.history(profileId, ContentType.live).take(20).toList();
    final favChannels = store.favorites(profileId, ContentType.live);
    final favMovies = store.favorites(profileId, ContentType.movie);
    final favSeries = store.favorites(profileId, ContentType.series);

    if ([continueWatching, recentChannels, favChannels, favMovies, favSeries].every((l) => l.isEmpty)) {
      return const MessageView(
        icon: Icons.favorite_border_rounded,
        title: 'No favorites yet',
        subtitle: 'Long-press OK on your remote (or right-click) on any channel, movie or series to add it here.',
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        if (continueWatching.isNotEmpty) _Row(title: 'Continue watching', items: continueWatching, wide: true),
        if (favChannels.isNotEmpty) _Row(title: 'Favorite channels', items: favChannels),
        if (recentChannels.isNotEmpty) _Row(title: 'Recently watched', items: recentChannels),
        if (favMovies.isNotEmpty) _Row(title: 'Favorite movies', items: favMovies, poster: true),
        if (favSeries.isNotEmpty) _Row(title: 'Favorite series', items: favSeries, poster: true),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.title, required this.items, this.poster = false, this.wide = false});

  final String title;
  final List<SavedItem> items;
  final bool poster;
  final bool wide;

  void _open(BuildContext context, SavedItem item, List<SavedItem> all) {
    switch (item.type) {
      case ContentType.live:
        final channels = all.where((e) => e.type == ContentType.live).map((e) => e.toChannel()).toList();
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                PlayerScreen(request: PlayRequest.live(channels, channels.indexWhere((c) => c.id == item.id))),
          ),
        );
      case ContentType.movie:
        openMovie(context, item.toMovie());
      case ContentType.series:
        // History entries for episodes are keyed "seriesId#episodeId".
        final seriesId = item.id.split('#').first;
        openSeries(
          context,
          SavedItem(
            profileId: item.profileId,
            type: ContentType.series,
            id: seriesId,
            name: item.extra['_seriesName'] ?? item.name,
            image: item.extra['_seriesPoster'] ?? item.image,
            extra: item.extra,
          ).toSeries(),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = poster ? 140.0 : (wide ? 260.0 : 180.0);
    final h = poster ? 230.0 : (wide ? 170.0 : 130.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 10),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        SizedBox(
          height: h + 12,
          child: FocusTraversalGroup(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (_, i) {
                final it = items[i];
                return SizedBox(
                  width: w,
                  child: TvFocusable(
                    onSelect: () => _open(context, it, items),
                    onLongPress: () => context.read<LibraryStore>().toggleFavorite(it),
                    child: Container(
                      color: Brand.surfaceCard,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                NetImage(
                                  it.image,
                                  fit: it.type == ContentType.live ? BoxFit.contain : BoxFit.cover,
                                  icon: it.type == ContentType.live ? Icons.live_tv_rounded : Icons.movie_rounded,
                                ),
                                if (it.progress > 0.01)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: BrandProgress(value: it.progress, height: 3),
                                  ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              it.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
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
        ),
      ],
    );
  }
}
