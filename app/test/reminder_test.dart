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
          'kinds': ['water_changed'],
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
    expect(repo.events(c, types: {'water'}).first.waterKinds, ['water_changed']);
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

  test('planned winter rest: reminder to start, switch on/off, reminder to wake up', () {
    final c = repo.createColony({'name': 'Lasius', 'species_text': 'Lasius niger'}, intervals: {'water': 2});
    repo.planWinter(c, start: DateTime(2026, 11, 1), end: DateTime(2027, 3, 1));
    expect(repo.winterRest(c)!.started, isFalse);
    expect(repo.reminders(), isEmpty, reason: 'nothing before the planned start');
    expect(repo.colony(c)!.status, 'active');

    now = DateTime.utc(2026, 11, 1, 10);
    final start = repo.reminders().where((r) => r.payload['kind'] == 'winter_start').single;
    expect(start.body, 'Winterruhe beginnen? Der geplante Start ist erreicht.');
    expect(handleReminder(repo, payload: start.payloadJson), '/colonies/$c');
    expect(digestFor(const {}, winterStarts: repo.winterStartsDue())!.body, '1× Winterruhe beginnen?');
    expect(repo.openWinterRests(), isEmpty, reason: 'a plan does not pause reminders yet');

    repo.startWinter(c);
    expect(repo.colony(c)!.status, 'hibernating');
    expect(repo.winterRest(c)!.startedOn, DateTime(2026, 11, 1));
    expect(repo.openWinterRests().keys, [c]);
    expect(repo.events(c, types: {'winter_start'}).single.json['winter_rest_id'], repo.winterRest(c)!.id);
    expect(repo.reminders().where((r) => r.payload['kind'] == 'winter_start'), isEmpty);
    final op = db.select("SELECT payload FROM outbox WHERE entity = 'winter_rests' ORDER BY rowid DESC LIMIT 1");
    expect(jsonDecode(op.single['payload'] as String), {
      'colony_id': c,
      'planned_start_on': '2026-11-01',
      'planned_end_on': '2027-03-01',
      'started_on': '2026-11-01',
    }, reason: 'unsent plan and start are sent as one create');

    now = DateTime.utc(2027, 3, 1, 10);
    expect(repo.reminders().map((r) => r.body), contains('Winterruhe beenden? Das geplante Ende ist erreicht.'));
    repo.endWinter(c);
    expect(repo.colony(c)!.status, 'active');
    expect(repo.winterRest(c), isNull);
    expect(repo.events(c, types: {'winter_end'}), hasLength(1));
    expect(repo.reminders().where((r) => r.payload['kind'] == 'winter'), isEmpty);
  });

  test('winter plan can be changed and deleted before it starts', () {
    final c = repo.createColony({'name': 'Messor', 'species_text': 'Messor barbarus'});
    repo.planWinter(c, start: DateTime(2026, 11, 1));
    repo.planWinter(c, start: DateTime(2026, 11, 15), end: DateTime(2027, 2, 1));
    final w = repo.winterRest(c)!;
    expect((w.plannedStartOn, w.plannedEndOn), (DateTime(2026, 11, 15), DateTime(2027, 2, 1)));
    repo.cancelWinterPlan(c);
    expect(repo.winterRest(c), isNull);
    // Without a plan the switch starts right away.
    repo.startWinter(c);
    expect(repo.winterRest(c)!.startedOn, DateTime(2026, 9, 20));
    repo.cancelWinterPlan(c);
    expect(repo.winterRest(c), isNotNull, reason: 'a running winter rest is ended, not deleted');
  });

  test('entries logged afterwards count at their own time', () {
    final c = repo.createColony({'name': 'Messor', 'species_text': 'Messor barbarus'}, intervals: {'water': 3});
    now = DateTime.utc(2026, 9, 25, 10);
    expect(repo.due(c).single.days, lessThan(0), reason: 'water overdue');
    // Forgot to log yesterday's water → due again in 2 days, not 3.
    repo.logEvent(c, 'water', at: DateTime.utc(2026, 9, 24, 18));
    expect(repo.due(c).single.nextDue!.toUtc(), DateTime.utc(2026, 9, 27, 18));
    // A later entry logged afterwards sorts in, but does not push the due date back.
    repo.logEvent(
      c,
      'water',
      at: DateTime.utc(2026, 9, 22, 8),
      details: {
        'water': {
          'kinds': ['drinker_refilled'],
        },
      },
    );
    expect(repo.due(c).single.nextDue!.toUtc(), DateTime.utc(2026, 9, 27, 18));
    expect(repo.events(c, types: {'water'}).map((e) => e.occurredAt.toUtc().day), [24, 22]);
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

  test('automations: sensor limit problems (24 h) and silent sensors are reported', () {
    final c = repo.createColony({'name': 'Kolonie 12', 'species_text': 'Messor barbarus'});
    db.putRecord('colony_events', {
      'id': 'e1',
      'colony_id': c,
      'type': 'problem',
      'occurred_at': now.subtract(const Duration(hours: 2)).toUtc().toIso8601String(),
      'note': 'Sensor „Regal A“: Temperatur 31,5 °C – über dem Grenzwert 28,0 °C.',
      'payload': {'source': 'sensor', 'metric': 'temperature'},
    });
    db.putRecord('colony_events', {
      'id': 'e2',
      'colony_id': c,
      'type': 'problem',
      'occurred_at': now.subtract(const Duration(days: 2)).toUtc().toIso8601String(),
      'note': 'alt',
      'payload': {'source': 'sensor'},
    });
    repo.logEvent(c, 'problem', note: 'selbst eingetragen – keine Benachrichtigung');
    db.putRecord('sensors', {
      'id': 's1',
      'name': 'Regal A',
      'active': true,
      'last_seen_at': now.subtract(const Duration(hours: 7)).toUtc().toIso8601String(),
    });
    db.putRecord('sensors', {'id': 's2', 'name': 'Neu', 'active': true}); // never sent anything yet
    final r = repo.reminders();
    expect(r.map((x) => x.body), [
      'Sensor „Regal A“: Temperatur 31,5 °C – über dem Grenzwert 28,0 °C.',
      'Sendet seit 7 Stunden keine Daten – Stromversorgung oder WLAN prüfen.',
    ]);
    expect(r.first.title, '⚠ Messor barbarus – Kolonie 12');
    expect(handleReminder(repo, payload: r.last.payloadJson), '/settings/sensors');
    expect(handleReminder(repo, payload: r.first.payloadJson), '/colonies/$c');
  });
}
