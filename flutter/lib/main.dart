import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';

import 'core/theme.dart';
import 'features/home/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Paint the shell first — MediaKit is only needed once a stream opens.
  runApp(const FctvApp());
  SchedulerBinding.instance.addPostFrameCallback((_) {
    MediaKit.ensureInitialized();
  });
}

class FctvApp extends StatelessWidget {
  const FctvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FCTV33',
      debugShowCheckedModeBanner: false,
      theme: buildFctvTheme(),
      builder: (context, child) {
        // Cap text scale so web/mobile zoom doesn’t blow the iOS-like chrome.
        final media = MediaQuery.of(context);
        final scale = media.textScaler.clamp(minScaleFactor: 0.9, maxScaleFactor: 1.15);
        return MediaQuery(
          data: media.copyWith(textScaler: scale),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const HomePage(),
    );
  }
}
