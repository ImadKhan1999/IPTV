import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv/core/models.dart';
import 'package:iptv/core/sources/xtream_source.dart';
import 'package:iptv/data/disk_cache.dart';

void main() {
  group('CachePolicy', () {
    test('uses a fresh entry without touching the network', () async {
      final cache = DiskCache.memory();
      final policy = CachePolicy(cache: cache, group: 'p', maxAge: const Duration(hours: 1));
      var loads = 0;
      Future<List<int>> load() async => [++loads];
      expect(await policy.fetch('k', load), [1]);
      expect(await policy.fetch('k', load), [1]);
      expect(loads, 1);
    });

    test('serves an expired entry at once and refreshes it in the background', () async {
      final cache = DiskCache.memory();
      final policy = CachePolicy(cache: cache, group: 'p', maxAge: const Duration(microseconds: 1));
      var loads = 0;
      Future<List<int>> load() async => [++loads];
      await policy.fetch('k', load);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(await policy.fetch('k', load), [1]); // old copy, no waiting
      await Future.wait(policy.pending);
      expect((await cache.read('p', 'k'))!.$2, [2]); // ready for next launch
    });

    test('falls back to the saved copy when the network fails', () async {
      final cache = DiskCache.memory();
      await cache.write('p', 'k', [7]);
      final policy = CachePolicy(cache: cache, group: 'p', maxAge: Duration.zero);
      expect(await policy.fetch('k', () async => throw Exception('offline')), [7]);
    });

    test('refresh skips the cache, and clearing a playlist removes its data', () async {
      final cache = DiskCache.memory();
      await cache.write('p', 'k', [1]);
      final policy = CachePolicy(cache: cache, group: 'p', maxAge: const Duration(days: 1), forceRefresh: true);
      expect(await policy.fetch('k', () async => [2]), [2]);
      await cache.clearGroup('p');
      expect(await cache.read('p', 'k'), isNull);
    });
  });

  test('a second launch reads Xtream lists from the saved copy', () async {
    final cache = DiskCache.memory();
    final requests = <String>[];
    final client = MockClient((req) async {
      final action = req.url.queryParameters['action'] ?? 'login';
      requests.add(action);
      return http.Response(
        jsonEncode(switch (action) {
          'get_live_streams' => [
            {'name': 'A', 'stream_id': 1, 'category_id': '3'},
          ],
          _ => <Object>[],
        }),
        200,
      );
    });
    XtreamSource launch() => XtreamSource(
      PlaylistProfile(id: 'x', name: 'X', kind: SourceKind.xtream, url: 'h', username: 'u', password: 'p'),
      client: client,
    )..cachePolicy = CachePolicy(cache: cache, group: 'x', maxAge: const Duration(days: 1));

    expect((await launch().channels('3')).single.name, 'A');
    expect((await launch().channels('3')).single.name, 'A');
    expect(requests.where((a) => a == 'get_live_streams'), hasLength(1));
  });
}
