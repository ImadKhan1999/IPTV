import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../data/library_store.dart';
import '../../state/session.dart';
import '../player/player_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Series detail: artwork, plot, season tabs and the episode list.
class SeriesScreen extends StatefulWidget {
  const SeriesScreen({super.key, required this.series});

  final Series series;

  @override
  State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen> {
  SeriesDetails? _details;
  String? _error;
  int? _season;

  @override
  void initState() {
    super.initState();
    context
        .read<Session>()
        .source!
        .seriesDetails(widget.series)
        .then(
          (d) {
            if (!mounted) return;
            setState(() {
              _details = d;
              _season = d.seasons.keys.isEmpty ? null : d.seasons.keys.first;
            });
          },
          onError: (Object e) {
            if (mounted) setState(() => _error = '$e');
          },
        );
  }

  void _play(List<Episode> episodes, int index) {
    final store = context.read<LibraryStore>();
    final profileId = context.read<Session>().profile!.id;
    final ep = episodes[index];
    final hist = store.historyItem(profileId, ContentType.series, '${widget.series.id}#${ep.id}');
    final resume = hist != null && hist.progress > 0.02 && hist.progress < 0.95
        ? Duration(milliseconds: hist.positionMs)
        : null;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          request: PlayRequest.episodes(_details?.series ?? widget.series, episodes, index, startAt: resume),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _details?.series ?? widget.series;
    final store = context.watch<LibraryStore>();
    final profileId = context.read<Session>().profile!.id;
    final fav = store.isFavorite(profileId, ContentType.series, s.id);
    final episodes = _season == null ? const <Episode>[] : _details!.seasons[_season]!;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Opacity(opacity: 0.18, child: NetImage(s.poster, icon: Icons.video_library_rounded)),
          ),
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Brand.deepVoid],
                  stops: [0, 0.55],
                ),
              ),
            ),
          ),
          SafeArea(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 24, 16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        const SizedBox(width: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: SizedBox(
                            width: 130,
                            height: 195,
                            child: NetImage(s.poster, icon: Icons.video_library_rounded),
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(s.name, style: Theme.of(context).textTheme.headlineSmall),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 12,
                                children: [
                                  if (s.year != null) Text(s.year!, style: const TextStyle(color: Brand.textSecondary)),
                                  if (s.rating != null && s.rating! > 0)
                                    Text(
                                      '★ ${s.rating!.toStringAsFixed(1)}',
                                      style: const TextStyle(color: Brand.warning),
                                    ),
                                ],
                              ),
                              if (s.plot != null) ...[
                                const SizedBox(height: 10),
                                Text(
                                  s.plot!,
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Brand.textSecondary),
                                ),
                              ],
                              const SizedBox(height: 14),
                              OutlinedButton.icon(
                                onPressed: () => store.toggleFavorite(SavedItem.series(profileId, s)),
                                icon: Icon(fav ? Icons.favorite_rounded : Icons.favorite_border_rounded),
                                label: Text(fav ? 'In favorites' : 'Add to favorites'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_error != null)
                  SliverFillRemaining(
                    child: MessageView(
                      icon: Icons.error_outline_rounded,
                      title: 'Could not load episodes',
                      subtitle: _error,
                    ),
                  ),
                if (_error == null && _details == null) const SliverFillRemaining(child: LoadingView()),
                if (_details != null) ...[
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 52,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        children: [
                          for (final season in _details!.seasons.keys)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text('Season $season'),
                                selected: season == _season,
                                onSelected: (_) => setState(() => _season = season),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                    sliver: SliverList.builder(
                      itemCount: episodes.length,
                      itemBuilder: (_, i) {
                        final e = episodes[i];
                        final progress =
                            store.historyItem(profileId, ContentType.series, '${s.id}#${e.id}')?.progress ?? 0;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: TvFocusable(
                            autofocus: i == 0,
                            borderRadius: 12,
                            scale: 1.015,
                            onSelect: () => _play(episodes, i),
                            child: Container(
                              color: Brand.surfaceCard,
                              padding: const EdgeInsets.all(10),
                              child: Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: SizedBox(
                                      width: 128,
                                      height: 72,
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          NetImage(e.image ?? s.poster, icon: Icons.play_circle_outline_rounded),
                                          if (progress > 0.01)
                                            Positioned(
                                              left: 0,
                                              right: 0,
                                              bottom: 0,
                                              child: BrandProgress(value: progress, height: 3),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'E${e.number}  ${e.title}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontWeight: FontWeight.w600),
                                        ),
                                        if (e.plot != null)
                                          Text(
                                            e.plot!,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(color: Brand.textSecondary, fontSize: 13),
                                          ),
                                        if (e.durationSecs != null)
                                          Text(
                                            formatDuration(Duration(seconds: e.durationSecs!)),
                                            style: const TextStyle(color: Brand.textMuted, fontSize: 12),
                                          ),
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.play_arrow_rounded, color: Brand.cyberMint),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
