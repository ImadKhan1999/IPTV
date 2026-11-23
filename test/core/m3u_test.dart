import 'package:flutter_test/flutter_test.dart';
import 'package:iptv/core/models.dart';
import 'package:iptv/core/sources/m3u_parser.dart';
import 'package:iptv/core/sources/m3u_source.dart';

const _playlist = '''
#EXTM3U url-tvg="http://epg.example.com/guide.xml.gz,http://backup/guide.xml" tvg-shift=0
#EXTINF:-1 tvg-id="bbc1.uk" tvg-name="BBC One" tvg-logo="http://logo/bbc1.png" tvg-chno="101" group-title="UK, News" catchup="default" catchup-days="7" catchup-source="http://cdn/bbc1?start={utc}&end={utcend}",BBC One HD
#EXTVLCOPT:http-user-agent=SmartIPTV/1.0
#EXTVLCOPT:http-referrer=http://ref.example.com/
http://cdn.example.com/live/bbc1.ts
#EXTINF:-1 tvg-id="cnn" group-title="News",CNN, International
http://cdn.example.com/live/cnn.m3u8
#EXTINF:0,No Group Channel
#EXTGRP:Misc
rtmp://cdn.example.com/live/misc
#EXTINF:-1 tvg-logo="http://img/matrix.jpg" group-title="Movies",The Matrix (1999)
http://provider.com/movie/user/pass/123.mkv
#EXTINF:-1 group-title="Series",Breaking Bad S01E02
http://provider.com/series/user/pass/9001.mp4
#EXTINF:-1 group-title="Series",Breaking Bad S01 E01
http://provider.com/series/user/pass/9000.mp4
#EXTINF:-1 group-title="Series",Breaking Bad S02E01
http://provider.com/series/user/pass/9100.mp4
#EXTINF:-1 group-title="Adult XXX",Late Night
http://cdn.example.com/live/late.ts
''';

void main() {
  group('M3uParser', () {
    test('reads header guide URL and every entry', () {
      final pl = M3uParser.parse(_playlist.replaceAll('\n', '\r\n'));
      expect(pl.epgUrl, 'http://epg.example.com/guide.xml.gz');
      expect(pl.entries, hasLength(8));
    });

    test('parses attributes, quoted commas, titles and VLC options', () {
      final e = M3uParser.parse(_playlist).entries.first;
      expect(e.name, 'BBC One HD');
      expect(e.group, 'UK, News');
      expect(e.attr('tvg-id'), 'bbc1.uk');
      expect(e.attr('tvg-chno'), '101');
      expect(e.headers['User-Agent'], 'SmartIPTV/1.0');
      expect(e.headers['Referer'], 'http://ref.example.com/');
      expect(e.url, 'http://cdn.example.com/live/bbc1.ts');
    });

    test('keeps commas inside the title', () {
      expect(M3uParser.parse(_playlist).entries[1].name, 'CNN, International');
    });

    test('falls back to #EXTGRP for the group', () {
      expect(M3uParser.parse(_playlist).entries[2].group, 'Misc');
    });

    test('classifies live, movie and series entries', () {
      final types = M3uParser.parse(_playlist).entries.map((e) => e.contentType).toList();
      expect(types, [
        ContentType.live,
        ContentType.live,
        ContentType.live,
        ContentType.movie,
        ContentType.series,
        ContentType.series,
        ContentType.series,
        ContentType.live,
      ]);
    });

    test('handles playlists without #EXTM3U or #EXTINF', () {
      final pl = M3uParser.parse('http://a/one.ts\nhttp://a/two.ts\n');
      expect(pl.entries.map((e) => e.name), ['one.ts', 'two.ts']);
    });
  });

  group('M3uSource', () {
    final source = M3uSource(PlaylistProfile(id: 'p', name: 'Test', kind: SourceKind.m3u, url: ''))
      ..loadFromText(_playlist);

    test('builds live categories in playlist order and flags adult ones', () async {
      final cats = await source.categories(ContentType.live);
      expect(cats.map((c) => c.name), ['UK, News', 'News', 'Misc', 'Adult XXX']);
      expect(cats.last.isAdult, isTrue);
      expect(cats.first.isAdult, isFalse);
    });

    test('maps channels with number, logo, guide id and catch-up', () async {
      final all = await source.channels(Category.allId);
      expect(all, hasLength(4));
      final bbc = all.first;
      expect(bbc.number, 101);
      expect(bbc.epgId, 'bbc1.uk');
      expect(bbc.catchupDays, 7);
      expect(bbc.hasCatchup, isTrue);
      final stream = await source.resolveChannel(bbc);
      expect(stream.headers['User-Agent'], 'SmartIPTV/1.0');
      expect(stream.isLive, isTrue);
    });

    test('groups episodes into a series with seasons', () async {
      final series = await source.series(Category.allId);
      expect(series, hasLength(1));
      expect(series.single.name, 'Breaking Bad');
      final details = await source.seriesDetails(series.single);
      expect(details.seasons.keys, [1, 2]);
      expect(details.seasons[1]!.map((e) => e.number), [1, 2]);
    });

    test('counts items per category', () async {
      final counts = await source.categoryCounts(ContentType.live);
      expect(counts![Category.allId], 4);
      expect(counts['News'], isNotNull);
      expect((await source.categoryCounts(ContentType.series))![Category.allId], 1);
    });

    test('lists movies', () async {
      final movies = await source.movies('Movies');
      expect(movies.single.name, 'The Matrix (1999)');
      expect(movies.single.poster, 'http://img/matrix.jpg');
    });

    test('fills catch-up templates', () async {
      final bbc = (await source.channels(Category.allId)).first;
      final start = DateTime.utc(2026, 1, 2, 20, 0);
      final url = buildCatchupUrl(bbc, start, start.add(const Duration(hours: 1)));
      expect(
        url,
        'http://cdn/bbc1?start=${start.millisecondsSinceEpoch ~/ 1000}&end=${start.millisecondsSinceEpoch ~/ 1000 + 3600}',
      );
    });
  });
}
