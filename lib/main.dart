import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:health/health.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'auth_service.dart';
import 'background_sync.dart'
    show
        androidSyncTaskName,
        androidSyncUniqueName,
        autoSyncPrefsKey,
        cancelAndroidSync,
        lastBackgroundSyncPrefsKey,
        scheduleAndroidSync,
        workManagerCallbackDispatcher;
import 'sync_service.dart';
import 'training_week.dart';

// Google Cloud Console OAuth 2.0 **web** client ID (the audience the server
// validates ID tokens against). Set via --dart-define-from-file=config/dev.json
// — see CLAUDE.md "Google Sign-In setup" for the Cloud Console steps. Empty
// disables Google Sign-In; dev-login still works.
const String _googleServerClientId = String.fromEnvironment(
  'GOOGLE_SERVER_CLIENT_ID',
  defaultValue: '',
);

// Git commit the build was made from, shown on the debug page so a tester can
// tell which source produced an APK. Injected at build time (see CLAUDE.md
// "Server config"): --dart-define=GIT_COMMIT=$(git rev-parse --short HEAD).
// 'dev' when built without it (e.g. plain `flutter run`).
const String _gitCommit = String.fromEnvironment(
  'GIT_COMMIT',
  defaultValue: 'dev',
);

// Distances display in miles (US team). Health Connect stores meters.
const double _metersPerMile = 1609.344;

// shared_preferences key — onboarding state. route_access_done marks the
// route-consent step completed (granted or explicitly skipped). The
// automatic-upload choice uses autoSyncPrefsKey (shared with the background
// entrypoint, imported from background_sync.dart); absence = not asked yet,
// which keeps the user in onboarding.
const String _routeAccessDonePrefsKey = 'route_access_done';

// shared_preferences key — iOS only: the health permission sheet has been
// shown and accepted. HealthKit never discloses READ-grant status (the
// plugin's hasPermissions returns null for reads), so without this flag every
// cold launch would treat permissions as missing and re-show onboarding.
const String _healthPermsRequestedPrefsKey = 'health_perms_requested';

// Moving-average window for smoothing the *displayed* GPS path — tames the
// zigzag from GPS jitter. Raw points are kept intact; only the drawn polyline
// is smoothed. Higher = smoother but rounds corners more; 1 disables.
const int _pathSmoothingWindow = 7;

// Returns a smoothed copy of [pts] using a centered moving average. Endpoints
// are preserved (the window shrinks at the edges).
List<LatLng> smoothPath(List<LatLng> pts, {int window = _pathSmoothingWindow}) {
  if (pts.length <= 2 || window < 2) return pts;
  final half = window ~/ 2;
  final out = <LatLng>[];
  for (var i = 0; i < pts.length; i++) {
    var lat = 0.0, lng = 0.0, n = 0;
    for (var j = i - half; j <= i + half; j++) {
      if (j < 0 || j >= pts.length) continue;
      lat += pts[j].latitude;
      lng += pts[j].longitude;
      n++;
    }
    out.add(LatLng(lat / n, lng / n));
  }
  return out;
}

// One logical run assembled from Health Connect workouts. Multiple apps often
// write the SAME physical run (e.g. Fitbit records it with a route but types
// it OTHER; Strava imports it typed RUNNING but without a route), so workouts
// whose time windows overlap are grouped into one run for display.
class _HcRun {
  final List<HealthDataPoint> members = [];
  DateTime start;
  DateTime end;

  // A WORKOUT_ROUTE record exists for this run (set by _loadHcRuns; true even
  // when consent blocks reading the points — the route still exists).
  bool hasRoute = false;

  _HcRun(HealthDataPoint first) : start = first.dateFrom, end = first.dateTo {
    members.add(first);
  }

  void add(HealthDataPoint w) {
    members.add(w);
    if (w.dateFrom.isBefore(start)) start = w.dateFrom;
    if (w.dateTo.isAfter(end)) end = w.dateTo;
  }

  bool overlaps(HealthDataPoint w) =>
      w.dateFrom.isBefore(end) && w.dateTo.isAfter(start);

  Set<String> get uuids => {for (final m in members) m.uuid};

  Duration get duration => end.difference(start);

  // Average speed in miles per hour, when distance and duration allow.
  double? get mph {
    final d = distanceMeters;
    final s = duration.inSeconds;
    if (d == null || s <= 0) return null;
    return (d / _metersPerMile) / (s / 3600);
  }

  double? get miles =>
      distanceMeters != null ? distanceMeters! / _metersPerMile : null;

  // Best label across the group: any specific type beats OTHER. On Android an
  // untyped group that looks like a run — it has a GPS route and averages
  // over 3.5 mph — displays as Running (Fitbit exports auto-detected runs as
  // OTHER). Display only: uploads carry the raw type and the server
  // classifies from raw signals.
  String get activityType {
    for (final m in members) {
      final v = m.value;
      if (v is WorkoutHealthValue && v.workoutActivityType.name != 'OTHER') {
        return canonicalActivityType(v.workoutActivityType.name);
      }
    }
    if (Platform.isAndroid && hasRoute && (mph ?? 0) > 3.5) {
      return 'RUNNING';
    }
    return 'OTHER';
  }

  // Whether this counts toward training volume. Walks and rides are recorded
  // by the same apps but aren't XC mileage. Single source of truth for the
  // weekly totals and the "counts" cue on run tiles.
  bool get isRun => activityType.contains('RUN');

  double? get distanceMeters {
    double? best;
    for (final m in members) {
      final v = m.value;
      final d = v is WorkoutHealthValue ? v.totalDistance?.toDouble() : null;
      if (d != null && (best == null || d > best)) best = d;
    }
    return best;
  }

  double? get energyKcal {
    double? best;
    for (final m in members) {
      final v = m.value;
      final e = v is WorkoutHealthValue
          ? v.totalEnergyBurned?.toDouble()
          : null;
      if (e != null && (best == null || e > best)) best = e;
    }
    return best;
  }

  int? get steps {
    int? best;
    for (final m in members) {
      final v = m.value;
      final s = v is WorkoutHealthValue ? v.totalSteps?.toInt() : null;
      if (s != null && (best == null || s > best)) best = s;
    }
    return best;
  }

  List<String> get sources {
    final seen = <String>{};
    return [
      for (final m in members)
        if (seen.add(m.sourceName)) m.sourceName,
    ];
  }
}

// The map itself: route polyline with start/end markers, framed to fit.
// Shown on the run detail page when the run has a GPS route.
class _RouteMapView extends StatelessWidget {
  final List<LatLng> points;

  const _RouteMapView(this.points);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FlutterMap(
      options: MapOptions(
        initialCenter: points.first,
        initialZoom: 16,
        initialCameraFit: points.length >= 2
            ? CameraFit.coordinates(
                coordinates: points,
                padding: const EdgeInsets.all(40),
              )
            : null,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.github.codingwithwarren.xctraining',
        ),
        PolylineLayer(
          polylines: [
            Polyline(
              points: smoothPath(points),
              strokeWidth: 5,
              color: theme.colorScheme.primary,
            ),
          ],
        ),
        MarkerLayer(
          markers: [
            Marker(
              point: points.first,
              width: 16,
              height: 16,
              child: _dot(Colors.green),
            ),
            Marker(
              point: points.last,
              width: 16,
              height: 16,
              child: _dot(Colors.red),
            ),
          ],
        ),
      ],
    );
  }

  static Widget _dot(Color c) => Container(
    decoration: BoxDecoration(
      color: c,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 2),
    ),
  );
}

// One metric shown on the run detail page.
class _RunStat {
  final IconData icon;
  final String label;
  final String value;

  const _RunStat(this.icon, this.label, this.value);
}

// Detail view for a run recorded by another app: its health metrics, with the
// GPS route shown on top when one is available. When there's no route we simply
// show the metrics — no empty-map placeholder.
class _HcRunDetailPage extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<_RunStat> stats;
  final List<LatLng>? points;
  final bool consentBlocked;

  const _HcRunDetailPage({
    required this.title,
    required this.subtitle,
    required this.stats,
    required this.points,
    required this.consentBlocked,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pts = points;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(subtitle, style: theme.textTheme.bodySmall),
          ),
        ),
      ),
      body: ListView(
        children: [
          if (pts != null) SizedBox(height: 320, child: _RouteMapView(pts)),
          if (pts == null && consentBlocked)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(
                'This run has a route. Enable the "Exercise routes" permission '
                'in Health Connect to see it here.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [for (final s in stats) _statCard(theme, s)],
            ),
          ),
        ],
      ),
    );
  }

  static Widget _statCard(ThemeData theme, _RunStat s) => Container(
    width: 104,
    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      children: [
        Icon(s.icon, size: 22, color: theme.colorScheme.primary),
        const SizedBox(height: 8),
        Text(
          s.value,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          s.label,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android background sync runs through WorkManager; iOS uses its own
  // BGTask/HealthKit path wired natively in AppDelegate, so it doesn't
  // initialize WorkManager here.
  if (Platform.isAndroid) {
    await Workmanager().initialize(workManagerCallbackDispatcher);
  }
  runApp(const XCTrainingApp());
}

class XCTrainingApp extends StatelessWidget {
  const XCTrainingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chadwick XC Training',
      theme: ThemeData(
        // Seeded from the team logo's sky blue (same value as the adaptive
        // launcher-icon background in pubspec.yaml).
        colorSchemeSeed: const Color(0xFF81C6F0),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Native bridge for Health Connect's route-consent dialogs (MainActivity.kt).
  // The health plugin can't request route access — see _grantRouteAccess.
  static const MethodChannel _routeAccess = MethodChannel(
    'xctraining/route_access',
  );

  final Health _health = Health();
  final AuthService _auth = AuthService(
    serverBase: serverBase,
    googleServerClientId: _googleServerClientId,
  );
  // The UI-independent sync engine (see sync_service.dart) — the UI only
  // renders its progress strings and final result.
  late final SyncService _sync = SyncService(auth: _auth, health: _health);

  String _status = 'Initializing Health Connect...';
  bool _configured = false;
  bool _permissionsGranted = false;
  bool _uploading = false;
  bool _authLoading = true;
  // Last sign-in failure, shown on the welcome screen (which doesn't display
  // the general _status text).
  String? _signInError;

  // Onboarding state, persisted in prefs. Onboarding is complete when health
  // permissions are granted, the route-access step is done (or skipped), and
  // the user has made an automatic-upload choice.
  bool _routeAccessDone = false;
  bool? _autoSyncEnabled; // null = not asked yet
  bool get _onboarded =>
      _permissionsGranted && _routeAccessDone && _autoSyncEnabled != null;

  // Home-page upload status: recorded workouts newer than the server's
  // watermark. null = check in progress; -1 = never synced;
  // -2 = server unreachable.
  int? _pendingSamples;
  DateTime? _lastSyncAt;

  // Cached future for the Runs tab: workouts other apps wrote to Health
  // Connect, grouped into logical runs. Refreshed when the tab is opened.
  Future<List<_HcRun>>? _hcRunsFuture;

  // Bottom-nav page index. Release: 0 = Home, 1 = Runs. Debug builds add
  // 2 = Debug tools.
  int _pageIndex = 0;

  // Single source of truth for what the sync reads + what we request permission
  // for. Must match the manifest's READ_* declarations and the union of
  // _numericStreams + _intervalStreams + [WORKOUT].
  final List<HealthDataType> _types = [
    // Core training signals
    HealthDataType.HEART_RATE,
    HealthDataType.STEPS,
    HealthDataType.DISTANCE_DELTA,
    // GPS routes attached to other apps' workouts (Fitbit / Pixel Watch runs).
    // Must be requested together with WORKOUT. Reading routes OTHER apps wrote
    // additionally needs "Exercise routes → Always allow" in Health Connect's
    // app permissions; until granted they read back empty (ConsentRequired).
    HealthDataType.WORKOUT_ROUTE,
    HealthDataType.ACTIVE_ENERGY_BURNED,
    // TOTAL_CALORIES_BURNED is required even though we never directly read
    // it via this list: the health package's WORKOUT reader internally
    // queries TotalCaloriesBurnedRecord to aggregate calories, and the read
    // returns empty without this permission.
    HealthDataType.TOTAL_CALORIES_BURNED,
    HealthDataType.WORKOUT,
    // Recovery streams (sleep, HRV, resting HR, respiratory rate) are
    // deliberately NOT read or requested: the app uploads workout data only
    // (privacy decision, 2026-07). Don't re-add without revisiting that.
  ];

  // All types are READ-only. The debug "Insert Test Workout" button no longer
  // needs WRITE; if you re-enable it, switch HEART_RATE, DISTANCE_DELTA, and
  // WORKOUT back to READ_WRITE here (and grant WRITE in Health Connect).
  List<HealthDataAccess> get _permissions =>
      _types.map((_) => HealthDataAccess.READ).toList();

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _auth.load();
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _authLoading = false;
      // HealthKit grants workout-route reading through the standard health
      // permission — there's no separate route consent like Health Connect's,
      // and the xctraining/route_access channel is Android-only. So on iOS the
      // route step is always satisfied; skip it.
      _routeAccessDone =
          Platform.isIOS || (prefs.getBool(_routeAccessDonePrefsKey) ?? false);
      _autoSyncEnabled = prefs.containsKey(autoSyncPrefsKey)
          ? prefs.getBool(autoSyncPrefsKey)
          : null;
    });
    await _configureHealth();
    if (!mounted) return;
    if (_auth.isSignedIn) _afterSignedIn();
  }

  // Post-sign-in kick-off, shared by app start and the sign-in buttons: if
  // the user is fully onboarded, either auto-upload (their choice) or just
  // refresh the "anything new to upload?" home status.
  void _afterSignedIn() {
    if (!_onboarded) return; // onboarding UI takes over
    if (_autoSyncEnabled == true && !_uploading) {
      // Ensure the periodic background task exists (survives reboot, but a
      // reinstall clears it) — idempotent, Android-only.
      scheduleAndroidSync();
      _syncHealthData(); // calls _refreshPendingData when done
    } else {
      _refreshPendingData();
    }
  }

  // Recomputes the home page's upload status: how many recorded workouts are
  // newer than the server's watermark. Only workout data uploads, so between
  // workouts the app is legitimately "all caught up" — continuous HR must not
  // count here or the Sync button would never disappear.
  Future<void> _refreshPendingData() async {
    if (!_onboarded || !_auth.isSignedIn) return;
    setState(() => _pendingSamples = null); // check in progress
    // Fail fast on a down server instead of hanging the 30s watermark fetch.
    if (!await _sync.serverReachable()) {
      if (!mounted) return;
      setState(() {
        _pendingSamples = -2; // server unreachable
        _lastSyncAt = null;
        _status = 'Server unreachable at $serverBase.';
      });
      return;
    }
    final DateTime? last;
    try {
      last = await _sync.fetchServerWatermark();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pendingSamples = -2; // server unreachable
        _lastSyncAt = null;
        _status = 'Could not check the server: $e';
      });
      return;
    }
    if (!mounted) return;
    if (last == null) {
      setState(() {
        _pendingSamples = -1; // never synced
        _lastSyncAt = null;
      });
      return;
    }
    final now = DateTime.now();
    // What the next sync would upload: workouts in the reconcile window that
    // the local record doesn't yet mark as on the server (matches sync()).
    final pending = await _sync.pendingWorkoutCount(
      now.subtract(historyWindow),
      now,
    );
    if (!mounted) return;
    setState(() {
      _pendingSamples = pending;
      _lastSyncAt = last!.toLocal();
    });
  }

  // Records the user's automatic-upload choice (the final onboarding step,
  // also togglable from the home page).
  Future<void> _setAutoSync(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(autoSyncPrefsKey, enabled);
    // Start/stop periodic background sync to match the choice (Android-only).
    if (enabled) {
      await scheduleAndroidSync();
    } else {
      await cancelAndroidSync();
    }
    if (!mounted) return;
    final firstDecision = _autoSyncEnabled == null;
    setState(() => _autoSyncEnabled = enabled);
    if (firstDecision && enabled && !_uploading) {
      _syncHealthData(); // onboarding just finished — start the first upload
    } else {
      _refreshPendingData();
    }
  }

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // Weekly totals as '3h 30m' / '22m'. A clock format would be ambiguous
  // here — a 22-minute week reads as 22 hours next to "miles" and "runs".
  String _fmtWeekTime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _status = 'Signing in with Google...';
      _signInError = null;
    });
    final err = await _auth.signInWithGoogle();
    if (!mounted) return;
    setState(() {
      _signInError = err;
      _status =
          err ?? 'Signed in as ${_auth.email ?? _auth.name ?? "(unknown)"}.';
    });
    if (err == null) _afterSignedIn();
  }

  Future<void> _signInWithDevEmail() async {
    final controller = TextEditingController(text: _auth.email ?? '');
    final String? email;
    try {
      email = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Dev sign-in'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Email to sign in as. The server must be running '
                'with DEV_MODE=true for this to work.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  hintText: 'you@example.com',
                ),
                autofocus: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('Sign in'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
    if (email == null || email.trim().isEmpty) return;
    if (!mounted) return;
    setState(() {
      _status = 'Signing in as $email...';
      _signInError = null;
    });
    final err = await _auth.signInWithDevEmail(email);
    if (!mounted) return;
    setState(() {
      _signInError = err;
      _status = err ?? 'Signed in as ${_auth.email ?? email}.';
    });
    if (err == null) _afterSignedIn();
  }

  Future<void> _signOut() async {
    await _auth.signOut();
    // No token for the background isolate to use — stop the periodic task.
    await cancelAndroidSync();
    if (!mounted) return;
    setState(() => _status = 'Signed out.');
  }

  Widget _buildAuthCard(ThemeData theme) {
    // Hide the auth UI entirely until prefs are loaded — avoids the brief
    // "not signed in" flash on a returning user.
    if (_authLoading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('Loading saved session...'),
            ],
          ),
        ),
      );
    }

    if (_auth.isSignedIn) {
      final label = _auth.email ?? _auth.name ?? 'Signed in';
      return Card(
        color: theme.colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(
                Icons.account_circle,
                color: theme.colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: theme.colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(onPressed: _signOut, child: const Text('Sign out')),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Sign in to sync', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Your athlete identity is read from the bearer token the '
              'server issues — pick a sign-in method.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _auth.isGoogleConfigured ? _signInWithGoogle : null,
              icon: const Icon(Icons.login),
              label: Text(
                _auth.isGoogleConfigured
                    ? 'Sign in with Google'
                    : 'Google Sign-In not configured',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _signInWithDevEmail,
              icon: const Icon(Icons.developer_mode),
              label: const Text('Dev sign-in (server DEV_MODE only)'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _configureHealth() async {
    try {
      await _health.configure();
      if (!mounted) return;
      _configured = true;
      await _checkPermissions();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Error initializing Health Connect: $e';
      });
    }
  }

  Future<void> _checkPermissions() async {
    try {
      final hasPermissions = await _health.hasPermissions(
        _types,
        permissions: _permissions,
      );
      // HealthKit never discloses READ-grant status, so on iOS hasPermissions
      // is always null for our read-only types. Fall back to "the permission
      // sheet was accepted once" persisted at request time — otherwise every
      // cold launch re-shows onboarding.
      var granted = hasPermissions ?? false;
      if (!granted && Platform.isIOS) {
        final prefs = await SharedPreferences.getInstance();
        granted = prefs.getBool(_healthPermsRequestedPrefsKey) ?? false;
      }
      if (!mounted) return;

      setState(() {
        _permissionsGranted = granted;
        _status = _permissionsGranted
            ? 'Permissions granted. Ready to read data!'
            : 'Tap "Request Permissions" to get started.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Error checking permissions: $e';
      });
    }
  }

  Future<void> _requestPermissions() async {
    if (!_configured) {
      setState(() => _status = 'Health Connect not ready yet. Please wait...');
      return;
    }

    setState(() => _status = 'Requesting permissions...');

    try {
      final requested = await _health.requestAuthorization(
        _types,
        permissions: _permissions,
      );
      if (requested && Platform.isIOS) {
        // Remember the grant — hasPermissions can't detect it on iOS (see
        // _checkPermissions).
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_healthPermsRequestedPrefsKey, true);
      }
      if (!mounted) return;

      setState(() {
        _permissionsGranted = requested;
        _status = requested
            ? 'Permissions granted!'
            : 'Permissions denied. Open Health Connect settings to grant access.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Error requesting permissions: $e';
        _permissionsGranted = false;
      });
    }
  }

  Future<void> _syncHealthData({bool backfill = false}) async {
    setState(() {
      _uploading = true;
      _status = 'Checking server...';
    });
    final result = await _sync.sync(
      backfill: backfill,
      onProgress: (msg) {
        if (mounted) setState(() => _status = msg);
      },
    );
    if (!mounted) return;
    setState(() {
      _uploading = false;
      _status = result.message;
      // Drive the home status to the "unreachable" line; otherwise it falls
      // back to the stale _pendingSamples value ("Checking for new data…").
      if (result.status == SyncStatus.unreachable) _pendingSamples = -2;
    });
    // On unauthorized the token was dropped — the sign-in card takes over;
    // unreachable was handled above. Everything else recomputes the home
    // page's upload status.
    if (result.status == SyncStatus.ok ||
        result.status == SyncStatus.httpError ||
        result.status == SyncStatus.error) {
      _refreshPendingData();
    }
  }

  // Marks the route-access onboarding step complete (granted or skipped).
  Future<void> _markRouteAccessDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_routeAccessDonePrefsKey, true);
    if (!mounted) return;
    setState(() => _routeAccessDone = true);
  }

  // Obtains Health Connect route access via the native dialogs (used by
  // onboarding and the debug page). Tries the blanket "Exercise routes"
  // permission first (Android 15+); if that's unavailable or denied, falls
  // back to the per-route consent dialog for the first consent-blocked route
  // (its "Allow all" option covers future runs).
  Future<void> _grantRouteAccess() async {
    // iOS has no separate route consent — HealthKit's standard permission
    // covers workout routes, and the route_access channel is Android-only.
    if (Platform.isIOS) {
      setState(() => _status = 'Route access is granted via Health on iOS.');
      await _markRouteAccessDone();
      return;
    }
    setState(() => _status = 'Requesting Health Connect route access...');
    try {
      final blanket = await _routeAccess.invokeMethod<bool>(
        'requestRoutesPermission',
      );
      if (!mounted) return;
      if (blanket == true) {
        setState(() => _status = 'Exercise-routes permission granted.');
        await _markRouteAccessDone();
        return;
      }
      // Fall back to per-route consent for the first blocked route.
      final now = DateTime.now();
      final points = await _sync.safeRead(
        HealthDataType.WORKOUT_ROUTE,
        now.subtract(const Duration(days: 30)),
        now,
      );
      if (!mounted) return;
      String? uuid;
      for (final p in points) {
        final v = p.value;
        if (v is WorkoutRouteHealthValue && v.locations.isEmpty) {
          uuid = v.workoutUuid ?? p.uuid;
          break;
        }
      }
      if (uuid == null) {
        // Nothing blocked on consent — nothing to grant right now.
        setState(
          () =>
              _status = 'No consent-blocked routes found in the last 30 days.',
        );
        await _markRouteAccessDone();
        return;
      }
      final ok = await _routeAccess.invokeMethod<bool>('requestRouteConsent', {
        'sessionUuid': uuid,
      });
      if (!mounted) return;
      setState(
        () => _status = ok == true
            ? 'Route consent granted — pick "Allow all" next time to cover '
                  'future runs automatically.'
            : 'Route consent denied.',
      );
      if (ok == true) await _markRouteAccessDone();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Route access request failed: $e');
    }
  }

  // Debug: full start-over. Asks the server to delete EVERYTHING this athlete
  // has uploaded (DELETE /me/data — see SERVER_SCHEMA.md "Data reset"), then
  // clears the local route-upload dedup list so the next Sync re-uploads the
  // full first-sync window and every route from scratch. (The sync watermark
  // lives on the server and resets with the data.) Local state is only
  // cleared after the server wipe succeeds, so a failed wipe can be retried.
  Future<void> _resetSyncWatermark() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wipe server data?'),
        content: Text(
          'This deletes ALL data uploaded for your account on the server '
          'and resets local sync state. The next Sync re-uploads the full '
          '${historyWindow.inDays}-day window and all saved routes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('Delete & Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _uploading = true;
      _status = 'Deleting server data...';
    });
    try {
      final resp = await http
          .delete(Uri.parse('$serverBase/me/data'), headers: _auth.authHeaders)
          .timeout(const Duration(seconds: 60));
      if (!mounted) return;
      if (resp.statusCode == 401) {
        await _auth.invalidate();
        if (!mounted) return;
        setState(() {
          _uploading = false;
          _status = 'Sign-in expired. Please sign in again, then retry.';
        });
        return;
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final body = resp.body.length > 300
            ? '${resp.body.substring(0, 300)}…'
            : resp.body;
        setState(() {
          _uploading = false;
          _status =
              'Server delete failed: ${resp.statusCode}. '
              'Local sync state left untouched.\n$body';
        });
        return;
      }
      // The server owns route dedup and the sample watermark; the only local
      // state is the uploaded-workout set (reconciliation), cleared here so the
      // next Sync re-reconciles the whole window from scratch.
      await _sync.clearUploadedWorkouts();
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _status =
            'Server data deleted: ${resp.body}\nLocal sync state '
            'cleared — next Sync re-uploads the full '
            '${historyWindow.inDays}-day window + all routes.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _status = 'Server delete failed: $e\nLocal sync state left untouched.';
      });
    }
  }

  Future<void> _readHeartRate() async {
    setState(() => _status = 'Reading heart rate data...');

    try {
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));

      final data = await _health.getHealthDataFromTypes(
        types: [HealthDataType.HEART_RATE],
        startTime: yesterday,
        endTime: now,
      );
      if (!mounted) return;

      if (data.isEmpty) {
        setState(() {
          _status = 'No heart rate data found in the last 24 hours.';
        });
        return;
      }

      data.sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
      final latest = data.first;
      final v = latest.value;
      final bpm = v is NumericHealthValue ? v.numericValue : v;

      setState(() {
        _status =
            'Latest heart rate: $bpm BPM at '
            '${latest.dateFrom.toLocal().toString().substring(0, 19)} '
            '(${data.length} readings in last 24h).';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Error reading heart rate: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Loading persisted session → blank spinner (avoids a sign-in flash).
    if (_authLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // Signed out → welcome screen: logo, message, sign-in. Nothing else.
    if (!_auth.isSignedIn) return _buildWelcome(theme);

    // Signed in but not set up → guided onboarding (permissions, route
    // access, automatic-upload choice).
    if (!_onboarded) return _buildOnboarding(theme);

    // The team doesn't record runs in-app, so release builds are Training +
    // Runs (workouts other apps wrote to Health Connect) + Settings. The Debug
    // tools tab exists only in debug builds.
    final tabs = <({String title, IconData icon, IconData selected})>[
      (
        title: 'Training',
        icon: Icons.insights_outlined,
        selected: Icons.insights,
      ),
      (
        title: 'Runs',
        icon: Icons.directions_run_outlined,
        selected: Icons.directions_run,
      ),
      (
        title: 'Settings',
        icon: Icons.settings_outlined,
        selected: Icons.settings,
      ),
      if (kDebugMode)
        (
          title: 'Debug',
          icon: Icons.bug_report_outlined,
          selected: Icons.bug_report,
        ),
    ];
    const settingsIndex = 2;
    final index = _pageIndex.clamp(0, tabs.length - 1);

    // Build only the active page — building all of them every frame would
    // re-run the Runs loaders on every setState.
    final Widget body = switch (index) {
      0 => _buildTrainingPage(theme),
      1 => _buildHcRunsPage(theme),
      settingsIndex => _buildSettingsPage(theme),
      _ => _buildDebugPage(theme),
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(tabs[index].title),
        centerTitle: true,
        actions: [_uploadChip(theme, settingsIndex)],
      ),
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) {
          setState(() {
            _pageIndex = i;
            if (i == 1) _hcRunsFuture = _loadHcRuns(); // refresh on open
          });
        },
        destinations: [
          for (final t in tabs)
            NavigationDestination(
              icon: Icon(t.icon),
              selectedIcon: Icon(t.selected),
              label: t.title,
            ),
        ],
      ),
    );
  }

  // Signed-out landing: team logo, welcome message, and sign-in — no other
  // buttons, no bottom nav.
  Widget _buildWelcome(ThemeData theme) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(32),
                  child: Image.asset(
                    'assets/icon/app_icon.jpg',
                    width: 160,
                    height: 160,
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  'Chadwick XC Training',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'Welcome! Sign in to share your training data with the team.',
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
                FilledButton.icon(
                  onPressed: _auth.isGoogleConfigured
                      ? _signInWithGoogle
                      : null,
                  icon: const Icon(Icons.login),
                  label: Text(
                    _auth.isGoogleConfigured
                        ? 'Sign in with Google'
                        : 'Google Sign-In not configured',
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
                if (kDebugMode) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _signInWithDevEmail,
                    child: const Text('Dev sign-in (debug builds only)'),
                  ),
                ],
                if (_signInError != null) ...[
                  const SizedBox(height: 24),
                  Text(
                    _signInError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Post-sign-in setup: health permissions → route access → automatic-upload
  // choice. One step is active at a time; completed steps get a check.
  Widget _buildOnboarding(ThemeData theme) {
    final autoDone = _autoSyncEnabled != null;

    Widget step(int n, String title, bool done, bool active) {
      return ListTile(
        leading: done
            ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
            : CircleAvatar(
                radius: 14,
                backgroundColor: active
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
                foregroundColor: active
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurfaceVariant,
                child: Text('$n'),
              ),
        title: Text(
          title,
          style: active ? const TextStyle(fontWeight: FontWeight.w600) : null,
        ),
      );
    }

    final healthActive = !_permissionsGranted;
    final routeActive = _permissionsGranted && !_routeAccessDone;
    final autoActive = _permissionsGranted && _routeAccessDone && !autoDone;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chadwick XC Training'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              "Let's get you set up",
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              Platform.isIOS
                  ? 'Two quick steps so your training data reaches the team.'
                  : 'Three quick steps so your training data reaches the team.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Card(
              child: Column(
                children: [
                  step(
                    1,
                    'Allow health data access',
                    _permissionsGranted,
                    healthActive,
                  ),
                  // Health Connect needs a separate route-consent step;
                  // HealthKit covers routes with the standard permission, so
                  // this step doesn't exist on iOS.
                  if (!Platform.isIOS)
                    step(
                      2,
                      'Allow workout route access',
                      _routeAccessDone,
                      routeActive,
                    ),
                  step(
                    Platform.isIOS ? 2 : 3,
                    'Choose automatic upload',
                    autoDone,
                    autoActive,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            if (healthActive)
              FilledButton.icon(
                onPressed: _requestPermissions,
                icon: const Icon(Icons.favorite),
                label: const Text('Allow health data access'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              )
            else if (routeActive) ...[
              Text(
                'When Health Connect asks, choose "Allow all" so every '
                'run\'s route is shared with the team.',
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _grantRouteAccess,
                icon: const Icon(Icons.route),
                label: const Text('Allow workout route access'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _markRouteAccessDone,
                child: const Text('Skip for now'),
              ),
            ] else if (autoActive) ...[
              Text(
                'Upload your workouts automatically whenever you open the app?',
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _setAutoSync(true),
                icon: const Icon(Icons.cloud_upload),
                label: const Text('Yes, upload automatically'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => _setAutoSync(false),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                child: const Text("No, I'll sync manually"),
              ),
            ],
            const SizedBox(height: 24),
            Text(
              _status,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // Shared status card — shown on both pages so an action's result is
  // visible whichever tab you're on.
  Widget _buildStatusCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Status', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(_status),
          ],
        ),
      ),
    );
  }

  // Loads workouts other apps wrote to Health Connect (last 30 days) and
  // groups time-overlapping ones into logical runs — see _HcRun.
  Future<List<_HcRun>> _loadHcRuns() async {
    final now = DateTime.now();
    final workouts = await _sync.safeRead(
      HealthDataType.WORKOUT,
      now.subtract(historyWindow),
      now,
    );
    workouts.sort((a, b) => a.dateFrom.compareTo(b.dateFrom));
    final runs = <_HcRun>[];
    for (final w in workouts) {
      if (runs.isNotEmpty && runs.last.overlaps(w)) {
        runs.last.add(w);
      } else {
        runs.add(_HcRun(w));
      }
    }

    // Mark runs that have a GPS route — feeds the looks-like-a-run display
    // heuristic in _HcRun.activityType. Matched by workout uuid, falling
    // back to time overlap (route records exist even when consent blocks
    // reading their points).
    final routes = await _sync.safeRead(
      HealthDataType.WORKOUT_ROUTE,
      now.subtract(historyWindow),
      now,
    );
    for (final p in routes) {
      final v = p.value;
      if (v is! WorkoutRouteHealthValue) continue;
      for (final run in runs) {
        final matches =
            run.uuids.contains(v.workoutUuid) ||
            run.uuids.contains(p.uuid) ||
            (p.dateFrom.isBefore(run.end) && p.dateTo.isAfter(run.start));
        if (matches) {
          run.hasRoute = true;
          break;
        }
      }
    }

    return runs.reversed.toList(); // newest first
  }

  // 'com.fitbit.FitbitMobile' -> 'Fitbit', 'com.strava' -> 'Strava', etc.
  String _prettySource(String source) {
    const known = {
      'com.strava': 'Strava',
      'com.fitbit.FitbitMobile': 'Fitbit',
      'com.google.android.apps.fitness': 'Google Fit',
      'com.google.android.apps.healthdata': 'Health Connect',
    };
    final k = known[source];
    if (k != null) return k;
    final seg = source.split('.').last;
    return seg.isEmpty ? source : seg[0].toUpperCase() + seg.substring(1);
  }

  // 'TRAIL_RUNNING' -> 'Trail running'.
  String _prettyActivity(String name) {
    final lower = name.replaceAll('_', ' ').toLowerCase();
    return lower[0].toUpperCase() + lower.substring(1);
  }

  IconData _activityIcon(String name) {
    if (name.contains('RUN')) return Icons.directions_run;
    if (name.contains('WALK') || name.contains('HIK')) {
      return Icons.directions_walk;
    }
    if (name.contains('BIK') || name.contains('CYCL')) {
      return Icons.pedal_bike;
    }
    if (name.contains('SWIM')) return Icons.pool;
    return Icons.fitness_center;
  }

  // Runs tab: workouts recorded by other apps (Fitbit, Strava, ...), grouped
  // per physical run. Tapping shows the GPS route when one is available.
  Widget _buildHcRunsPage(ThemeData theme) {
    return FutureBuilder<List<_HcRun>>(
      future: _hcRunsFuture ??= _loadHcRuns(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final runs = snap.data ?? [];
        if (runs.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No workouts found in the last 30 days.\n'
                'Runs recorded by Fitbit, Strava, and other apps connected '
                'to Health Connect show up here.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView.separated(
          itemCount: runs.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => _runTile(runs[i]),
        );
      },
    );
  }

  // One run in a list — shared by the Runs tab and the Training tab's recent
  // runs. Tapping opens the detail page.
  Widget _runTile(_HcRun r) {
    final miles = r.miles;
    final parts = <String>[
      if (miles != null) '${miles.toStringAsFixed(2)} mi',
      _fmtDuration(r.duration),
      if (miles != null && miles > 0) _fmtPace(r.duration, miles),
      r.sources.map(_prettySource).join(' + '),
    ];
    final theme = Theme.of(context);
    return ListTile(
      // Tinted when the activity counts toward weekly run mileage — the cue
      // that explains why a listed activity may not be in the total.
      leading: Icon(
        _activityIcon(r.activityType),
        color: r.isRun
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(
        '${_prettyActivity(r.activityType)} · ${_fmtRunDate(r.start.toUtc())}',
      ),
      subtitle: Text(parts.join(' · ')),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openHcRun(r),
    );
  }

  // Fetches the GPS route for a grouped run: the route record whose workout
  // uuid belongs to the group (any overlapping route as fallback).
  Future<({List<LatLng>? points, bool consentBlocked})> _routeForRun(
    _HcRun run,
  ) async {
    final records = await _sync.safeRead(
      HealthDataType.WORKOUT_ROUTE,
      run.start.subtract(const Duration(minutes: 5)),
      run.end.add(const Duration(minutes: 5)),
    );
    var consentBlocked = false;
    for (final p in records) {
      final v = p.value;
      if (v is! WorkoutRouteHealthValue) continue;
      final matches =
          v.workoutUuid == null ||
          run.uuids.contains(v.workoutUuid) ||
          run.uuids.contains(p.uuid);
      if (!matches) continue;
      if (v.locations.isNotEmpty) {
        return (
          points: [
            for (final l in v.locations) LatLng(l.latitude, l.longitude),
          ],
          consentBlocked: false,
        );
      }
      consentBlocked = true; // route exists but HC withheld the points
    }
    return (points: null, consentBlocked: consentBlocked);
  }

  Future<void> _openHcRun(_HcRun run) async {
    final route = await _routeForRun(run);

    // Average / max heart rate over the run window, if any HR was recorded.
    int? avgHr, maxHr;
    try {
      final hr = await _sync.safeRead(
        HealthDataType.HEART_RATE,
        run.start,
        run.end,
      );
      final bpms = <double>[
        for (final p in hr)
          if (p.value is NumericHealthValue)
            (p.value as NumericHealthValue).numericValue.toDouble(),
      ];
      if (bpms.isNotEmpty) {
        avgHr = (bpms.reduce((a, b) => a + b) / bpms.length).round();
        maxHr = bpms.reduce((a, b) => a > b ? a : b).round();
      }
    } catch (e) {
      debugPrint('HR read for run failed: $e');
    }
    if (!mounted) return;

    final miles = run.miles;
    final energy = run.energyKcal;
    final steps = run.steps;
    final stats = <_RunStat>[
      if (miles != null)
        _RunStat(
          Icons.straighten,
          'Distance',
          '${miles.toStringAsFixed(2)} mi',
        ),
      _RunStat(Icons.timer_outlined, 'Duration', _fmtDuration(run.duration)),
      if (miles != null && miles > 0)
        _RunStat(Icons.speed, 'Pace', _fmtPace(run.duration, miles)),
      if (energy != null)
        _RunStat(
          Icons.local_fire_department,
          'Energy',
          '${energy.round()} kcal',
        ),
      if (steps != null) _RunStat(Icons.directions_walk, 'Steps', '$steps'),
      if (avgHr != null) _RunStat(Icons.favorite, 'Avg HR', '$avgHr bpm'),
      if (maxHr != null)
        _RunStat(Icons.favorite_border, 'Max HR', '$maxHr bpm'),
    ];

    final pts = route.points;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _HcRunDetailPage(
          title:
              '${_prettyActivity(run.activityType)} · ${_fmtRunDate(run.start.toUtc())}',
          subtitle: run.sources.map(_prettySource).join(' + '),
          stats: stats,
          points: (pts != null && pts.length >= 2) ? pts : null,
          consentBlocked: route.consentBlocked,
        ),
      ),
    );
  }

  // Pace as m:ss per mile.
  String _fmtPace(Duration d, double miles) {
    final secPerMile = (d.inSeconds / miles).round();
    final m = secPerMile ~/ 60;
    final s = secPerMile % 60;
    return '$m:${s.toString().padLeft(2, '0')} /mi';
  }

  String _fmtRunDate(DateTime utc) {
    final d = utc.toLocal();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final ampm = d.hour < 12 ? 'AM' : 'PM';
    final min = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day}, ${d.year}  $h:$min $ampm';
  }

  // Upload state, rendered both as the app-bar chip and on the Settings tab.
  // Computed in one place so the two can't disagree.
  ({IconData icon, String line}) get _uploadStatus {
    final pending = _pendingSamples;
    if (_uploading) {
      return (icon: Icons.cloud_upload, line: _status); // live sync progress
    }
    if (pending == null) {
      return (icon: Icons.cloud_queue, line: 'Checking for new data…');
    }
    if (pending == -2) {
      return (
        icon: Icons.cloud_off,
        line: 'Could not reach the server — tap Sync to retry.',
      );
    }
    if (pending == -1) {
      return (
        icon: Icons.cloud_off,
        line:
            'Nothing uploaded yet — tap Sync to upload your last '
            '${historyWindow.inDays} days.',
      );
    }
    if (pending == 0) {
      return (icon: Icons.cloud_done, line: 'All data uploaded.');
    }
    return (
      icon: Icons.cloud_upload,
      line: pending == 1
          ? '1 workout not yet uploaded — tap Sync.'
          : '$pending workouts not yet uploaded — tap Sync.',
    );
  }

  // True when the server is missing data (including "never synced" and
  // "unreachable") — gates the Sync button.
  bool get _syncBehind => _pendingSamples != null && _pendingSamples != 0;

  // Compact upload indicator in the app bar. Uploading is plumbing, so it gets
  // an icon here instead of a card on the main screen; tapping opens Settings,
  // where the full status line and the Sync button live.
  Widget _uploadChip(ThemeData theme, int settingsIndex) {
    final status = _uploadStatus;
    final busy = _uploading || _pendingSamples == null;
    return IconButton(
      tooltip: status.line,
      onPressed: () => setState(() => _pageIndex = settingsIndex),
      icon: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              status.icon,
              color: _pendingSamples == -2 ? theme.colorScheme.error : null,
            ),
    );
  }

  // Signed-in home: what the athlete has actually run — this week's volume,
  // the four-week trend, and the latest runs. Everything here is computed from
  // Health Connect / HealthKit on the phone, so it works offline.
  Widget _buildTrainingPage(ThemeData theme) {
    return FutureBuilder<List<_HcRun>>(
      future: _hcRunsFuture ??= _loadHcRuns(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final runs = snap.data ?? [];
        final onlyRuns = [
          for (final r in runs)
            if (r.isRun) r,
        ];
        final weeks = weeklyTotals([
          for (final r in onlyRuns)
            RunSummary(start: r.start, miles: r.miles, duration: r.duration),
        ], DateTime.now());
        final thisWeek = weeks.last;
        final lastWeek = weeks[weeks.length - 2];

        return RefreshIndicator(
          onRefresh: () async {
            final future = _loadHcRuns();
            setState(() => _hcRunsFuture = future);
            await future;
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'This week',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          // "run miles", not "miles" — the list below shows all
                          // activity, but only runs count toward volume.
                          _bigMetric(
                            theme,
                            thisWeek.miles.toStringAsFixed(1),
                            'run miles',
                          ),
                          _bigMetric(theme, '${thisWeek.runs}', 'runs'),
                          _bigMetric(
                            theme,
                            _fmtWeekTime(thisWeek.time),
                            'time',
                          ),
                        ],
                      ),
                      if (thisWeek.miles > 0 || lastWeek.miles > 0) ...[
                        const SizedBox(height: 12),
                        _weekDelta(theme, thisWeek.miles - lastWeek.miles),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          'Weekly mileage',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      WeeklyMileageChart(weeks),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (runs.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No workouts found in the last ${historyWindow.inDays} '
                    'days. Runs recorded by Fitbit, Strava, and other apps '
                    'show up here once they sync.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 4),
                  child: Text(
                    'Recent activity',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (final r in runs.take(3)) _runTile(r),
                if (runs.length > 3)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(() => _pageIndex = 1),
                      child: Text('See all ${runs.length} activities'),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  // One of the three big numbers on the "This week" card.
  Widget _bigMetric(ThemeData theme, String value, String label) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.primary,
          ),
        ),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );

  // "▲ 2.1 mi vs last week" — the comparison a runner actually looks for.
  Widget _weekDelta(ThemeData theme, double deltaMiles) {
    final rounded = double.parse(deltaMiles.toStringAsFixed(1));
    if (rounded == 0) {
      return Text(
        'Even with last week',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final up = rounded > 0;
    return Row(
      children: [
        Icon(
          up ? Icons.arrow_upward : Icons.arrow_downward,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 4),
        Text(
          '${rounded.abs().toStringAsFixed(1)} mi vs last week',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  // Account, upload status, and the automatic-upload choice.
  Widget _buildSettingsPage(ThemeData theme) {
    final status = _uploadStatus;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildAuthCard(theme),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (_uploading || _pendingSamples == null)
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Icon(status.icon, color: theme.colorScheme.primary),
                      const SizedBox(width: 12),
                      Text(
                        'Upload status',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(status.line),
                  if (!_uploading && _lastSyncAt != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Last synced: ${_fmtRunDate(_lastSyncAt!.toUtc())}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (!_uploading && _syncBehind)
            FilledButton.icon(
              onPressed: _syncHealthData,
              icon: const Icon(Icons.cloud_upload),
              label: const Text('Sync to Server'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
          const SizedBox(height: 16),
          Card(
            child: SwitchListTile(
              title: const Text('Upload automatically'),
              subtitle: const Text(
                'Sync in the background and when the app opens',
              ),
              value: _autoSyncEnabled ?? false,
              onChanged: _uploading ? null : (v) => _setAutoSync(v),
            ),
          ),
          if (!_uploading) ...[
            const SizedBox(height: 16),
            Text(
              _status,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ============================================================
  // DEBUG ONLY — this whole page is built only when kDebugMode is
  // true. Remove the page (and its methods) before final ship.
  // ============================================================
  Widget _buildDebugPage(ThemeData theme) {
    final orange = Colors.orange.shade800;
    OutlinedButton debugButton(
      IconData icon,
      String label,
      VoidCallback onPressed,
    ) {
      return OutlinedButton.icon(
        onPressed: _uploading ? null : onPressed,
        icon: Icon(icon),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: orange,
          side: BorderSide(color: orange),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Which source produced this build (injected via --dart-define).
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Icon(
                  Icons.commit,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  'Build: $_gitCommit',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          _buildStatusCard(theme),
          const SizedBox(height: 16),
          if (!_permissionsGranted)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Grant Health Connect permissions on the Home tab first — '
                  'the debug tools read and write health data.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
          // Independent of health permissions — wipes server data + sync state.
          debugButton(
            Icons.restart_alt,
            'Reset (wipe server + start over)',
            _resetSyncWatermark,
          ),
          const SizedBox(height: 8),
          // Background syncs run headlessly and are otherwise invisible —
          // the entrypoint records each attempt for exactly this button.
          debugButton(Icons.bedtime, 'Last Background Sync', () async {
            final prefs = await SharedPreferences.getInstance();
            // The record is written by the background isolate; reload so this
            // (UI) isolate's cached copy picks up that out-of-process write.
            await prefs.reload();
            final last = prefs.getString(lastBackgroundSyncPrefsKey);
            if (!mounted) return;
            setState(
              () => _status = last == null
                  ? 'No background sync has run yet.'
                  : 'Last background sync:\n$last',
            );
          }),
          const SizedBox(height: 8),
          // Spike: enqueue a WorkManager one-off to prove Health Connect reads
          // work in a headless isolate. WorkManager runs it within ~seconds;
          // check "Last Background Sync" after.
          if (Platform.isAndroid)
            debugButton(
              Icons.play_circle_outline,
              'Run Background Sync (WorkManager)',
              () async {
                await Workmanager().registerOneOffTask(
                  '$androidSyncUniqueName-test',
                  androidSyncTaskName,
                  existingWorkPolicy: ExistingWorkPolicy.replace,
                );
                if (!mounted) return;
                setState(
                  () => _status =
                      'Enqueued a WorkManager sync. Wait a few seconds, then '
                      'tap "Last Background Sync".',
                );
              },
            ),
          if (Platform.isAndroid) const SizedBox(height: 8),
          if (_permissionsGranted) ...[
            debugButton(
              Icons.history,
              'Upload Past ${historyWindow.inDays} Days (backfill)',
              () {
                if (!_uploading) _syncHealthData(backfill: true);
              },
            ),
            const SizedBox(height: 8),
            debugButton(Icons.favorite, 'Read Heart Rate', _readHeartRate),
          ],
        ],
      ),
    );
  }
}
