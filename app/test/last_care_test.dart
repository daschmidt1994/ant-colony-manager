import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  test('last care: newest per kind, back-dated entries, categories, own activities, only asked colonies', () {
    final db = memoryDb();
    final start = DateTime.utc(2026, 9, 1, 9);
    var now = start;
    final repo = ColonyRepository(db, userId: 'u1', onChanged: () {}, clock: () => now);
    final a = repo.createColony({'name': 'A'}, intervals: {'protein': 3});
    final b = repo.createColony({'name': 'B'}, intervals: {'water': 7});
    repo.setCustomTasks(a, [(id: null, title: 'Nest befeuchten', days: 7)]);
    final nest = repo.customTasks(a).single;

    Map<String, dynamic> feeding(String category) => {
      'feeding': {
        'items': [
          {'food_name': 'x', 'category': category},
        ],
      },
    };
    DateTime day(int d) => start.add(Duration(days: d));

    now = day(10);
    repo.logEvent(a, 'feeding', details: feeding('protein'), at: day(2));
    repo.logEvent(a, 'feeding', details: feeding('carbohydrate'), at: day(5));
    repo.logEvent(a, 'feeding', details: feeding('protein'), at: day(4)); // entered later, happened earlier
    repo.logEvent(a, 'census', at: day(6));
    repo.logEvent(a, 'water', at: day(3));
    repo.logCustomTask(a, nest, at: day(1));
    repo.logEvent(b, 'water', at: day(8));

    final last = repo.lastCare();
    final la = last[a]!, lb = last[b]!;
    expect(la.protein?.toUtc(), day(4));
    expect(la.carbohydrate?.toUtc(), day(5));
    expect(la.feeding?.toUtc(), day(5));
    expect(la.water?.toUtc(), day(3));
    expect(la.cleaning, isNull);
    expect(la.check?.toUtc(), day(6), reason: 'a census counts as a look at the colony');
    expect(la.bySchedule.map((k, v) => MapEntry(k, v.toUtc())), {nest.id: day(1)});
    expect(lb.water?.toUtc(), day(8));
    expect(lb.feeding, isNull);

    expect(repo.lastCare(colonyIds: [b]).keys, [b]);
    final due = repo.due(a).firstWhere((d) => d.schedule.taskType == 'protein');
    expect(due.nextDue!.isAtSameMomentAs(day(7)), isTrue);
    db.dispose();
  });
}
