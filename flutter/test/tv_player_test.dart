import 'dart:async';

import 'package:fctv33/core/platform.dart';
import 'package:fctv33/features/player/stream_player.dart';
import 'package:fctv33/shared/tv_focus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _VideoPlatform extends VideoPlayerPlatform {
  VideoCreationOptions? creation;
  final events = StreamController<VideoEvent>();
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    creation = options;
    return 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events.stream;
  @override
  Future<void> dispose(int playerId) async {
    await events.close();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox(key: ValueKey('native video surface'));
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late VideoPlayerPlatform previous;
  late _VideoPlatform video;
  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      platformChannel,
      (call) async => call.method == 'isAndroidTv' ? true : null,
    );
    await detectAndroidTv();
    previous = VideoPlayerPlatform.instance;
    video = _VideoPlatform();
    VideoPlayerPlatform.instance = video;
  });
  tearDown(() {
    VideoPlayerPlatform.instance = previous;
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      platformChannel,
      null,
    );
  });
  for (final fullscreen in [false, true]) {
    testWidgets('Pause Down targets fullscreen (fullscreen=$fullscreen)', (
      tester,
    ) async {
      var toggles = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StreamPlayer(
              url: 'https://example.com/test.m3u8',
              title: 'TV test',
              isFullscreen: fullscreen,
              onToggleFullscreen: () => toggles++,
            ),
          ),
        ),
      );
      await tester.pump();
      video.events.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(minutes: 1),
          size: const Size(1920, 1080),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // Protect the native-surface workaround used on Fire TV.
      expect(video.creation!.viewType, VideoViewType.platformView);
      final surface = find.byKey(const ValueKey('native video surface'));
      expect(surface, findsOneWidget);
      expect(
        find.ancestor(of: surface, matching: find.byType(FittedBox)),
        findsNothing,
      );
      expect(
        find.ancestor(of: surface, matching: find.byType(ClipRRect)),
        findsNothing,
      );
      final play = tester.widget<TvFocusIconButton>(
        find.byWidgetPredicate(
          (w) =>
              w is TvFocusIconButton &&
              (w.tooltip == 'Pause' || w.tooltip == 'Play'),
        ),
      );
      play.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      final target = tester.widget<TvFocusIconButton>(
        find.byWidgetPredicate(
          (w) =>
              w is TvFocusIconButton &&
              w.tooltip == (fullscreen ? 'Exit fullscreen' : 'Fullscreen'),
        ),
      );
      expect(target.focusNode!.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(toggles, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
