import 'dart:convert';
import 'dart:io' show gzip;

import 'package:http/http.dart' as http;
import 'package:xml/xml_events.dart';

import '../models.dart';

/// In-memory XMLTV guide, indexed by channel id.
class EpgGuide {
  EpgGuide(this._byChannel, this._displayNames);

  final Map<String, List<EpgProgram>> _byChannel;

  /// Lower-cased display name -> channel id, used when a channel has no tvg-id.
  final Map<String, String> _displayNames;

  static final empty = EpgGuide({}, {});

  bool get isEmpty => _byChannel.isEmpty;
  int get channelCount => _byChannel.length;

  List<EpgProgram> programsFor(String? epgId, {String? channelName}) {
    var list = epgId == null ? null : _byChannel[epgId];
    if (list == null && channelName != null) {
      final id = _displayNames[channelName.toLowerCase().trim()];
      if (id != null) list = _byChannel[id];
    }
    return list ?? const [];
  }

  /// Programmes from the one on air now onwards.
  List<EpgProgram> upcoming(String? epgId, {String? channelName, int limit = 6, DateTime? now}) {
    final t = now ?? DateTime.now();
    return programsFor(epgId, channelName: channelName).where((p) => p.end.isAfter(t)).take(limit).toList();
  }

  static Future<EpgGuide> download(String url, {http.Client? client, Map<String, String> headers = const {}}) async {
    final c = client ?? http.Client();
    try {
      final res = await c.get(Uri.parse(url), headers: headers);
      if (res.statusCode != 200) throw SourceException('Guide download failed (HTTP ${res.statusCode})');
      return fromBytes(res.bodyBytes);
    } finally {
      if (client == null) c.close();
    }
  }

  /// Raw guide bytes as downloaded (gzip or plain XML).
  static Future<List<int>> fetchBytes(String url, {http.Client? client, Map<String, String> headers = const {}}) async {
    final c = client ?? http.Client();
    try {
      final res = await c.get(Uri.parse(url), headers: headers);
      if (res.statusCode != 200) throw SourceException('Guide download failed (HTTP ${res.statusCode})');
      return res.bodyBytes;
    } finally {
      if (client == null) c.close();
    }
  }

  static EpgGuide fromBytes(List<int> bytes) {
    if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) bytes = gzip.decode(bytes);
    return parse(utf8.decode(bytes, allowMalformed: true));
  }

  /// Streams through the XML so large guides do not build a full DOM.
  static EpgGuide parse(String xml) {
    final byChannel = <String, List<EpgProgram>>{};
    final names = <String, String>{};

    String? currentChannelId;
    String? progChannel;
    DateTime? progStart;
    DateTime? progEnd;
    String? textTarget;
    final title = StringBuffer();
    final desc = StringBuffer();
    final displayName = StringBuffer();

    for (final event in parseEvents(xml)) {
      if (event is XmlStartElementEvent) {
        String? attr(String n) {
          for (final a in event.attributes) {
            if (a.name == n) return a.value;
          }
          return null;
        }

        switch (event.name) {
          case 'channel':
            currentChannelId = attr('id');
          case 'display-name':
            if (currentChannelId != null) {
              textTarget = 'name';
              displayName.clear();
            }
          case 'programme':
            progChannel = attr('channel');
            progStart = parseXmltvTime(attr('start'));
            progEnd = parseXmltvTime(attr('stop'));
            title.clear();
            desc.clear();
          case 'title':
            if (progChannel != null && title.isEmpty) textTarget = 'title';
          case 'desc':
            if (progChannel != null && desc.isEmpty) textTarget = 'desc';
        }
        if (event.isSelfClosing && event.name == 'programme') progChannel = null;
      } else if (event is XmlTextEvent || event is XmlCDATAEvent) {
        final value = event is XmlTextEvent ? event.value : (event as XmlCDATAEvent).value;
        switch (textTarget) {
          case 'title':
            title.write(value);
          case 'desc':
            desc.write(value);
          case 'name':
            displayName.write(value);
        }
      } else if (event is XmlEndElementEvent) {
        switch (event.name) {
          case 'title' || 'desc':
            textTarget = null;
          case 'display-name':
            if (currentChannelId != null && displayName.isNotEmpty) {
              names.putIfAbsent(displayName.toString().toLowerCase().trim(), () => currentChannelId!);
            }
            textTarget = null;
          case 'channel':
            currentChannelId = null;
          case 'programme':
            if (progChannel != null && progStart != null && progEnd != null) {
              (byChannel[progChannel] ??= []).add(
                EpgProgram(
                  channelId: progChannel,
                  start: progStart,
                  end: progEnd,
                  title: title.toString().trim(),
                  description: desc.toString().trim(),
                ),
              );
            }
            progChannel = null;
        }
      }
    }
    for (final list in byChannel.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }
    return EpgGuide(byChannel, names);
  }
}

/// Parses XMLTV timestamps such as `20241123203000 +0100` into local time.
DateTime? parseXmltvTime(String? s) {
  if (s == null) return null;
  final t = s.trim();
  if (t.length < 12) return null;
  final y = int.tryParse(t.substring(0, 4));
  final mo = int.tryParse(t.substring(4, 6));
  final d = int.tryParse(t.substring(6, 8));
  final h = int.tryParse(t.substring(8, 10));
  final mi = int.tryParse(t.substring(10, 12));
  final sec = t.length >= 14 ? int.tryParse(t.substring(12, 14)) ?? 0 : 0;
  if (y == null || mo == null || d == null || h == null || mi == null) return null;
  var utc = DateTime.utc(y, mo, d, h, mi, sec);
  final tz = RegExp(r'([+-])(\d{2}):?(\d{2})').firstMatch(t.length > 14 ? t.substring(14) : '');
  if (tz != null) {
    final sign = tz.group(1) == '-' ? -1 : 1;
    final offset = Duration(hours: int.parse(tz.group(2)!), minutes: int.parse(tz.group(3)!));
    utc = sign > 0 ? utc.subtract(offset) : utc.add(offset);
  }
  return utc.toLocal();
}
