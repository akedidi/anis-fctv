# FCTV33 — Android mobile (phone / tablet)

Same Flutter client as web & TV, with **PiP** and **AirPlay / Cast** chrome enabled on phones.

| Feature | Android phone | Android TV |
|---------|---------------|------------|
| Live list / detail / HLS | ✅ | ✅ |
| Mini-player | ✅ | ❌ |
| System Picture-in-Picture | ✅ | ❌ |
| AirPlay / Cast button | ✅ (Cast hint) | ❌ |
| Dual-pane leanback shell | wide screens | always |
| Video (`mediacodec_embed`) | ✅ | emulator ✅ / device `gpu` |

Phone emulator AVD: **`FCTV_Android_Phone`** (Pixel 6 / API 34).

> Impeller is disabled on Android — it often causes a black `media_kit` surface.

## Build APK

```bash
cd flutter
flutter pub get
flutter build apk --release \
  --dart-define=API_BASE=https://fctv33-api.kedidi-anis.workers.dev
```

Output:

- `build/app/outputs/flutter-apk/app-release.apk`
- Copied as `build/android-mobile/FCTV33-mobile-release.apk` by the build script below

## Install on a phone

```bash
adb install -r build/android-mobile/FCTV33-mobile-release.apk
```

Or copy the APK to the device and open it (enable “Install unknown apps” if needed).

## Run from source

```bash
flutter run -d <android-device-id> \
  --dart-define=API_BASE=https://fctv33-api.kedidi-anis.workers.dev
```
