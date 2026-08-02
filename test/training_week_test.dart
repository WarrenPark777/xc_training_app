// Week bucketing is pure calendar math and easy to get subtly wrong, so it's
// covered here — no device or health data needed.

import 'package:flutter_test/flutter_test.dart';
import 'package:xctraining/training_week.dart';

RunSummary run(DateTime start, double miles) => RunSummary(
  start: start,
  miles: miles,
  duration: const Duration(minutes: 30),
);

void main() {
  test('startOfWeek returns the Monday midnight of that week', () {
    // Aug 2 2026 is a Sunday; its week starts Mon Jul 27.
    expect(startOfWeek(DateTime(2026, 8, 2, 23, 59)), DateTime(2026, 7, 27));
    expect(startOfWeek(DateTime(2026, 7, 27, 0, 0)), DateTime(2026, 7, 27));
    expect(startOfWeek(DateTime(2026, 8, 3, 6, 0)), DateTime(2026, 8, 3));
  });

  test('buckets runs into the four most recent weeks, oldest first', () {
    final now = DateTime(2026, 8, 2, 12); // Sunday
    final weeks = weeklyTotals([
      run(DateTime(2026, 8, 1, 8), 6.0), // this week (Jul 27–Aug 2)
      run(DateTime(2026, 7, 28, 7), 4.0), // this week
      run(DateTime(2026, 7, 21, 7), 5.0), // last week (Jul 20–26)
      run(DateTime(2026, 7, 8, 7), 3.0), // three weeks back (Jul 6–12)
    ], now);

    expect(weeks.length, 4);
    expect(weeks.map((w) => w.start), [
      DateTime(2026, 7, 6),
      DateTime(2026, 7, 13),
      DateTime(2026, 7, 20),
      DateTime(2026, 7, 27),
    ]);
    expect(weeks.map((w) => w.miles), [3.0, 0.0, 5.0, 10.0]);
    expect(weeks.map((w) => w.runs), [1, 0, 1, 2]);
    expect(weeks.last.time, const Duration(hours: 1));
  });

  test('ignores runs outside the window and tolerates missing distance', () {
    final now = DateTime(2026, 8, 2, 12);
    final weeks = weeklyTotals([
      run(DateTime(2026, 6, 1), 20.0), // far older than 4 weeks
      RunSummary(
        start: DateTime(2026, 7, 30),
        miles: null, // treadmill run with no distance recorded
        duration: const Duration(minutes: 45),
      ),
    ], now);

    expect(weeks.fold<double>(0, (s, w) => s + w.miles), 0.0);
    expect(weeks.last.runs, 1);
    expect(weeks.last.time, const Duration(minutes: 45));
  });
}
