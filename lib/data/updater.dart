import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// The version this build was made as. CI passes it with --dart-define; local builds say 0.0.0-dev.
abstract final class AppVersion {
  static const name = String.fromEnvironment('APP_VERSION', defaultValue: '0.0.0-dev');
  static const build = int.fromEnvironment('APP_BUILD');

  static String get label => build > 0 ? '$name ($build)' : name;
}

/// A newer release on GitHub and the file this device should install.
class UpdateInfo {
  const UpdateInfo({required this.version, required this.notes, required this.pageUrl, this.assetUrl, this.assetName});

  final String version;
  final String notes;
  final String pageUrl;
  final String? assetUrl;
  final String? assetName;
}

/// Checks GitHub Releases for a newer version and installs it: the right APK for this
/// device's CPU on Android, the installer on Windows.
class Updater {
  Updater({http.Client? client}) : _client = client ?? http.Client();

  static const repo = 'ImadKhan1999/IPTV';
  final http.Client _client;

  /// Compares dotted versions ("1.10.0" > "1.9.2"). A release beats a pre-release of the same
  /// number ("1.0.0" > "1.0.0-beta").
  static int compare(String a, String b) {
    List<int> nums(String v) => v.split('-').first.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final x = nums(a), y = nums(b);
    for (var i = 0; i < 3; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d.sign;
    }
    final preA = a.contains('-'), preB = b.contains('-');
    if (preA == preB) return 0;
    return preA ? -1 : 1;
  }

  /// Picks the download for this device from a release's file names.
  static String? pickAsset(
    List<String> names, {
    required bool android,
    required bool windows,
    List<String> abis = const [],
  }) {
    if (android) {
      for (final abi in abis) {
        final n = 'iPTV-$abi.apk';
        if (names.contains(n)) return n;
      }
      return names.contains('iPTV-universal.apk') ? 'iPTV-universal.apk' : null;
    }
    if (windows) {
      for (final n in names) {
        if (n.startsWith('iPTV-Setup') && n.endsWith('.exe')) return n;
      }
    }
    return null;
  }

  /// The latest release when it is newer than [current], else null.
  Future<UpdateInfo?> check({
    String current = AppVersion.name,
    required bool android,
    required bool windows,
    List<String> abis = const [],
  }) async {
    final res = await _client
        .get(
          Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
          headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'iPTV-app'},
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 404) return null; // no release yet
    if (res.statusCode != 200) throw HttpException('Update check failed (HTTP ${res.statusCode})');
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final tag = (j['tag_name'] as String? ?? '').replaceFirst(RegExp('^v'), '');
    if (tag.isEmpty || compare(tag, current) <= 0) return null;
    final assets = [
      for (final a in (j['assets'] as List? ?? const []))
        if (a is Map) (a['name'] as String? ?? '', a['browser_download_url'] as String? ?? ''),
    ];
    final name = pickAsset(assets.map((a) => a.$1).toList(), android: android, windows: windows, abis: abis);
    return UpdateInfo(
      version: tag,
      notes: (j['body'] as String? ?? '').trim(),
      pageUrl: j['html_url'] as String? ?? 'https://github.com/$repo/releases/latest',
      assetName: name,
      assetUrl: name == null ? null : assets.firstWhere((a) => a.$1 == name).$2,
    );
  }

  /// Downloads the update into the temp folder, reporting progress from 0 to 1.
  Future<File> download(UpdateInfo info, void Function(double progress) onProgress) async {
    final req = http.Request('GET', Uri.parse(info.assetUrl!))..headers['User-Agent'] = 'iPTV-app';
    final res = await _client.send(req);
    if (res.statusCode != 200) throw HttpException('Download failed (HTTP ${res.statusCode})');
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}${info.assetName}');
    final sink = file.openWrite();
    final total = res.contentLength ?? 0;
    var got = 0;
    await for (final chunk in res.stream) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) onProgress(got / total);
    }
    await sink.close();
    return file;
  }
}
