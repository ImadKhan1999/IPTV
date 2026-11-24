import 'dart:convert';
import 'dart:io';

import '../epg/xmltv.dart';
import '../models.dart';
import 'iptv_source.dart';
import 'm3u_parser.dart';

/// Plain M3U / M3U8 playlist (URL or local file). Splits entries into live, movies and
/// series, and groups "Show S01E02" style entries into series with seasons.
class M3uSource extends IptvSource {
  M3uSource(super.profile, {super.client});

  M3uPlaylist? _playlist;
  final _channels = <Channel>[];
  final _movies = <Movie>[];
  final _series = <String, _SeriesBuilder>{};
  EpgGuide guide = EpgGuide.empty;

  @override
  Set<SourceFeature> get features => {
    SourceFeature.live,
    if (_movies.isNotEmpty) SourceFeature.movies,
    if (_series.isNotEmpty) SourceFeature.series,
    if (xmltvUrl != null) SourceFeature.epg,
    if (_catchup) SourceFeature.catchup,
  };

  @override
  String? get xmltvUrl => profile.epgUrl.isNotEmpty ? profile.epgUrl : _playlist?.epgUrl;

  @override
  Future<AccountInfo?> connect() async {
    final text = await _load(profile.url);
    if (!text.contains('#EXTINF') && !text.contains('://')) {
      throw SourceException('This does not look like an M3U playlist.');
    }
    // Parsing and building every channel object happens on a background thread, so a big
    // playlist never freezes the screen (TV boxes have slow CPUs).
    _apply(await IptvSource.offThread(_parseAndBuild, text, text.length));
    if (_channels.isEmpty && _movies.isEmpty && _series.isEmpty) {
      throw SourceException('The playlist is empty.');
    }
    return null;
  }

  /// Parses [text] directly (also used by tests).
  void loadFromText(String text) => _apply(_parseAndBuild(text));

  static _Built _parseAndBuild(String text) => _build(M3uParser.parse(text));

  bool _catchup = false;

  void _apply(_Built b) {
    _playlist = b.playlist;
    _channels
      ..clear()
      ..addAll(b.channels);
    _movies
      ..clear()
      ..addAll(b.movies);
    _series
      ..clear()
      ..addAll(b.series);
    _catchup = b.channels.any((c) => c.hasCatchup);
  }

  static _Built _build(M3uPlaylist pl) {
    final channels = <Channel>[];
    final movies = <Movie>[];
    final series = <String, _SeriesBuilder>{};
    var index = 0;
    for (final e in pl.entries) {
      index++;
      final group = e.group.isEmpty ? 'Uncategorised' : e.group;
      switch (e.contentType) {
        case ContentType.live:
          channels.add(
            Channel(
              id: 'm3u:$index',
              name: e.name,
              number: int.tryParse(e.attr('tvg-chno') ?? ''),
              logo: e.attr('tvg-logo'),
              categoryId: group,
              streamUrl: e.url,
              epgId: e.attr('tvg-id'),
              catchupDays: int.tryParse(e.attr('catchup-days') ?? e.attr('timeshift') ?? '') ?? 0,
              catchupSource: e.attr('catchup-source'),
              headers: e.headers,
              extra: {if (e.attr('catchup') != null) 'catchup': e.attr('catchup')!},
            ),
          );
        case ContentType.movie:
          movies.add(
            Movie(
              id: 'm3u:$index',
              name: e.name,
              poster: e.attr('tvg-logo'),
              categoryId: group,
              streamUrl: e.url,
              headers: e.headers,
            ),
          );
        case ContentType.series:
          final parsed = _splitEpisodeName(e.name);
          final key = '$group|${parsed.show.toLowerCase()}';
          final b = series.putIfAbsent(
            key,
            () => _SeriesBuilder(
              Series(
                id: 'm3u-series:${series.length + 1}',
                name: parsed.show,
                poster: e.attr('tvg-logo'),
                categoryId: group,
              ),
            ),
          );
          b.episodes.add(
            Episode(
              id: 'm3u:$index',
              title: e.name,
              season: parsed.season,
              number: parsed.episode,
              image: e.attr('tvg-logo'),
              streamUrl: e.url,
              headers: e.headers,
            ),
          );
      }
    }
    // The parsed entries are not needed any more; only the playlist's own settings are kept.
    return (
      playlist: M3uPlaylist(epgUrl: pl.epgUrl, entries: const []),
      channels: channels,
      movies: movies,
      series: series,
    );
  }

  Future<String> _load(String location) async {
    if (location.startsWith('http://') || location.startsWith('https://')) {
      final bytes = await cachedBytes('m3u|$location', () async {
        final res = await client.get(Uri.parse(location), headers: defaultHeaders);
        if (res.statusCode != 200) {
          throw SourceException('Could not download the playlist (HTTP ${res.statusCode}).');
        }
        final text = utf8.decode(res.bodyBytes, allowMalformed: true);
        if (!text.contains('#EXTINF') && !text.contains('://')) {
          throw SourceException('This does not look like an M3U playlist.');
        }
        return res.bodyBytes;
      });
      return utf8.decode(bytes, allowMalformed: true);
    }
    final f = File(location.startsWith('file://') ? Uri.parse(location).toFilePath() : location);
    if (!await f.exists()) throw SourceException('Playlist file not found.');
    return utf8.decode(await f.readAsBytes(), allowMalformed: true);
  }

  List<Category> _categoriesOf(Iterable<String> groups, ContentType type) {
    final seen = <String>{};
    return [
      for (final g in groups)
        if (seen.add(g)) Category(id: g, name: g, type: type, isAdult: looksAdult(g)),
    ];
  }

  @override
  Future<List<Category>> categories(ContentType type) async => switch (type) {
    ContentType.live => _categoriesOf(_channels.map((c) => c.categoryId), type),
    ContentType.movie => _categoriesOf(_movies.map((m) => m.categoryId), type),
    ContentType.series => _categoriesOf(_series.values.map((s) => s.series.categoryId), type),
  };

  @override
  Future<Map<String, int>?> categoryCounts(ContentType type) async => IptvSource.countByCategory(switch (type) {
    ContentType.live => _channels.map((c) => c.categoryId),
    ContentType.movie => _movies.map((m) => m.categoryId),
    ContentType.series => _series.values.map((s) => s.series.categoryId),
  });

  @override
  Future<List<Channel>> channels(String categoryId) async =>
      categoryId == Category.allId ? List.of(_channels) : _channels.where((c) => c.categoryId == categoryId).toList();

  @override
  Future<List<Movie>> movies(String categoryId) async =>
      categoryId == Category.allId ? List.of(_movies) : _movies.where((m) => m.categoryId == categoryId).toList();

  @override
  Future<List<Series>> series(String categoryId) async => _series.values
      .map((b) => b.series)
      .where((s) => categoryId == Category.allId || s.categoryId == categoryId)
      .toList();

  @override
  Future<SeriesDetails> seriesDetails(Series series) async {
    final b = _series.values.firstWhere(
      (b) => b.series.id == series.id,
      orElse: () => throw SourceException('Series not found.'),
    );
    final seasons = <int, List<Episode>>{};
    for (final e in b.episodes) {
      (seasons[e.season] ??= []).add(e);
    }
    for (final l in seasons.values) {
      l.sort((a, b) => a.number.compareTo(b.number));
    }
    return SeriesDetails(
      series: b.series,
      seasons: Map.fromEntries(seasons.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
    );
  }

  @override
  Future<List<EpgProgram>> shortEpg(Channel channel, {int limit = 6}) async =>
      guide.upcoming(channel.epgId, channelName: channel.name, limit: limit);

  Map<String, String> _headers(Map<String, String> h) => {...defaultHeaders, ...h};

  @override
  Future<PlayableStream> resolveChannel(Channel channel) async =>
      PlayableStream(channel.streamUrl!, headers: _headers(channel.headers), isLive: true, title: channel.name);

  @override
  Future<PlayableStream> resolveMovie(Movie movie) async =>
      PlayableStream(movie.streamUrl!, headers: _headers(movie.headers), title: movie.name);

  @override
  Future<PlayableStream> resolveEpisode(Episode episode) async =>
      PlayableStream(episode.streamUrl!, headers: _headers(episode.headers), title: episode.title);

  @override
  Future<PlayableStream?> resolveCatchup(Channel channel, EpgProgram program) async {
    final url = buildCatchupUrl(channel, program.start, program.end);
    if (url == null) return null;
    return PlayableStream(url, headers: _headers(channel.headers), title: '${channel.name} - ${program.title}');
  }

  static final _episodePattern = RegExp(r'^(.*?)[\s\-_.]*S(\d{1,2})\s*E(\d{1,3})', caseSensitive: false);

  static ({String show, int season, int episode}) _splitEpisodeName(String name) {
    final m = _episodePattern.firstMatch(name);
    if (m == null) return (show: name, season: 1, episode: 0);
    final show = m.group(1)!.trim();
    return (show: show.isEmpty ? name : show, season: int.parse(m.group(2)!), episode: int.parse(m.group(3)!));
  }
}

typedef _Built = ({
  M3uPlaylist playlist,
  List<Channel> channels,
  List<Movie> movies,
  Map<String, _SeriesBuilder> series,
});

class _SeriesBuilder {
  _SeriesBuilder(this.series);

  final Series series;
  final episodes = <Episode>[];
}

/// Builds a catch-up URL from the M3U `catchup` / `catchup-source` attributes.
/// Supports the common placeholders used by Kodi / TiviMate style playlists.
String? buildCatchupUrl(Channel channel, DateTime start, DateTime end) {
  final mode = channel.extra['catchup']?.toLowerCase() ?? (channel.catchupSource != null ? 'default' : null);
  final base = channel.streamUrl;
  if (base == null || mode == null) return null;

  final utcStart = start.toUtc();
  final utcEnd = end.toUtc();
  final durationSecs = utcEnd.difference(utcStart).inSeconds;
  String two(int v) => v.toString().padLeft(2, '0');

  String fill(String template) => template
      .replaceAll('{utc}', '${utcStart.millisecondsSinceEpoch ~/ 1000}')
      .replaceAll('\${start}', '${utcStart.millisecondsSinceEpoch ~/ 1000}')
      .replaceAll('{utcend}', '${utcEnd.millisecondsSinceEpoch ~/ 1000}')
      .replaceAll('\${end}', '${utcEnd.millisecondsSinceEpoch ~/ 1000}')
      .replaceAll('{lutc}', '${DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000}')
      .replaceAll('\${timestamp}', '${DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000}')
      .replaceAll('{duration}', '$durationSecs')
      .replaceAll('\${duration}', '$durationSecs')
      .replaceAll('{Y}', '${utcStart.year}')
      .replaceAll('{m}', two(utcStart.month))
      .replaceAll('{d}', two(utcStart.day))
      .replaceAll('{H}', two(utcStart.hour))
      .replaceAll('{M}', two(utcStart.minute))
      .replaceAll('{S}', two(utcStart.second))
      .replaceAll('{offset:1}', '${utcStart.millisecondsSinceEpoch ~/ 1000}');

  switch (mode) {
    case 'append':
      return base + fill(channel.catchupSource ?? '');
    case 'shift':
    case 'timeshift':
      final sep = base.contains('?') ? '&' : '?';
      return '$base${sep}utc=${utcStart.millisecondsSinceEpoch ~/ 1000}&lutc=${DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000}';
    case 'flussonic':
    case 'flussonic-hls':
    case 'fs':
      final uri = Uri.parse(base);
      final segs = List.of(uri.pathSegments);
      if (segs.isEmpty) return null;
      final ts = utcStart.millisecondsSinceEpoch ~/ 1000;
      final last = segs.removeLast();
      final name = last.endsWith('.ts') || last == 'mpegts' ? 'timeshift_abs-$ts.ts' : 'index-$ts-$durationSecs.m3u8';
      return uri.replace(pathSegments: [...segs, name]).toString();
    default:
      final src = channel.catchupSource;
      return src == null ? null : fill(src);
  }
}
