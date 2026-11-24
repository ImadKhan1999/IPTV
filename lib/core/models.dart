/// Data models shared by every IPTV source (M3U, Xtream Codes, Stalker portal).
library;

enum SourceKind { m3u, xtream, stalker }

extension SourceKindLabel on SourceKind {
  String get label => switch (this) {
    SourceKind.m3u => 'M3U playlist',
    SourceKind.xtream => 'Xtream Codes',
    SourceKind.stalker => 'Stalker portal',
  };
}

enum ContentType { live, movie, series }

/// A playlist the user added: everything needed to reconnect to it.
class PlaylistProfile {
  PlaylistProfile({
    required this.id,
    required this.name,
    required this.kind,
    required this.url,
    this.username = '',
    this.password = '',
    this.mac = '',
    this.serial = '',
    this.deviceId = '',
    this.deviceId2 = '',
    this.signature = '',
    this.stbModel = '',
    this.epgUrl = '',
    this.userAgent = '',
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  final String id;
  final String name;
  final SourceKind kind;

  /// M3U: playlist URL or local file path. Xtream: server URL. Stalker: portal URL.
  final String url;
  final String username;
  final String password;

  /// Stalker MAC address (00:1A:79:XX:XX:XX).
  final String mac;

  /// Stalker device identity. Some portals bind a subscription to the box's serial number,
  /// device IDs and signature as well as the MAC; leave empty to derive them from the MAC.
  final String serial;
  final String deviceId;
  final String deviceId2;
  final String signature;

  /// Stalker STB model reported to the portal (MAG250, MAG254, MAG322...). Empty means MAG250.
  final String stbModel;

  /// Optional XMLTV guide URL that overrides the one the source provides.
  final String epgUrl;

  /// Optional custom User-Agent for every request and stream.
  final String userAgent;
  final DateTime addedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'url': url,
    'username': username,
    'password': password,
    'mac': mac,
    'serial': serial,
    'deviceId': deviceId,
    'deviceId2': deviceId2,
    'signature': signature,
    'stbModel': stbModel,
    'epgUrl': epgUrl,
    'userAgent': userAgent,
    'addedAt': addedAt.toIso8601String(),
  };

  factory PlaylistProfile.fromJson(Map<String, dynamic> j) {
    String str(String k) => j[k] as String? ?? '';
    return PlaylistProfile(
      id: j['id'] as String,
      name: j['name'] as String? ?? 'Playlist',
      kind: SourceKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => SourceKind.m3u),
      url: str('url'),
      username: str('username'),
      password: str('password'),
      mac: str('mac'),
      serial: str('serial'),
      deviceId: str('deviceId'),
      deviceId2: str('deviceId2'),
      signature: str('signature'),
      stbModel: str('stbModel'),
      epgUrl: str('epgUrl'),
      userAgent: str('userAgent'),
      addedAt: DateTime.tryParse(str('addedAt')),
    );
  }
}

class Category {
  const Category({required this.id, required this.name, required this.type, this.isAdult = false});

  final String id;
  final String name;
  final ContentType type;
  final bool isAdult;

  /// Pseudo-category id that means "everything".
  static const allId = '__all__';
}

class Channel {
  const Channel({
    required this.id,
    required this.name,
    this.number,
    this.logo,
    this.categoryId = '',
    this.streamUrl,
    this.epgId,
    this.catchupDays = 0,
    this.catchupSource,
    this.headers = const {},
    this.extra = const {},
  });

  final String id;
  final String name;
  final int? number;
  final String? logo;
  final String categoryId;

  /// Direct stream URL when the source knows it up front (M3U, Xtream).
  final String? streamUrl;

  /// XMLTV channel id (tvg-id / epg_channel_id).
  final String? epgId;
  final int catchupDays;

  /// M3U catch-up template (catchup-source) if any.
  final String? catchupSource;

  /// Per-stream HTTP headers (User-Agent, Referer) from #EXTVLCOPT lines.
  final Map<String, String> headers;

  /// Source specific data (for example the Stalker `cmd`).
  final Map<String, String> extra;

  bool get hasCatchup => catchupDays > 0;
}

class Movie {
  const Movie({
    required this.id,
    required this.name,
    this.poster,
    this.categoryId = '',
    this.rating,
    this.year,
    this.plot,
    this.containerExt = 'mp4',
    this.streamUrl,
    this.headers = const {},
    this.extra = const {},
  });

  final String id;
  final String name;
  final String? poster;
  final String categoryId;
  final double? rating;
  final String? year;
  final String? plot;
  final String containerExt;
  final String? streamUrl;
  final Map<String, String> headers;
  final Map<String, String> extra;
}

class Series {
  const Series({
    required this.id,
    required this.name,
    this.poster,
    this.categoryId = '',
    this.rating,
    this.plot,
    this.year,
    this.extra = const {},
  });

  final String id;
  final String name;
  final String? poster;
  final String categoryId;
  final double? rating;
  final String? plot;
  final String? year;
  final Map<String, String> extra;
}

class Episode {
  const Episode({
    required this.id,
    required this.title,
    required this.season,
    required this.number,
    this.plot,
    this.image,
    this.durationSecs,
    this.containerExt = 'mp4',
    this.streamUrl,
    this.headers = const {},
    this.extra = const {},
  });

  final String id;
  final String title;
  final int season;
  final int number;
  final String? plot;
  final String? image;
  final int? durationSecs;
  final String containerExt;
  final String? streamUrl;
  final Map<String, String> headers;
  final Map<String, String> extra;
}

class SeriesDetails {
  const SeriesDetails({required this.series, required this.seasons});

  final Series series;

  /// Season number -> episodes, sorted.
  final Map<int, List<Episode>> seasons;
}

class EpgProgram {
  const EpgProgram({
    required this.channelId,
    required this.start,
    required this.end,
    required this.title,
    this.description = '',
    this.hasArchive = false,
  });

  final String channelId;
  final DateTime start;
  final DateTime end;
  final String title;
  final String description;
  final bool hasArchive;

  bool isLiveAt(DateTime t) => !t.isBefore(start) && t.isBefore(end);

  double progressAt(DateTime t) {
    final total = end.difference(start).inSeconds;
    if (total <= 0) return 0;
    return (t.difference(start).inSeconds / total).clamp(0.0, 1.0);
  }
}

/// A resolved, ready-to-play stream.
class PlayableStream {
  const PlayableStream(this.url, {this.headers = const {}, this.isLive = false, this.title = ''});

  final String url;
  final Map<String, String> headers;
  final bool isLive;
  final String title;
}

/// Account details reported by the provider (Xtream user_info, Stalker profile).
class AccountInfo {
  const AccountInfo({this.status, this.expiresAt, this.maxConnections, this.activeConnections, this.message});

  final String? status;
  final DateTime? expiresAt;
  final int? maxConnections;
  final int? activeConnections;
  final String? message;
}

class SourceException implements Exception {
  SourceException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}
