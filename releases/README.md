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
