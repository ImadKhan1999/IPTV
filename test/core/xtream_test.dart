import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv/core/models.dart';
import 'package:iptv/core/sources/xtream_source.dart';

void main() {
  late List<Uri> requests;

  XtreamSource source(Map<String, Object> byAction, {int status = 200}) {
    requests = [];
    final client = MockClient((req) async {
      requests.add(req.url);
      final action = req.url.queryParameters['action'] ?? '';
      return http.Response(jsonEncode(byAction[action] ?? []), status);
    });
    return XtreamSource(
      PlaylistProfile(
        id: 'x',
        name: 'X',
        kind: SourceKind.xtream,
        url: 'provider.com:8080/',
        username: 'u s',
        password: 'p&w',
      ),
      client: client,
    );
  }

  final login = {
    'user_info': {
      'auth': 1,
      'status': 'Active',
      'exp_date': '1893456000',
      'max_connections': '2',
      'active_cons': 1,
      'allowed_output_formats': ['m3u8'],
    },
    'server_info': {'url': 'provider.com'},
  };

  test('logs in and reads account info', () async {
    final s = source({'': login});
    final info = await s.connect();
    expect(info!.status, 'Active');
    expect(info.maxConnections, 2);
    expect(info.expiresAt, DateTime.fromMillisecondsSinceEpoch(1893456000 * 1000));
    expect(requests.single.toString(), startsWith('http://provider.com:8080/player_api.php'));
    expect(requests.single.queryParameters['username'], 'u s');
    // Panel only allows HLS, so live URLs switch to .m3u8.
    expect(s.liveExtension, 'm3u8');
  });

  test('rejects failed logins with a readable message', () async {
    final s = source({
      '': {
        'user_info': {'auth': 0},
      },
    });
    expect(s.connect(), throwsA(isA<SourceException>()));
  });

  test('maps live streams with lenient types and encoded credentials', () async {
    final s = source({
      'get_live_streams': [
        {
          'num': 1,
          'name': 'Sky News',
          'stream_id': 42,
          'stream_icon': '',
          'epg_channel_id': 'sky.news',
          'category_id': '3',
          'tv_archive': 1,
          'tv_archive_duration': '5',
        },
        {'num': '2', 'name': 'No id'},
      ],
    });
    final list = await s.channels('3');
    expect(list, hasLength(1));
    final c = list.single;
    expect(c.id, '42');
    expect(c.logo, isNull);
    expect(c.catchupDays, 5);
    expect(c.streamUrl, 'http://provider.com:8080/live/u%20s/p%26w/42.ts');
    expect(requests.single.queryParameters['category_id'], '3');
  });

  test('caches lists', () async {
    final s = source({
      'get_live_categories': [
        {'category_id': '1', 'category_name': 'XXX Adult'},
      ],
    });
    final a = await s.categories(ContentType.live);
    await s.categories(ContentType.live);
    expect(requests, hasLength(1));
    expect(a.single.isAdult, isTrue);
  });

  test('reads series info with seasons given as a map', () async {
    final s = source({
      'get_series_info': {
        'info': {'plot': 'A chemistry teacher...', 'cover': 'http://c.jpg'},
        'episodes': {
          '2': [
            {
              'id': '201',
              'episode_num': 1,
              'title': 'S2E1',
              'container_extension': 'mkv',
              'season': 2,
              'info': {'duration_secs': 2700},
            },
          ],
          '1': [
            {'id': '102', 'episode_num': '2', 'title': 'S1E2', 'container_extension': 'mp4'},
            {'id': '101', 'episode_num': '1', 'title': 'S1E1', 'container_extension': 'mp4'},
          ],
        },
      },
    });
    final d = await s.seriesDetails(const Series(id: '9', name: 'Breaking Bad'));
    expect(d.seasons.keys, [1, 2]);
    expect(d.seasons[1]!.map((e) => e.id), ['101', '102']);
    expect(d.seasons[2]!.single.streamUrl, 'http://provider.com:8080/series/u%20s/p%26w/201.mkv');
    expect(d.seasons[2]!.single.durationSecs, 2700);
    expect(d.series.plot, 'A chemistry teacher...');
  });

  test('decodes base64 short EPG', () async {
    final s = source({
      'get_short_epg': {
        'epg_listings': [
          {
            'title': base64.encode(utf8.encode('Nachrichten – Live')),
            'description': base64.encode(utf8.encode('Desc')),
            'start_timestamp': '1700000000',
            'stop_timestamp': '1700003600',
          },
        ],
      },
    });
    final epg = await s.shortEpg(const Channel(id: '42', name: 'X'));
    expect(epg.single.title, 'Nachrichten – Live');
    expect(epg.single.end.difference(epg.single.start), const Duration(hours: 1));
  });

  test('builds timeshift URLs in UTC', () {
    final s = source({});
    final start = DateTime.utc(2026, 3, 4, 5, 6);
    expect(
      s.timeshiftUrl('42', start, start.add(const Duration(minutes: 90))),
      'http://provider.com:8080/timeshift/u%20s/p%26w/90/2026-03-04:05-06/42.ts',
    );
  });
}
