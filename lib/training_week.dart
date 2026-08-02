// Weekly training aggregates for the Training page.
//
// Deliberately independent of Health Connect / HealthKit types: callers reduce
// their platform runs to [RunSummary] and this file does the calendar math and
// drawing. That keeps the week bucketing testable without a device.
//
// Weeks run Monday–Sunday in *local* time, which is how a training week is
// read. All the date arithmetic goes through the DateTime constructor's
// out-of-range normalization (`day - 7`) rather than `subtract(Duration)`, so
// it stays correct across daylight-saving boundaries.

import 'package:flutter/material.dart';

/// One run, reduced to what the weekly totals need.
class RunSummary {
  final DateTime start; // local
  final double? miles; // null when the source recorded no distance
  final Duration duration;

  const RunSummary({
    required this.start,
    required this.miles,
    required this.duration,
  });
}

/// Totals for one Monday–Sunday week.
class TrainingWeek {
  final DateTime start; // local Monday, midnight
  final double miles;
  final int runs;
  final Duration time;

  const TrainingWeek({
    required this.start,
    required this.miles,
    required this.runs,
    required this.time,
  });
}

/// The Monday midnight (local) of the week containing [d].
DateTime startOfWeek(DateTime d) =>
    DateTime(d.year, d.month, d.day - (d.weekday - DateTime.monday));

/// Buckets [runs] into the [weeks] most recent Monday–Sunday weeks, oldest
/// first — so the last entry is always the week containing [now], even if it
/// has no runs yet. Runs outside the window are ignored.
List<TrainingWeek> weeklyTotals(
  List<RunSummary> runs,
  DateTime now, {
  int weeks = 4,
}) {
  final current = startOfWeek(now);
  final starts = [
    for (var i = weeks - 1; i >= 0; i--)
      DateTime(current.year, current.month, current.day - 7 * i),
  ];

  final miles = List<double>.filled(weeks, 0);
  final counts = List<int>.filled(weeks, 0);
  final time = List<Duration>.filled(weeks, Duration.zero);

  for (final r in runs) {
    final bucket = startOfWeek(r.start);
    for (var i = 0; i < weeks; i++) {
      if (bucket == starts[i]) {
        miles[i] += r.miles ?? 0;
        counts[i] += 1;
        time[i] += r.duration;
        break;
      }
    }
  }

  return [
    for (var i = 0; i < weeks; i++)
      TrainingWeek(
        start: starts[i],
        miles: miles[i],
        runs: counts[i],
        time: time[i],
      ),
  ];
}

/// Simple bar chart of weekly mileage — no charting dependency, just sized
/// containers. The newest week (last entry) is highlighted as "This week".
class WeeklyMileageChart extends StatelessWidget {
  final List<TrainingWeek> weeks;
  final double height;

  const WeeklyMileageChart(this.weeks, {super.key, this.height = 120});

  static const _months = [
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peak = weeks.fold<double>(0, (m, w) => w.miles > m ? w.miles : m);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < weeks.length; i++)
          Expanded(
            child: _bar(
              theme,
              weeks[i],
              peak,
              current: i == weeks.length - 1,
              label: i == weeks.length - 1
                  ? 'This wk'
                  : '${_months[weeks[i].start.month - 1]} ${weeks[i].start.day}',
            ),
          ),
      ],
    );
  }

  Widget _bar(
    ThemeData theme,
    TrainingWeek week,
    double peak, {
    required bool current,
    required String label,
  }) {
    // Empty weeks still get a sliver of bar so the axis reads as a baseline.
    final fraction = peak <= 0 ? 0.0 : week.miles / peak;
    final color = current
        ? theme.colorScheme.primary
        : theme.colorScheme.primaryContainer;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            week.miles == 0 ? '–' : week.miles.toStringAsFixed(1),
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: current ? FontWeight.w700 : FontWeight.w500,
              color: current
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            height: (height * fraction).clamp(3.0, height),
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(6),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
