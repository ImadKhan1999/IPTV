import 'package:flutter_test/flutter_test.dart';
import 'package:iptv/core/models.dart';
import 'package:iptv/core/playlist_link.dart';

void main() {
  test('Xtream get.php link becomes server + login', () {
    final d = PlaylistDraft.parse('http://tv.example.com:8080/get.php?username=ali&password=s3cr%40t&type=m3u_plus&output=ts')!;
    expect(d.kind, SourceKind.xtream);
    expect(d.url, 'http://tv.example.com:8080');
    expect(d.username, 'ali');
    expect(d.password, 's3cr@t');
    expect(d.missing, isNull);
  });

  test('player_api and stream links are Xtream too', () {
    expect(PlaylistDraft.parse('https://x.io/player_api.php?username=a&password=b')!.kind, SourceKind.xtream);
    final s = PlaylistDraft.parse('http://x.io:80/live/user1/pass1/12345.ts')!;
    expect((s.kind, s.url, s.username, s.password), (SourceKind.xtream, 'http://x.io', 'user1', 'pass1'));
  });

  test('link inside a sentence is found', () {
    final d = PlaylistDraft.parse('Your playlist: http://p.tv/list.m3u8 (valid 12 months).')!;
    expect(d.kind, SourceKind.m3u);
    expect(d.url, 'http://p.tv/list.m3u8');
  });

  test('plain m3u links, file paths and bare hosts', () {
    expect(PlaylistDraft.parse('http://p.tv/get.php?type=m3u')!.kind, SourceKind.m3u); // no login
    expect(PlaylistDraft.parse(r'C:\Users\me\list.m3u')!.kind, SourceKind.m3u);
    expect(PlaylistDraft.parse('p.tv/list.m3u')!.url, 'http://p.tv/list.m3u');
    expect(PlaylistDraft.parse('hello there'), isNull);
    expect(PlaylistDraft.parse(''), isNull);
  });

  test('Stalker portal with MAC', () {
    final d = PlaylistDraft.parse('http://portal.tv:8080/c/ 00-1a-79-aa-bb-cc')!;
    expect(d.kind, SourceKind.stalker);
    expect(d.mac, '00:1A:79:AA:BB:CC');
    expect(d.missing, isNull);
    expect(PlaylistDraft.parse('http://portal.tv/stalker_portal/c/')!.missing, isNotNull);
  });

  test('phone page JSON', () {
    final link = PlaylistDraft.fromJson({'link': 'http://a.b/get.php?username=u&password=p', 'name': 'Home'})!;
    expect((link.kind, link.name), (SourceKind.xtream, 'Home'));
    final x = PlaylistDraft.fromJson({'kind': 'xtream', 'url': 'http://a.b:8080', 'username': 'u', 'password': ' p '})!;
    expect(x.password, ' p ');
    // Full link typed into the Xtream server box.
    final y = PlaylistDraft.fromJson({'kind': 'xtream', 'url': 'http://a.b/get.php?username=u&password=p'})!;
    expect((y.url, y.username), ('http://a.b', 'u'));
    expect(PlaylistDraft.fromJson({'kind': 'xtream', 'url': 'http://a.b'})!.missing, isNotNull);
    expect(PlaylistDraft.fromJson({'link': 'nope'}), isNull);
  });
}
