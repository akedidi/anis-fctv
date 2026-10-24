import 'dart:convert';

import 'package:fctv33/core/app_update.dart';
import 'package:fctv33/shared/update_button.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fctv-update-test');
  const codec = StandardMethodCodec();
  var installedBuild = 10;
  var installCalls = 0;
  var installResult = 'started';
  final manifest = <String, Object>{
    'channel': 'android-tv',
    'versionCode': 11,
    'versionName': '1.0.10',
    'apkUrl': 'https://example.com/fctv.apk',
    'sha256': 'test-digest',
    'changelog': 'Automatic return after update',
  };

  setUp(() {
    installedBuild = 10;
    installCalls = 0;
    installResult = 'started';
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'getAppVersion') {
        return {'versionCode': installedBuild, 'versionName': '1.0.9'};
      }
      if (call.method == 'installUpdate') {
        installCalls++;
        expect(call.arguments['url'], manifest['apkUrl']);
        expect(call.arguments['sha256'], manifest['sha256']);
        return installResult;
      }
      return null;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  AppUpdateService service({MockClient? client}) {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final result = AppUpdateService(
      nativeChannel: channel,
      client:
          client ??
          MockClient((request) async {
            expect(request.url.queryParameters['t'], isNotEmpty);
            return http.Response(jsonEncode(manifest), 200);
          }),
    );
    addTearDown(result.dispose);
    return result;
  }

  Future<void> progress(Map<String, Object> values) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall('updateInstallProgress', values)),
      (_) {},
    );
  }

  Future<void> showButton(WidgetTester tester, AppUpdateService updater) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AppUpdateButton(service: updater)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Update'), findsOneWidget);
  }

  Future<void> startUpdate(WidgetTester tester) async {
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  test('FCTV and AnisFlix manifest fields remain compatible', () {
    final update = AppUpdateInfo.fromJson({
      'buildNumber': '11',
      'version': '1.0.10',
      'downloadUrl': 'https://example.com/fctv.apk',
      'releaseNotes': 'Return to app',
    });
    expect(update.versionCode, 11);
    expect(update.versionName, '1.0.10');
    expect(update.changelog, 'Return to app');
  });

  test('only a strictly newer installed build is offered', () async {
    final updater = service();
    expect((await updater.checkForUpdate())?.versionCode, 11);
    installedBuild = 11;
    expect(await updater.checkForUpdate(), isNull);
    installedBuild = 12;
    expect(await updater.checkForUpdate(), isNull);
    installedBuild = 0;
    expect(await updater.checkForUpdate(), isNull);
  });

  test('invalid or failed manifests do not produce an update', () async {
    final updater = service(
      client: MockClient(
        (_) async => http.Response(
          '{"versionCode":11,"apkUrl":"http://example.com/app.apk"}',
          200,
        ),
      ),
    );
    expect(await updater.fetchLatest(), isNull);
    final failed = service(
      client: MockClient((_) async => http.Response('offline', 503)),
    );
    expect(await failed.checkLatest(), isNull);
  });

  test('progress handles unknown length, percent, and installer phases', () {
    final known = AppUpdateProgress.fromMap({
      'phase': 'downloading',
      'received': '32',
      'total': 64,
    });
    expect(known.percent, 50);
    expect(known.indicatorValue, 0.5);
    expect(known.busy, isTrue);
    expect(
      const AppUpdateProgress(phase: 'downloading').indicatorValue,
      isNull,
    );
    expect(const AppUpdateProgress(phase: 'verifying').indicatorValue, 1);
    expect(const AppUpdateProgress(phase: 'awaiting_user').busy, isFalse);
    expect(const AppUpdateProgress(phase: 'failed').busy, isFalse);
  });

  testWidgets(
    'native download progress stays visible and prevents duplicate taps',
    (tester) async {
      await showButton(tester, service());
      await startUpdate(tester);
      expect(installCalls, 1);
      await progress({'phase': 'downloading', 'received': 50, 'total': 100});
      await tester.pump();
      expect(find.text('Downloading 50%'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.5,
      );
      await tester.tap(find.text('Downloading 50%'));
      await tester.pump();
      expect(installCalls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'permission return resumes progress without a second update click',
    (tester) async {
      installResult = 'settings';
      await showButton(tester, service());
      await startUpdate(tester);
      expect(find.text('Permission required'), findsOneWidget);
      await progress({'phase': 'downloading', 'received': 25, 'total': 100});
      await tester.pump();
      expect(find.text('Downloading 25%'), findsOneWidget);
      expect(installCalls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'installer failure exposes retry instead of a permanent spinner',
    (tester) async {
      await showButton(tester, service());
      await startUpdate(tester);
      await progress({'phase': 'failed', 'error': 'Installation cancelled'});
      await tester.pumpAndSettle();
      expect(find.text('Retry update'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('Installation cancelled'), findsOneWidget);
      await tester.tap(find.text('Retry update'));
      await tester.pumpAndSettle();
      expect(find.text('Update to 1.0.10'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets('a transient poll failure preserves the detected update', (
    tester,
  ) async {
    var calls = 0;
    final updater = service(
      client: MockClient((_) async {
        calls++;
        return calls == 1
            ? http.Response(jsonEncode(manifest), 200)
            : http.Response('offline', 503);
      }),
    );
    await showButton(tester, updater);
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Update'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));
}
