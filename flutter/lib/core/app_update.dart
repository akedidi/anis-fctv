import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'platform.dart';

/// Base for channel manifests on the git repo (raw GitHub).
const String kDefaultUpdateManifestBase =
    String.fromEnvironment(
      'UPDATE_MANIFEST_BASE',
      defaultValue:
          'https://raw.githubusercontent.com/akedidi/anis-fctv/main/releases',
    );

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.channel,
    required this.versionCode,
    required this.versionName,
    required this.apkUrl,
    this.changelog = '',
  });

  final String channel;
  final int versionCode;
  final String versionName;
  final String apkUrl;
  final String changelog;

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      channel: (json['channel'] as String?) ?? '',
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      versionName: (json['versionName'] as String?) ?? '',
      apkUrl: (json['apkUrl'] as String?) ?? '',
      changelog: (json['changelog'] as String?) ?? '',
    );
  }
}

class AppVersion {
  const AppVersion({required this.versionCode, required this.versionName});
  final int versionCode;
  final String versionName;
}

/// Checks git `releases/<channel>/latest.json` and installs APKs on Android.
class AppUpdateService {
  AppUpdateService({this.manifestBase = kDefaultUpdateManifestBase});

  final String manifestBase;

  String get channel {
    if (isAndroidTv) return 'android-tv';
    if (defaultTargetPlatform == TargetPlatform.android) return 'android-mobile';
    return '';
  }

  bool get isSupported => channel.isNotEmpty;

  Uri get manifestUri => Uri.parse('$manifestBase/$channel/latest.json');

  Future<AppVersion?> installedVersion() async {
    if (!isSupported) return null;
    try {
      final raw = await platformChannel.invokeMethod<Map<Object?, Object?>>('getAppVersion');
      if (raw == null) return null;
      return AppVersion(
        versionCode: (raw['versionCode'] as num?)?.toInt() ?? 0,
        versionName: (raw['versionName'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  Future<AppUpdateInfo?> fetchLatest() async {
    if (!isSupported) return null;
    try {
      final res = await http.get(manifestUri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final map = jsonDecode(res.body);
      if (map is! Map<String, dynamic>) return null;
      final info = AppUpdateInfo.fromJson(map);
      if (info.versionCode <= 0 || info.apkUrl.isEmpty) return null;
      return info;
    } catch (_) {
      return null;
    }
  }

  /// Returns [AppUpdateInfo] when a newer build is available on the repo.
  Future<AppUpdateInfo?> checkForUpdate() async {
    final installed = await installedVersion();
    final latest = await fetchLatest();
    if (installed == null || latest == null) return null;
    if (latest.versionCode <= installed.versionCode) return null;
    return latest;
  }

  /// Downloads the APK and opens the system installer.
  /// Returns `null` on success, or an error message.
  Future<String?> installUpdate(AppUpdateInfo info) async {
    if (!isSupported || info.apkUrl.isEmpty) return 'Update not supported';
    try {
      await platformChannel.invokeMethod<void>(
        'installApkFromUrl',
        <String, Object?>{
          'url': info.apkUrl,
          'fileName': 'fctv33-$channel-update.apk',
        },
      );
      return null;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } catch (e) {
      return e.toString();
    }
  }
}
