import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

/// Keeps provider replies (playlists, channel / movie / series lists, TV guides) on disk so the
/// app opens instantly. Entries are grouped per playlist so a playlist can be refreshed or
/// removed on its own.
///
/// Reads follow "stale while revalidate": a fresh entry is used as is; an expired entry is still
/// returned at once and refreshed in the background for the next launch; with no entry the
/// network is used. When the network fails, any old entry is better than an error.
class DiskCache {
  DiskCache._(this._root);

  /// In-memory cache for tests.
  DiskCache.memory() : _root = null;

  final Directory? _root;
  final _memory = <String, (DateTime, List<int>)>{};

  static Future<DiskCache> open() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}provider_cache');
    await dir.create(recursive: true);
    return DiskCache._(dir);
  }

  File _file(String group, String key) {
    final name = sha1.convert(utf8.encode(key)).toString();
    final sep = Platform.pathSeparator;
    return File('${_root!.path}$sep${_safe(group)}$sep$name.bin');
  }

  static String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  Future<(DateTime, List<int>)?> read(String group, String key) async {
    if (_root == null) return _memory['$group|$key'];
    final f = _file(group, key);
    try {
      if (!await f.exists()) return null;
      return (await f.lastModified(), await f.readAsBytes());
    } catch (e) {
      debugPrint('Cache read failed: $e');
      return null;
    }
  }

  Future<void> write(String group, String key, List<int> bytes) async {
    if (_root == null) {
      _memory['$group|$key'] = (DateTime.now(), bytes);
      return;
    }
    final f = _file(group, key);
    try {
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('Cache write failed: $e');
    }
  }

  /// Removes everything stored for one playlist (Refresh now, or the playlist was deleted).
  Future<void> clearGroup(String group) async {
    if (_root == null) {
      _memory.removeWhere((k, _) => k.startsWith('$group|'));
      return;
    }
    final dir = Directory('${_root.path}${Platform.pathSeparator}${_safe(group)}');
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('Cache clear failed: $e');
    }
  }

  /// Time of the oldest list stored for a playlist, shown as "Updated 3 h ago".
  Future<DateTime?> updatedAt(String group) async {
    if (_root == null) {
      final times = [
        for (final e in _memory.entries)
          if (e.key.startsWith('$group|')) e.value.$1,
      ];
      return times.isEmpty ? null : times.reduce((a, b) => a.isBefore(b) ? a : b);
    }
    final dir = Directory('${_root.path}${Platform.pathSeparator}${_safe(group)}');
    if (!await dir.exists()) return null;
    DateTime? oldest;
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.bin')) continue;
      final t = await f.lastModified();
      if (oldest == null || t.isBefore(oldest)) oldest = t;
    }
    return oldest;
  }
}

/// How one source uses the cache: which playlist group, how long entries stay fresh, and
/// whether this connection must skip the cache (Refresh now).
class CachePolicy {
  CachePolicy({required this.cache, required this.group, required this.maxAge, this.forceRefresh = false});

  final DiskCache cache;
  final String group;

  /// Zero means "check the provider every launch" (the cache is then only an offline fallback).
  final Duration maxAge;
  bool forceRefresh;

  /// Background refreshes started for expired entries, awaited by tests.
  final pending = <Future<void>>[];

  Future<List<int>> fetch(String key, Future<List<int>> Function() load) async {
    final hit = forceRefresh ? null : await cache.read(group, key);
    if (hit != null) {
      final age = DateTime.now().difference(hit.$1);
      if (maxAge > Duration.zero) {
        if (age > maxAge) {
          pending.add(
            load().then((b) => cache.write(group, key, b)).catchError((Object e) {
              debugPrint('Background refresh failed: $e');
            }),
          );
        }
        return hit.$2;
      }
    }
    try {
      final bytes = await load();
      await cache.write(group, key, bytes);
      return bytes;
    } catch (e) {
      final old = hit ?? await cache.read(group, key);
      if (old != null) return old.$2; // offline: use what we have
      rethrow;
    }
  }
}
