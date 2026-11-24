import 'dart:async';

import 'package:flutter/foundation.dart' hide Category;

import '../core/epg/xmltv.dart';
import '../core/models.dart';
import '../core/sources/iptv_source.dart';
import '../core/sources/m3u_source.dart';
import '../core/sources/stalker_source.dart';
import '../core/sources/xtream_source.dart';
import '../data/disk_cache.dart';
import '../data/library_store.dart';

enum SessionState { idle, connecting, ready, error }

/// The live connection to the active playlist, plus guide data and caches.
class Session extends ChangeNotifier {
  Session(this.store, {DiskCache? cache}) : cache = cache ?? DiskCache.memory();

  final LibraryStore store;

  /// Playlists, lists and guides saved between launches so the app opens instantly.
  final DiskCache cache;

  /// When the cached lists for the current playlist were downloaded.
  DateTime? cachedAt;

  IptvSource? source;
  AccountInfo? account;
  SessionState state = SessionState.idle;
  String? error;
  EpgGuide guide = EpgGuide.empty;
  bool guideLoading = false;

  /// Items per category (and the total under [Category.allId]) for each content type,
  /// filled in the background after connecting.
  final counts = <ContentType, Map<String, int>>{};

  int? total(ContentType t) => counts[t]?[Category.allId];

  final _epgCache = <String, ({DateTime at, List<EpgProgram> list})>{};
  Timer? _keepAlive;

  PlaylistProfile? get profile => source?.profile;

  /// Connects to [p]. Lists come from the disk cache when it has them; [refresh] downloads
  /// everything again (Settings > Refresh playlist).
  Future<bool> connect(PlaylistProfile p, {bool refresh = false}) async {
    disconnect();
    state = SessionState.connecting;
    error = null;
    notifyListeners();
    final s = IptvSource.create(p);
    if (s is XtreamSource) s.liveExtension = store.player.liveFormat;
    s.cachePolicy = CachePolicy(
      cache: cache,
      group: p.id,
      maxAge: Duration(hours: store.player.refreshHours),
      forceRefresh: refresh,
    );
    try {
      account = await s.connect();
      unawaited(
        cache.updatedAt(p.id).then((t) {
          cachedAt = t;
          notifyListeners();
        }),
      );
      source = s;
      state = SessionState.ready;
      await store.setActiveProfile(p.id);
      if (s is StalkerSource) {
        _keepAlive = Timer.periodic(const Duration(minutes: 2), (_) => s.keepAlive());
      }
      notifyListeners();
      unawaited(_loadGuide());
      unawaited(_loadCounts(s));
      return true;
    } catch (e) {
      s.dispose();
      error = e is SourceException ? e.message : 'Connection failed: $e';
      state = SessionState.error;
      notifyListeners();
      return false;
    }
  }

  void disconnect() {
    _keepAlive?.cancel();
    _keepAlive = null;
    source?.dispose();
    source = null;
    account = null;
    guide = EpgGuide.empty;
    cachedAt = null;
    counts.clear();
    _epgCache.clear();
    state = SessionState.idle;
  }

  /// Downloads the full XMLTV guide. Needed for M3U playlists; other sources use their API
  /// for now/next, so the full guide is only fetched for them when the user set one.
  Future<void> _loadGuide() async {
    final s = source;
    if (s == null) return;
    final url = s.xmltvUrl;
    final wantFull = s is M3uSource || s.profile.epgUrl.isNotEmpty;
    if (url == null || !wantFull) return;
    guideLoading = true;
    notifyListeners();
    try {
      final bytes = await s.cachedBytes('epg|$url', () => EpgGuide.fetchBytes(url, headers: s.defaultHeaders));
      if (source != s) return;
      // Big guides take a moment to parse; keep the UI smooth by doing it off the main thread.
      final g = kIsWeb ? EpgGuide.fromBytes(bytes) : await compute(EpgGuide.fromBytes, bytes);
      if (source != s) return;
      guide = g;
      if (s is M3uSource) s.guide = g;
    } catch (e) {
      debugPrint('Guide failed: $e');
    } finally {
      guideLoading = false;
      notifyListeners();
    }
  }

  Future<void> _loadCounts(IptvSource s) async {
    for (final type in ContentType.values) {
      if (type == ContentType.movie && !s.features.contains(SourceFeature.movies)) continue;
      if (type == ContentType.series && !s.features.contains(SourceFeature.series)) continue;
      try {
        final c = await s.categoryCounts(type);
        if (source != s) return;
        if (c != null) {
          counts[type] = c;
          notifyListeners();
        }
      } catch (e) {
        debugPrint('Counting $type failed: $e');
      }
    }
  }

  Future<void> reloadGuide() => _loadGuide();

  /// Now/next for a channel: full guide first, then the provider API, cached for 5 minutes.
  Future<List<EpgProgram>> epgFor(Channel c, {int limit = 6}) async {
    final fromGuide = guide.upcoming(c.epgId, channelName: c.name, limit: limit);
    if (fromGuide.isNotEmpty) return fromGuide;
    final s = source;
    if (s == null || s is M3uSource) return const [];
    final hit = _epgCache[c.id];
    if (hit != null && DateTime.now().difference(hit.at) < const Duration(minutes: 5)) return hit.list;
    try {
      final list = await s.shortEpg(c, limit: limit);
      _epgCache[c.id] = (at: DateTime.now(), list: list);
      return list;
    } catch (_) {
      return const [];
    }
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
