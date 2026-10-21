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
    this.sha256 = '',
  });

  final String channel;
  final int versionCode;
  final String versionName;
  final String apkUrl;
  final String changelog;
  final String sha256;

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      channel: (json['channel'] as String?) ?? '',
      versionCode: _readVersionCode(json['versionCode'] ?? json['buildNumber']),
      versionName: (json['versionName'] as String?) ??
          (json['version'] as String?) ??
          '',
      apkUrl: (json['apkUrl'] as String?) ??
          (json['downloadUrl'] as String?) ??
          '',
      changelog: (json['changelog'] as String?) ??
          (json['releaseNotes'] as String?) ??
          '',
      sha256: (json['sha256'] as String?) ?? '',
    );
  }
}

int _readVersionCode(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim()) ?? 0;
  return 0;
}

class AppVersion {
  const AppVersion({required this.versionCode, required this.versionName});
  final int versionCode;
  final String versionName;
}

/// Checks git `releases/<channel>/latest.json` and installs APKs on Android
/// (same internal flow as AnisFlix TV: native download → system installer →
/// delete cached APK after replace).
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
        versionCode: _readVersionCode(raw['versionCode']),
        versionName: (raw['versionName'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  Future<AppUpdateInfo?> fetchLatest() async {
    if (!isSupported) return null;
    try {
      // Bust CDN/browser caches so we never keep showing a stale "newer" build.
      final uri = manifestUri.replace(
        queryParameters: {
          ...manifestUri.queryParameters,
          't': '${DateTime.now().millisecondsSinceEpoch}',
        },
      );
      final res = await http
          .get(
            uri,
            headers: const {
              'Accept': 'application/vnd.github.raw+json',
              'Cache-Control': 'no-cache',
              'Pragma': 'no-cache',
            },
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final map = jsonDecode(res.body);
      if (map is! Map<String, dynamic>) return null;
      final info = AppUpdateInfo.fromJson(map);
      if (info.versionCode <= 0 || !info.apkUrl.startsWith('https://')) return null;
      return info;
    } catch (_) {
      return null;
    }
  }

  /// Returns [AppUpdateInfo] only when the repo build is strictly newer.
  Future<AppUpdateInfo?> checkForUpdate() async {
    final installed = await installedVersion();
    final latest = await fetchLatest();
    if (installed == null || latest == null) return null;
    if (installed.versionCode <= 0) return null;
    if (latest.versionCode <= installed.versionCode) return null;
    return latest;
  }

  /// Starts the native async download + system installer.
  ///
  /// Returns: `started` | `settings` | `invalid_url` | `failed` | `ignored`
  Future<String> installUpdate(AppUpdateInfo info) async {
    if (!isSupported || info.apkUrl.isEmpty) return 'ignored';
    try {
      final result = await platformChannel.invokeMethod<String>(
        'installUpdate',
        <String, Object?>{
          'url': info.apkUrl,
          'sha256': info.sha256,
        },
      );
      return result ?? 'failed';
    } on PlatformException catch (e) {
      if (e.code == 'permission') return 'settings';
      return 'failed';
    } catch (_) {
      return 'failed';
    }
  }
}
