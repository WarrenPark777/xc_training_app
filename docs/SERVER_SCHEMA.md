# Server Schema — Chadwick XC Training App Upload

This document describes the JSON payload the **Chadwick XC Training** mobile app POSTs to the analysis server.

**The app uploads workout data only** (privacy decision, July 2026). Each sync ships the recorded workouts in the window plus the continuous streams (heart rate, steps, distance, calories) read **only within ±10 minutes of each workout** — warm-up/cool-down context. Nothing between workouts leaves the phone, and the recovery streams (sleep, HRV, resting heart rate, respiratory rate) are no longer read, requested, or uploaded at all — their payload arrays are gone.

Consequence for the server: **session detection from raw 24/7 streams no longer applies** — an activity the recording app didn't wrap in an `ExerciseSessionRecord` never reaches the server. Detection/classification logic still applies *within* uploaded workout windows (e.g. relabeling Fitbit's `OTHER`).

The client remains a thin uploader. It does **not** aggregate, smooth, classify, or compute derived metrics. All of that happens server-side.

---

## Transport

| | |
|---|---|
| Method | `POST` |
| URL | `<base>/workouts` for the sync, `<base>/auth/google` and `<base>/auth/dev-login` for auth. `<base>` comes from `--dart-define=SERVER_URL=...` (see `config/dev.json.example`) and defaults to `http://10.0.2.2:8000` (the Android emulator's alias for the host's localhost). |
| Content-Type | `application/json` |
| Body encoding | UTF-8 JSON |
| Timeout (client) | 120 seconds |
| Auth | **Required.** `Authorization: Bearer <server JWT>` — see "Auth" below. Requests without it get `401`. |

The client treats any `2xx` response as success. `4xx` and `5xx` are surfaced to the user as errors with the response body included for debugging.

`10.0.2.2` is the Android emulator's alias for the host machine's localhost. From a physical phone, replace with the LAN IP (or the public URL once deployed).

### Auth

The client signs in with Google (Google Sign-In SDK / Credential Manager on
Android), then exchanges the **Google ID token** for the server's own JWT:

```
POST /auth/google
{ "id_token": "<google id token>" }
→ { "access_token": "<server jwt>", "token_type": "bearer", "athlete": {...} }
```

The server must validate the Google ID token's `aud` (audience) claim, but
**`aud` is not the same value on every platform** — so the server has to accept
*any of this project's own OAuth client IDs*, not a single hard-coded one:

| Platform | `aud` on the ID token | Why |
|---|---|---|
| Android | **Web** client ID | `GoogleSignIn.initialize(serverClientId:)` mints the token for the web/server client. |
| iOS | **iOS** client ID | The GoogleSignIn-iOS SDK always stamps the token with the app's *own* iOS client ID. `serverClientId` only produces a separate `serverAuthCode` — it does **not** change `aud`. |

So the server must treat the token as valid when `aud` matches **any** client ID
registered to this project. Verify the signature/issuer as usual, then check
`aud` against an allow-list:

| Role | Client ID |
|---|---|
| Web (server audience) | `210202837170-t1hhp4v24n8fqs6a5kfcb201k2rkvik6.apps.googleusercontent.com` |
| iOS | *(create in project `210202837170` for bundle ID `com.github.codingwithwarren.xctraining`, then list it here and update `GIDClientID` + the reversed-ID URL scheme in `ios/Runner/Info.plist` — the plist still holds the retired project's client)* |

All clients live in Google Cloud project `210202837170` (the org's management
account); the original `573308562088` project is retired — tokens minted for
its client IDs get `401 audience mismatch`. Android never appears in this
allow-list: Android ID tokens carry the *web* client ID as `aud`. (The Android
OAuth client — `210202837170-563u76fequa3lh7ntuvsjchu9dkbrpmv` — still has to
*exist* in the project, paired with the app's package name and signing SHA-1,
but it never shows up as a token audience.)

This is still safe: the allow-list contains only *our* OAuth clients, so an ID
token minted for an unrelated app is still rejected (`401`, "Google token
audience mismatch"). Pin the audience to a single value and iOS sign-ins fail
even though Android works.

> Implementation note (google-auth / Python): call
> `id_token.verify_oauth2_token(token, request)` **without** the `audience=`
> argument (which pins a single value), then assert `idinfo["aud"]` is in the
> allow-list above.

Send `Authorization: Bearer <access_token>` on every subsequent request and
persist the token (it currently lasts 30 days; the server will add refresh
tokens later). On `401`, re-run the Google exchange. First sign-in creates the
athlete server-side from the Google profile.

The server derives the athlete from the token — the payload's `athlete_id`
field is now **deprecated and ignored** (still accepted so old builds parse).
One athlete cannot upload as another.

During development the server may run with `DEV_MODE=true`, which adds
`POST /auth/dev-login` (`{"email": "..."}` → same token response) so the app
can be tested without a Google round-trip.

### Body size

Uploads are workout-scoped, so payloads are small: a 45-minute workout (±10 min padding) with a Fitbit-class 1 Hz HR sensor is roughly ~4,000 HR samples plus a few hundred interval records — **well under 1 MB per workout**. Even a 30-day backfill with daily workouts stays in the single-digit MB range. (Historical note: the old whole-window uploads ran ~15 MB per 30 days — the `client_max_body_size 32m` reverse-proxy bump from that era is still safe to keep.)

---

## Top-level payload

```json
{
  "type": "health_sync",
  "athlete_id": 1,
  "client_version": "1.0.0+1",
  "uploaded_at": "2026-06-07T19:09:35.982Z",
  "source_platform": "googleHealthConnect",
  "window_start": "2026-05-08T19:09:35.982Z",
  "window_end":   "2026-06-07T19:09:35.982Z",

  "workouts": [ /* see "Workouts" below — may be empty */ ],

  "heart_rate_samples":         [ /* NumericSample, BPM       */ ],

  "step_samples":               [ /* IntervalSample, count    */ ],
  "distance_samples":           [ /* IntervalSample, meters   */ ],
  "total_calorie_samples":      [ /* IntervalSample, kcal     */ ],
  "active_energy_samples":      [ /* IntervalSample, kcal     */ ]
}
```

All sample arrays contain only records within ±10 minutes of a workout in
`workouts`. The previously documented streams — `speed_samples`,
`hrv_rmssd_samples`, `resting_heart_rate_samples`, `respiratory_rate_samples`,
`blood_oxygen_samples`, `skin_temperature_samples`, `body_temperature_samples`,
`basal_energy_samples`, `flights_climbed_samples`,
`activity_intensity_samples`, `sleep_sessions`, and the `sleep_*_samples`
stage arrays — **are no longer sent** (workout-only upload policy). The server
should tolerate their absence; old rows already stored can stay.

| Field | Type | Notes |
|---|---|---|
| `type` | string literal `"health_sync"` | Discriminator. |
| `athlete_id` | integer | **Deprecated — ignored.** The server attributes the upload to the athlete in the Bearer token. |
| `client_version` | string | App version. |
| `uploaded_at` | ISO-8601 UTC | When the client built the payload. |
| `source_platform` | string | `"googleHealthConnect"` (Android) or `"appleHealthKit"` (iOS, future). |
| `window_start` / `window_end` | ISO-8601 UTC | The time range the client queried — now always the **full history window** (last 30 days). Each sync reconciles that whole window: it reads every workout in it and uploads the ones a local record doesn't yet mark as on the server (dropping that record, so re-sending everything, whenever `GET /me/last-sample-time` reports no data). The `workouts` array therefore holds only the *missing* workouts, not the whole window; the composite-key upsert still makes any overlap idempotent. |
| `backfill` | boolean, **optional** | Present and `true` only when the upload came from the debug **"Upload Past 30 Days"** button, which ignores the watermark and re-sends the full history window. Storage needs no special handling — the composite-key upserts dedup the overlap — but the flag lets the server distinguish a deliberate re-send from a real gap: skip overlap/anomaly warnings, log it as a backfill, and re-run session detection over the whole window. Absent on normal syncs. |
| `workouts` | array | Explicit exercise sessions the recording app wrote. May be empty. |
| `*_samples` arrays | array | Samples within **±10 minutes of a workout** in `workouts` (never the whole window). Empty array if there were no workouts, the type had no data, or it wasn't permissioned. |

Arrays are always present even when empty — makes the schema easy to consume.

---

## Sample shapes

### `NumericSample` — point-in-time reading

```json
{
  "uuid":   "61c2e4f1-14a3-4f00-a47d-be314801d6f4",
  "time":   "2026-06-06T15:54:00.000Z",
  "value":  107,
  "unit":   "BEATS_PER_MINUTE",
  "source": "com.fitbit.FitbitMobile",
  "recording_method": "automatic"
}
```

### `IntervalSample` — value measured over a span

```json
{
  "uuid":   "8b95a048-0f5d-4057-be86-f28d72c97c4a",
  "start":  "2026-06-06T15:08:00.000Z",
  "end":    "2026-06-06T15:09:00.000Z",
  "value":  64.1,
  "unit":   "METER",
  "source": "com.fitbit.FitbitMobile",
  "recording_method": "automatic"
}
```

`value` is a `number` (int or float depending on the source — store as `float`).
`unit` strings are stable: `BEATS_PER_MINUTE`, `METER`, `KILOCALORIE`, `COUNT`, `METER_PER_SECOND`, `MILLISECOND`, `RESPIRATIONS_PER_MINUTE`, `PERCENT`, `DEGREE_CELSIUS`, `MINUTE`.

---

## Workouts

When present, a workout is what the recording app (Strava, Fitbit, Google Fit, etc.) wrote as a discrete `ExerciseSessionRecord`. Treat them as **hints, not ground truth** — many Fitbit-tracked treadmill sessions never get an ExerciseSessionRecord written, which is exactly why the server does its own detection from the raw streams below.

```json
{
  "source_uuid":     "409236da-213c-346b-a9f9-dcacacc56968",
  "source_app":      "com.strava",
  "source_device_id":"unknown",
  "activity_type":   "RUNNING",
  "recording_method":"unknown",
  "start_time":      "2026-06-06T15:53:49.000Z",
  "end_time":        "2026-06-06T16:02:36.000Z",
  "duration_seconds": 527,
  "total_distance_meters": 3374,
  "total_energy_kcal":     130,
  "total_steps":           3054
}
```

`activity_type` values seen so far: `RUNNING`, `WALKING`, `BIKING`, `OTHER`. Full enum is the `health` package's `HealthWorkoutActivityType`.

`recording_method` values: `automatic`, `manual`, `active`, `unknown`.

`source_uuid` is the **dedup key** — see "Dedup" below.

---

## Server-side exercise-session detection

This is the whole point of sending raw streams. The recipe:

### Inputs
- `heart_rate_samples` — typically ~1 Hz from a wrist tracker, BPM
- `step_samples` — interval records, value = step count, span typically 1 minute
- `distance_samples`, `total_calorie_samples` — corroborating signals

### Algorithm (start simple, refine later)

```python
# Pseudocode
def detect_sessions(hr_samples, step_samples,
                    athlete_resting_hr=60,
                    athlete_max_hr=190):
    # 1. Build a 1-minute time grid across the window.
    #    For each minute: median HR, total steps.
    grid = build_minute_grid(hr_samples, step_samples)

    # 2. Mark "active" minutes:
    #    HR ≥ resting + 40%  (or fixed 130 BPM as a fallback)
    #    AND steps_per_min ≥ 60 (filters out HR spikes from stress/heat)
    hr_threshold = athlete_resting_hr + 0.4 * (athlete_max_hr - athlete_resting_hr)
    for minute in grid:
        minute.active = (minute.median_hr >= hr_threshold
                         and minute.steps_per_min >= 60)

    # 3. Group consecutive active minutes, allowing ≤ 2-min gaps
    #    (a quick water break shouldn't end the session).
    sessions = group_runs(grid, gap_tolerance=2)

    # 4. Drop sessions shorter than 5 minutes (too short to be a workout).
    sessions = [s for s in sessions if s.duration_minutes >= 5]

    # 5. Per session, compute:
    return [
        DetectedSession(
            start = s.start,
            end = s.end,
            duration_seconds = (s.end - s.start).total_seconds(),
            peak_hr = max(m.median_hr for m in s.minutes),
            avg_hr  = mean(m.median_hr for m in s.minutes),
            total_steps = sum(m.total_steps for m in s.minutes),
            avg_steps_per_min = total_steps / s.duration_minutes,
            # likely a run if avg cadence ≥ ~150 spm, else walk/other
            inferred_activity = "RUNNING" if avg_steps_per_min >= 150 else "WALKING",
            source_workout_uuid = match_to_explicit_workout(s, workouts),
        )
        for s in sessions
    ]
```

### Tuning notes
- **HR threshold is athlete-specific.** Stash `resting_hr` and `max_hr` per athlete (220-age is fine as a starting heuristic). Falling back to a fixed 130 BPM works OK for the cross country team age range.
- **Smooth before thresholding.** 1-Hz HR is noisy; a 5-sample rolling median kills spikes from sensor artifacts.
- **Dedup steps by source before computing cadence.** Steps arrive from several sources at once (Fitbit + Android + Health Connect's aggregator) that redundantly count the *same* steps, often with overlapping records — summing them roughly **doubles** cadence. Pick one primary source (e.g. the wrist tracker — in practice the source with the most records) and take the largest record per minute; don't sum across sources.
- **Walk-vs-run cutoff is roughly 150 spm cadence.** Treadmill walks land 80-110; runs land 160-185.
- **Reconcile with the `workouts` array.** If a detected session's window overlaps an explicit workout, prefer the explicit `activity_type` and use the session's HR/step stats to enrich it. If a detected session has no matching explicit workout, you've recovered a Fitbit-untagged treadmill session — exactly the case that motivated this design.
- **Recurring false-positives.** Long brisk walks will trip the threshold; that's correct behavior — capture them and let the user classify on the dashboard if it matters.

### Data quality flags worth recording per detected session
- HR coverage % within the session window (gaps indicate sensor was off)
- Did the session source the HR from one source only, or multiple (less reliable)
- Whether it matches an explicit workout vs detected-only

---

## Dedup

`source_uuid` is the dedup key for workouts. For samples the key depends on the stream:

- **Heart rate → `(uuid, time)`.** A Health Connect `HeartRateRecord` is a *series*: one record (one `uuid`) carries many timestamped readings, so `uuid` alone is **not** unique per reading — deduping on it would collapse the whole series into one row. (Observed in real data: ~165k HR readings shared only ~6.7k uuids.)
- **Interval streams → `(uuid, stream, start_time)`.** Steps/distance/calories have unique uuids, but a `SleepSessionRecord` decomposes into per-stage rows (DEEP/REM/LIGHT/AWAKE plus the session itself) that **all share the parent session's uuid** — so `uuid` alone would collapse a whole night into one row. (Observed: a session row and its first DEEP row shared `81694f2a-…`.) The composite key is safe for every interval stream.

```sql
-- heart rate: composite key (uuid, time)
INSERT INTO heart_rate_samples (uuid, athlete_id, time, bpm, source, recording_method)
VALUES (...)
ON CONFLICT (uuid, time) DO UPDATE SET
  bpm = EXCLUDED.bpm,
  source = EXCLUDED.source;

-- interval streams: composite key (sleep stages share the session uuid)
INSERT INTO interval_samples (uuid, stream, start_time, ...) VALUES (...)
ON CONFLICT (uuid, stream, start_time) DO UPDATE SET value = EXCLUDED.value, ...;
```

Re-uploads with the same keys idempotently update. The client syncs incrementally, and **the server owns the watermark**: before each sync the client calls `GET /me/last-sample-time` (below) and re-queries `[watermark - 24 hours, now]`. The 24-hour overlap re-reads the tail of the previous window so records that arrive in Health Connect late still get captured — a workout can land hours after it happened (Fitbit syncs to the phone lazily), and HR batches 30–60 minutes behind — and your composite-key dedup is what makes that overlap free. When the server has no data for the athlete (first sync, or right after `DELETE /me/data`), the client uploads the last 24 hours.

### Sync watermark: `GET /me/last-sample-time`

Returns the newest sample timestamp the server has stored for the authenticated athlete, across **all** ingested tables (workouts, numeric samples, interval samples). This replaces the client-side watermark: a reinstall or a second device automatically resumes where the athlete's data actually ends.

```
GET /me/last-sample-time
Authorization: Bearer <jwt>
→ 200 { "last_sample_time": "2026-07-04T21:18:30Z" }   // ISO-8601 UTC
→ 200 { "last_sample_time": null }                      // no data yet
```

The value must be the max of the *end* timestamps (`end_time` for workouts and interval samples, the sample `time` for numeric streams) — the same quantity the client previously tracked. FastAPI sketch:

```python
@app.get("/me/last-sample-time")
def last_sample_time(athlete=Depends(current_athlete)):
    times = [
        db.scalar(select(func.max(Workout.end_time)).where(Workout.athlete_id == athlete.id)),
        db.scalar(select(func.max(NumericSample.time)).where(NumericSample.athlete_id == athlete.id)),
        db.scalar(select(func.max(IntervalSample.end_time)).where(IntervalSample.athlete_id == athlete.id)),
    ]
    newest = max((t for t in times if t is not None), default=None)
    return {"last_sample_time": newest.isoformat() if newest else None}
```

Performance note: this endpoint is hit at the start of every sync **and** every time the home screen recomputes its status, so the `MAX()` on the one large table (heart-rate samples) must be an index-only seek — it needs an `(athlete_id, time)` index. Small tables (workouts, interval samples) can just scan. Streams the server doesn't persist in queryable tables simply don't contribute, which is fine: live HR densely tracks the true data end, and the client's 24-hour re-query overlap is what catches late-arriving derived data (resting HR, HRV, sleep) regardless. A watermark that under-reports only causes some re-upload, which the composite-key dedup absorbs; it can never create a gap.

---

## Data quality notes

1. **Multiple sources per stream.** Heart rate may come exclusively from Fitbit; steps from Fitbit + Android system + Health Connect's own aggregator simultaneously. Always store `source` per sample — when the server reconciles overlapping signals, having the source is what makes it tractable.

2. **Time granularity varies.** HR: ~1 Hz from wearables. Distance: ~1-minute deltas from Fitbit, one big chunk from Strava. Total calories: 15-minute aggregate buckets. Don't try to interpolate across sources.

3. **`recording_method` affects confidence.** `automatic` = sensor stream (high confidence). `active` = live tracking session (very high). `manual` = user typed it in (low — possibly fictitious). `unknown` = source didn't say. Detected workouts should weight `manual` samples lower or exclude them.

4. **Sample counts are large.** Plan storage accordingly. Postgres `jsonb` for the raw payload + typed rows for the streams you query against gives good ergonomics.

5. **Health Connect is mutable.** Apps can edit/delete records after-the-fact. Same UUID, different content, is legitimate. Don't enforce immutability.

6. **Timestamps are UTC in the payload.** Health Connect returns local time without zone info; the client converts to UTC. Store as UTC, render in athlete-local time on the dashboard.

7. **GPS routes are missing.** Strava, Fitbit, and most third-party apps don't write `ExerciseRouteRecord` to Health Connect. For GPS, use the app's own recording (see [Route tracks](#route-tracks-diy-gps-recording)) or Strava OAuth server-side.

---

## Suggested Postgres schema

```sql
CREATE TABLE syncs (
  id              SERIAL PRIMARY KEY,
  athlete_id      INTEGER NOT NULL,
  uploaded_at     TIMESTAMPTZ NOT NULL,
  window_start    TIMESTAMPTZ NOT NULL,
  window_end      TIMESTAMPTZ NOT NULL,
  client_version  TEXT,
  source_platform TEXT,
  raw_payload     JSONB NOT NULL    -- the whole thing, for replay
);
CREATE INDEX ON syncs (athlete_id, uploaded_at DESC);

CREATE TABLE workouts (
  source_uuid     UUID PRIMARY KEY,
  athlete_id      INTEGER NOT NULL,
  source_app      TEXT NOT NULL,
  activity_type   TEXT NOT NULL,
  recording_method TEXT,
  start_time      TIMESTAMPTZ NOT NULL,
  end_time        TIMESTAMPTZ NOT NULL,
  duration_seconds INTEGER NOT NULL,
  total_distance_meters INTEGER,
  total_energy_kcal     INTEGER,
  total_steps           INTEGER
);
CREATE INDEX ON workouts (athlete_id, start_time DESC);

CREATE TABLE heart_rate_samples (
  uuid       UUID NOT NULL,        -- shared across a HeartRateRecord series
  athlete_id INTEGER NOT NULL,
  time       TIMESTAMPTZ NOT NULL,
  bpm        INTEGER NOT NULL,
  source     TEXT,
  recording_method TEXT,
  PRIMARY KEY (uuid, time)         -- uuid alone is NOT unique per reading
);
CREATE INDEX ON heart_rate_samples (athlete_id, time);

CREATE TABLE interval_samples (    -- one table for all interval streams
  uuid       UUID NOT NULL,         -- sleep stages share the session's uuid
  stream     TEXT NOT NULL,         -- "step", "distance", "sleep_deep", ...
  start_time TIMESTAMPTZ NOT NULL,
  athlete_id INTEGER NOT NULL,
  end_time   TIMESTAMPTZ NOT NULL,
  value      DOUBLE PRECISION NOT NULL,
  unit       TEXT NOT NULL,
  source     TEXT,
  recording_method TEXT,
  PRIMARY KEY (uuid, stream, start_time)
);
CREATE INDEX ON interval_samples (athlete_id, stream, start_time);

CREATE TABLE detected_sessions (    -- output of the detection algorithm
  id              SERIAL PRIMARY KEY,
  athlete_id      INTEGER NOT NULL,
  start_time      TIMESTAMPTZ NOT NULL,
  end_time        TIMESTAMPTZ NOT NULL,
  duration_seconds INTEGER NOT NULL,
  peak_hr         INTEGER,
  avg_hr          INTEGER,
  total_steps     INTEGER,
  avg_steps_per_min DOUBLE PRECISION,
  inferred_activity TEXT,
  matched_workout_uuid UUID REFERENCES workouts(source_uuid),
  detection_version TEXT NOT NULL   -- bump when the algorithm changes
);
CREATE INDEX ON detected_sessions (athlete_id, start_time DESC);
```

Keep `syncs.raw_payload` so you can re-run the detection algorithm against old data after tuning the thresholds — without making the client re-upload.

---

## Example FastAPI handler

```python
from datetime import datetime
from typing import Literal
from pydantic import BaseModel
from fastapi import FastAPI

class NumericSample(BaseModel):
    uuid: str | None = None
    time: datetime
    value: float
    unit: str
    source: str | None = None
    recording_method: str | None = None

class IntervalSample(BaseModel):
    uuid: str | None = None
    start: datetime
    end: datetime
    value: float
    unit: str
    source: str | None = None
    recording_method: str | None = None

class Workout(BaseModel):
    source_uuid: str
    source_app: str
    source_device_id: str | None = None
    activity_type: str
    recording_method: str | None = None
    start_time: datetime
    end_time: datetime
    duration_seconds: int
    total_distance_meters: int | None = None
    total_energy_kcal: int | None = None
    total_steps: int | None = None

class HealthSync(BaseModel):
    type: Literal["health_sync"]
    athlete_id: int
    client_version: str | None = None
    uploaded_at: datetime
    source_platform: str
    window_start: datetime
    window_end: datetime

    workouts: list[Workout] = []

    heart_rate_samples: list[NumericSample] = []
    speed_samples: list[NumericSample] = []
    hrv_rmssd_samples: list[NumericSample] = []
    resting_heart_rate_samples: list[NumericSample] = []
    respiratory_rate_samples: list[NumericSample] = []
    blood_oxygen_samples: list[NumericSample] = []
    skin_temperature_samples: list[NumericSample] = []
    body_temperature_samples: list[NumericSample] = []

    step_samples: list[IntervalSample] = []
    distance_samples: list[IntervalSample] = []
    total_calorie_samples: list[IntervalSample] = []
    active_energy_samples: list[IntervalSample] = []
    basal_energy_samples: list[IntervalSample] = []
    flights_climbed_samples: list[IntervalSample] = []
    activity_intensity_samples: list[IntervalSample] = []

    sleep_sessions: list[IntervalSample] = []
    sleep_deep_samples: list[IntervalSample] = []
    sleep_rem_samples: list[IntervalSample] = []
    sleep_light_samples: list[IntervalSample] = []
    sleep_awake_samples: list[IntervalSample] = []

app = FastAPI()

@app.post("/workouts")  # endpoint name is legacy; payload type discriminates
async def post_sync(payload: HealthSync):
    # 1. Persist the raw payload (syncs.raw_payload)
    # 2. Upsert workouts by source_uuid
    # 3. Upsert heart_rate_samples by uuid
    # 4. Upsert interval_samples (all the *_samples streams) by uuid
    # 5. Kick off detect_sessions() — sync or async background job
    return {
        "received_workouts": len(payload.workouts),
        "received_hr_samples": len(payload.heart_rate_samples),
        "received_step_samples": len(payload.step_samples),
    }
```

---

## Route tracks (DIY GPS recording)

Separate from the health sync above: the app can record a run's GPS track
on-device (the **Record** tab) and upload it so the dashboard can draw where the
athlete ran. Unlike Strava import (a summary polyline), this carries the **full
per-point track** — lat/lng/time plus accuracy, altitude, and speed.

### Transport

| | |
|---|---|
| Method | `POST` |
| URL | `<base>/routes` |
| Content-Type | `application/json` |
| Auth | **Required** — `Authorization: Bearer <jwt>`, same as the health sync. |

One run per request. Before uploading, the client asks `GET /routes` which
`client_route_id`s the server already has and sends only the missing ones —
the server is the source of truth for route dedup, exactly like the sample
watermark (`GET /me/last-sample-time`); no sync state is kept on the device.
The athlete is derived from the token — there is no `athlete_id` in the body.

### Payload — `route_track`

This is exactly what the app writes to its local track files today, plus a
`client_route_id` added for idempotent dedup:

```json
{
  "type": "route_track",
  "client_route_id": "f1c2e4f1-14a3-4f00-a47d-be314801d6f4",
  "source": "diy_gps",
  "client_version": "1.0.0+1",
  "recorded_at": "2026-06-16T21:48:27.000Z",
  "start_time":  "2026-06-16T21:45:57.000Z",
  "end_time":    "2026-06-16T21:48:27.000Z",
  "duration_seconds": 149,
  "distance_meters":  185.8,
  "point_count": 24,
  "points": [
    {
      "lat": 33.8494169,
      "lng": -118.3770797,
      "time": "2026-06-16T21:46:25.000Z",
      "accuracy_m": 13.9,
      "altitude_m": -1.6,
      "speed_mps": 0.9
    }
  ]
}
```

| Field | Type | Notes |
|---|---|---|
| `type` | string literal `"route_track"` | Discriminator. |
| `client_route_id` | UUID | The **dedup key**. For `health_connect` routes this is the Health Connect workout uuid (stable across re-uploads). (DIY local files are keyed by `start_time`; the client adds this id when wiring upload — until then, dedup on `(athlete_id, start_time)`.) |
| `source` | string | `"diy_gps"` for in-app recording; `"health_connect"` for routes other apps (Fitbit, Pixel Watch) attached to their workouts, re-read via Health Connect. |
| `source_workout_uuid` | UUID, optional | `health_connect` routes: the parent workout's uuid — join it against `workouts.source_uuid` to attach the path to the workout's HR/pace analysis directly. On Android this comes straight from Health Connect; on iOS the health plugin doesn't surface it, so the client recovers it by time-overlap with the workout before uploading. **May still be null** (no overlapping workout found) — fall back to time-overlap reconciliation (below). **POST /routes must upsert on `client_route_id`** (`ON CONFLICT DO UPDATE`), not plain-insert: clients re-send a track to backfill this field (early iOS uploads went out with it null). A `409` on a duplicate is also tolerated — the client then stops re-sending — but upsert is what actually repairs orphaned rows. |
| `recorded_at` / `start_time` / `end_time` | ISO-8601 UTC | `end_time` is the **stop moment** (not the last fix), so it matches `duration_seconds`. |
| `duration_seconds` | int | Wall-clock from start to stop. |
| `distance_meters` | float | Client-summed great-circle distance between consecutive fixes. |
| `point_count` | int | `points.length`. |
| `points` | array | Ordered by `time`; see below. The client never uploads an empty track. |

Each point:

| Field | Unit | Notes |
|---|---|---|
| `lat` / `lng` | WGS84 degrees | The path geometry. |
| `time` | ISO-8601 UTC | Per-fix timestamp. |
| `accuracy_m` | meters | Horizontal accuracy; lower is better — useful for dropping bad fixes. Nullable for `health_connect` routes. |
| `altitude_m` | meters | Can be noisy or negative indoors. Nullable for `health_connect` routes. |
| `speed_mps` | m/s | Instantaneous speed from the GPS provider. Always `null` for `health_connect` routes (Health Connect doesn't store per-point speed). |

A 5 m `distanceFilter` on the client means fixes are ~5 m+ apart, so a typical
run is a few hundred to a few thousand points — tens to low-hundreds of KB,
much smaller than a health sync.

### Dedup

`(athlete_id, client_route_id)` — re-uploading the same track idempotently
updates, so the client can retry a flaky upload without duplicating a run.

### Display

`points` is already lat/lng — draw it directly as a polyline with start/end
markers (the app's Runs page does exactly this with flutter_map). For the web
dashboard, encode it as a polyline or store a PostGIS `LINESTRING` and render
that.

Reconcile a route with a [detected session](#server-side-exercise-session-detection)
(or a Strava activity) by **time overlap** — `start_time` within a few minutes,
comparable duration — to attach the GPS path to the HR/pace analysis.

### Storage (Postgres)

```sql
CREATE TABLE route_tracks (
  client_route_id  UUID PRIMARY KEY,
  athlete_id       INTEGER NOT NULL,
  source           TEXT NOT NULL,            -- 'diy_gps' | 'health_connect'
  start_time       TIMESTAMPTZ NOT NULL,
  end_time         TIMESTAMPTZ NOT NULL,
  duration_seconds INTEGER NOT NULL,
  distance_meters  DOUBLE PRECISION,
  point_count      INTEGER NOT NULL,
  uploaded_at      TIMESTAMPTZ NOT NULL,
  raw_payload      JSONB NOT NULL            -- includes points[]
);
CREATE INDEX ON route_tracks (athlete_id, start_time DESC);
```

Keeping the points in `raw_payload` is enough to draw the route. For spatial
queries (distance from a landmark, segment matching), normalize the points into
a `route_points` table or a PostGIS geometry column.

### Example FastAPI handler

```python
class TrackPoint(BaseModel):
    lat: float
    lng: float
    time: datetime
    accuracy_m: float | None = None
    altitude_m: float | None = None
    speed_mps: float | None = None

class RouteTrack(BaseModel):
    type: Literal["route_track"]
    client_route_id: str
    source: str
    client_version: str | None = None
    recorded_at: datetime
    start_time: datetime
    end_time: datetime
    duration_seconds: int
    distance_meters: float | None = None
    point_count: int
    points: list[TrackPoint] = []

@app.post("/routes")
async def post_route(payload: RouteTrack):
    # Upsert by (athlete_id from token, client_route_id); store raw_payload.
    return {"received_points": len(payload.points)}
```

---

## Data reset (dev)

`DELETE <base>/me/data` — deletes **everything the authenticated athlete has
uploaded**: workouts, every raw sample stream, detected sessions, and route
tracks. The athlete comes from the Bearer token like every other endpoint.

The app's debug **Reset (wipe server + start over)** button calls this.
Nothing local needs clearing — all sync state lives on the server (the
sample watermark via `GET /me/last-sample-time`, route dedup via `GET
/routes`), and deleting the data resets both automatically, so the next
Sync re-uploads the full first-sync window and every route from scratch.

No body, no query params. Responses:

- `200` with per-table delete counts (shape below). The client displays the
  raw JSON in its status card; it doesn't parse specific keys, so include
  whatever tables your schema has.
- `401` — invalid/expired token (client drops the token and re-prompts
  sign-in).

```json
{"deleted": {"workouts": 16, "heart_rate_samples": 165204, "step_samples": 8123, "route_tracks": 3}}
```

### Example FastAPI handler

```python
ATHLETE_TABLES = [
    # children first if you added FKs to workouts/detected_sessions
    "detected_sessions",
    "heart_rate_samples", "step_samples", "distance_samples",
    "active_energy_samples", "total_calorie_samples",
    "hrv_rmssd_samples", "resting_heart_rate_samples",
    "respiratory_rate_samples", "sleep_sessions", "sleep_stage_samples",
    "workouts", "route_tracks",
]

@app.delete("/me/data")
async def delete_my_data(athlete_id: int = Depends(athlete_from_token)):
    counts = {}
    for table in ATHLETE_TABLES:
        result = await db.execute(
            text(f"DELETE FROM {table} WHERE athlete_id = :a"),  # table names from our list, not user input
            {"a": athlete_id},
        )
        counts[table] = result.rowcount
    return {"deleted": counts}
```

Scope it to the token's athlete only — this must never be able to touch
another athlete's rows. It's a dev convenience; consider disabling it (or
requiring `DEV_MODE=true`) in production.

---

## Future work

- **Background sync** via WorkManager (no need to open the app).
- **Strava OAuth server-side** for GPS routes (Health Connect never has them).
- **More permissions** (HRV, resting HR, respiratory rate) for richer recovery analysis. Today the manifest only declares what the v1 scan needs.
- **Auth.** Replace `athlete_id` integer with a token-derived athlete identity.

---

## Versioning

If the schema changes incompatibly, bump the `type` discriminator (`health_sync_v2`) rather than mutating field meanings. The server should reject unknown `type` values explicitly.
