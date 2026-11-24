import 'models.dart';

/// Playlist details read from one pasted link, a QR code or the phone pairing page.
///
/// Fields left empty are simply not filled in on the add-playlist form.
class PlaylistDraft {
  const PlaylistDraft({
    required this.kind,
    required this.url,
    this.name = '',
    this.username = '',
    this.password = '',
    this.mac = '',
    this.epgUrl = '',
    this.userAgent = '',
    this.serial = '',
    this.deviceId = '',
    this.deviceId2 = '',
    this.signature = '',
    this.stbModel = '',
  });

  final SourceKind kind;
  final String url;
  final String name;
  final String username;
  final String password;
  final String mac;
  final String epgUrl;
  final String userAgent;
  final String serial;
  final String deviceId;
  final String deviceId2;
  final String signature;
  final String stbModel;

  bool get hasIdentity => [serial, deviceId, deviceId2, signature, stbModel].any((v) => v.isNotEmpty);

  /// Reads the JSON the phone pairing page sends. A bare `link` field is parsed like a pasted link.
  static PlaylistDraft? fromJson(Map<String, dynamic> j) {
    String s(String k) => (j[k] ?? '').toString().trim();
    final kindName = s('kind');
    final kind = SourceKind.values.where((k) => k.name == kindName).firstOrNull;
    final url = s('url');
    if (kind == null || url.isEmpty) {
      final link = s('link').isNotEmpty ? s('link') : url;
      final parsed = parse(link);
      if (parsed == null) return null;
      return parsed.copyWith(name: s('name'), epgUrl: s('epg'));
    }
    final draft = PlaylistDraft(
      kind: kind,
      url: url,
      name: s('name'),
      username: s('username'),
      password: (j['password'] ?? '').toString(),
      mac: s('mac').toUpperCase(),
      epgUrl: s('epg'),
      userAgent: s('userAgent'),
      serial: s('serial'),
      deviceId: s('deviceId'),
      deviceId2: s('deviceId2'),
      signature: s('signature'),
      stbModel: s('stbModel'),
    );
    // Someone picked "Xtream" but pasted the full get.php link into the server field.
    if (kind == SourceKind.xtream && draft.username.isEmpty) {
      final parsed = parse(url);
      if (parsed != null && parsed.kind == SourceKind.xtream) {
        return parsed.copyWith(name: draft.name, epgUrl: draft.epgUrl, userAgent: draft.userAgent);
      }
    }
    return draft;
  }

  /// Works out the playlist type from a single link, so nobody has to type a username and password.
  ///
  /// * `http://host:8080/get.php?username=u&password=p&type=m3u_plus` → Xtream (server + login)
  /// * `http://host:8080/player_api.php?username=u&password=p` → Xtream
  /// * `http://host:8080/live/u/p/123.ts` (any stream link) → Xtream
  /// * `http://host/c/` or `.../portal.php` / `stalker_portal` → Stalker portal (MAC still needed)
  /// * anything else that looks like a URL or file path → M3U playlist
  ///
  /// Returns null for text that isn't a link.
  static PlaylistDraft? parse(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    // A pasted line may carry other words around the link ("Your playlist: http://...").
    final found = RegExp(r'(https?|rtmp|rtsp)://\S+', caseSensitive: false).firstMatch(text);
    if (found != null) {
      text = found.group(0)!.replaceAll(RegExp(r'''[)\]>"',.;]+$'''), '');
    } else if (RegExp(r'^[\w.-]+\.[a-z]{2,}(:\d+)?(/\S*)?$', caseSensitive: false).hasMatch(text)) {
      text = 'http://$text';
    } else if (RegExp(r'^[a-zA-Z]:\\|^/|^file://').hasMatch(text) || text.toLowerCase().endsWith('.m3u') || text.toLowerCase().endsWith('.m3u8')) {
      return PlaylistDraft(kind: SourceKind.m3u, url: text);
    } else {
      return null;
    }

    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    final server = '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
    final path = uri.path.toLowerCase();
    final q = {for (final e in uri.queryParameters.entries) e.key.toLowerCase(): e.value};
    final user = q['username'] ?? '';
    final pass = q['password'] ?? '';

    if ((path.endsWith('/get.php') || path.endsWith('/player_api.php') || path.endsWith('/xmltv.php')) &&
        user.isNotEmpty &&
        pass.isNotEmpty) {
      return PlaylistDraft(kind: SourceKind.xtream, url: server, username: user, password: pass);
    }

    // http://host/live/user/pass/123.ts, /movie/user/pass/1.mp4, /series/..., or /user/pass/123
    final seg = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (seg.length == 4 && const {'live', 'movie', 'series', 'timeshift'}.contains(seg[0].toLowerCase()) && _looksLikeStreamId(seg[3])) {
      return PlaylistDraft(kind: SourceKind.xtream, url: server, username: seg[1], password: seg[2]);
    }

    if (path.contains('stalker_portal') || path.endsWith('/c') || path.endsWith('/c/') || path.endsWith('portal.php') || path.endsWith('load.php')) {
      final mac = RegExp(r'([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}').firstMatch(input)?.group(0)?.replaceAll('-', ':').toUpperCase() ?? '';
      return PlaylistDraft(kind: SourceKind.stalker, url: text, mac: mac);
    }

    return PlaylistDraft(kind: SourceKind.m3u, url: text);
  }

  static bool _looksLikeStreamId(String s) => RegExp(r'^\d+(\.\w{2,4})?$').hasMatch(s);

  PlaylistDraft copyWith({String? name, String? epgUrl, String? userAgent}) => PlaylistDraft(
    kind: kind,
    url: url,
    name: (name == null || name.isEmpty) ? this.name : name,
    username: username,
    password: password,
    mac: mac,
    epgUrl: (epgUrl == null || epgUrl.isEmpty) ? this.epgUrl : epgUrl,
    userAgent: (userAgent == null || userAgent.isEmpty) ? this.userAgent : userAgent,
    serial: serial,
    deviceId: deviceId,
    deviceId2: deviceId2,
    signature: signature,
    stbModel: stbModel,
  );

  /// What's missing before this can be connected, or null when it's complete.
  String? get missing => switch (kind) {
    SourceKind.xtream when username.isEmpty || password.isEmpty => 'Enter the username and password.',
    SourceKind.stalker when !RegExp(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(mac) => 'Enter the MAC address.',
    _ => null,
  };
}
