import 'package:ant_colony_manager/domain/growth.dart';
import 'package:ant_colony_manager/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

ColonyEvent census(String at, Map<String, dynamic> c) =>
    ColonyEvent({'id': at, 'colony_id': 'c', 'type': 'census', 'occurred_at': at, 'census': c});

void main() {
  final events = [
    census('2026-03-01T10:00:00Z', {'exact_count': 12}),
    census('2026-06-01T10:00:00Z', {'estimate_min': 50, 'estimate_max': 80}),
    census('2026-08-01T10:00:00Z', {'note_only': true}),
  ];

  test('worker count at a photo date: last census before it', () {
    expect(workersAt(events, DateTime.utc(2026, 2, 1)), isNull);
    expect(workersAt(events, DateTime.utc(2026, 4, 1))?.min, 12);
    final w = workersAt(events, DateTime.utc(2026, 9, 1))!;
    expect((w.min, w.max), (50, 80), reason: 'a census without numbers does not count');
  });

  test('time between two photos', () {
    expect(timeBetween(DateTime(2025, 1, 15), DateTime(2026, 4, 20)), (years: 1, months: 3, days: 5));
    expect(timeBetween(DateTime(2026, 4, 20), DateTime(2026, 1, 31)), (years: 0, months: 2, days: 20));
    expect(timeBetween(DateTime(2026, 5, 1), DateTime(2026, 5, 9)), (years: 0, months: 0, days: 8));
  });
}
