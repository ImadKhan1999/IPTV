import '../models.dart';

/// One #EXTINF entry of an M3U / M3U8 playlist.
class M3uEntry {
  M3uEntry({
    required this.name,
    required this.url,
    this.attributes = const {},
    this.group = '',
    this.duration = -1,
    this.headers = const {},
  });

  final String name;
  final String url;
  final Map<String, String> attributes;
  final String group;
  final double duration;
  final Map<String, String> headers;

  String? attr(String key) {
    final v = attributes[key];
    return (v == null || v.isEmpty) ? null : v;
  }

  ContentType get contentType => classify(url, name);

  static final _seriesName = RegExp(r'\bS\d{1,2}\s*E\d{1,3}\b', caseSensitive: false);
  static const _vodExtensions = {'mp4', 'mkv', 'avi', 'mov', 'm4v', 'wmv', 'flv', 'webm', 'mpg', 'mpeg'};

  static ContentType classify(String url, String name) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    if (path.contains('/series/')) return ContentType.series;
    if (path.contains('/movie/')) return ContentType.movie;
    final dot = path.lastIndexOf('.');
    final ext = dot >= 0 ? path.substring(dot + 1) : '';
    if (_vodExtensions.contains(ext)) {
      return _seriesName.hasMatch(name) ? ContentType.series : ContentType.movie;
    }
    return ContentType.live;
  }
}

class M3uPlaylist {
  M3uPlaylist({required this.entries, this.epgUrl});

  final List<M3uEntry> entries;

  /// Guide URL from the header (url-tvg / x-tvg-url).
  final String? epgUrl;
}

/// Fast, forgiving M3U parser. Handles extended attributes, #EXTGRP, #EXTVLCOPT headers,
/// Windows line endings and playlists without #EXTM3U.
class M3uParser {
  static final _attr = RegExp(r'([\w\-]+)\s*=\s*"([^"]*)"|([\w\-]+)\s*=\s*([^\s,"]+)');

  static M3uPlaylist parse(String text) {
    final entries = <M3uEntry>[];
    String? epgUrl;

    String? pendingName;
    var pendingAttrs = <String, String>{};
    var pendingDuration = -1.0;
    String? pendingGroup;
    var pendingHeaders = <String, String>{};

    void reset() {
      pendingName = null;
      pendingAttrs = {};
      pendingDuration = -1;
      pendingGroup = null;
      pendingHeaders = {};
    }

    for (var raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXTM3U')) {
        final attrs = _parseAttributes(line.substring(7));
        final tvg = attrs['url-tvg'] ?? attrs['x-tvg-url'] ?? attrs['tvg-url'];
        epgUrl = tvg?.split(',').first.trim();
        continue;
      }
      if (line.startsWith('#EXTINF')) {
        reset();
        final body = line.substring(line.indexOf(':') + 1);
        final comma = _titleComma(body);
        final head = comma >= 0 ? body.substring(0, comma) : body;
        pendingName = comma >= 0 ? body.substring(comma + 1).trim() : '';
        final firstSpace = head.indexOf(RegExp(r'\s'));
        final durationText = firstSpace >= 0 ? head.substring(0, firstSpace) : head;
        pendingDuration = double.tryParse(durationText.trim()) ?? -1;
        pendingAttrs = _parseAttributes(firstSpace >= 0 ? head.substring(firstSpace) : '');
        continue;
      }
      if (line.startsWith('#EXTGRP:')) {
        pendingGroup = line.substring(8).trim();
        continue;
      }
      if (line.startsWith('#EXTVLCOPT:')) {
        final opt = line.substring(11);
        final eq = opt.indexOf('=');
        if (eq > 0) {
          final key = opt.substring(0, eq).trim().toLowerCase();
          final value = opt.substring(eq + 1).trim();
          if (key == 'http-user-agent') pendingHeaders['User-Agent'] = value;
          if (key == 'http-referrer' || key == 'http-referer') pendingHeaders['Referer'] = value;
          if (key == 'http-origin') pendingHeaders['Origin'] = value;
        }
        continue;
      }
      if (line.startsWith('#')) continue; // #KODIPROP and other directives

      // A URL line.
      final attrs = pendingAttrs;
      final name = (pendingName?.isNotEmpty ?? false) ? pendingName! : (attrs['tvg-name'] ?? _nameFromUrl(line));
      entries.add(
        M3uEntry(
          name: name,
          url: line,
          attributes: attrs,
          group: attrs['group-title'] ?? pendingGroup ?? '',
          duration: pendingDuration,
          headers: pendingHeaders,
        ),
      );
      reset();
    }
    return M3uPlaylist(entries: entries, epgUrl: epgUrl);
  }

  /// Index of the comma that separates attributes from the title, ignoring commas in quotes.
  static int _titleComma(String s) {
    var inQuotes = false;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c == 0x22) inQuotes = !inQuotes;
      if (c == 0x2C && !inQuotes) return i;
    }
    return -1;
  }

  static Map<String, String> _parseAttributes(String s) {
    final out = <String, String>{};
    for (final m in _attr.allMatches(s)) {
      final key = (m.group(1) ?? m.group(3))!.toLowerCase();
      out[key] = (m.group(2) ?? m.group(4) ?? '').trim();
    }
    return out;
  }

  static String _nameFromUrl(String url) {
    final path = Uri.tryParse(url)?.pathSegments ?? const [];
    return path.isNotEmpty ? Uri.decodeComponent(path.last) : url;
  }
}
