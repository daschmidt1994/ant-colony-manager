import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/domain/due.dart';
import 'package:ant_colony_manager/features/reminders/reminder_actions.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late AppDatabase db;
  late ColonyRepository repo;
  var now = DateTime.utc(2026, 9, 20, 10);

  setUp(() {
    db = memoryDb();
    now = DateTime.utc(2026, 9, 20, 10);
    repo = ColonyRepository(db, userId: 'u1', onChanged: () {}, clock: () => now);
  });
  tearDown(() => db.dispose());

  test('nextDue: snooze only pushes later, never earlier; paused stays paused', () {
    final s = Schedule(
      id: 's',
      colonyId: 'c',
      taskType: 'water',
      intervalDays: 2,
      startsAt: DateTime.utc(2026, 9, 1),
      snoozedUntil: DateTime.utc(2026, 9, 10),
    );
    expect(nextDue(s, null, null), DateTime.utc(2026, 9, 10));
    expect(nextDue(s, DateTime.utc(2026, 9, 12), null), DateTime.utc(2026, 9, 14)); // cared for since
    expect(nextDue(s, null, const WinterRestInfo(mode: 'pause', factor: 4)), isNull);
  });

  test('„Morgen“ on an overdue task: due tomorrow, reminder gone, undo restores', () {
    final c = repo.createColony({'name': 'A', 'species_text': 'x'}, intervals: {'water': 2});
    now = now.add(const Duration(days: 4));
    final r = repo.reminders().single;
    expect(r.canSnooze, isTrue);
    expect(handleReminder(repo, actionId: 'snooze', payload: r.payloadJson), isNull);
    final t = repo.due(c).single;
    expect(t.nextDue!.isAtSameMomentAs(startOfTomorrow(now)), isTrue);
    expect(t.days, 1);
    expect(repo.reminders(), isEmpty);
    // In the app with „Rückgängig“.
    final prev = repo.setScheduleSnooze(t.schedule.id, null);
    expect(prev, isNotNull);
    expect(repo.due(c).single.status, DueStatus.overdue);
    // Two days later it is overdue again.
    repo.snoozeSchedule(t.schedule.id);
    now = now.add(const Duration(days: 2));
    expect(repo.due(c).single.status, DueStatus.overdue);
  });

  test('„Morgen“ on a winter plan: start moves to tomorrow, end stays after it', () {
    final c = repo.createColony({'name': 'L', 'species_text': 'x'});
    final today = DateTime(now.toLocal().year, now.toLocal().month, now.toLocal().day);
    repo.planWinter(c, start: today.subtract(const Duration(days: 2)), end: today);
    final r = repo.reminders().singleWhere((r) => r.payload['kind'] == 'winter_start');
    expect(r.canSnooze, isTrue);
    handleReminder(repo, actionId: 'snooze', payload: r.payloadJson);
    final w = repo.winterRest(c)!;
    expect(w.plannedStartOn, today.add(const Duration(days: 1)));
    expect(w.plannedEndOn, today.add(const Duration(days: 2)));
    expect(repo.reminders().where((r) => r.payload['kind'] == 'winter_start'), isEmpty);
    // Running winter rest past its planned end: end moves.
    repo.startWinter(c);
    repo.planWinter(c, start: today, end: today);
    handleReminder(repo, actionId: 'snooze', payload: repo.reminders().single.payloadJson);
    expect(repo.winterRest(c)!.plannedEndOn, today.add(const Duration(days: 1)));
  });

  test('app channel switches per topic', () {
    final c = repo.createColony({'name': 'L', 'species_text': 'x'}, intervals: {'water': 1});
    final today = DateTime(now.toLocal().year, now.toLocal().month, now.toLocal().day);
    repo.planWinter(c, start: today, end: today.add(const Duration(days: 90)));
    now = now.add(const Duration(days: 3));
    expect(repo.reminders().map((r) => r.payload['kind']).toSet(), {'due', 'winter_start'});
    db.putRecord('user_settings', {'id': 'u1', 'notify_winter_app': false});
    expect(repo.reminders().map((r) => r.payload['kind']).toSet(), {'due'});
    db.putRecord('user_settings', {'id': 'u1', 'notify_overdue': false, 'notify_winter_app': false});
    expect(repo.reminders(), isEmpty);
  });
}
