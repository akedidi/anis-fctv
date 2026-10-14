# FCTV33 — Android TV

Full Flutter client (same features as web / phone), without AirPlay and PiP.

## Prerequisites (already installable via CLI)

```bash
export ANDROID_HOME="$HOME/Library/Android/sdk"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
```

Installed for this project:

- Android SDK cmdline-tools
- Android Emulator
- Platform 34
- System image `system-images;android-34;android-tv;arm64-v8a`
- AVD **`FCTV_Android_TV`** (tv_1080p)

## Run

Terminal 1 — API (or use production Workers):

```bash
cd api && npm run dev:worker
# → http://127.0.0.1:3000
```

Terminal 2 — emulator:

```bash
emulator -avd FCTV_Android_TV -gpu auto
```

Terminal 3 — app (emulator reaches host via `10.0.2.2`):

```bash
cd flutter
flutter pub get
flutter run -d emulator-5554 \
  --dart-define=API_BASE=http://10.0.2.2:3000
```

Production API:

```bash
flutter run -d emulator-5554 \
  --dart-define=API_BASE=https://fctv33-api.kedidi-anis.workers.dev
```

## What TV gets

| Feature | Android TV |
|---------|------------|
| Live list + auto refresh | ✅ |
| Match detail / servers / HLS | ✅ |
| Overview events, lineups, stats, H2H | ✅ |
| D-pad focus (list + chrome) | ✅ |
| Dual-pane landscape shell | ✅ |
| Leanback launcher + banner | ✅ |
| AirPlay | ❌ |
| PiP / mini-player | ❌ |

## Build APK

```bash
cd flutter
flutter build apk --release \
  --dart-define=API_BASE=https://fctv33-api.kedidi-anis.workers.dev
# → build/app/outputs/flutter-apk/app-release.apk
# → build/android-tv/FCTV33-tv-release.apk
```

Same binary as mobile: at runtime TV disables PiP / AirPlay and uses the leanback shell.
