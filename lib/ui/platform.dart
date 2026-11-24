import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform facts and Android-only features (TV detection, picture-in-picture).
abstract final class AppPlatform {
  static const _channel = MethodChannel('imadlabs/platform');

  static bool isTv = false;
  static bool pipSupported = false;
  static bool voiceSupported = false;
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
      voiceSupported = await _channel.invokeMethod<bool>('voiceSupported') ?? false;
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

  /// Speech-to-text through the system recogniser (the mic button on TV remotes).
  static Future<String?> voiceSearch({String? prompt}) async {
    if (!voiceSupported) return null;
    try {
      return await _channel.invokeMethod<String>('voiceSearch', {'prompt': prompt});
    } catch (_) {
      return null;
    }
  }

  /// CPU types this device runs, best first (picks the right APK for updates).
  static Future<List<String>> abis() async {
    if (!isAndroid) return const [];
    try {
      return (await _channel.invokeListMethod<String>('abis')) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// Opens the system installer for a downloaded APK.
  static Future<bool> installApk(String path) async {
    try {
      return await _channel.invokeMethod<bool>('installApk', {'path': path}) ?? false;
    } catch (_) {
      return false;
    }
  }
}
