import 'package:ant_colony_manager/core/session.dart';
import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/domain/due.dart';
import 'package:ant_colony_manager/features/colonies/colony_list_screen.dart';
import 'package:ant_colony_manager/features/scan/scan_screens.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late AppDatabase db;
  late ColonyRepository repo;
  var now = DateTime.utc(2026, 9, 26, 12);

  setUp(() {
    db = memoryDb();
    now = DateTime.utc(2026, 9, 26, 12);
    repo = ColonyRepository(db, userId: 'u1', onChanged: () {}, clock: () => now);
  });
  tearDown(() => db.dispose());

  test('creating a colony works offline and brings schedules and a QR code', () {
    final id = repo.createColony(
      {'name': 'Messor #1', 'species_text': 'Messor barbarus'},
      intervals: {'protein': 3, 'water': 2},
    );
    final c = repo.colony(id)!;
    expect(c.number, 1);
    expect(repo.schedules(colonyId: id), hasLength(2));
    final links = repo.scanLinks(id);
    expect(links, hasLength(1));
    expect(RegExp(r'^[0-9A-Za-z]{16}$').hasMatch(links.first.token), isTrue);
    expect(db.pendingOpCount(), 4); // colony + 2 schedules + scan link

    // QR → right colony, offline.
    expect((repo.resolveToken(links.first.token) as ScanFound).colonyId, id);
    expect(repo.resolveToken('0000000000000000'), isA<ScanUnknown>());
    expect(repo.createColony({'name': 'B', 'species_text': 'Lasius niger'}), isNot(id));
    expect(repo.colonies().map((c) => c.number), [1, 2]);
  });

  test('deactivated code is recognised', () {
    final id = repo.createColony({'name': 'A', 'species_text': 'x'});
    final link = repo.scanLinks(id).first;
    db.putRecord('scan_links', {...link.json, 'active': false});
    expect(repo.resolveToken(link.token), isA<ScanRevoked>());
  });

  test('repeat last feeding copies items and resets acceptance', () {
    final id = repo.createColony({'name': 'A', 'species_text': 'x'});
    expect(repo.repeatLastFeeding(id), isNull);
    repo.logEvent(
      id,
      'feeding',
      details: {
        'feeding': {
          'acceptance': 'accepted',
          'items': [
            {'food_name': 'Schabe', 'category': 'protein', 'quantity': 2, 'unit': 'piece', 'size': 'small'},
            {'food_name': 'Zuckerwasser', 'category': 'carbohydrate'},
          ],
        },
      },
    );
    expect(repo.fedJustNow(id), isTrue);
    now = now.add(const Duration(hours: 3));
    expect(repo.fedJustNow(id), isFalse);
    final e = repo.repeatLastFeeding(id)!;
    expect(e.acceptance, 'unknown');
    expect(e.items.map((i) => i.foodName), ['Schabe', 'Zuckerwasser']);
    expect(repo.events(id, types: {'feeding'}), hasLength(2));
  });

  test('due dates follow protein feedings (JSON query in SQLite)', () {
    final id = repo.createColony({'name': 'A', 'species_text': 'x'});
    final s = repo.schedules(colonyId: id);
    expect(s, isEmpty);
    repo.setIntervals(id, {'protein': 3, 'carbohydrate': 5});
    // make both schedules start long ago
    for (final r in db.records('care_schedules')) {
      db.putRecord('care_schedules', {...r.json, 'starts_at': '2026-09-01T00:00:00Z'}, pending: true);
    }
    repo.logEvent(
      id,
      'feeding',
      at: now.subtract(const Duration(days: 5)),
      details: {
        'feeding': {
          'items': [
            {'food_name': 'Schabe', 'category': 'protein'},
          ],
        },
      },
    );
    final due = {for (final t in repo.due(id)) t.schedule.taskType: t};
    expect(due['protein']!.days, -2);
    expect(due['protein']!.status, DueStatus.overdue);
    // carbohydrate was never fed: start 1.9. + 5 days → long overdue
    expect(due['carbohydrate']!.status, DueStatus.overdue);
  });

  test('acceptance is sent with the complete feeding details', () {
    final id = repo.createColony({'name': 'A', 'species_text': 'x'});
    final e = repo.logEvent(
      id,
      'feeding',
      details: {
        'feeding': {
          'items': [
            {'food_name': 'Heimchen', 'category': 'protein'},
          ],
        },
      },
    );
    repo.setAcceptance(e.id, 'accepted');
    final op = db.select("SELECT payload FROM outbox WHERE entity = 'colony_events'").single['payload'] as String;
    // merged into the unsent create
    expect(op, contains('"acceptance":"accepted"'));
    expect(op, contains('Heimchen'));
  });

  test('outbox: unsent edits are merged, unsent creates dropped on delete', () {
    final id = repo.createColony({'name': 'A', 'species_text': 'x'});
    final ops = db.pendingOpCount();
    repo.updateColony(id, {'notes': 'eins'});
    repo.updateColony(id, {'status': 'founding'});
    expect(db.pendingOpCount(), ops, reason: 'merged into the create');
    final taken = db.takeOps(100);
    // while in flight, new edits get their own op
    repo.updateColony(id, {'notes': 'zwei'});
    expect(db.pendingOpCount(), ops + 1);
    db.retryLater(taken.map((o) => o.seq).toList(), 'offline');
    expect(db.takeOps(100).where((o) => o.op == 'create'), isEmpty, reason: 'backoff');
    db.resetBackoff();
    // location that never reached the server: delete drops everything
    final loc = repo.createLocation('Regal');
    final before = db.pendingOpCount();
    repo.db.queueDelete('x', 'locations', loc);
    expect(db.pendingOpCount(), before - 1);
  });

  test('colony list filter and search', () {
    final a = repo.createColony({'name': 'Messor #1', 'species_text': 'Messor barbarus'});
    repo.createColony({'name': 'Lasius #2', 'species_text': 'Lasius niger', 'status': 'founding'});
    final all = repo.colonies();
    expect(filterColonies(all, const {}, 'messor', {}).single.id, a);
    expect(filterColonies(all, const {}, '#2', {}).single.name, 'Lasius #2');
    expect(filterColonies(all, const {}, '', {ColonyFilter.founding}).single.name, 'Lasius #2');
  });

  test('scan input and server address parsing', () {
    expect(parseScanInput('https://ants.example.com/c/7Kq2mZr9XbT4pLwA'), '7Kq2mZr9XbT4pLwA');
    expect(parseScanInput(' 7Kq2mZr9XbT4pLwA '), '7Kq2mZr9XbT4pLwA');
    expect(parseScanInput('https://example.com/other'), isNull);
    expect(normalizeServerUrl('192.168.1.50:8080'), 'http://192.168.1.50:8080');
    expect(normalizeServerUrl('ants.example.com/'), 'https://ants.example.com');
    expect(normalizeServerUrl('https://ants.example.com/link#code=abc'), 'https://ants.example.com');
  });
}
