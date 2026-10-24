// Device-only update check. Stage the newer release APK in the debug app's
// cache/updates/fctv33-update.apk and supply its SHA with UPDATE_TEST_SHA256.
// Build this entry point with a lower build number than the staged release.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fctv33/core/app_update.dart';
import 'package:fctv33/core/platform.dart';
import 'package:fctv33/shared/update_button.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await detectAndroidTv();
  const digest = String.fromEnvironment('UPDATE_TEST_SHA256');
  if (digest.isEmpty) throw StateError('Missing test APK digest');
  final updater = AppUpdateService(
    client: MockClient(
      (_) async => http.Response(
        jsonEncode({
          'channel': 'android-tv',
          'versionCode': 12,
          'versionName': '1.0.11',
          'apkUrl': 'https://github.com/akedidi/anis-fctv/releases/download/android-tv-1.0.3/fctv-tv-1.0.3.apk',
          'sha256': digest,
          'changelog':
              'Test de l’installation Android complète : Ouvrir / Terminé.',
        }),
        200,
      ),
    ),
  );
  runApp(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('FCTV33 · Test de mise à jour'),
              const SizedBox(height: 20),
              AppUpdateButton(service: updater),
            ],
          ),
        ),
      ),
    ),
  );
}
