import 'dart:convert';
import 'dart:io';

import 'package:ant_colony_manager/domain/due.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('classify matches the shared test vectors (same as the Go server)', () {
    final vectors = jsonDecode(File('../test-vectors/due.json').readAsStringSync()) as Map<String, dynamic>;
    for (final c in (vectors['cases'] as List).cast<Map<String, dynamic>>()) {
      final loc = tz.getLocation(c['timezone'] as String);
      LocalDate toLocal(DateTime t) {
        final z = tz.TZDateTime.from(t, loc);
        return (year: z.year, month: z.month, day: z.day);
      }

      final next = c['next_due_at'] == null ? null : DateTime.parse(c['next_due_at'] as String);
      final r = classify(next, DateTime.parse(c['now'] as String), soonDays: c['soon_days'] as int, toLocal: toLocal);
      expect(r.status.name, c['status'] == 'paused' ? 'paused' : c['status'], reason: c['name'] as String);
      final group = switch (r.group) {
        DueGroup.thisWeek => 'this_week',
        final g => g.name,
      };
      expect(group, c['group'], reason: c['name'] as String);
      expect(r.days, c['days'], reason: c['name'] as String);
    }
  });

  group('nextDue', () {
    final start = DateTime.utc(2026, 9, 1);
    Schedule s({String? winterMode}) =>
        Schedule(id: 's', colonyId: 'c', taskType: 'water', intervalDays: 2, startsAt: start, winterMode: winterMode);

    test('uses last care, otherwise the start', () {
      expect(nextDue(s(), null, null), DateTime.utc(2026, 9, 3));
      expect(nextDue(s(), DateTime.utc(2026, 9, 10), null), DateTime.utc(2026, 9, 12));
    });

    test('winter rest scales or pauses reminders', () {
      const scale = WinterRestInfo(mode: 'scale', factor: 4);
      const pause = WinterRestInfo(mode: 'pause', factor: 4);
      expect(nextDue(s(), start, scale), DateTime.utc(2026, 9, 9));
      expect(nextDue(s(), start, pause), isNull);
      expect(nextDue(s(winterMode: 'keep'), start, pause), DateTime.utc(2026, 9, 3));
    });

    test('computeDue sorts by urgency, paused last', () {
      final now = DateTime.utc(2026, 9, 26, 12);
      final tasks = computeDue(
        schedules: [
          Schedule(id: 'a', colonyId: 'c', taskType: 'cleaning', intervalDays: 7, startsAt: now),
          Schedule(id: 'b', colonyId: 'c', taskType: 'protein', intervalDays: 3, startsAt: now),
        ],
        last: LastCare(protein: now.subtract(const Duration(days: 5))),
        now: now,
        toLocal: (t) => (year: t.year, month: t.month, day: t.day),
      );
      expect(tasks.first.schedule.taskType, 'protein');
      expect(tasks.first.status, DueStatus.overdue);
      expect(tasks.first.days, -2);
      expect(worstOf(tasks), tasks.first);
    });
  });
}
