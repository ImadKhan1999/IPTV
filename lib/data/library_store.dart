import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' hide Category;
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';

/// A saved reference to a channel, movie or series (favorites, history).
class SavedItem {
  SavedItem({
    required this.profileId,
    required this.type,
    required this.id,
    required this.name,
    this.image,
    this.categoryId = '',
    this.streamUrl,
    this.epgId,
    this.catchupDays = 0,
    this.headers = const {},
    this.extra = const {},
    this.positionMs = 0,
    this.durationMs = 0,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String profileId;
  final ContentType type;
  final String id;
  final String name;
  final String? image;
  final String categoryId;
  final String? streamUrl;
  final String? epgId;
  final int catchupDays;
  final Map<String, String> headers;
  final Map<String, String> extra;
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;

  String get key => '$profileId|${type.name}|$id';

  double get progress => durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0, 1);

  factory SavedItem.channel(String profileId, Channel c) => SavedItem(
    profileId: profileId,
    type: ContentType.live,
    id: c.id,
    name: c.name,
    image: c.logo,
    categoryId: c.categoryId,
    streamUrl: c.streamUrl,
    epgId: c.epgId,
    catchupDays: c.catchupDays,
    headers: c.headers,
    extra: {
      ...c.extra,
      if (c.number != null) '_number': '${c.number}',
      if (c.catchupSource != null) '_catchupSource': c.catchupSource!,
    },
  );

  factory SavedItem.movie(String profileId, Movie m) => SavedItem(
    profileId: profileId,
    type: ContentType.movie,
    id: m.id,
    name: m.name,
    image: m.poster,
    categoryId: m.categoryId,
    streamUrl: m.streamUrl,
    headers: m.headers,
    extra: {...m.extra, '_ext': m.containerExt, if (m.year != null) '_year': m.year!},
  );

  factory SavedItem.series(String profileId, Series s) => SavedItem(
    profileId: profileId,
    type: ContentType.series,
    id: s.id,
    name: s.name,
    image: s.poster,
    categoryId: s.categoryId,
    extra: {...s.extra, if (s.plot != null) '_plot': s.plot!},
  );

  Channel toChannel() => Channel(
    id: id,
    name: name,
    number: int.tryParse(extra['_number'] ?? ''),
    logo: image,
    categoryId: categoryId,
    streamUrl: streamUrl,
    epgId: epgId,
    catchupDays: catchupDays,
    catchupSource: extra['_catchupSource'],
    headers: headers,
    extra: extra,
  );

  Movie toMovie() => Movie(
    id: id,
    name: name,
    poster: image,
    categoryId: categoryId,
    streamUrl: streamUrl,
    containerExt: extra['_ext'] ?? 'mp4',
    year: extra['_year'],
    headers: headers,
    extra: extra,
  );

  Series toSeries() =>
      Series(id: id, name: name, poster: image, categoryId: categoryId, plot: extra['_plot'], extra: extra);

  SavedItem withProgress(int positionMs, int durationMs) => SavedItem(
    profileId: profileId,
    type: type,
    id: id,
    name: name,
    image: image,
    categoryId: categoryId,
    streamUrl: streamUrl,
    epgId: epgId,
    catchupDays: catchupDays,
    headers: headers,
    extra: extra,
    positionMs: positionMs,
    durationMs: durationMs,
  );

  Map<String, dynamic> toJson() => {
    'profileId': profileId,
    'type': type.name,
    'id': id,
    'name': name,
    'image': image,
    'categoryId': categoryId,
    'streamUrl': streamUrl,
    'epgId': epgId,
    'catchupDays': catchupDays,
    'headers': headers,
    'extra': extra,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory SavedItem.fromJson(Map<String, dynamic> j) => SavedItem(
    profileId: j['profileId'] as String,
    type: ContentType.values.firstWhere((t) => t.name == j['type'], orElse: () => ContentType.live),
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    image: j['image'] as String?,
    categoryId: j['categoryId'] as String? ?? '',
    streamUrl: j['streamUrl'] as String?,
    epgId: j['epgId'] as String?,
    catchupDays: j['catchupDays'] as int? ?? 0,
    headers: (j['headers'] as Map?)?.cast<String, String>() ?? const {},
    extra: (j['extra'] as Map?)?.cast<String, String>() ?? const {},
    positionMs: j['positionMs'] as int? ?? 0,
    durationMs: j['durationMs'] as int? ?? 0,
    updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
  );
}

class PlayerSettings {
  const PlayerSettings({
    this.hardwareDecoding = true,
    this.bufferSeconds = 8,
    this.autoPlayNextEpisode = true,
    this.rememberPosition = true,
    this.liveFormat = 'ts',
    this.refreshHours = 24,
    this.startOnLastChannel = true,
  });

  final bool hardwareDecoding;
  final int bufferSeconds;
  final bool autoPlayNextEpisode;
  final bool rememberPosition;
  final String liveFormat;

  /// How long downloaded playlists and guides are used before the app checks the provider
  /// again (in the background). 0 means check on every launch.
  final int refreshHours;

  /// Open straight into the channel watched last, playing.
  final bool startOnLastChannel;

  PlayerSettings copyWith({
    bool? hardwareDecoding,
    int? bufferSeconds,
    bool? autoPlayNextEpisode,
    bool? rememberPosition,
    String? liveFormat,
    int? refreshHours,
    bool? startOnLastChannel,
  }) => PlayerSettings(
    hardwareDecoding: hardwareDecoding ?? this.hardwareDecoding,
    bufferSeconds: bufferSeconds ?? this.bufferSeconds,
    autoPlayNextEpisode: autoPlayNextEpisode ?? this.autoPlayNextEpisode,
    rememberPosition: rememberPosition ?? this.rememberPosition,
    liveFormat: liveFormat ?? this.liveFormat,
    refreshHours: refreshHours ?? this.refreshHours,
    startOnLastChannel: startOnLastChannel ?? this.startOnLastChannel,
  );

  Map<String, dynamic> toJson() => {
    'hardwareDecoding': hardwareDecoding,
    'bufferSeconds': bufferSeconds,
    'autoPlayNextEpisode': autoPlayNextEpisode,
    'rememberPosition': rememberPosition,
    'liveFormat': liveFormat,
    'refreshHours': refreshHours,
    'startOnLastChannel': startOnLastChannel,
  };

  factory PlayerSettings.fromJson(Map<String, dynamic> j) => PlayerSettings(
    hardwareDecoding: j['hardwareDecoding'] as bool? ?? true,
    bufferSeconds: j['bufferSeconds'] as int? ?? 8,
    autoPlayNextEpisode: j['autoPlayNextEpisode'] as bool? ?? true,
    rememberPosition: j['rememberPosition'] as bool? ?? true,
    liveFormat: j['liveFormat'] as String? ?? 'ts',
    refreshHours: j['refreshHours'] as int? ?? 24,
    startOnLastChannel: j['startOnLastChannel'] as bool? ?? true,
  );
}

/// A user-made list of live channels ("Sports", "Kids"…), kept in the user's order.
class ChannelGroup {
  ChannelGroup({required this.id, required this.profileId, required this.name, List<String>? channelIds})
    : channelIds = channelIds ?? [];

  final String id;
  final String profileId;
  String name;
  final List<String> channelIds;

  Map<String, dynamic> toJson() => {'id': id, 'profileId': profileId, 'name': name, 'channelIds': channelIds};

  factory ChannelGroup.fromJson(Map<String, dynamic> j) => ChannelGroup(
    id: j['id'] as String,
    profileId: j['profileId'] as String,
    name: j['name'] as String? ?? 'Group',
    channelIds: (j['channelIds'] as List? ?? []).cast<String>().toList(),
  );
}

/// Everything the app persists, stored as one JSON file in the app support folder.
/// Writes are debounced and atomic (write temp file, then rename).
class LibraryStore extends ChangeNotifier {
  LibraryStore._(this._file);

  /// In-memory store for tests.
  LibraryStore.memory() : _file = null;

  final File? _file;

  final List<PlaylistProfile> profiles = [];
  final Map<String, SavedItem> _favorites = {};
  final Map<String, SavedItem> _history = {};
  final Set<String> lockedCategories = {};
  final List<ChannelGroup> _groups = [];
  final Set<String> _hidden = {};

  /// Favorites in the user's order, per "profileId|type".
  final Map<String, List<String>> _favOrder = {};
  DateTime? lastUpdateCheck;
  String? activeProfileId;
  String? _pinHash;
  bool hideAdult = true;
  PlayerSettings player = const PlayerSettings();

  static Future<LibraryStore> open() async {
    final dir = await getApplicationSupportDirectory();
    final store = LibraryStore._(File('${dir.path}${Platform.pathSeparator}library.json'));
    await store._load();
    return store;
  }

  Future<void> _load() async {
    final f = _file;
    if (f == null || !await f.exists()) return;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      profiles.addAll((j['profiles'] as List? ?? []).map((e) => PlaylistProfile.fromJson((e as Map).cast())));
      for (final e in (j['favorites'] as List? ?? [])) {
        final item = SavedItem.fromJson((e as Map).cast());
        _favorites[item.key] = item;
      }
      for (final e in (j['history'] as List? ?? [])) {
        final item = SavedItem.fromJson((e as Map).cast());
        _history[item.key] = item;
      }
      lockedCategories.addAll((j['lockedCategories'] as List? ?? []).cast<String>());
      _groups.addAll((j['groups'] as List? ?? []).map((e) => ChannelGroup.fromJson((e as Map).cast())));
      _hidden.addAll((j['hidden'] as List? ?? []).cast<String>());
      ((j['favOrder'] as Map?) ?? {}).forEach((k, v) => _favOrder['$k'] = (v as List).cast<String>().toList());
      lastUpdateCheck = DateTime.tryParse(j['lastUpdateCheck'] as String? ?? '');
      activeProfileId = j['activeProfileId'] as String?;
      _pinHash = j['pinHash'] as String?;
      hideAdult = j['hideAdult'] as bool? ?? true;
      player = PlayerSettings.fromJson((j['player'] as Map?)?.cast() ?? {});
    } catch (e) {
      debugPrint('library.json could not be read: $e');
    }
  }

  bool _saving = false;
  bool _dirty = false;

  Future<void> _save() async {
    notifyListeners();
    final f = _file;
    if (f == null) return;
    _dirty = true;
    if (_saving) return;
    _saving = true;
    try {
      while (_dirty) {
        _dirty = false;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final json = jsonEncode({
          'version': 1,
          'profiles': profiles.map((p) => p.toJson()).toList(),
          'favorites': _favorites.values.map((e) => e.toJson()).toList(),
          'history': _history.values.map((e) => e.toJson()).toList(),
          'lockedCategories': lockedCategories.toList(),
          'groups': _groups.map((g) => g.toJson()).toList(),
          'hidden': _hidden.toList(),
          'favOrder': _favOrder,
          'lastUpdateCheck': lastUpdateCheck?.toIso8601String(),
          'activeProfileId': activeProfileId,
          'pinHash': _pinHash,
          'hideAdult': hideAdult,
          'player': player.toJson(),
        });
        await f.parent.create(recursive: true);
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(json, flush: true);
        await tmp.rename(f.path);
      }
    } finally {
      _saving = false;
    }
  }

  // Profiles ---------------------------------------------------------------

  PlaylistProfile? get activeProfile {
    for (final p in profiles) {
      if (p.id == activeProfileId) return p;
    }
    return profiles.isEmpty ? null : profiles.first;
  }

  Future<void> upsertProfile(PlaylistProfile p) {
    final i = profiles.indexWhere((e) => e.id == p.id);
    i >= 0 ? profiles[i] = p : profiles.add(p);
    return _save();
  }

  Future<void> removeProfile(String id) {
    profiles.removeWhere((p) => p.id == id);
    _favorites.removeWhere((_, v) => v.profileId == id);
    _history.removeWhere((_, v) => v.profileId == id);
    _groups.removeWhere((g) => g.profileId == id);
    _hidden.removeWhere((k) => k.startsWith('$id|'));
    _favOrder.removeWhere((k, _) => k.startsWith('$id|'));
    if (activeProfileId == id) activeProfileId = profiles.isEmpty ? null : profiles.first.id;
    return _save();
  }

  Future<void> setActiveProfile(String id) {
    activeProfileId = id;
    return _save();
  }

  // Favorites --------------------------------------------------------------

  /// Favorites in the order the user arranged them; new ones go to the end.
  List<SavedItem> favorites(String profileId, [ContentType? type]) {
    final list = _favorites.values.where((f) => f.profileId == profileId && (type == null || f.type == type)).toList();
    int rank(SavedItem f) {
      final i = _favOrder['$profileId|${f.type.name}']?.indexOf(f.id) ?? -1;
      return i < 0 ? 1 << 30 : i;
    }

    list.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.updatedAt.compareTo(b.updatedAt);
    });
    return list;
  }

  /// Moves a favorite one place up (-1) or down (+1).
  Future<void> moveFavorite(String profileId, ContentType type, String id, int delta) {
    final ids = favorites(profileId, type).map((f) => f.id).toList();
    _move(ids, id, delta);
    _favOrder['$profileId|${type.name}'] = ids;
    return _save();
  }

  static void _move(List<String> ids, String id, int delta) {
    final i = ids.indexOf(id);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= ids.length) return;
    ids
      ..removeAt(i)
      ..insert(j, id);
  }

  bool isFavorite(String profileId, ContentType type, String id) =>
      _favorites.containsKey('$profileId|${type.name}|$id');

  Future<void> toggleFavorite(SavedItem item) {
    _favorites.remove(item.key) ?? (_favorites[item.key] = item);
    return _save();
  }

  // Channel groups and hidden channels -------------------------------------

  List<ChannelGroup> groups(String profileId) => _groups.where((g) => g.profileId == profileId).toList();

  ChannelGroup? group(String id) {
    for (final g in _groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  Future<ChannelGroup> createGroup(String profileId, String name) async {
    final g = ChannelGroup(id: 'g${DateTime.now().microsecondsSinceEpoch}', profileId: profileId, name: name.trim());
    _groups.add(g);
    await _save();
    return g;
  }

  Future<void> renameGroup(ChannelGroup g, String name) {
    g.name = name.trim();
    return _save();
  }

  Future<void> deleteGroup(ChannelGroup g) {
    _groups.remove(g);
    return _save();
  }

  Future<void> toggleInGroup(ChannelGroup g, String channelId) {
    if (!g.channelIds.remove(channelId)) g.channelIds.add(channelId);
    return _save();
  }

  Future<void> moveInGroup(ChannelGroup g, String channelId, int delta) {
    _move(g.channelIds, channelId, delta);
    return _save();
  }

  bool isHidden(String profileId, String channelId) => _hidden.contains('$profileId|$channelId');

  Set<String> hiddenIds(String profileId) => {
    for (final k in _hidden)
      if (k.startsWith('$profileId|')) k.substring(profileId.length + 1),
  };

  Future<void> setHidden(String profileId, String channelId, bool hidden) {
    hidden ? _hidden.add('$profileId|$channelId') : _hidden.remove('$profileId|$channelId');
    return _save();
  }

  Future<void> markUpdateCheck() {
    lastUpdateCheck = DateTime.now();
    return _save();
  }

  // History / continue watching -------------------------------------------

  List<SavedItem> history(String profileId, [ContentType? type]) =>
      _history.values.where((h) => h.profileId == profileId && (type == null || h.type == type)).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  SavedItem? historyItem(String profileId, ContentType type, String id) => _history['$profileId|${type.name}|$id'];

  /// The live channel watched most recently on this playlist.
  SavedItem? lastChannel(String profileId) => history(profileId, ContentType.live).firstOrNull;

  Future<void> recordPlayback(SavedItem item) {
    _history[item.key] = item;
    // Keep the history bounded.
    if (_history.length > 300) {
      final oldest = _history.values.toList()..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
      for (final o in oldest.take(_history.length - 300)) {
        _history.remove(o.key);
      }
    }
    return _save();
  }

  Future<void> clearHistory(String profileId) {
    _history.removeWhere((_, v) => v.profileId == profileId);
    return _save();
  }

  // Parental control -------------------------------------------------------

  bool get hasPin => _pinHash != null;

  static String _hash(String pin) => sha256.convert(utf8.encode('imadlabs-iptv:$pin')).toString();

  bool checkPin(String pin) => _pinHash != null && _hash(pin) == _pinHash;

  Future<void> setPin(String? pin) {
    _pinHash = pin == null || pin.isEmpty ? null : _hash(pin);
    return _save();
  }

  Future<void> setHideAdult(bool v) {
    hideAdult = v;
    return _save();
  }

  bool isCategoryLocked(String profileId, Category c) =>
      lockedCategories.contains('$profileId|${c.type.name}|${c.id}') || (hideAdult && c.isAdult);

  Future<void> toggleCategoryLock(String profileId, Category c) {
    final key = '$profileId|${c.type.name}|${c.id}';
    lockedCategories.remove(key) || lockedCategories.add(key);
    return _save();
  }

  Future<void> updatePlayer(PlayerSettings s) {
    player = s;
    return _save();
  }
}
