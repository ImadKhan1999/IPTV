import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv/core/models.dart' show PlaylistProfile, SourceKind;
import 'package:iptv/core/playlist_link.dart';
import 'package:iptv/data/pairing_server.dart';

void main() {
  late PairingServer server;
  final client = HttpClient();

  setUp(() async => server = await PairingServer.start(key: 'testkey1', deviceName: 'Living room TV'));
  tearDown(() => server.close());

  Future<(int, String)> call(String method, String path, [Object? body]) async {
    final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    return (res.statusCode, await utf8.decoder.bind(res).join());
  }

  test('serves the phone page only with the key', () async {
    final (ok, page) = await call('GET', '/?k=testkey1');
    expect(ok, 200);
    expect(page, contains('Send to TV'));
    final (_, expired) = await call('GET', '/?k=wrong');
    expect(expired, contains('Scan the QR code again'));
  });

  test('phone sends a link and the app receives it', () async {
    final got = server.received.first;
    final (status, body) = await call('POST', '/send?k=testkey1', {'link': 'http://a.b:8080/get.php?username=u&password=p'});
    expect(status, 200, reason: body);
    final d = await got;
    expect((d.kind, d.url, d.username), (SourceKind.xtream, 'http://a.b:8080', 'u'));
  });

  test('rejects wrong key and incomplete details', () async {
    expect((await call('POST', '/send?k=nope', {'link': 'http://a.b/x.m3u'})).$1, 403);
    final (status, body) = await call('POST', '/send?k=testkey1', {'kind': 'stalker', 'url': 'http://p/c/'});
    expect(status, 400);
    expect(body, contains('MAC'));
  });

  test('another device finds this one and sends its playlists', () async {
    final (_, hello) = await call('GET', '/hello');
    final j = jsonDecode(hello) as Map;
    expect((j['app'], j['name'], j['k']), (PairingServer.appId, 'Living room TV', 'testkey1'));

    final got = server.imported.first;
    final p1 = PlaylistProfile(id: '1', name: 'Main', kind: SourceKind.xtream, url: 'http://a.b', username: 'u', password: 'p');
    final p2 = PlaylistProfile(id: '2', name: 'Local file', kind: SourceKind.m3u, url: '/data/x.m3u');
    await NearbyDevice(name: 'TV', address: '127.0.0.1', port: server.port, key: 'testkey1')
        .send(PlaylistTransfer(from: 'Bedroom TV', profiles: [p1, p2], activeId: '1'));
    final t = await got;
    expect(t.from, 'Bedroom TV');
    expect(t.activeId, '1');
    expect(t.profiles.map((p) => p.name), ['Main']); // local files stay behind
    expect(t.profiles.single.password, 'p');
  });

  test('draft fromJson ignores unknown kinds gracefully', () {
    expect(PlaylistDraft.fromJson({'kind': 'weird', 'url': 'http://a.b/list.m3u'})!.kind, SourceKind.m3u);
  });
}
