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
3. Create a GitHub Release tag, e.g. `android-tv-1.0.1` / `android-mobile-1.0.1`, and attach the APK.
4. Update the matching `latest.json` (`versionCode`, `versionName`, `apkUrl`, `changelog`).
5. Commit & push this repo so clients can read:

`https://raw.githubusercontent.com/akedidi/anis-fctv/main/releases/<channel>/latest.json`
