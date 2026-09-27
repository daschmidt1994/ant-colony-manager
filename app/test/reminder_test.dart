import 'dart:convert';

import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/domain/reminders.dart';
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

  String feed(String colony, String category, String name) => repo
      .logEvent(
        colony,
        'feeding',
        details: {
          'feeding': {
            'items': [
              {'food_name': name, 'category': category, 'quantity': 2, 'unit': 'piece'},
            ],
          },
        },
      )
      .id;

  test('overdue care: one reminder per task, text like the spec, stable slot', () {
    final c = repo.createColony(
      {'name': 'Kolonie 12', 'species_text': 'Messor barbarus'},
      intervals: {'protein': 3, 'water': 7},
    );
    now = now.add(const Duration(days: 5)); // protein 2 days overdue, water not yet
    final r = repo.reminders();
    expect(r, hasLength(1));
    expect(r.single.title, 'Messor barbarus – Kolonie 12');
    expect(r.single.body, 'Proteinfütterung seit 2 Tagen überfällig.');
    expect(r.single.canComplete, isTrue);
    expect(jsonDecode(r.single.payloadJson), containsPair('colony', c));
    // A day later: same slot (replaces the notification), new reason (shown again).
    now = now.add(const Duration(days: 1));
    final r2 = repo.reminders().single;
    expect(r2.slot, r.single.slot);
    expect(r2.key, r.single.key, reason: 'still the same due date → not shown again');
    expect(r2.body, 'Proteinfütterung seit 3 Tagen überfällig.');
  });

  test('no single reminders when disabled, for viewers, archived or paused colonies', () {
    final c = repo.createColony({'name': 'A', 'species_text': 'x'}, intervals: {'water': 1});
    final shared = repo.createColony({'name': 'Geteilt', 'species_text': 'x'}, intervals: {'water': 1});
    db.putRecord('colony_members', {'id': 'm1', 'colony_id': shared, 'user_id': 'u1', 'role': 'viewer'});
    final archived = repo.createColony({'name': 'Alt', 'species_text': 'x'}, intervals: {'water': 1});
    repo.archiveColony(archived, true);
    now = now.add(const Duration(days: 4));
    expect(repo.reminders().map((r) => r.payload['colony']), [c]);
    db.putRecord('user_settings', {'id': 'u1', 'notify_overdue': false});
    expect(repo.reminders(), isEmpty);
  });

  test('„Erledigt“: protein repeats the last protein feeding, water the last kinds', () {
    final c = repo.createColony({'name': 'A', 'species_text': 'x'}, intervals: {'protein': 3, 'water': 2});
    feed(c, 'protein', 'Schabe');
    feed(c, 'carbohydrate', 'Honigwasser'); // newer, but not protein
    repo.logEvent(
      c,
      'water',
      details: {
        'water': {
          'kinds': ['test_tube_changed'],
        },
      },
    );
    now = now.add(const Duration(days: 6));
    expect(repo.reminders(), hasLength(2));

    for (final r in repo.reminders()) {
      expect(handleReminder(repo, actionId: 'done', payload: r.payloadJson), isNull);
    }
    final feeding = repo.events(c, types: {'feeding'}).first;
    expect(feeding.items.single.foodName, 'Schabe');
    expect(repo.events(c, types: {'water'}).first.waterKinds, ['test_tube_changed']);
    expect(repo.reminders(), isEmpty, reason: 'done → no longer overdue');
  });

  test('„Erledigt“ without a previous feeding opens the colony instead', () {
    final c = repo.createColony({'name': 'A', 'species_text': 'x'}, intervals: {'protein': 1});
    now = now.add(const Duration(days: 3));
    final r = repo.reminders().single;
    expect(handleReminder(repo, actionId: 'done', payload: r.payloadJson), '/colonies/$c');
    expect(handleReminder(repo, payload: r.payloadJson), '/colonies/$c', reason: 'tap opens the colony');
    expect(handleReminder(repo, payload: jsonEncode({'kind': 'digest'})), '/');
  });

  test('winter rest past its planned end and open tasks are reminded', () {
    final c = repo.createColony({'name': 'Lasius', 'species_text': 'Lasius niger'});
    db.putRecord('winter_rests', {
      'id': 'w1',
      'colony_id': c,
      'started_on': '2026-01-01',
      'planned_end_on': '2026-09-19',
    });
    db.putRecord('tasks', {'id': 't1', 'colony_id': c, 'title': 'Nest umziehen', 'due_at': '2026-09-20T08:00:00Z'});
    final r = repo.reminders();
    expect(r.map((x) => x.body), ['Winterruhe beenden? Das geplante Ende ist erreicht.', 'Nest umziehen ist fällig.']);
    expect(handleReminder(repo, actionId: 'done', payload: r.last.payloadJson), isNull);
    expect(db.record('tasks', 't1')!.json['done_at'], isNotNull);
    expect(repo.reminders(), hasLength(1));
  });

  test('daily overview counts colonies, not tasks', () {
    final a = repo.createColony({'name': 'A', 'species_text': 'x'}, intervals: {'protein': 2, 'water': 2});
    repo.createColony({'name': 'B', 'species_text': 'x'}, intervals: {'water': 3});
    repo.createColony({'name': 'C', 'species_text': 'x'}, intervals: {'water': 30});
    now = now.add(const Duration(days: 3)); // A overdue (2 tasks), B due today, C fine
    final d = digestFor(repo.dueAll())!;
    expect(d.body, '2 Kolonien brauchen heute Aufmerksamkeit (1 überfällig)');
    repo.completeDue(a, 'water');
    expect(digestFor(repo.dueAll())!.body, '2 Kolonien brauchen heute Aufmerksamkeit (1 überfällig)');
    now = DateTime.utc(2026, 9, 20, 10);
    expect(digestFor(repo.dueAll()), isNull);
  });

  test('notification ids are stable and positive', () {
    expect(notificationId('due:abc'), notificationId('due:abc'));
    expect(notificationId('due:abc'), isNot(notificationId('due:abd')));
    expect(notificationId('x'), greaterThan(0));
  });
}
