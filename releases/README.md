# App releases (Android)

Each device channel has its own folder and `latest.json` so TV and mobile can ship independently.

| Folder | Device |
|--------|--------|
| `android-tv/` | Android TV / Google TV |
| `android-mobile/` | Phone / tablet |

## `latest.json` schema

```json
{
  "channel": "android-tv",
  "versionCode": 2,
  "versionName": "1.0.1",
  "apkUrl": "https://github.com/akedidi/anis-fctv/releases/download/android-tv-1.0.1/FCTV33-tv-release.apk",
  "changelog": "What changed",
  "publishedAt": "2026-10-13"
}
```

- **`versionCode`** — must match Flutter `pubspec.yaml` build number (`1.0.1+2` → `2`). The app shows **Update** only when this is greater than the installed code.
- **`apkUrl`** — public HTTPS URL of the APK (prefer [GitHub Releases](https://github.com/akedidi/anis-fctv/releases); do **not** commit large APK binaries into git).

## In-app installation (1.0.11 / build 12)

The Android TV and mobile updater follow the current AnisFlix build 45 flow:

- Check the matching channel at startup and every 30 seconds. Only offer a
  build number strictly higher than the installed version; keep a detected update
  if a background check temporarily fails.
- Show download progress and retry up to three times. Follow HTTPS redirects,
  verify the manifest SHA-256 when provided, and reuse an already verified APK
  if the installer was previously dismissed.
- Resume automatically after the user grants installation permission.
- Open the complete system APK installer with ACTION_VIEW, a FileProvider URI,
  ClipData and a temporary read grant. EXTRA_RETURN_RESULT is false so Android
  retains its final **Open / Done** screen. ACTION_INSTALL_PACKAGE is a fallback
  for devices without an APK viewer.
- Let the user choose **Open** or **Done**. There are no package replacement
  receivers, automatic relaunches or overlay permission requests.
- Keep the cached APK throughout installation. Clean it on the first start of
  a successfully upgraded version. Cancellation preserves it for retry.

An update started from 1.0.10 or an older version still uses that version's
installer. To get the complete Open / Done flow for this first transition, open
this APK with Downloader. Updates started from 1.0.11 use the new flow on both
mobile and TV. The stable URLs and Downloader codes below are unchanged.

Updater tests:

```bash
cd flutter
flutter test test/app_update_test.dart
```

`flutter/tool/update_install_smoke.dart` is a device-only test entry point for
the complete system installer and its final Open / Done screen. Build it with a lower build number than
the staged release and supply the staged APK's SHA-256 as UPDATE_TEST_SHA256.
It does not change the public update channel.

## Publish a new build

1. Bump `flutter/pubspec.yaml` (`version: x.y.z+N`).
2. Build the APK (`flutter build apk --release …`).
3. **Android TV (Downloader `5471757`)** — always **overwrite** the stable asset (do not change the URL):

   ```bash
   cp app-release.apk /tmp/fctv-tv-1.0.3.apk
   gh release upload android-tv-1.0.3 /tmp/fctv-tv-1.0.3.apk --clobber
   ```

   Stable URL (in-app update + Downloader code):
   `https://github.com/akedidi/anis-fctv/releases/download/android-tv-1.0.3/fctv-tv-1.0.3.apk`

4. **Android mobile (Downloader `2306515`)** — always **overwrite** the stable asset:

   ```bash
   cp app-release.apk /tmp/fctv-mobile-1.0.6.apk
   gh release upload android-mobile-1.0.6 /tmp/fctv-mobile-1.0.6.apk --clobber
   ```

   Stable URL:
   `https://github.com/akedidi/anis-fctv/releases/download/android-mobile-1.0.6/fctv-mobile-1.0.6.apk`

5. Update the matching `latest.json` (`versionCode`, `versionName`, `apkUrl`, `changelog`, optional `sha256`).
6. Commit & push this repo so clients can read:

`https://raw.githubusercontent.com/akedidi/anis-fctv/main/releases/<channel>/latest.json`
