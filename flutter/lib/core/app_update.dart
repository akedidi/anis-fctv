import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'platform.dart';

/// Base for channel manifests on the git repo (raw GitHub).
const String kDefaultUpdateManifestBase = String.fromEnvironment(
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

  bool isNewerThan(AppVersion installed) =>
      installed.versionCode > 0 && versionCode > installed.versionCode;

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      channel: (json['channel'] as String?) ?? '',
      versionCode: _readVersionCode(json['versionCode'] ?? json['buildNumber']),
      versionName:
          (json['versionName'] as String?) ??
          (json['version'] as String?) ??
          '',
      apkUrl:
          (json['apkUrl'] as String?) ?? (json['downloadUrl'] as String?) ?? '',
      changelog:
          (json['changelog'] as String?) ??
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

/// Native installer states, shared by Android TV and mobile.
class AppUpdateProgress {
  const AppUpdateProgress({
    required this.phase,
    this.received = 0,
    this.total = 0,
    this.attempt = 1,
    this.maxAttempts = 3,
    this.error,
  });

  factory AppUpdateProgress.fromMap(Map<Object?, Object?> raw) =>
      AppUpdateProgress(
        phase: raw['phase']?.toString() ?? 'downloading',
        received: _readVersionCode(raw['received']),
        total: _readVersionCode(raw['total']),
        attempt: _readVersionCode(raw['attempt']).clamp(1, 99),
        maxAttempts: _readVersionCode(raw['maxAttempts']).clamp(1, 99),
        error: raw['error']?.toString(),
      );

  final String phase;
  final int received;
  final int total;
  final int attempt;
  final int maxAttempts;
  final String? error;

  double get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
  int get percent => (fraction * 100).round();
  bool get busy => const {
    'downloading',
    'retrying',
    'verifying',
    'installing',
  }.contains(phase);
  double? get indicatorValue =>
      const {'verifying', 'installing', 'awaiting_user', 'done'}.contains(phase)
      ? 1
      : total > 0
      ? fraction
      : null;

  String get label => switch (phase) {
    'verifying' => 'Verifying…',
    'installing' => 'Installing…',
    'awaiting_permission' => 'Permission required',
    'awaiting_user' => 'Confirm installation',
    'retrying' => 'Retrying $attempt/$maxAttempts',
    'failed' => 'Retry update',
    'done' => 'Installed',
    _ => total > 0 ? 'Downloading $percent%' : 'Downloading…',
  };
}

/// Checks git `releases/<channel>/latest.json` and installs APKs on Android
/// (same internal flow as AnisFlix TV: native download → system installer →
/// delete cached APK after replace).
class AppUpdateService {
  AppUpdateService({
    this.manifestBase = kDefaultUpdateManifestBase,
    http.Client? client,
    MethodChannel? nativeChannel,
  }) : _client = client ?? http.Client(),
       _nativeChannel = nativeChannel ?? platformChannel {
    if (isSupported) {
      _nativeChannel.setMethodCallHandler((call) async {
        if (call.method == 'updateInstallProgress' && call.arguments is Map) {
          if (_progress.isClosed) return;
          _progress.add(
            AppUpdateProgress.fromMap(
              Map<Object?, Object?>.from(call.arguments as Map),
            ),
          );
        }
      });
    }
  }

  final String manifestBase;
  final http.Client _client;
  final MethodChannel _nativeChannel;
  final _progress = StreamController<AppUpdateProgress>.broadcast();
  bool _disposed = false;
  Stream<AppUpdateProgress> get progress => _progress.stream;

  String get channel {
    if (kIsWeb) return '';
    if (isAndroidTv) return 'android-tv';
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'android-mobile';
    }
    return '';
  }

  bool get isSupported => channel.isNotEmpty;

  Uri get manifestUri => Uri.parse('$manifestBase/$channel/latest.json');

  Future<AppVersion?> installedVersion() async {
    if (!isSupported) return null;
    try {
      final raw = await _nativeChannel
          .invokeMethod<Map<Object?, Object?>>('getAppVersion')
          .timeout(const Duration(seconds: 3));
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
      final res = await _client
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
      if (info.versionCode <= 0 || !info.apkUrl.startsWith('https://')) {
        return null;
      }
      return info;
    } catch (_) {
      return null;
    }
  }

  /// Returns [AppUpdateInfo] only when the repo build is strictly newer.
  Future<AppUpdateInfo?> checkForUpdate() async {
    final result = await checkLatest();
    if (result == null) return null;
    return result.latest.isNewerThan(result.installed) ? result.latest : null;
  }

  /// A failed poll is distinct from a successful check with no newer version.
  Future<({AppVersion installed, AppUpdateInfo latest})?> checkLatest() async {
    final installed = await installedVersion();
    final latest = await fetchLatest();
    if (installed == null || latest == null) return null;
    if (installed.versionCode <= 0) return null;
    return (installed: installed, latest: latest);
  }

  /// Starts the native async download + system installer.
  ///
  /// Returns: `started` | `settings` | `invalid_url` | `failed` | `ignored`
  Future<String> installUpdate(AppUpdateInfo info) async {
    if (!isSupported || info.apkUrl.isEmpty) return 'ignored';
    try {
      final result = await _nativeChannel.invokeMethod<String>(
        'installUpdate',
        <String, Object?>{'url': info.apkUrl, 'sha256': info.sha256},
      );
      return result ?? 'failed';
    } on PlatformException catch (e) {
      if (e.code == 'permission') return 'settings';
      return 'failed';
    } catch (_) {
      return 'failed';
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (isSupported) _nativeChannel.setMethodCallHandler(null);
    unawaited(_progress.close());
    _client.close();
  }
}
