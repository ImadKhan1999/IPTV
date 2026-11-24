import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import '../core/models.dart' show PlaylistProfile, SourceKind, SourceKindLabel;
import '../core/playlist_link.dart';

/// Lets a phone on the same Wi-Fi send a playlist to this device.
///
/// The TV shows a QR code with `http://<tv-ip>:<port>/?k=<key>`. The phone opens that page,
/// pastes the link (or fills in Xtream/Stalker details, or picks an .m3u file) and taps Send.
/// The page POSTs to this server, which hands the playlist to the app through [received].
///
/// The server only runs while the pairing card is on screen, and requests without the
/// random key are refused, so other devices on the network can't push playlists.
class PairingServer {
  PairingServer._(this._server, this.key, this.addresses, this.deviceName);

  /// Shown on the sending device's list ("Living room TV").
  final String deviceName;

  final HttpServer _server;

  /// Random key carried in the QR code; every request must include it.
  final String key;

  /// This device's local network addresses (best guess first).
  final List<String> addresses;

  final _received = StreamController<PlaylistDraft>.broadcast();
  final _imported = StreamController<PlaylistTransfer>.broadcast();

  /// Playlists sent from another iPTV device ("Send playlists to another device").
  Stream<PlaylistTransfer> get imported => _imported.stream;

  /// Playlists sent from the phone.
  Stream<PlaylistDraft> get received => _received.stream;

  int get port => _server.port;

  /// The link the QR code holds, or null when the device has no network address.
  String? get url => addresses.isEmpty ? null : 'http://${addresses.first}:$port/?k=$key';

  /// Short address shown under the QR code for typing on a computer browser.
  String? get shortUrl => addresses.isEmpty ? null : '${addresses.first}:$port';

  static const preferredPort = 8765;

  /// Marks the `/hello` answer so other apps on port [preferredPort] are ignored.
  static const appId = 'iptv-imadlabs';

  static Future<PairingServer> start({String? key, String deviceName = 'iPTV device'}) async {
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort, shared: true);
    } on SocketException {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    final rnd = Random.secure();
    const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
    final k = key ?? List.generate(8, (_) => alphabet[rnd.nextInt(alphabet.length)]).join();
    final p = PairingServer._(server, k, await localAddresses(), deviceName);
    p._listen();
    return p;
  }

  /// Local IPv4 addresses, Wi-Fi/Ethernet first, skipping loopback and link-local ones.
  static Future<List<String>> localAddresses() async {
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      final scored = <(int, String)>[];
      for (final i in ifaces) {
        final n = i.name.toLowerCase();
        for (final a in i.addresses) {
          final ip = a.address;
          if (a.isLoopback || ip.startsWith('169.254.')) continue;
          var score = 0;
          if (ip.startsWith('192.168.')) score += 3;
          if (ip.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip)) score += 2;
          if (n.contains('wlan') || n.contains('wi-fi') || n.contains('wifi') || n.contains('eth') || n.contains('ethernet')) {
            score += 2;
          }
          if (n.contains('vethernet') || n.contains('virtual') || n.contains('vbox') || n.contains('vmware') || n.contains('docker') || n.contains('tun') || n.contains('wsl')) {
            score -= 4;
          }
          scored.add((score, ip));
        }
      }
      scored.sort((a, b) => b.$1.compareTo(a.$1));
      return [for (final s in scored) s.$2];
    } catch (_) {
      return const [];
    }
  }

  void _listen() {
    _server.listen((req) async {
      try {
        await _handle(req);
      } catch (_) {
        try {
          req.response.statusCode = HttpStatus.internalServerError;
          await req.response.close();
        } catch (_) {}
      }
    });
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set('Cache-Control', 'no-store');
    final authorised = req.uri.queryParameters['k'] == key;
    if (req.method == 'GET' && (req.uri.path == '/' || req.uri.path == '/index.html')) {
      res.headers.contentType = ContentType.html;
      res.write(authorised ? pairingPage : _expiredPage);
      await res.close();
      return;
    }
    if (req.method == 'GET' && req.uri.path == '/hello') {
      // Lets "Send playlists to another device" find this screen on the network.
      return _json(res, 200, {'app': appId, 'v': 1, 'name': deviceName, 'k': key});
    }
    if (req.method == 'POST' && req.uri.path == '/import') {
      if (!authorised) return _json(res, 403, {'ok': false, 'error': 'expired'});
      final body = await utf8.decoder.bind(req).join().timeout(const Duration(seconds: 30));
      if (body.length > 1024 * 1024) return _json(res, 413, {'ok': false, 'error': 'Too large.'});
      final t = PlaylistTransfer.fromJson((jsonDecode(body) as Map).cast<String, dynamic>());
      if (t.profiles.isEmpty) return _json(res, 400, {'ok': false, 'error': 'No playlists.'});
      _imported.add(t);
      return _json(res, 200, {'ok': true, 'count': t.profiles.length});
    }
    if (req.method == 'POST' && req.uri.path == '/send') {
      if (!authorised) return _json(res, 403, {'ok': false, 'error': 'This code has expired. Scan the QR code on the TV again.'});
      final body = await utf8.decoder.bind(req).join().timeout(const Duration(seconds: 30));
      if (body.length > 64 * 1024) return _json(res, 413, {'ok': false, 'error': 'Too large.'});
      final draft = PlaylistDraft.fromJson((jsonDecode(body) as Map).cast<String, dynamic>());
      if (draft == null) return _json(res, 400, {'ok': false, 'error': 'That doesn\'t look like a playlist link.'});
      final missing = draft.missing;
      if (missing != null) return _json(res, 400, {'ok': false, 'error': missing});
      _received.add(draft);
      return _json(res, 200, {'ok': true, 'kind': draft.kind.label});
    }
    if (req.method == 'POST' && req.uri.path == '/upload') {
      if (!authorised) return _json(res, 403, {'ok': false, 'error': 'This code has expired. Scan the QR code on the TV again.'});
      // Raw .m3u file body. Keep it on this device and add it as a local playlist.
      final bytes = <int>[];
      await for (final chunk in req) {
        bytes.addAll(chunk);
        if (bytes.length > 80 * 1024 * 1024) return _json(res, 413, {'ok': false, 'error': 'File is too large.'});
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!text.trimLeft().startsWith('#EXTM3U') && !text.contains('#EXTINF')) {
        return _json(res, 400, {'ok': false, 'error': 'That file isn\'t an M3U playlist.'});
      }
      final name = (req.uri.queryParameters['name'] ?? '').trim();
      final dir = await getApplicationSupportDirectory();
      final folder = Directory('${dir.path}${Platform.pathSeparator}playlists');
      await folder.create(recursive: true);
      final file = File('${folder.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}.m3u');
      await file.writeAsBytes(bytes, flush: true);
      _received.add(PlaylistDraft(kind: SourceKind.m3u, url: file.path, name: name.replaceAll(RegExp(r'\.m3u8?$', caseSensitive: false), '')));
      return _json(res, 200, {'ok': true, 'kind': 'M3U file'});
    }
    res.statusCode = HttpStatus.notFound;
    await res.close();
  }

  Future<void> _json(HttpResponse res, int status, Map<String, dynamic> body) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }

  Future<void> close() async {
    await _received.close();
    await _imported.close();
    await _server.close(force: true);
  }

  static const _expiredPage = '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>iPTV</title>
<style>body{font-family:system-ui,sans-serif;background:#070B14;color:#E8EEF8;display:grid;place-items:center;min-height:100vh;margin:0;padding:24px;text-align:center}</style>
</head><body><div><h2>Scan the QR code again</h2><p style="color:#93A0B8">This link has expired. Open <b>Add playlist → Use your phone</b> on the TV and scan the new code.</p></div></body></html>''';

  /// The page the phone opens. Plain HTML + JS, no external files, so it works offline on the LAN.
  static const pairingPage = r'''<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="dark">
<title>Send playlist to iPTV</title>
<style>
:root{--bg:#070B14;--card:#0F1626;--line:#1E2A40;--text:#E8EEF8;--muted:#93A0B8;--mint:#2EE6A6;--err:#FF6B7A}
*{box-sizing:border-box}
body{margin:0;background:radial-gradient(120% 80% at 0% 0%,#111C33,var(--bg));color:var(--text);font:16px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;min-height:100vh;padding:20px 16px 40px}
main{max-width:480px;margin:0 auto}
h1{font-size:22px;margin:8px 0 4px}
p.sub{color:var(--muted);margin:0 0 20px}
.brand{font-weight:800;letter-spacing:.2px}.brand b{color:var(--mint)}
.tabs{display:grid;grid-template-columns:repeat(4,1fr);gap:6px;margin-bottom:16px}
.tabs button{padding:10px 4px;border-radius:10px;border:1px solid var(--line);background:var(--card);color:var(--muted);font-weight:600;font-size:14px}
.tabs button.on{border-color:var(--mint);color:var(--text);background:rgba(46,230,166,.12)}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:18px}
label{display:block;font-size:13px;color:var(--muted);margin:12px 0 6px}
label:first-child{margin-top:0}
input,textarea{width:100%;padding:13px 14px;border-radius:10px;border:1px solid var(--line);background:#0A1120;color:var(--text);font:inherit;font-size:16px}
textarea{min-height:110px;resize:vertical}
input:focus,textarea:focus{outline:2px solid var(--mint);border-color:transparent}
.row{display:flex;gap:8px}.row>*{flex:1}
.hint{font-size:13px;color:var(--muted);margin-top:8px}
.btn{width:100%;margin-top:18px;padding:15px;border:0;border-radius:12px;background:var(--mint);color:#04130D;font-weight:800;font-size:17px}
.btn:disabled{opacity:.6}
.ghost{background:transparent;border:1px solid var(--line);color:var(--text);padding:10px 12px;border-radius:10px;font-weight:600;margin-top:8px;width:auto}
.msg{margin-top:14px;padding:12px 14px;border-radius:10px;display:none}
.msg.ok{display:block;background:rgba(46,230,166,.12);color:var(--mint)}
.msg.err{display:block;background:rgba(255,107,122,.12);color:var(--err)}
.hide{display:none}
[data-p=common]{margin-top:14px}
details{margin-top:12px;color:var(--muted)}summary{cursor:pointer;font-size:14px}
</style></head>
<body><main>
<div class="brand">iPTV <span style="color:var(--muted);font-weight:500">by Imad<b>Labs</b></span></div>
<h1>Send a playlist to your TV</h1>
<p class="sub">Paste your link here. The TV adds it and connects by itself.</p>
<div class="tabs" role="tablist">
  <button data-t="link" class="on">Link</button>
  <button data-t="xtream">Xtream</button>
  <button data-t="stalker">Stalker</button>
  <button data-t="file">File</button>
</div>
<form id="f" class="card" autocomplete="off">
  <div data-p="link">
    <label for="link">M3U or Xtream link</label>
    <textarea id="link" placeholder="http://provider.com/get.php?username=…&password=…&type=m3u_plus"></textarea>
    <button type="button" class="ghost" id="paste">Paste from clipboard</button>
    <div class="hint">Xtream links with a username and password are recognised automatically.</div>
  </div>
  <div data-p="xtream" class="hide">
    <label for="xurl">Server URL</label><input id="xurl" inputmode="url" placeholder="http://provider.com:8080">
    <label for="xuser">Username</label><input id="xuser" autocapitalize="off">
    <label for="xpass">Password</label><input id="xpass" type="password" autocapitalize="off">
  </div>
  <div data-p="stalker" class="hide">
    <label for="surl">Portal URL</label><input id="surl" inputmode="url" placeholder="http://portal.com:8080/c/">
    <label for="smac">MAC address</label><input id="smac" placeholder="00:1A:79:XX:XX:XX" autocapitalize="characters">
    <details><summary>Device IDs (only if your provider needs them)</summary>
      <label for="ssn">Serial number</label><input id="ssn">
      <label for="sid">Device ID</label><input id="sid">
      <label for="sid2">Device ID 2</label><input id="sid2">
      <label for="ssig">Signature</label><input id="ssig">
      <label for="smodel">STB model</label><input id="smodel" placeholder="MAG250">
    </details>
  </div>
  <div data-p="file" class="hide">
    <label for="file">.m3u file on this phone</label>
    <input id="file" type="file" accept=".m3u,.m3u8,audio/x-mpegurl,application/x-mpegurl,text/plain">
    <div class="hint">The file is copied to the TV.</div>
  </div>
  <div data-p="common">
    <label for="name">Name (optional)</label><input id="name" placeholder="My provider">
    <details id="adv"><summary>EPG and User-Agent (optional)</summary>
      <label for="epg">EPG (XMLTV) URL</label><input id="epg" inputmode="url">
      <label for="ua">User-Agent</label><input id="ua">
    </details>
  </div>
  <button class="btn" id="go" type="submit">Send to TV</button>
  <div id="msg" class="msg"></div>
</form>
</main>
<script>
const k=new URLSearchParams(location.search).get('k')||'';
const $=id=>document.getElementById(id);
let tab='link';
document.querySelectorAll('.tabs button').forEach(b=>b.onclick=()=>{
  tab=b.dataset.t;
  document.querySelectorAll('.tabs button').forEach(x=>x.classList.toggle('on',x===b));
  document.querySelectorAll('[data-p]').forEach(p=>{if(p.dataset.p!=='common')p.classList.toggle('hide',p.dataset.p!==tab)});
  $('adv').classList.toggle('hide',tab==='file');
  msg('');
});
$('paste').onclick=async()=>{try{$('link').value=(await navigator.clipboard.readText()).trim()}catch(e){$('link').focus();msg('Long-press the box and choose Paste.','err')}};
if(!(navigator.clipboard&&navigator.clipboard.readText))$('paste').classList.add('hide');
function msg(t,c){const m=$('msg');m.textContent=t;m.className='msg'+(t?' '+c:'')}
$('f').onsubmit=async e=>{
  e.preventDefault();
  const go=$('go');go.disabled=true;msg('Sending…','ok');
  try{
    let r;
    if(tab==='file'){
      const f=$('file').files[0];
      if(!f){msg('Choose a file first.','err');go.disabled=false;return}
      r=await fetch('/upload?k='+encodeURIComponent(k)+'&name='+encodeURIComponent($('name').value||f.name),{method:'POST',body:f});
    }else{
      const v=id=>$(id).value.trim();
      let body={name:v('name'),epg:v('epg'),userAgent:v('ua')};
      if(tab==='link'){if(!v('link')){msg('Paste a link first.','err');go.disabled=false;return}body.link=v('link')}
      if(tab==='xtream')Object.assign(body,{kind:'xtream',url:v('xurl'),username:v('xuser'),password:$('xpass').value});
      if(tab==='stalker')Object.assign(body,{kind:'stalker',url:v('surl'),mac:v('smac'),serial:v('ssn'),deviceId:v('sid'),deviceId2:v('sid2'),signature:v('ssig'),stbModel:v('smodel')});
      r=await fetch('/send?k='+encodeURIComponent(k),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    }
    const j=await r.json().catch(()=>({}));
    if(r.ok&&j.ok){msg('Sent! Look at your TV, it\'s connecting now.','ok')}
    else msg(j.error||'The TV didn\'t accept it. Try again.','err');
  }catch(err){msg('Can\'t reach the TV. Make sure your phone is on the same Wi-Fi and the QR code is still on screen.','err')}
  go.disabled=false;
};
</script>
</body></html>''';
}

/// Playlists copied from one iPTV device to another.
class PlaylistTransfer {
  PlaylistTransfer({required this.from, required this.profiles, this.activeId});

  final String from;
  final List<PlaylistProfile> profiles;
  final String? activeId;

  Map<String, dynamic> toJson() => {
    'from': from,
    'active': activeId,
    'profiles': [for (final p in profiles) p.toJson()],
  };

  factory PlaylistTransfer.fromJson(Map<String, dynamic> j) {
    final list = <PlaylistProfile>[];
    for (final e in (j['profiles'] as List? ?? const [])) {
      try {
        final p = PlaylistProfile.fromJson((e as Map).cast<String, dynamic>());
        // Local M3U files live on the other device; they can't be opened here.
        final local = p.kind == SourceKind.m3u && !RegExp(r'^[a-z]+://', caseSensitive: false).hasMatch(p.url);
        if (!local && p.url.isNotEmpty) list.add(p);
      } catch (_) {}
    }
    return PlaylistTransfer(from: (j['from'] ?? '').toString(), profiles: list, activeId: j['active'] as String?);
  }
}

/// Another device showing its "add playlist" screen, found on the local network.
class NearbyDevice {
  const NearbyDevice({required this.name, required this.address, required this.port, required this.key});

  final String name;
  final String address;
  final int port;
  final String key;

  /// Copies [transfer] to this device. Throws with a readable message on failure.
  Future<void> send(PlaylistTransfer transfer) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.postUrl(Uri.parse('http://$address:$port/import?k=$key'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(transfer.toJson()));
      final res = await req.close().timeout(const Duration(seconds: 15));
      final body = await utf8.decoder.bind(res).join();
      if (res.statusCode != 200) {
        throw Exception(res.statusCode == 403 ? 'That screen was closed on $name. Open it again and retry.' : 'Not accepted ($body)');
      }
    } finally {
      client.close(force: true);
    }
  }
}

/// Finds devices on the same network that have the add-playlist screen (and its QR code) open.
///
/// Asks every address in this device's /24 subnet(s) on [PairingServer.preferredPort];
/// this avoids UDP broadcast, which many Android TVs and routers drop.
Stream<NearbyDevice> discoverNearby({Duration timeout = const Duration(milliseconds: 1500)}) async* {
  final own = (await PairingServer.localAddresses()).toSet();
  final subnets = {
    for (final ip in own)
      if (RegExp(r'^(\d+\.){3}\d+$').hasMatch(ip)) ip.substring(0, ip.lastIndexOf('.')),
  };
  final found = StreamController<NearbyDevice>();
  final client = HttpClient()..connectionTimeout = timeout;
  var pending = 0;
  void done() {
    if (--pending == 0) {
      client.close(force: true);
      found.close();
    }
  }

  for (final net in subnets.take(3)) {
    for (var i = 1; i < 255; i++) {
      final ip = '$net.$i';
      if (own.contains(ip)) continue;
      pending++;
      () async {
        try {
          final req = await client.getUrl(Uri.parse('http://$ip:${PairingServer.preferredPort}/hello'));
          final res = await req.close().timeout(timeout);
          final j = jsonDecode(await utf8.decoder.bind(res).join().timeout(timeout));
          if (j is Map && j['app'] == PairingServer.appId) {
            found.add(NearbyDevice(
              name: (j['name'] ?? ip).toString(),
              address: ip,
              port: PairingServer.preferredPort,
              key: (j['k'] ?? '').toString(),
            ));
          }
        } catch (_) {
        } finally {
          done();
        }
      }();
    }
  }
  if (pending == 0) {
    client.close(force: true);
    await found.close();
  }
  yield* found.stream;
}
