import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv/core/models.dart';
import 'package:iptv/core/sources/iptv_source.dart';
import 'package:iptv/core/sources/m3u_source.dart';
import 'package:iptv/core/sources/xtream_source.dart';

/// Big playlists are parsed and turned into channels on a background thread.
void main() {
  test('a big M3U playlist loads on a background thread', () async {
    final dir = await Directory.systemTemp.createTemp('iptv');
    addTearDown(() => dir.delete(recursive: true));
    final b = StringBuffer('#EXTM3U url-tvg="http://epg/g.xml"\n');
    for (var i = 0; i < 6000; i++) {
      b
        ..writeln('#EXTINF:-1 tvg-id="c$i" catchup="default" catchup-days="3" group-title="Group ${i % 20}",Channel $i')
        ..writeln('http://cdn.example.com/live/$i.ts');
    }
    b
      ..writeln('#EXTINF:-1 group-title="Shows",Show S01E02')
      ..writeln('http://cdn.example.com/series/u/p/1.mp4');
    final f = File('${dir.path}/big.m3u')..writeAsStringSync(b.toString());
    expect(f.lengthSync(), greaterThan(128 * 1024));

    final s = M3uSource(PlaylistProfile(id: 'm', name: 'M', kind: SourceKind.m3u, url: f.path));
    await s.connect();
    expect((await s.channels(Category.allId)).length, 6000);
    expect((await s.categories(ContentType.live)).length, 20);
    expect((await s.series(Category.allId)).single.name, 'Show');
    expect(s.xmltvUrl, 'http://epg/g.xml');
    expect(s.features, contains(SourceFeature.catchup));
  });

  test('a big Xtream channel list is mapped on a background thread', () async {
    final streams = [
      for (var i = 0; i < 4000; i++)
        {
          'stream_id': i,
          'name': 'Channel number $i',
          'num': i,
          'category_id': '${i % 7}',
          'stream_icon': 'http://l/$i.png',
        },
    ];
    final client = MockClient((req) async => http.Response(jsonEncode(streams), 200));
    final s = XtreamSource(
      PlaylistProfile(id: 'x', name: 'X', kind: SourceKind.xtream, url: 'h.com', username: 'u', password: 'p'),
      client: client,
    );
    final all = await s.channels(Category.allId);
    expect(all.length, 4000);
    expect(all[5].streamUrl, 'http://h.com/live/u/p/5.ts');
    expect((await s.channels('3')).length, 4000 ~/ 7 + (4000 % 7 > 3 ? 1 : 0));
  });
}
