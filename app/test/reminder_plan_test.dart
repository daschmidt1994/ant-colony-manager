import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/domain/due.dart';
import 'package:ant_colony_manager/features/reminders/plan.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late AppDatabase db;
  late ColonyRepository repo;
  var now = DateTime(2026, 9, 20, 10); // local time

  setUp(() {
    db = memoryDb();
    now = DateTime(2026, 9, 20, 10);
    repo = ColonyRepository(db, userId: 'u1', onChanged: () {}, clock: () => now);
  });
  tearDown(() => db.dispose());

  test('care is planned for 8 o\'clock on its first overdue day', () {
    final c = repo.createColony({'name': 'Messor', 'species_text': 'x'}, intervals: {'water': 2});
    final due = repo.due(c).single.nextDue!.toLocal();
    final plan = planCareReminders(repo, activeSlots: {});
    expect(plan, hasLength(1));
    expect(plan.single.at, DateTime(due.year, due.month, due.day + 1, 8));
    expect(plan.single.reminder.slot, startsWith('due:'));
    expect(plan.single.reminder.body, contains('seit 1 Tag überfällig'));
  });

  test('overdue care is shown now, not planned; deferred care only after the deferral', () {
    final c = repo.createColony({'name': 'Messor', 'species_text': 'x'}, intervals: {'water': 2});
    now = now.add(const Duration(days: 5));
    final active = {for (final r in repo.reminders()) r.slot};
    expect(active, isNotEmpty);
    expect(planCareReminders(repo, activeSlots: active), isEmpty);

    final t = repo.due(c).single;
    repo.deferSchedule(t.schedule.id, reason: 'water_enough', days: 3);
    final plan = planCareReminders(repo, activeSlots: {for (final r in repo.reminders()) r.slot});
    expect(plan, hasLength(1));
    final until = repo.due(c).single.nextDue!.toLocal();
    expect(plan.single.at, DateTime(until.year, until.month, until.day + 1, 8));
    expect(repo.due(c).single.status, isNot(DueStatus.overdue));
  });

  test('only the next days, and at most the limit', () {
    for (var i = 0; i < 5; i++) {
      repo.createColony({'name': 'K$i', 'species_text': 'x'}, intervals: {'water': 2, 'check': 30});
    }
    final plan = planCareReminders(repo, activeSlots: {}, days: 7);
    expect(plan.every((p) => p.at.difference(now) <= const Duration(days: 8)), isTrue);
    expect(plan.map((p) => p.reminder.slot).toSet(), hasLength(plan.length)); // each once
    expect(plan, hasLength(5)); // water of each colony; check in 30 days is too far
    expect(planCareReminders(repo, activeSlots: {}, limit: 2), hasLength(2));
  });
}
