// UI-independent sync engine, extracted from the home screen's State so a
// headless background isolate can run it (phase 1 of background sync). No
// Flutter widgets or BuildContext in here — progress is reported through an
// optional onProgress callback and the outcome through a SyncResult; the UI
// (or a background entrypoint) decides what to do with them.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:health/health.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';

// Server BASE URL (no trailing path). Override at build/run time:
//   flutter run --dart-define-from-file=config/dev.json
// (see config/dev.json.example for the schema). The default value below is
// the Android emulator's alias for the host machine's localhost — safe as a
// fall-back for someone freshly cloning the repo.
//
// Endpoints constructed from this base:
//   $serverBase/workouts          — health sync (POST)
//   $serverBase/routes            — route upload (POST) + dedup listing (GET)
//   $serverBase/auth/google       — exchange Google ID token → server JWT
//   $serverBase/auth/dev-login    — dev-only: email-based JWT (DEV_MODE=true)
const String serverBase = String.fromEnvironment(
  'SERVER_URL',
  defaultValue: 'http://10.0.2.2:8000',
);

// Server attributes uploads to the athlete in the Bearer token; this field
// is now deprecated and ignored, but kept in the payload so older server
// builds still parse the request.
const int athleteId = 1;

// Reported in every sync payload so the server can tell which client emitted
// it. Must match `version` in pubspec.yaml — bump both together.
const String clientVersion = '1.0.0+1';

// How far back every sync reconciles, and how far back the Runs tab, route
// uploads, and the debug export look. Each sync compares the workouts in this
// window against what the server already has and uploads the difference — so a
// workout that lands with a backdated timestamp (e.g. a Garmin activity that
// syncs in days late) still gets picked up, which a watermark-forward sync
// would miss once its newest-sample mark moved past the workout's date.
const Duration historyWindow = Duration(days: 30);

// The app uploads workout data only: continuous streams (HR, steps, distance,
// calories) are read solely within this padding around each recorded workout.
// The padding keeps warm-up / cool-down context for HR-recovery analysis.
const Duration workoutPadding = Duration(minutes: 10);

// On iOS the health plugin maps several Android-only names onto a single
// HKWorkoutActivityType (RUNNING_TREADMILL → .running, ROCK_CLIMBING →
// .climbing, SWIMMING_POOL / SWIMMING_OPEN_WATER → .swimming) and reverse-maps
// on read with first(where:) over an *unordered* Swift dictionary — so a plain
// outdoor run can come back labeled RUNNING_TREADMILL at random. HealthKit
// can't even express those distinctions in the activity type, so on iOS
// collapse the aliases to their canonical names. Android's are real distinct
// Health Connect types — leave them alone.
String canonicalActivityType(String name) {
  if (!Platform.isIOS) return name;
  switch (name) {
    case 'RUNNING_TREADMILL':
      return 'RUNNING';
    case 'ROCK_CLIMBING':
      return 'CLIMBING';
    case 'SWIMMING_POOL':
    case 'SWIMMING_OPEN_WATER':
      return 'SWIMMING';
    default:
      return name;
  }
}

enum SyncStatus { ok, httpError, unauthorized, unreachable, error }

class SyncResult {
  const SyncResult(this.status, this.message);
  final SyncStatus status;
  final String message;
}

typedef RouteUploadResult = ({
  int uploaded,
  int failed,
  int pendingConsent,
  bool unauthorized,
});

class SyncService {
  SyncService({required this.auth, Health? health})
    : health = health ?? Health();

  final AuthService auth;
  final Health health;

  // Max time span per Health Connect query. The plugin serializes each read's
  // ENTIRE result into one method-channel envelope on the Java heap; a full
  // 30-day window of heart-rate data (165k+ samples) OOM-crashed the app even
  // with largeHeap, so long windows are read in slices this wide and stitched
  // together on the Dart side.
  static const Duration _readChunk = Duration(days: 3);

  // Streams uploaded around each workout — see buildSyncPayload. Every type
  // here MUST be in the UI's permission list (and the Android manifest must
  // declare the matching READ_* permission), or the read returns empty.
  static const Map<String, HealthDataType> _numericStreams = {
    'heart_rate_samples': HealthDataType.HEART_RATE,
  };

  static const Map<String, HealthDataType> _intervalStreams = {
    'step_samples': HealthDataType.STEPS,
    'distance_samples': HealthDataType.DISTANCE_DELTA,
    'total_calorie_samples': HealthDataType.TOTAL_CALORIES_BURNED,
    'active_energy_samples': HealthDataType.ACTIVE_ENERGY_BURNED,
  };

  // Quick liveness probe so a down/unreachable server fails in ~5s with a
  // clear message, instead of hanging the full 120s upload timeout on a dead
  // connection. Any HTTP response (even 404) means the server answered; only a
  // socket error or the short timeout counts as unreachable.
  Future<bool> serverReachable() async {
    try {
      await http
          .get(Uri.parse('$serverBase/'))
          .timeout(const Duration(seconds: 5));
      return true;
    } catch (_) {
      return false;
    }
  }

  // Asks the server for the newest sample timestamp it has for this athlete
  // (GET /me/last-sample-time) — the sync watermark. Returns null when the
  // server has no data yet (first sync, or right after a data reset). Throws
  // on any failure; a 401 also drops the token so the sign-in card returns.
  Future<DateTime?> fetchServerWatermark() async {
    final resp = await http
        .get(
          Uri.parse('$serverBase/me/last-sample-time'),
          headers: auth.authHeaders,
        )
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode == 401) {
      await auth.invalidate();
      throw Exception('Sign-in expired. Please sign in again.');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Server returned ${resp.statusCode}');
    }
    final t =
        (jsonDecode(resp.body) as Map<String, dynamic>)['last_sample_time'];
    return t == null ? null : DateTime.parse(t as String).toLocal();
  }

  // Local memory of which workout UUIDs the server already has, so a sync only
  // re-reads and re-uploads the *missing* ones (see buildSyncPayload). The
  // server stays the source of truth: this set is dropped whenever the server
  // reports no data (GET /me/last-sample-time == null), so a wipe or a fresh
  // athlete safely re-reconciles the whole window. Being wrong can only cause a
  // re-upload, which the server's composite-key upsert dedups — never a gap.
  static const String _uploadedWorkoutsPrefsKey = 'uploaded_workout_uuids';

  Future<Set<String>> _loadUploadedWorkouts() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_uploadedWorkoutsPrefsKey) ?? const <String>[])
        .toSet();
  }

  Future<void> _saveUploadedWorkouts(Set<String> uuids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_uploadedWorkoutsPrefsKey, uuids.toList());
  }

  /// Forgets which workouts have been uploaded, forcing the next sync to
  /// re-reconcile the whole window. Called after a server data reset.
  Future<void> clearUploadedWorkouts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_uploadedWorkoutsPrefsKey);
  }

  /// How many workouts in [start, end] are not yet on the server — the count
  /// the next sync would upload. Powers the home screen's "pending" indicator.
  Future<int> pendingWorkoutCount(DateTime start, DateTime end) async {
    final workouts = await safeRead(HealthDataType.WORKOUT, start, end);
    final uploaded = await _loadUploadedWorkouts();
    return workouts.where((w) => !uploaded.contains(w.uuid)).length;
  }

  Future<List<HealthDataPoint>> safeRead(
    HealthDataType t,
    DateTime start,
    DateTime end,
  ) async {
    final out = <HealthDataPoint>[];
    // Records overlapping a slice boundary are returned by both slices —
    // dedup by uuid so callers see each record once.
    final seen = <String>{};
    var cursor = start;
    while (cursor.isBefore(end)) {
      var sliceEnd = cursor.add(_readChunk);
      if (sliceEnd.isAfter(end)) sliceEnd = end;
      try {
        final slice = await health.getHealthDataFromTypes(
          types: [t],
          startTime: cursor,
          endTime: sliceEnd,
        );
        for (final p in slice) {
          if (seen.add(p.uuid)) out.add(p);
        }
      } catch (e, st) {
        // Don't crash the caller — expected for unpermissioned types — but
        // log so it's still visible in the dev console.
        debugPrint('[_safeRead] ${t.name} $cursor..$sliceEnd failed: $e\n$st');
      }
      cursor = sliceEnd;
    }
    return out;
  }

  Map<String, dynamic> _numericSample(HealthDataPoint p) {
    final v = p.value;
    return {
      'uuid': p.uuid,
      'time': p.dateFrom.toUtc().toIso8601String(),
      'value': v is NumericHealthValue ? v.numericValue : null,
      'unit': p.unit.name,
      'source': p.sourceName,
      'recording_method': p.recordingMethod.name,
    };
  }

  Map<String, dynamic> _intervalSample(HealthDataPoint p) {
    final v = p.value;
    return {
      'uuid': p.uuid,
      'start': p.dateFrom.toUtc().toIso8601String(),
      'end': p.dateTo.toUtc().toIso8601String(),
      'value': v is NumericHealthValue ? v.numericValue : null,
      'unit': p.unit.name,
      'source': p.sourceName,
      'recording_method': p.recordingMethod.name,
    };
  }

  /// Reads workouts over [windowStart, now] and assembles the `health_sync`
  /// payload. The app uploads **workout data only** (privacy decision,
  /// 2026-07): the continuous streams (HR, steps, distance, calories) are
  /// read solely within ±[workoutPadding] of each recorded workout — nothing
  /// between workouts ever leaves the phone. Shared by sync and export so the
  /// two can't drift (a past divergence here caused an OOM). Reports progress
  /// per stream via [onProgress]; [labelSuffix] distinguishes the caller in
  /// that text.
  ///
  /// Reads one stream per query on purpose — batching all types into a single
  /// getHealthDataFromTypes call makes the health plugin serialize the whole
  /// result across the method channel in one allocation, and a full window of
  /// ~165k HR samples OOMs the Java heap.
  Future<
    ({
      Map<String, dynamic> payload,
      int totalSamples,
      Set<String> windowWorkoutUuids,
    })
  >
  buildSyncPayload(
    DateTime windowStart,
    DateTime now, {
    String labelSuffix = '',
    Set<String> skipWorkoutUuids = const {},
    void Function(String status)? onProgress,
  }) async {
    // Workouts use the package's special WORKOUT path (it aggregates
    // distance/calories/steps from related records). Separate read.
    final allWorkouts = await safeRead(HealthDataType.WORKOUT, windowStart, now);
    final windowWorkoutUuids = {for (final w in allWorkouts) w.uuid};

    // Reconciliation: skip workouts the server already has (tracked locally by
    // the caller) so we don't re-read their heavy HR/step samples every sync.
    // What's left is what the server is missing — including backdated imports
    // a watermark-forward sync would never revisit.
    final workouts = skipWorkoutUuids.isEmpty
        ? allWorkouts
        : allWorkouts
              .where((w) => !skipWorkoutUuids.contains(w.uuid))
              .toList();

    // Padded, merged time ranges around the recorded workouts — the only
    // ranges the continuous streams are read from. Merging keeps overlapping
    // paddings (back-to-back or double-recorded workouts) as one range.
    final sorted = [...workouts]
      ..sort((a, b) => a.dateFrom.compareTo(b.dateFrom));
    final windows = <({DateTime start, DateTime end})>[];
    for (final w in sorted) {
      final s = w.dateFrom.subtract(workoutPadding);
      final e = w.dateTo.add(workoutPadding);
      if (windows.isNotEmpty && !s.isAfter(windows.last.end)) {
        if (e.isAfter(windows.last.end)) {
          windows.last = (start: windows.last.start, end: e);
        }
      } else {
        windows.add((start: s, end: e));
      }
    }

    // Reads one stream across all workout windows, deduping records that
    // straddle two adjacent ranges.
    Future<List<HealthDataPoint>> readAroundWorkouts(HealthDataType t) async {
      final seen = <String>{};
      final out = <HealthDataPoint>[];
      for (final win in windows) {
        for (final p in await safeRead(t, win.start, win.end)) {
          if (seen.add('${p.uuid}/${p.dateFrom.microsecondsSinceEpoch}')) {
            out.add(p);
          }
        }
      }
      return out;
    }

    final workoutPayloads = workouts.map((w) {
      final wv = w.value is WorkoutHealthValue
          ? w.value as WorkoutHealthValue
          : null;
      return <String, dynamic>{
        'source_uuid': w.uuid,
        'source_app': w.sourceName,
        'source_device_id': w.sourceDeviceId,
        'activity_type': canonicalActivityType(
          wv?.workoutActivityType.name ?? 'OTHER',
        ),
        'recording_method': w.recordingMethod.name,
        'start_time': w.dateFrom.toUtc().toIso8601String(),
        'end_time': w.dateTo.toUtc().toIso8601String(),
        'duration_seconds': w.dateTo.difference(w.dateFrom).inSeconds,
        'total_distance_meters': wv?.totalDistance,
        'total_energy_kcal': wv?.totalEnergyBurned,
        'total_steps': wv?.totalSteps,
      };
    }).toList();

    final payload = <String, dynamic>{
      'type': 'health_sync',
      'athlete_id': athleteId,
      'client_version': clientVersion,
      'uploaded_at': now.toUtc().toIso8601String(),
      'source_platform': 'googleHealthConnect',
      'window_start': windowStart.toUtc().toIso8601String(),
      'window_end': now.toUtc().toIso8601String(),
      'workouts': workoutPayloads,
    };

    var totalSamples = 0;
    for (final e in _numericStreams.entries) {
      onProgress?.call('Reading ${e.key}$labelSuffix...');
      final samples = await readAroundWorkouts(e.value);
      payload[e.key] = samples.map(_numericSample).toList();
      totalSamples += samples.length;
    }
    for (final e in _intervalStreams.entries) {
      onProgress?.call('Reading ${e.key}$labelSuffix...');
      final samples = await readAroundWorkouts(e.value);
      payload[e.key] = samples.map(_intervalSample).toList();
      totalSamples += samples.length;
    }

    return (
      payload: payload,
      totalSamples: totalSamples,
      windowWorkoutUuids: windowWorkoutUuids,
    );
  }

  /// The full sync: reconcile → payload build → POST /workouts → route upload.
  /// Reconciles the whole [historyWindow] rather than only uploading forward
  /// from the server's newest sample: it reads every workout in the window,
  /// skips the ones a local record says the server already has, and uploads
  /// the rest. This catches backdated workouts (a Garmin run that syncs in
  /// late) that a watermark-forward sync would step over. [backfill] (debug)
  /// ignores the local record and re-sends the whole window; safe to repeat —
  /// the server's composite-key upsert dedups, and the payload carries
  /// "backfill": true so the server knows the overlap is deliberate.
  ///
  /// Never throws: every outcome (including a 401, which also invalidates
  /// the token) comes back as a [SyncResult] whose message is ready to show.
  Future<SyncResult> sync({
    bool backfill = false,
    void Function(String status)? onProgress,
  }) async {
    onProgress?.call('Checking server...');
    // Fail fast when the server is down instead of hanging on the upload.
    if (!await serverReachable()) {
      return SyncResult(
        SyncStatus.unreachable,
        'Server unreachable at $serverBase.\n'
        'Check it is running and on the same network, then re-tap Sync.',
      );
    }

    try {
      final now = DateTime.now();
      final windowStart = now.subtract(historyWindow);

      // The server is the source of truth for what it already has. When it
      // reports data we trust the local record of uploaded workouts and skip
      // them; when it reports nothing (first sync, or right after a data reset)
      // that record is stale, so drop it and re-send the whole window. A
      // backfill always re-sends.
      Set<String> alreadyUploaded;
      if (backfill) {
        alreadyUploaded = const {};
      } else {
        onProgress?.call('Checking what the server already has...');
        final serverWatermark = await fetchServerWatermark();
        if (serverWatermark == null) {
          await clearUploadedWorkouts();
          alreadyUploaded = const {};
        } else {
          alreadyUploaded = await _loadUploadedWorkouts();
        }
      }

      onProgress?.call('Reading data from Health Connect...');
      final built = await buildSyncPayload(
        windowStart,
        now,
        skipWorkoutUuids: alreadyUploaded,
        onProgress: onProgress,
      );
      final payload = built.payload;
      if (backfill) payload['backfill'] = true;
      final totalSamples = built.totalSamples;
      final newWorkoutCount = (payload['workouts'] as List).length;
      final alreadyOnServer =
          built.windowWorkoutUuids.length - newWorkoutCount;

      final bodyBytes = utf8.encode(jsonEncode(payload));
      final sizeMB = (bodyBytes.length / 1024 / 1024).toStringAsFixed(2);
      onProgress?.call(
        'Uploading $newWorkoutCount new workouts + $totalSamples samples ($sizeMB MB)...',
      );

      final response = await http
          .post(
            Uri.parse('$serverBase/workouts'),
            headers: {'Content-Type': 'application/json', ...auth.authHeaders},
            body: bodyBytes,
          )
          .timeout(const Duration(seconds: 120));

      final ok = response.statusCode >= 200 && response.statusCode < 300;
      if (ok) {
        // Everything in the window is now on the server — the skipped ones were
        // already there, the new ones we just sent. Remember the full set so
        // the next sync skips their samples; keyed to the window, so it prunes
        // itself as workouts age past the horizon.
        await _saveUploadedWorkouts(built.windowWorkoutUuids);
      }

      // 401 → token rejected. Drop it so the next sync attempt forces
      // sign-in, and show the auth card again instead of a noisy error.
      if (response.statusCode == 401) {
        await auth.invalidate();
        return const SyncResult(
          SyncStatus.unauthorized,
          'Sign-in expired. Please sign in again, then re-tap Sync.',
        );
      }

      // Also upload any GPS routes other apps attached to their workouts
      // (Fitbit / Pixel Watch / Apple Watch runs). Independent of the health
      // upload above — see SERVER_SCHEMA.md "Route tracks". Like the workout
      // reconcile, this scans the full history window and dedups against the
      // server's route list, so a route that only became readable later (route
      // permission granted after the run, or the Watch delivered it late) is
      // still caught on a subsequent sync.
      onProgress?.call('Uploading workout routes...');
      final hcRoutes = await uploadRoutes(now.subtract(historyWindow), now);
      if (hcRoutes.unauthorized) {
        await auth.invalidate();
        return const SyncResult(
          SyncStatus.unauthorized,
          'Sign-in expired. Please sign in again, then re-tap Sync.',
        );
      }

      final routeMsg = (hcRoutes.uploaded == 0 && hcRoutes.failed == 0)
          ? ' No new routes.'
          : ' Routes: ${hcRoutes.uploaded} uploaded'
                '${hcRoutes.failed > 0 ? ", ${hcRoutes.failed} failed" : ""}.';
      final consentMsg = hcRoutes.pendingConsent > 0
          ? '\n${hcRoutes.pendingConsent} Health Connect route(s) unreadable — '
                'grant "Exercise routes → Always allow" in Health Connect → '
                'App permissions → Chadwick XC Training, then Sync again.'
          : '';
      if (ok) {
        return SyncResult(
          SyncStatus.ok,
          'Synced $sizeMB MB (last ${historyWindow.inDays} days): '
          '$newWorkoutCount new workout(s) uploaded, '
          '$alreadyOnServer already on server, $totalSamples samples. '
          'Server: ${response.statusCode}.$routeMsg$consentMsg',
        );
      }
      return SyncResult(
        SyncStatus.httpError,
        'Health upload failed: ${response.statusCode}.$routeMsg$consentMsg\n'
        '${response.body}',
      );
    } catch (e) {
      return SyncResult(SyncStatus.error, 'Sync error: $e');
    }
  }

  // Uploads GPS routes that OTHER apps (Fitbit, Pixel Watch, Apple Watch...)
  // attached to their workouts, as route_track payloads to POST /routes.
  // Routes the user hasn't consented to yet read back with no locations
  // (ConsentRequired) — counted in pendingConsent so the status can tell the
  // user to grant "Exercise routes" in Health Connect's app permissions.
  Future<RouteUploadResult> uploadRoutes(
    DateTime windowStart,
    DateTime now,
  ) async {
    // Dedup against the server, like the sample watermark — the server is the
    // source of truth for what it already has. A local list would go stale on
    // a server-side wipe (routes never re-sent) or an app reinstall.
    final Set<String> done;
    try {
      final resp = await http
          .get(Uri.parse('$serverBase/routes'), headers: auth.authHeaders)
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode == 401) {
        return (uploaded: 0, failed: 0, pendingConsent: 0, unauthorized: true);
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('server returned ${resp.statusCode}');
      }
      done = {
        for (final r in jsonDecode(resp.body) as List)
          (r as Map<String, dynamic>)['client_route_id'] as String,
      };
    } catch (e) {
      // Can't know what the server has — skip route upload this sync rather
      // than re-send everything; surfaced as a failure so it isn't silent.
      debugPrint('[hc-routes] listing server routes failed: $e');
      return (uploaded: 0, failed: 1, pendingConsent: 0, unauthorized: false);
    }

    final points = await safeRead(
      HealthDataType.WORKOUT_ROUTE,
      windowStart,
      now,
    );
    var uploaded = 0;
    var failed = 0;
    var pendingConsent = 0;
    for (final r in points) {
      final v = r.value;
      if (v is! WorkoutRouteHealthValue) continue;
      // The workout uuid is the stable identity of the route (and what the
      // server can join against the workouts table); fall back to the record
      // uuid if the package didn't surface it.
      final id = v.workoutUuid ?? r.uuid;
      if (done.contains(id)) continue;
      if (v.locations.isEmpty) {
        pendingConsent++;
        continue;
      }
      // iOS: the health plugin never surfaces the parent workout's uuid for a
      // route (Android does), and the server joins routes to workouts on
      // source_workout_uuid — a null leaves the route orphaned. Recover the
      // uuid by time overlap with the workout it belongs to.
      var workoutUuid = v.workoutUuid;
      if (workoutUuid == null) {
        final nearby = await safeRead(
          HealthDataType.WORKOUT,
          r.dateFrom.subtract(const Duration(minutes: 10)),
          r.dateTo.add(const Duration(minutes: 10)),
        );
        for (final w in nearby) {
          if (w.value is! WorkoutHealthValue) continue;
          if (w.dateFrom.isBefore(r.dateTo) && w.dateTo.isAfter(r.dateFrom)) {
            workoutUuid = w.uuid;
            break;
          }
        }
      }
      final locs = v.locations;
      var dist = 0.0;
      for (var i = 1; i < locs.length; i++) {
        dist += Geolocator.distanceBetween(
          locs[i - 1].latitude,
          locs[i - 1].longitude,
          locs[i].latitude,
          locs[i].longitude,
        );
      }
      final payload = {
        'type': 'route_track',
        'client_route_id': id,
        'source': 'health_connect',
        'source_workout_uuid': workoutUuid,
        'recorded_at': now.toUtc().toIso8601String(),
        'start_time': r.dateFrom.toUtc().toIso8601String(),
        'end_time': r.dateTo.toUtc().toIso8601String(),
        'duration_seconds': r.dateTo.difference(r.dateFrom).inSeconds,
        'distance_meters': dist,
        'point_count': locs.length,
        'points': [
          for (final p in locs)
            {
              'lat': p.latitude,
              'lng': p.longitude,
              'time': p.timestamp.toUtc().toIso8601String(),
              'accuracy_m': p.horizontalAccuracy,
              'altitude_m': p.altitude,
              'speed_mps': p.speed, // null on Android — HC routes omit speed
            },
        ],
      };
      try {
        final resp = await http
            .post(
              Uri.parse('$serverBase/routes'),
              headers: {
                'Content-Type': 'application/json',
                ...auth.authHeaders,
              },
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 60));
        if (resp.statusCode == 401) {
          return (
            uploaded: uploaded,
            failed: failed,
            pendingConsent: pendingConsent,
            unauthorized: true,
          );
        }
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          done.add(id);
          uploaded++;
        } else if (resp.statusCode == 409) {
          // Server already has this client_route_id and won't upsert —
          // treat as synced so it isn't retried forever.
          done.add(id);
        } else {
          debugPrint(
            '[hc-routes] $id rejected: ${resp.statusCode} ${resp.body}',
          );
          failed++;
        }
      } catch (e) {
        debugPrint('[hc-routes] upload of $id failed: $e');
        failed++; // network/timeout — retried next sync
      }
    }
    return (
      uploaded: uploaded,
      failed: failed,
      pendingConsent: pendingConsent,
      unauthorized: false,
    );
  }
}
