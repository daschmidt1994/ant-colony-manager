import 'package:ant_colony_manager/app/strings.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/features/actions/actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  test('own activities: create, rename, remove; done resets the due date and keeps the name', () {
    final db = memoryDb();
    var now = DateTime.utc(2026, 10, 1, 9);
    final repo = ColonyRepository(db, userId: 'u1', onChanged: () {}, clock: () => now);
    final id = repo.createColony({'name': 'Messor'}, intervals: {'water': 3});

    repo.setCustomTasks(id, [
      (id: null, title: ' Nest befeuchten ', days: 7),
      (id: null, title: '', days: 5), // no name: ignored
      (id: null, title: 'Heizmatte prüfen', days: 0), // no interval: ignored
    ]);
    var tasks = repo.customTasks(id);
    expect(tasks.map((t) => (t.title, t.intervalDays)), [('Nest befeuchten', 7.0)]);
    final nest = tasks.single;
    expect(repo.due(id).map((d) => d.schedule.title), contains('Nest befeuchten'));

    // done after 8 days → next due 7 days later; the event carries the name
    now = now.add(const Duration(days: 8));
    final e = repo.logCustomTask(id, nest);
    expect(e.json['schedule_id'], nest.id);
    expect(S.eventSummary(e), 'Nest befeuchten erledigt');
    final due = repo.due(id).firstWhere((d) => d.schedule.id == nest.id);
    expect(due.nextDue!.isAtSameMomentAs(now.add(const Duration(days: 7))), isTrue);

    // „erledigt“ from a reminder works the same
    expect(S.eventSummary(repo.completeDue(id, 'custom', scheduleId: nest.id)!), 'Nest befeuchten erledigt');

    // rename keeps the schedule (and its history), a missing entry is removed
    repo.setCustomTasks(id, [(id: nest.id, title: 'Nest sprühen', days: 5), (id: null, title: 'Arena', days: 14)]);
    tasks = repo.customTasks(id);
    expect(tasks.map((t) => t.title), containsAll(['Nest sprühen', 'Arena']));
    expect(tasks.firstWhere((t) => t.title == 'Nest sprühen').id, nest.id);
    repo.setCustomTasks(id, [(id: nest.id, title: 'Nest sprühen', days: 5)]);
    expect(repo.customTasks(id).map((t) => t.title), ['Nest sprühen']);
    // the standard intervals are untouched
    expect(repo.schedules(colonyId: id).where((s) => s.taskType == 'water'), hasLength(1));
    db.dispose();
  });

  test('icon of an own activity', () {
    expect(customTaskIcon('Nest sprühen'), Icons.opacity);
    expect(customTaskIcon('Nest befeuchten'), Icons.opacity);
    expect(customTaskIcon('Heizmatte prüfen'), Icons.task_alt);
  });
}
