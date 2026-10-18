import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const platformChannel = MethodChannel('com.fctv33.fctv33/platform');

bool? _androidTvCached;
bool? _androidEmulatorCached;

/// True on Android TV / leanback devices (D-pad; no AirPlay / PiP).
Future<bool> detectAndroidTv() async {
  if (_androidTvCached != null) return _androidTvCached!;
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    _androidTvCached = false;
    return false;
  }
  try {
    final v = await platformChannel.invokeMethod<bool>('isAndroidTv');
    _androidTvCached = v == true;
  } catch (_) {
    _androidTvCached = false;
  }
  return _androidTvCached!;
}

/// Detect Android Emulator (ranchu / goldfish / sdk_*).
Future<bool> detectAndroidEmulator() async {
  if (_androidEmulatorCached != null) return _androidEmulatorCached!;
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    _androidEmulatorCached = false;
    return false;
  }
  try {
    final v = await platformChannel.invokeMethod<bool>('isAndroidEmulator');
    _androidEmulatorCached = v == true;
  } catch (_) {
    _androidEmulatorCached = false;
  }
  return _androidEmulatorCached!;
}

/// Synchronous cache after [detectAndroidTv] (false until resolved).
bool get isAndroidTv => _androidTvCached == true;

/// Synchronous cache after [detectAndroidEmulator].
bool get isAndroidEmulator => _androidEmulatorCached == true;

/// Phone / tablet Android (not TV).
bool get isAndroidPhone {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  return !isAndroidTv;
}

/// Mini-player / in-app PiP — phones only. Disabled on Android TV, web, desktop.
bool get supportsMiniPlayer {
  if (kIsWeb || isAndroidTv) return false;
  return defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;
}

/// AirPlay (iOS) / Cast chrome (Android phone). Not used on Android TV.
bool get supportsAirPlayChrome {
  if (kIsWeb || isAndroidTv) return false;
  return defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;
}

/// Picture-in-Picture — phones (system PiP on Android, mini / overlay elsewhere).
/// Disabled on Android TV.
bool get supportsPictureInPicture {
  if (kIsWeb || isAndroidTv) return false;
  return defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;
}

/// Enter Android system PiP. Returns `true` if the OS accepted the request.
Future<bool> enterAndroidPictureInPicture() async {
  if (!isAndroidPhone) return false;
  try {
    final v = await platformChannel.invokeMethod<bool>('enterPictureInPicture');
    return v == true;
  } catch (_) {
    return false;
  }
}

/// Keep the display awake (blocks Android TV screensaver during playback).
Future<void> setKeepScreenOn(bool enabled) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await platformChannel.invokeMethod<void>('setKeepScreenOn', {'enabled': enabled});
  } catch (_) {}
}
