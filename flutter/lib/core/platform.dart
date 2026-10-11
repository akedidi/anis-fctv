import 'package:flutter/foundation.dart';

/// Mini-player / in-app PiP is mobile-only (iOS/Android). Not used on web or desktop.
bool get supportsMiniPlayer {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;
}
