import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iptv/data/updater.dart';

void main() {
  test('compares versions', () {
    expect(Updater.compare('1.10.0', '1.9.2'), 1);
    expect(Updater.compare('1.0.0', '1.0.0'), 0);
    expect(Updater.compare('1.0.0', '1.0.0-beta'), 1);
    expect(Updater.compare('0.9', '1.0.0'), -1);
  });

  test('picks the APK for the device CPU, or the Windows installer', () {
    const names = ['iPTV-arm64-v8a.apk', 'iPTV-armeabi-v7a.apk', 'iPTV-universal.apk', 'iPTV-Setup-1.1.0.exe'];
    expect(Updater.pickAsset(names, android: true, windows: false, abis: ['arm64-v8a']), 'iPTV-arm64-v8a.apk');
    expect(Updater.pickAsset(names, android: true, windows: false, abis: ['mips']), 'iPTV-universal.apk');
    expect(Updater.pickAsset(names, android: false, windows: true), 'iPTV-Setup-1.1.0.exe');
  });

  test('offers a newer GitHub release with the right download', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'tag_name': 'v1.1.0',
          'body': 'New stuff',
          'html_url': 'https://github.com/x',
          'assets': [
            {'name': 'iPTV-Setup-1.1.0.exe', 'browser_download_url': 'https://dl/setup.exe'},
          ],
        }),
        200,
      ),
    );
    final u = Updater(client: client);
    final info = await u.check(current: '1.0.0', android: false, windows: true);
    expect(info!.version, '1.1.0');
    expect(info.assetUrl, 'https://dl/setup.exe');
    expect(await u.check(current: '1.1.0', android: false, windows: true), isNull);
  });
}
