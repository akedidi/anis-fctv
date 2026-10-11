# FCTV33 monorepo

| Path | Role |
|------|------|
| [`ios/`](ios/) | **Native SwiftUI app — do not mix with Flutter** |
| [`ios-flutter/`](ios-flutter/) | Flutter iOS runner (Xcode project for the Flutter client) |
| [`flutter/`](flutter/) | Shared Flutter UI (web, Android, Android TV, ios-flutter) |
| [`api/`](api/) | Node API (live / detail / resolve / HLS proxy) for all Flutter targets |
| [`fctv33-stream-resolver/`](fctv33-stream-resolver/) | Historical Node prototype (reference) |
| [`web/`](web/) | Abandoned Next.js scaffold (optional cleanup) |

`flutter/ios` is a symlink → `../ios-flutter` so the native `ios/` folder stays untouched and unambiguous.

## API (local)

```bash
cd api
npm install
npm run dev
```

Health: `http://127.0.0.1:3000/api/health`

## Flutter

```bash
cd flutter
flutter pub get
# phone / desktop / chrome
flutter run -d chrome --dart-define=API_BASE=http://127.0.0.1:3000
# Android
flutter run -d android --dart-define=API_BASE=http://10.0.2.2:3000
```

Open the Flutter iOS runner (not the native app):

```bash
open ios-flutter/Runner.xcworkspace
# or
cd flutter && flutter run -d ios --dart-define=API_BASE=http://127.0.0.1:3000
```

## Vercel

1. **API project**: Root Directory = `api` → deploy.
2. **Flutter web**: build then host static output:

```bash
cd flutter
flutter build web --dart-define=API_BASE=https://YOUR-API.vercel.app
# deploy build/web (Vercel static / any CDN)
```

## Android TV

The Android manifest includes Leanback / touchscreen-not-required so the same APK can run on Android TV. Use D-pad focus on the event list and server chips.
