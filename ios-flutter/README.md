# ios-flutter

Flutter iOS runner for the shared [`../flutter`](../flutter) app.

This is **not** the native SwiftUI project. The native app lives in [`../ios`](../ios) and must stay separate.

```bash
cd ../flutter
flutter run -d ios --dart-define=API_BASE=http://127.0.0.1:3000
```

Or open `Runner.xcworkspace` from this folder after `flutter pub get` / pod install from the Flutter tooling.
