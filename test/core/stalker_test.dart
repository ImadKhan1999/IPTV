import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv/core/models.dart';
import 'package:iptv/core/sources/stalker_source.dart';

void main() {
  test('derives API endpoints from portal URLs', () {
    expect(StalkerSource.endpointCandidates('http://host:8080/c/').first, 'http://host:8080/portal.php');
    expect(
      StalkerSource.endpointCandidates('host/stalker_portal/c').first,
      'http://host/stalker_portal/server/load.php',
    );
    expect(StalkerSource.endpointCandidates('http://host/portal.php'), ['http://host/portal.php']);
  });

  test('cleans ffmpeg-prefixed commands', () {
    expect(cleanStalkerCmd('ffmpeg http://s/live/1.ts'), 'http://s/live/1.ts');
    expect(cleanStalkerCmd('ffrt3 rtmp://s/live'), 'rtmp://s/live');
    expect(cleanStalkerCmd('auto'), '');
  });

  group('session', () {
    late List<http.Request> requests;
    late StalkerSource source;

    setUp(() {
      requests = [];
      final client = MockClient((req) async {
        requests.add(req);
        final q = req.url.queryParameters;
        if (req.url.path.endsWith('portal.php') && q['action'] == 'handshake') {
          // First candidate fails like a portal without portal.php.
          return http.Response('Not found', 404);
        }
        Object js = const {};
        switch ('${q['type']}/${q['action']}') {
          case 'stb/handshake':
            js = {'token': 'TOKEN123'};
          case 'stb/get_profile':
            js = {'id': 1, 'status': 0};
          case 'account_info/get_main_info':
            js = {'end_date': '2027-01-31'};
          case 'itv/get_genres':
            js = [
              {'id': '*', 'title': 'All'},
              {'id': '10', 'title': 'Sports'},
              {'id': '11', 'title': 'Adult', 'censored': 1},
            ];
          case 'itv/get_all_channels':
            js = {
              'data': [
                {
                  'id': '1',
                  'name': 'Sport 1',
                  'number': '5',
                  'cmd': 'ffmpeg http://cdn/s1.ts',
                  'tv_genre_id': '10',
                  'logo': '/logos/s1.png',
                  'use_http_tmp_link': '0',
                },
                {
                  'id': '2',
                  'name': 'Sport 2',
                  'cmd': 'ffrt http://localhost/ch/2',
                  'tv_genre_id': '10',
                  'use_http_tmp_link': '1',
                },
              ],
            };
          case 'itv/create_link':
            js = {'cmd': 'ffmpeg http://cdn/s2.ts?token=abc'};
          case 'vod/get_ordered_list':
            final page = int.parse(q['p']!);
            js = {
              'total_items': 3,
              'data': page == 1
                  ? [
                      {'id': 'm1', 'name': 'Movie 1', 'cmd': 'cmd1'},
                      {'id': 'm2', 'name': 'Movie 2', 'cmd': 'cmd2'},
                    ]
                  : [
                      {'id': 'm3', 'name': 'Movie 3', 'cmd': 'cmd3'},
                    ],
            };
        }
        return http.Response(jsonEncode({'js': js}), 200);
      });
      source = StalkerSource(
        PlaylistProfile(
          id: 's',
          name: 'S',
          kind: SourceKind.stalker,
          url: 'http://portal.tv/c/',
          mac: '00:1a:79:12:34:56',
        ),
        client: client,
      );
    });

    test('rejects malformed MAC addresses', () {
      final bad = StalkerSource(PlaylistProfile(id: 's', name: 'S', kind: SourceKind.stalker, url: 'x', mac: '1234'));
      expect(bad.connect(), throwsA(isA<SourceException>()));
    });

    test('handshakes, falls back to load.php and sends STB headers', () async {
      final info = await source.connect();
      expect(info!.expiresAt, DateTime(2027, 1, 31));
      final profileReq = requests.firstWhere((r) => r.url.queryParameters['action'] == 'get_profile');
      expect(profileReq.url.path, '/server/load.php');
      expect(profileReq.headers['Authorization'], 'Bearer TOKEN123');
      expect(profileReq.headers['Cookie'], contains('mac=00%3A1A%3A79%3A12%3A34%3A56'));
      expect(profileReq.url.queryParameters['sn'], hasLength(13));
    });

    test('lists genres without the "All" pseudo genre and flags censored ones', () async {
      await source.connect();
      final cats = await source.categories(ContentType.live);
      expect(cats.map((c) => c.name), ['Sports', 'Adult']);
      expect(cats.last.isAdult, isTrue);
    });

    test('plays direct links and creates temporary links when needed', () async {
      await source.connect();
      final channels = await source.channels('10');
      expect(channels.first.logo, 'http://portal.tv/logos/s1.png');
      expect((await source.resolveChannel(channels[0])).url, 'http://cdn/s1.ts');
      expect((await source.resolveChannel(channels[1])).url, 'http://cdn/s2.ts?token=abc');
    });

    test('pages through VOD lists', () async {
      await source.connect();
      final movies = await source.movies(Category.allId);
      expect(movies.map((m) => m.id), ['m1', 'm2', 'm3']);
    });
  });
}
