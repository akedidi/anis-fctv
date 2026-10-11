# anis-fctv (FCTV33)

Remote: **https://github.com/akedidi/anis-fctv**

## Où est mon app ?

| Dossier | C’est quoi | Comment l’ouvrir |
|---------|------------|------------------|
| **`ios/`** | Ton app iOS **native** (SwiftUI) — celle qui marchait déjà | Xcode → `ios/FCTV.xcworkspace` |
| **`flutter/`** | Nouvelle app multiplateforme (web + Android + TV) | `cd flutter && flutter run` |
| **`ios-flutter/`** | Runner iOS **Flutter** (pas le natif) | généré pour Flutter ; ne pas confondre avec `ios/` |
| **`api/`** | Backend live / resolve / HLS pour Flutter | `cd api && npm run dev` → http://127.0.0.1:3000 |

L’app iOS native n’a **pas été effacée** : elle est dans `ios/` (ex-dossier `FCTV/`).

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

## API on Cloudflare Workers (recommended)

Avoids Vercel Deployment Protection / cold-start flakes for `/api/match/events` etc.

```bash
cd api
npm install
npx wrangler login          # once
npm run deploy:worker
```

**Production API:** https://fctv33-api.kedidi-anis.workers.dev

Local worker:

```bash
cd api && npm run dev:worker   # http://127.0.0.1:3000
```

## Vercel (`web-snowy-alpha-91` / projet `web`)

Root Directory Vercel = **`flutter/`** (pas `web/`). Build = Flutter web avec :

`API_BASE=https://fctv33-api.kedidi-anis.workers.dev`

L’UI prod = **la même app que `flutter run`**. Le Next.js dans `web/` n’est plus déployé sur cette URL.

| Appel | Où | Pourquoi |
|-------|-----|----------|
| live / match / events / lineup / resolve | **Workers** | session + signatures côté serveur |
| HLS playlist + segments | **Workers** `/api/hls` | Referer / geo CDN obligatoires |
| UI (HTML/JS) | **Vercel** static | CDN front |

On ne peut pas appeler le CDN match/events directement depuis le navigateur (auth/session). Seul le player consomme le flux HLS, toujours via le proxy Workers.

Redeploy rapide (build local) :

```bash
cd flutter
flutter build web --release --dart-define=API_BASE=https://fctv33-api.kedidi-anis.workers.dev
# temporairement rootDirectory=null sur le projet Vercel, puis :
npx vercel deploy build/web --prod --yes
```


## Android TV

The Android manifest includes Leanback / touchscreen-not-required so the same APK can run on Android TV. Use D-pad focus on the event list and server chips.
