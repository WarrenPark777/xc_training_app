# Chadwick XC Training App

A Flutter app for a cross country team. It shows an athlete their recent training — weekly mileage, trend, and each run's route and metrics — and uploads **recorded workouts only** to a server for team-wide analysis: each workout record plus the heart rate, steps, distance, and calories within ±10 minutes of it. Nothing between workouts leaves the phone (no sleep, resting HR, or all-day streams).

The training views are computed on-device from the phone's health store, so they work offline. Team-wide analysis happens server-side.

Runs on **Android** (Health Connect) and **iOS** (HealthKit).

## Prerequisites

- Flutter 3.44+
- A server implementing the upload contract — see [docs/SERVER_SCHEMA.md](docs/SERVER_SCHEMA.md)
- **Android:** device on API 28+ with Health Connect installed and populated (Fitbit, Strava, Google Fit, Wear OS, etc.), USB debugging enabled
- **iOS:** macOS with the full **Xcode** + **CocoaPods**, and a **physical iPhone** — HealthKit and GPS routes don't exist on the Simulator. A free Apple ID signs dev builds onto your own device; TestFlight/App Store needs the paid Apple Developer Program. See [CLAUDE.md](CLAUDE.md) "iOS / HealthKit gotchas".

## Run

```bash
flutter pub get
flutter devices               # confirm your device is listed
```

Point the app at your server with `config/dev.json` (copy `config/dev.json.example`) — see [CLAUDE.md](CLAUDE.md) "Server config".

**Android:**

```bash
flutter run -d <device-id> --dart-define-from-file=config/dev.json
```

**iOS** — build and install via `devicectl` (more reliable than `flutter run` on Xcode 26; keep the iPhone **unlocked**, and use a **release** build — debug builds crash on ProMotion devices, see [CLAUDE.md](CLAUDE.md)):

```bash
flutter build ios --release --dart-define-from-file=config/dev.json
xcrun devicectl device install app --device <udid> build/ios/iphoneos/Runner.app
xcrun devicectl device process launch --device <udid> com.github.codingwithwarren.xctraining
```

## Current state

Working end-to-end on Android and iOS phones.

**Sign-in and permissions** — Google Sign-In (or dev-login) → server JWT; health permissions are auto-detected and requested on launch, with guided onboarding (3 steps on Android, 2 on iOS — see [CLAUDE.md](CLAUDE.md)).

**Uploading** — every sync reconciles the last 30 days: it reads the workouts in that window, skips the ones the server already has, and POSTs the rest as `type: "health_sync"` with the samples around each one. Reconciling (rather than syncing forward from a watermark) means a workout that arrives with a backdated timestamp — a Garmin activity that syncs days late — still gets picked up. The server is the source of truth for what's been uploaded: `GET /me/last-sample-time` returning null drops the local record and re-reconciles the whole window.

**Background sync** — runs unattended when "Upload automatically" is on: WorkManager on Android (~15 min cadence), `BGAppRefreshTask` plus a HealthKit workout observer on iOS. Both wake a headless Dart isolate that runs the same `SyncService` as the foreground app.

**Training views** — a Training tab (this week's run miles / runs / time, the change vs last week, a four-week mileage chart, recent activity) and a Runs tab listing each workout with distance, duration, and pace. Tapping a run shows its GPS route on a map plus its metrics. All computed on-device, so they work offline.

## Roadmap

Still open:

1. Server-backed views — season history and team/coach features (leaderboard, roster, assigned workouts) need new server endpoints
2. Run detail depth — per-mile splits, HR-zone breakdown, pace-colored route
3. iOS: TestFlight / App Store distribution (needs the paid Apple Developer Program)
4. Remove the debug-only UI section (already hidden in release builds)
5. Drop the local-dev cleartext exceptions (`usesCleartextTraffic` on Android, `NSAllowsArbitraryLoads` on iOS) once local-HTTP development is no longer needed

Already shipped (was on the roadmap):

- **Background sync** — WorkManager on Android, BGTask + HealthKit background delivery on iOS; both gated on the automatic-upload toggle.
- **Multi-athlete** — Google Sign-In → server JWT; the server keys all data to the athlete in the token and ignores the payload's `athlete_id`. Any number of athletes can sign in.
- **HTTPS** — the shared server runs behind valid TLS at `https://xc-server.duckdns.org`.
- **GPS routes** — read from Health Connect via a native route-consent flow (see [CLAUDE.md](CLAUDE.md)), so the planned Strava OAuth path isn't needed.
- **Server-side session detection from raw streams** — obsoleted by the workout-only upload policy (raw 24/7 streams are no longer uploaded); detection/classification now applies only within uploaded workout windows.

## Where things live

- [lib/main.dart](lib/main.dart) — UI: onboarding, the Training / Runs / Settings tabs, the run detail page, and the debug tools
- [lib/sync_service.dart](lib/sync_service.dart) — the sync engine, free of any UI. Shared by the app and the background isolates
- [lib/background_sync.dart](lib/background_sync.dart) — headless entrypoints and scheduling for Android and iOS background sync
- [lib/auth_service.dart](lib/auth_service.dart) — Google / dev sign-in and JWT persistence
- [lib/training_week.dart](lib/training_week.dart) — weekly mileage bucketing and the chart (unit tested in [test/](test/))
- [docs/SERVER_SCHEMA.md](docs/SERVER_SCHEMA.md) — upload contract: payload shape, dedup strategy, suggested Postgres tables, session-detection algorithm
- [CLAUDE.md](CLAUDE.md) — coding conventions, server/auth config, and Android/Health Connect + iOS/HealthKit gotchas
