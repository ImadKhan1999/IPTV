import 'dart:convert';

import '../models.dart';
import 'iptv_source.dart';
import 'json_utils.dart';

/// Xtream Codes API (`player_api.php`).
class XtreamSource extends IptvSource {
  XtreamSource(super.profile, {super.client});

  late final String server = normalizeServerUrl(profile.url);
  String get _u => Uri.encodeComponent(profile.username);
  String get _p => Uri.encodeComponent(profile.password);

  /// Preferred live container: `ts` plays everywhere; some panels only allow `m3u8`.
  String liveExtension = 'ts';
  final _cache = <String, Object>{};

  @override
  Set<SourceFeature> get features => {
    SourceFeature.live,
    SourceFeature.movies,
    SourceFeature.series,
    SourceFeature.epg,
    SourceFeature.catchup,
  };

  @override
  String? get xmltvUrl => profile.epgUrl.isNotEmpty ? profile.epgUrl : '$server/xmltv.php?username=$_u&password=$_p';

  Uri _api([Map<String, String> params = const {}]) =>
      Uri.parse('$server/player_api.php')
          .replace(queryParameters: {'username': profile.username, 'password': profile.password, ...params});

  /// List replies that are kept on disk between launches. Login and EPG are always live.
  static const _cacheableActions = {
    'get_live_categories',
    'get_vod_categories',
    'get_series_categories',
    'get_live_streams',
    'get_vod_streams',
    'get_series',
    'get_series_info',
    'get_vod_info',
  };

  Future<dynamic> _get(Map<String, String> params) async {
    final bytes = await _bytes(params);
    return IptvSource.offThread(_decode, bytes, bytes.length);
  }

  /// Downloads (or reads from the disk cache), decodes and turns the reply into app objects
  /// in one go on a background thread. Big lists (tens of thousands of channels) never
  /// freeze the screen this way.
  Future<R> _getMapped<R>(Map<String, String> params, R Function(List<int>) work) async {
    final bytes = await _bytes(params);
    return IptvSource.offThread(work, bytes, bytes.length);
  }

  Future<List<int>> _bytes(Map<String, String> params) async {
    final uri = _api(params);
    Future<List<int>> load({bool validate = false}) async {
      final res = await client.get(uri, headers: defaultHeaders).timeout(const Duration(seconds: 30));
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw SourceException('Login rejected: check the username and password.');
      }
      if (res.statusCode != 200) throw SourceException('Server error (HTTP ${res.statusCode}).');
      if (validate) {
        // Never store a broken reply.
        await IptvSource.offThread(_decode, res.bodyBytes, res.bodyBytes.length);
      }
      return res.bodyBytes;
    }

    return _cacheableActions.contains(params['action'])
        ? cachedBytes('xtream|$uri', () => load(validate: true))
        : load();
  }

  static dynamic _decode(List<int> bytes) {
    final body = utf8.decode(bytes, allowMalformed: true).trim();
    if (body.isEmpty) return const [];
    try {
      return jsonDecode(body);
    } on FormatException catch (e) {
      throw SourceException('The server sent an unexpected reply.', e);
    }
  }

  Future<T> _cached<T extends Object>(String key, Future<T> Function() load) async {
    final hit = _cache[key];
    if (hit is T) return hit;
    final v = await load();
    _cache[key] = v;
    return v;
  }

  @override
  Future<AccountInfo?> connect() async {
    final data = jMap(await _get(const {}));
    final user = jMap(data['user_info']);
    if (user.isEmpty || !jBool(user['auth'] ?? 1)) {
      throw SourceException('Login failed: check the server, username and password.');
    }
    final status = jStr(user['status']);
    if (status != null && status.toLowerCase() != 'active') {
      throw SourceException('Account status: $status');
    }
    final formats = (user['allowed_output_formats'] as List?)?.map((e) => '$e').toList() ?? const [];
    if (formats.isNotEmpty && !formats.contains('ts') && formats.contains('m3u8')) liveExtension = 'm3u8';
    final exp = jInt(user['exp_date']);
    return AccountInfo(
      status: status,
      expiresAt: exp == null ? null : DateTime.fromMillisecondsSinceEpoch(exp * 1000),
      maxConnections: jInt(user['max_connections']),
      activeConnections: jInt(user['active_cons']),
      message: jStr(user['message']),
    );
  }

  @override
  Future<List<Category>> categories(ContentType type) => _cached('cat:${type.name}', () async {
    final action = switch (type) {
      ContentType.live => 'get_live_categories',
      ContentType.movie => 'get_vod_categories',
      ContentType.series => 'get_series_categories',
    };
    return [
      for (final c in jList(await _get({'action': action})))
        Category(
          id: jStr(c['category_id']) ?? '',
          name: jStr(c['category_name']) ?? 'Unnamed',
          type: type,
          isAdult: looksAdult(jStr(c['category_name']) ?? ''),
        ),
    ];
  });

  /// When the full list is already loaded (for counts or search), filter it locally instead of
  /// asking the server again.
  List<T>? _fromFullList<T>(String kind, String categoryId, String Function(T) categoryOf) {
    if (categoryId == Category.allId) return null;
    final all = _cache['$kind:${Category.allId}'];
    if (all is! List<T>) return null;
    return all.where((e) => categoryOf(e) == categoryId).toList();
  }

  @override
  Future<Map<String, int>?> categoryCounts(ContentType type) async => switch (type) {
    ContentType.live => IptvSource.countByCategory((await channels(Category.allId)).map((c) => c.categoryId)),
    ContentType.movie => IptvSource.countByCategory((await movies(Category.allId)).map((m) => m.categoryId)),
    ContentType.series => IptvSource.countByCategory((await series(Category.allId)).map((s) => s.categoryId)),
  };

  Map<String, String> _catParam(String categoryId) =>
      categoryId == Category.allId ? const {} : {'category_id': categoryId};

  @override
  Future<List<Channel>> channels(String categoryId) async =>
      _fromFullList<Channel>('live', categoryId, (c) => c.categoryId) ?? await _channels(categoryId);

  Future<List<Channel>> _channels(String categoryId) => _cached(
    'live:$categoryId',
    () => _getMapped({
      'action': 'get_live_streams',
      ..._catParam(categoryId),
    }, _channelMapper('$server/live/$_u/$_p/', liveExtension)),
  );

  static List<Channel> Function(List<int>) _channelMapper(String prefix, String ext) =>
      (bytes) => [
        for (final s in jList(_decode(bytes)))
          if (jStr(s['stream_id']) != null)
            Channel(
              id: jStr(s['stream_id'])!,
              name: jStr(s['name']) ?? 'Channel',
              number: jInt(s['num']),
              logo: jStr(s['stream_icon']),
              categoryId: jStr(s['category_id']) ?? '',
              streamUrl: '$prefix${jStr(s['stream_id'])}.$ext',
              epgId: jStr(s['epg_channel_id']),
              catchupDays: jBool(s['tv_archive']) ? (jInt(s['tv_archive_duration']) ?? 0) : 0,
            ),
      ];

  @override
  Future<List<Movie>> movies(String categoryId) async =>
      _fromFullList<Movie>('vod', categoryId, (m) => m.categoryId) ?? await _movies(categoryId);

  Future<List<Movie>> _movies(String categoryId) => _cached(
    'vod:$categoryId',
    () => _getMapped({'action': 'get_vod_streams', ..._catParam(categoryId)}, _movieMapper('$server/movie/$_u/$_p/')),
  );

  static List<Movie> Function(List<int>) _movieMapper(String prefix) =>
      (bytes) => [
        for (final s in jList(_decode(bytes)))
          if (jStr(s['stream_id']) != null)
            Movie(
              id: jStr(s['stream_id'])!,
              name: jStr(s['name']) ?? 'Movie',
              poster: jStr(s['stream_icon']),
              categoryId: jStr(s['category_id']) ?? '',
              rating: jDouble(s['rating']),
              year: jStr(s['year']),
              containerExt: jStr(s['container_extension']) ?? 'mp4',
              streamUrl: '$prefix${jStr(s['stream_id'])}.${jStr(s['container_extension']) ?? 'mp4'}',
            ),
      ];

  /// Full movie details (plot, cast, trailer...).
  Future<Map<String, dynamic>> movieInfo(Movie movie) async =>
      jMap(jMap(await _get({'action': 'get_vod_info', 'vod_id': movie.id}))['info']);

  @override
  Future<List<Series>> series(String categoryId) async =>
      _fromFullList<Series>('series', categoryId, (s) => s.categoryId) ?? await _series(categoryId);

  Future<List<Series>> _series(String categoryId) =>
      _cached('series:$categoryId', () => _getMapped({'action': 'get_series', ..._catParam(categoryId)}, _mapSeries));

  static List<Series> _mapSeries(List<int> bytes) => [
    for (final s in jList(_decode(bytes)))
      if (jStr(s['series_id']) != null)
        Series(
          id: jStr(s['series_id'])!,
          name: jStr(s['name']) ?? 'Series',
          poster: jStr(s['cover']),
          categoryId: jStr(s['category_id']) ?? '',
          rating: jDouble(s['rating']),
          plot: jStr(s['plot']),
          year: jStr(s['releaseDate'])?.split('-').first,
        ),
  ];

  @override
  Future<SeriesDetails> seriesDetails(Series series) async {
    final data = jMap(await _get({'action': 'get_series_info', 'series_id': series.id}));
    final episodesRaw = data['episodes'];
    final seasons = <int, List<Episode>>{};
    void addEpisodes(int? seasonKey, Object? list) {
      for (final e in jList(list)) {
        final id = jStr(e['id']);
        if (id == null) continue;
        final info = jMap(e['info']);
        final season = jInt(e['season']) ?? seasonKey ?? 1;
        final ext = jStr(e['container_extension']) ?? 'mp4';
        (seasons[season] ??= []).add(
          Episode(
            id: id,
            title: jStr(e['title']) ?? 'Episode ${jInt(e['episode_num']) ?? ''}',
            season: season,
            number: jInt(e['episode_num']) ?? 0,
            plot: jStr(info['plot']),
            image: jStr(info['movie_image']),
            durationSecs: jInt(info['duration_secs']),
            containerExt: ext,
            streamUrl: '$server/series/$_u/$_p/$id.$ext',
          ),
        );
      }
    }

    if (episodesRaw is Map) {
      episodesRaw.forEach((k, v) => addEpisodes(int.tryParse('$k'), v));
    } else if (episodesRaw is List) {
      for (final group in episodesRaw) {
        group is List ? addEpisodes(null, group) : addEpisodes(null, [group]);
      }
    }
    for (final l in seasons.values) {
      l.sort((a, b) => a.number.compareTo(b.number));
    }
    final info = jMap(data['info']);
    return SeriesDetails(
      series: Series(
        id: series.id,
        name: series.name,
        poster: series.poster ?? jStr(info['cover']),
        categoryId: series.categoryId,
        rating: series.rating ?? jDouble(info['rating']),
        plot: jStr(info['plot']) ?? series.plot,
        year: series.year,
      ),
      seasons: Map.fromEntries(seasons.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
    );
  }

  @override
  Future<List<EpgProgram>> shortEpg(Channel channel, {int limit = 6}) async {
    final data = jMap(await _get({'action': 'get_short_epg', 'stream_id': channel.id, 'limit': '$limit'}));
    return [
      for (final e in jList(data['epg_listings']))
        if (jInt(e['start_timestamp']) != null && jInt(e['stop_timestamp']) != null)
          EpgProgram(
            channelId: channel.id,
            start: DateTime.fromMillisecondsSinceEpoch(jInt(e['start_timestamp'])! * 1000),
            end: DateTime.fromMillisecondsSinceEpoch(jInt(e['stop_timestamp'])! * 1000),
            title: decodeMaybeBase64(jStr(e['title']) ?? ''),
            description: decodeMaybeBase64(jStr(e['description']) ?? ''),
            hasArchive: jBool(e['has_archive']),
          ),
    ];
  }

  @override
  Future<PlayableStream> resolveChannel(Channel channel) async =>
      PlayableStream(channel.streamUrl!, headers: defaultHeaders, isLive: true, title: channel.name);

  @override
  Future<PlayableStream> resolveMovie(Movie movie) async =>
      PlayableStream(movie.streamUrl!, headers: defaultHeaders, title: movie.name);

  @override
  Future<PlayableStream> resolveEpisode(Episode episode) async =>
      PlayableStream(episode.streamUrl!, headers: defaultHeaders, title: episode.title);

  @override
  Future<PlayableStream?> resolveCatchup(Channel channel, EpgProgram program) async {
    if (!channel.hasCatchup) return null;
    return PlayableStream(
      timeshiftUrl(channel.id, program.start, program.end),
      headers: defaultHeaders,
      title: '${channel.name} - ${program.title}',
    );
  }

  /// `/timeshift/{user}/{pass}/{minutes}/{YYYY-MM-DD:HH-MM}/{id}.ts`, start time in server
  /// local time. Most panels run in UTC; this uses UTC.
  String timeshiftUrl(String streamId, DateTime start, DateTime end) {
    final s = start.toUtc();
    final minutes = end.difference(start).inMinutes.clamp(1, 24 * 60);
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${s.year}-${two(s.month)}-${two(s.day)}:${two(s.hour)}-${two(s.minute)}';
    return '$server/timeshift/$_u/$_p/$minutes/$stamp/$streamId.ts';
  }
}

/// Xtream short-EPG titles are base64; fall back to the raw text if it is not.
String decodeMaybeBase64(String s) {
  if (s.isEmpty || s.length % 4 != 0 || !RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(s)) return s;
  try {
    return utf8.decode(base64.decode(s));
  } catch (_) {
    return s;
  }
}
