import 'package:http/http.dart' as http;

import '../models.dart';
import 'm3u_source.dart';
import 'stalker_source.dart';
import 'xtream_source.dart';

enum SourceFeature { live, movies, series, epg, catchup }

/// One provider connection. Every playlist type implements this, so the UI never
/// needs to know whether it is talking to an M3U file, Xtream Codes or a Stalker portal.
abstract class IptvSource {
  IptvSource(this.profile, {http.Client? client}) : client = client ?? http.Client();

  final PlaylistProfile profile;
  final http.Client client;

  Set<SourceFeature> get features;

  /// Logs in / downloads the playlist. Throws [SourceException] with a readable message.
  Future<AccountInfo?> connect();

  Future<List<Category>> categories(ContentType type);

  /// Live channels in [categoryId], or all channels when it is [Category.allId].
  Future<List<Channel>> channels(String categoryId);

  Future<List<Movie>> movies(String categoryId);

  Future<List<Series>> series(String categoryId);

  Future<SeriesDetails> seriesDetails(Series series);

  /// Now / next programmes for a channel. Empty when no guide data is available.
  Future<List<EpgProgram>> shortEpg(Channel channel, {int limit = 6});

  Future<PlayableStream> resolveChannel(Channel channel);

  Future<PlayableStream> resolveMovie(Movie movie);

  Future<PlayableStream> resolveEpisode(Episode episode);

  /// How many items each category holds, keyed by category id, with the overall total under
  /// [Category.allId]. A source may return only the total, or null when counting would mean
  /// downloading everything.
  Future<Map<String, int>?> categoryCounts(ContentType type) async => null;

  /// Counts items per category id and adds the total under [Category.allId].
  static Map<String, int> countByCategory(Iterable<String> categoryIds) {
    final out = <String, int>{};
    var total = 0;
    for (final id in categoryIds) {
      out[id] = (out[id] ?? 0) + 1;
      total++;
    }
    out[Category.allId] = total;
    return out;
  }

  /// Catch-up (timeshift) URL for a past programme, or null when unsupported.
  Future<PlayableStream?> resolveCatchup(Channel channel, EpgProgram program) async => null;

  /// XMLTV guide URL for full-guide downloads, if known.
  String? get xmltvUrl => profile.epgUrl.isNotEmpty ? profile.epgUrl : null;

  Map<String, String> get defaultHeaders => profile.userAgent.isNotEmpty ? {'User-Agent': profile.userAgent} : const {};

  void dispose() => client.close();

  static IptvSource create(PlaylistProfile profile, {http.Client? client}) => switch (profile.kind) {
    SourceKind.m3u => M3uSource(profile, client: client),
    SourceKind.xtream => XtreamSource(profile, client: client),
    SourceKind.stalker => StalkerSource(profile, client: client),
  };
}

/// Normalises a user-typed server address: adds http:// and strips trailing slashes.
String normalizeServerUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) return s;
  if (!s.contains('://')) s = 'http://$s';
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// Words that mark a category as adult content for the parental filter.
final _adultPattern = RegExp(r'\b(adult|xxx|18\+|\+18|porn|for adults)\b', caseSensitive: false);

bool looksAdult(String name) => _adultPattern.hasMatch(name);
