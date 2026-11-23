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

  /// Optional XMLTV guide URL that overrides the one the source provides.
  final String epgUrl;

  /// Optional custom User-Agent for every request and stream.
  final String userAgent;
  final DateTime addedAt;

  PlaylistProfile copyWith({
    String? name,
    String? url,
    String? username,
    String? password,
    String? mac,
    String? epgUrl,
    String? userAgent,
  }) => PlaylistProfile(
    id: id,
    name: name ?? this.name,
    kind: kind,
    url: url ?? this.url,
    username: username ?? this.username,
    password: password ?? this.password,
    mac: mac ?? this.mac,
    epgUrl: epgUrl ?? this.epgUrl,
    userAgent: userAgent ?? this.userAgent,
    addedAt: addedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'url': url,
    'username': username,
    'password': password,
    'mac': mac,
    'epgUrl': epgUrl,
    'userAgent': userAgent,
    'addedAt': addedAt.toIso8601String(),
  };

  factory PlaylistProfile.fromJson(Map<String, dynamic> j) => PlaylistProfile(
    id: j['id'] as String,
    name: j['name'] as String? ?? 'Playlist',
    kind: SourceKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => SourceKind.m3u),
    url: j['url'] as String? ?? '',
    username: j['username'] as String? ?? '',
    password: j['password'] as String? ?? '',
    mac: j['mac'] as String? ?? '',
    epgUrl: j['epgUrl'] as String? ?? '',
    userAgent: j['userAgent'] as String? ?? '',
    addedAt: DateTime.tryParse(j['addedAt'] as String? ?? ''),
  );
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
