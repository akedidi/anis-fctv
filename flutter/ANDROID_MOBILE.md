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
  --target-platform android-arm64,android-arm \
  --dart-define=API_BASE=https://fctv33-api.kedidi-anis.workers.dev \
  --android-project-arg=fctvAbiFilters=arm64-v8a,armeabi-v7a
```

Same size cut as Android TV: ARM only (no x86 emulator libs).

Output:

- `build/app/outputs/flutter-apk/app-release.apk`
- Release asset: `fctv-mobile-<version>.apk` on GitHub Releases (`android-mobile-*` tags)

In-app updates use `releases/android-mobile/latest.json` (same updater as TV).

## Install on a phone

```bash
adb install -r build/android-mobile/fctv-mobile-1.0.6.apk
```

Or copy the APK to the device and open it (enable “Install unknown apps” if needed).

## Run from source

```bash
flutter run -d <android-device-id> \
  --dart-define=API_BASE=https://fctv33-api.kedidi-anis.workers.dev
```
