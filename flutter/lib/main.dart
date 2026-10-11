import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'core/theme.dart';
import 'features/home/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const FctvApp());
}

class FctvApp extends StatelessWidget {
  const FctvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FCTV33',
      debugShowCheckedModeBanner: false,
      theme: buildFctvTheme(),
      home: const HomePage(),
    );
  }
}
