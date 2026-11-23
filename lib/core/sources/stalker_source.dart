import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models.dart';
import 'iptv_source.dart';
import 'json_utils.dart';

/// Stalker / Ministra middleware portal, logging in as a MAG set-top box with a MAC address.
class StalkerSource extends IptvSource {
  StalkerSource(super.profile, {super.client});

  static const _stbUserAgent =
      'Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3';

  String? _endpoint;
  String? _token;
  final _cache = <String, Object>{};
  List<Channel>? _allChannels;

  String get mac => profile.mac.trim().toUpperCase();

  /// Serial number, device IDs and signature: the user's values when the portal needs the
  /// real box identity, otherwise derived from the MAC the way MAG firmware does.
  String get serial => profile.serial.trim().isNotEmpty
      ? profile.serial.trim()
      : md5.convert(utf8.encode(mac)).toString().toUpperCase().substring(0, 13);
  String get deviceId => profile.deviceId.trim().isNotEmpty
      ? profile.deviceId.trim()
      : sha256.convert(utf8.encode(mac)).toString().toUpperCase();
  String get deviceId2 => profile.deviceId2.trim().isNotEmpty ? profile.deviceId2.trim() : deviceId;
  String get signature => profile.signature.trim().isNotEmpty
      ? profile.signature.trim()
      : sha256.convert(utf8.encode('$serial$mac')).toString().toUpperCase();
  String get model => profile.stbModel.trim().isNotEmpty ? profile.stbModel.trim().toUpperCase() : 'MAG250';

  @override
  Set<SourceFeature> get features => {
    SourceFeature.live,
    SourceFeature.movies,
    SourceFeature.series,
    SourceFeature.epg,
  };

  /// Candidate API endpoints for a portal URL such as `http://host:8080/c/` or
  /// `http://host/stalker_portal/c/`.
  static List<String> endpointCandidates(String portalUrl) {
    var base = normalizeServerUrl(portalUrl);
    if (base.endsWith('.php')) return [base];
    if (base.endsWith('/c')) base = base.substring(0, base.length - 2);
    if (base.contains('/stalker_portal')) {
      final root = base.substring(0, base.indexOf('/stalker_portal'));
      return ['$root/stalker_portal/server/load.php', '$root/portal.php'];
    }
    return ['$base/portal.php', '$base/server/load.php', '$base/stalker_portal/server/load.php'];
  }

  Map<String, String> get _headers => {
    'User-Agent': profile.userAgent.isNotEmpty ? profile.userAgent : _stbUserAgent,
    'X-User-Agent': 'Model: $model; Link: WiFi',
    'Referer': '${normalizeServerUrl(profile.url)}/',
    'Accept': '*/*',
    'Cookie': 'mac=${Uri.encodeComponent(mac)}; stb_lang=en; timezone=${Uri.encodeComponent(_timezone)}',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  static String get _timezone => 'Europe/London';

  Future<dynamic> _call(Map<String, String> params, {String? endpoint}) async {
    final url = endpoint ?? _endpoint!;
    final uri = Uri.parse(url).replace(queryParameters: {...params, 'JsHttpRequest': '1-xml'});
    final res = await client.get(uri, headers: _headers).timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) throw SourceException('Portal error (HTTP ${res.statusCode}).');
    final body = utf8.decode(res.bodyBytes, allowMalformed: true).trim();
    if (body.isEmpty || body.toLowerCase().contains('authorization failed')) {
      throw SourceException('The portal rejected this MAC address.');
    }
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? decoded['js'] : decoded;
    } on FormatException catch (e) {
      throw SourceException('The portal sent an unexpected reply.', e);
    }
  }

  @override
  Future<AccountInfo?> connect() async {
    if (!RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$').hasMatch(mac)) {
      throw SourceException('Enter the MAC address as 00:1A:79:XX:XX:XX.');
    }
    Object? lastError;
    for (final candidate in endpointCandidates(profile.url)) {
      try {
        _token = null;
        final js = jMap(
          await _call({'type': 'stb', 'action': 'handshake', 'token': '', 'prehash': '0'}, endpoint: candidate),
        );
        final token = jStr(js['token']);
        if (token == null) continue;
        _endpoint = candidate;
        _token = token;
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (_endpoint == null) {
      throw lastError is SourceException
          ? lastError
          : SourceException('Could not reach the portal. Check the portal URL.', lastError);
    }
    final profileJs = jMap(
      await _call({
        'type': 'stb',
        'action': 'get_profile',
        'hd': '1',
        'ver': 'ImageDescription: 0.2.18-r23-250; ImageDate: Thu Sep 13 11:31:16 EEST 2018; PORTAL version: 5.6.2; API Version: JS API version: 343; STB API version: 146; Player Engine version: 0x58c',
        'num_banks': '2',
        'sn': serial,
        'stb_type': model,
        'client_type': 'STB',
        'image_version': '218',
        'video_out': 'hdmi',
        'device_id': deviceId,
        'device_id2': deviceId2,
        'signature': signature,
        'auth_second_step': '1',
        'hw_version': '1.7-BD-00',
        'not_valid_token': '0',
        'api_signature': '262',
        'prehash': '',
      }),
    );
    if (jStr(profileJs['status']) == '2' || jStr(profileJs['blocked']) == '1') {
      throw SourceException(jStr(profileJs['msg']) ?? 'This device is blocked by the portal.');
    }
    var account = <String, dynamic>{};
    try {
      account = jMap(await _call({'type': 'account_info', 'action': 'get_main_info'}));
    } catch (_) {
      // Not every portal exposes account info.
    }
    final phone = jStr(account['end_date']) ?? jStr(account['phone']);
    return AccountInfo(
      status: 'Active',
      expiresAt: phone == null ? null : DateTime.tryParse(phone),
      message: jStr(profileJs['msg']),
    );
  }

  /// Keeps the session alive; call every couple of minutes while playing.
  Future<void> keepAlive() async {
    try {
      await _call({
        'type': 'watchdog',
        'action': 'get_events',
        'event_active_id': '0',
        'init': '0',
        'cur_play_type': '1',
      });
    } catch (_) {}
  }

  Future<T> _cached<T extends Object>(String key, Future<T> Function() load) async {
    final hit = _cache[key];
    if (hit is T) return hit;
    final v = await load();
    _cache[key] = v;
    return v;
  }

  @override
  Future<List<Category>> categories(ContentType type) => _cached('cat:${type.name}', () async {
    final js = type == ContentType.live
        ? await _call({'type': 'itv', 'action': 'get_genres'})
        : await _call({'type': type == ContentType.movie ? 'vod' : 'series', 'action': 'get_categories'});
    return [
      for (final g in jList(js))
        if (jStr(g['id']) != null && jStr(g['id']) != '*')
          Category(
            id: jStr(g['id'])!,
            name: jStr(g['title']) ?? 'Unnamed',
            type: type,
            isAdult: jBool(g['censored']) || looksAdult(jStr(g['title']) ?? ''),
          ),
    ];
  });

  Future<List<Channel>> _loadAllChannels() async {
    if (_allChannels != null) return _allChannels!;
    final js = jMap(await _call({'type': 'itv', 'action': 'get_all_channels'}));
    _allChannels = [
      for (final c in jList(js['data']))
        if (jStr(c['id']) != null)
          Channel(
            id: jStr(c['id'])!,
            name: jStr(c['name']) ?? 'Channel',
            number: jInt(c['number']),
            logo: _absolute(jStr(c['logo'])),
            categoryId: jStr(c['tv_genre_id']) ?? '',
            epgId: jStr(c['xmltv_id']),
            catchupDays: jBool(c['tv_archive']) ? ((jInt(c['tv_archive_duration']) ?? 0) ~/ 24).clamp(1, 30) : 0,
            extra: {'cmd': jStr(c['cmd']) ?? '', 'use_http_tmp_link': jStr(c['use_http_tmp_link']) ?? '0'},
          ),
    ];
    return _allChannels!;
  }

  @override
  Future<List<Channel>> channels(String categoryId) async {
    final all = await _loadAllChannels();
    return categoryId == Category.allId ? all : all.where((c) => c.categoryId == categoryId).toList();
  }

  @override
  Future<Map<String, int>?> categoryCounts(ContentType type) async {
    if (type == ContentType.live) {
      return IptvSource.countByCategory((await _loadAllChannels()).map((c) => c.categoryId));
    }
    // VOD lists are paged; the first page reports the total, so only the total is counted.
    final js = jMap(
      await _call({'type': type == ContentType.movie ? 'vod' : 'series', 'action': 'get_ordered_list', 'p': '1'}),
    );
    final total = jInt(js['total_items']);
    return total == null ? null : {Category.allId: total};
  }

  /// Pages through `get_ordered_list` (VOD and series lists are paginated, 14 per page).
  Future<List<Map<String, dynamic>>> _orderedList(String type, Map<String, String> params, {int maxPages = 50}) async {
    final out = <Map<String, dynamic>>[];
    for (var page = 1; page <= maxPages; page++) {
      final js = jMap(await _call({'type': type, 'action': 'get_ordered_list', 'p': '$page', ...params}));
      final data = jList(js['data']);
      out.addAll(data);
      final total = jInt(js['total_items']) ?? out.length;
      if (data.isEmpty || out.length >= total) break;
    }
    return out;
  }

  @override
  Future<List<Movie>> movies(String categoryId) => _cached('vod:$categoryId', () async {
    final rows = await _orderedList('vod', {
      if (categoryId != Category.allId) 'category': categoryId,
      'sortby': 'added',
    });
    return [
      for (final m in rows)
        if (!jBool(m['is_series']))
          Movie(
            id: jStr(m['id']) ?? '',
            name: jStr(m['name']) ?? 'Movie',
            poster: _absolute(jStr(m['screenshot_uri'])),
            categoryId: jStr(m['category_id']) ?? categoryId,
            rating: jDouble(m['rating_imdb']),
            year: jStr(m['year']),
            plot: jStr(m['description']),
            extra: {'cmd': jStr(m['cmd']) ?? ''},
          ),
    ];
  });

  @override
  Future<List<Series>> series(String categoryId) => _cached('series:$categoryId', () async {
    final rows = await _orderedList('series', {
      if (categoryId != Category.allId) 'category': categoryId,
      'sortby': 'added',
    });
    return [
      for (final s in rows)
        Series(
          id: jStr(s['id']) ?? '',
          name: jStr(s['name']) ?? 'Series',
          poster: _absolute(jStr(s['screenshot_uri'])),
          categoryId: jStr(s['category_id']) ?? categoryId,
          rating: jDouble(s['rating_imdb']),
          plot: jStr(s['description']),
          year: jStr(s['year']),
          extra: {'cmd': jStr(s['cmd']) ?? ''},
        ),
    ];
  });

  @override
  Future<SeriesDetails> seriesDetails(Series series) async {
    final rows = await _orderedList('series', {'movie_id': series.id, 'season_id': '0', 'episode_id': '0'});
    final seasons = <int, List<Episode>>{};
    for (final s in rows) {
      final seasonNo =
          jInt(s['season_number']) ??
          int.tryParse(RegExp(r'\d+').firstMatch(jStr(s['name']) ?? '')?.group(0) ?? '') ??
          seasons.length + 1;
      final cmd = jStr(s['cmd']) ?? '';
      final eps = (s['series'] as List?) ?? const [];
      seasons[seasonNo] = [
        for (final n in eps)
          Episode(
            id: '${jStr(s['id'])}:$n',
            title: 'Episode $n',
            season: seasonNo,
            number: jInt(n) ?? 0,
            image: _absolute(jStr(s['screenshot_uri'])),
            extra: {'cmd': cmd, 'series': '$n'},
          ),
      ];
    }
    return SeriesDetails(
      series: series,
      seasons: Map.fromEntries(seasons.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
    );
  }

  @override
  Future<List<EpgProgram>> shortEpg(Channel channel, {int limit = 6}) async {
    final js = await _call({'type': 'itv', 'action': 'get_short_epg', 'ch_id': channel.id, 'size': '$limit'});
    return [
      for (final e in jList(js))
        if (jInt(e['start_timestamp']) != null && jInt(e['stop_timestamp']) != null)
          EpgProgram(
            channelId: channel.id,
            start: DateTime.fromMillisecondsSinceEpoch(jInt(e['start_timestamp'])! * 1000),
            end: DateTime.fromMillisecondsSinceEpoch(jInt(e['stop_timestamp'])! * 1000),
            title: jStr(e['name']) ?? '',
            description: jStr(e['descr']) ?? '',
          ),
    ];
  }

  Future<String> _createLink(String type, String cmd, {String series = ''}) async {
    final js = jMap(
      await _call({
        'type': type,
        'action': 'create_link',
        'cmd': cmd,
        'series': series,
        'forced_storage': 'undefined',
        'disable_ad': '0',
        'download': '0',
      }),
    );
    final link = cleanStalkerCmd(jStr(js['cmd']) ?? '');
    if (link.isEmpty) throw SourceException('The portal did not return a stream link.');
    return link;
  }

  Map<String, String> get _streamHeaders => {'User-Agent': _headers['User-Agent']!};

  @override
  Future<PlayableStream> resolveChannel(Channel channel) async {
    final cmd = channel.extra['cmd'] ?? '';
    final direct = cleanStalkerCmd(cmd);
    // Channels with a real URL and no temporary-link requirement can play directly.
    final needsLink = channel.extra['use_http_tmp_link'] == '1' || direct.isEmpty || direct.contains('localhost');
    final url = needsLink ? await _createLink('itv', cmd) : direct;
    return PlayableStream(url, headers: _streamHeaders, isLive: true, title: channel.name);
  }

  @override
  Future<PlayableStream> resolveMovie(Movie movie) async =>
      PlayableStream(await _createLink('vod', movie.extra['cmd'] ?? ''), headers: _streamHeaders, title: movie.name);

  @override
  Future<PlayableStream> resolveEpisode(Episode episode) async => PlayableStream(
    await _createLink('vod', episode.extra['cmd'] ?? '', series: episode.extra['series'] ?? ''),
    headers: _streamHeaders,
    title: episode.title,
  );

  String? _absolute(String? path) {
    if (path == null) return null;
    if (path.startsWith('http')) return path;
    final base = Uri.parse(normalizeServerUrl(profile.url));
    return base.resolve(path).toString();
  }
}

/// Stalker `cmd` values look like `ffmpeg http://host/...` or `ffrt http://...`; keep the URL.
String cleanStalkerCmd(String cmd) {
  final t = cmd.trim();
  final i = t.indexOf(RegExp(r'(https?|rtmp|rtsp|udp)://'));
  return i >= 0 ? t.substring(i).trim() : '';
}
