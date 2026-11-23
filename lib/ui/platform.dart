import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform facts and Android-only features (TV detection, picture-in-picture).
abstract final class AppPlatform {
  static const _channel = MethodChannel('imadlabs/platform');

  static bool isTv = false;
  static bool pipSupported = false;
  static final pipActive = ValueNotifier<bool>(false);

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;
  static bool get isDesktop => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static Future<void> init() async {
    if (!isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pipChanged') pipActive.value = call.arguments == true;
    });
    try {
      isTv = await _channel.invokeMethod<bool>('isTv') ?? false;
      pipSupported = await _channel.invokeMethod<bool>('pipSupported') ?? false;
    } catch (_) {}
  }

  static Future<bool> enterPip({int? width, int? height}) async {
    if (!pipSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('enterPip', {'width': width, 'height': height}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Enter PiP automatically when the user presses Home while a video plays.
  static Future<void> setAutoPip(bool enabled, {int? width, int? height}) async {
    if (!pipSupported) return;
    try {
      await _channel.invokeMethod('setAutoPip', {'enabled': enabled, 'width': width, 'height': height});
    } catch (_) {}
  }
}
