import 'package:ant_colony_manager/core/api_client.dart';
import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/data/sync/sync_engine.dart';
import 'package:ant_colony_manager/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late AppDatabase db;
  late ColonyRepository repo;
  var now = DateTime.utc(2026, 9, 26, 8);

  setUp(() {
    db = memoryDb();
    now = DateTime.utc(2026, 9, 26, 8);
    repo = ColonyRepository(db, userId: 'u1', onChanged: () {}, clock: () => now);
  });
  tearDown(() => db.dispose());

  /// Three colonies on two shelves; two of them need water after three days.
  (String, String, String) shelf() {
    final regalA = repo.createLocation('Regal A');
    final regalB = repo.createLocation('Regal B');
    final a1 = repo.createColony(
      {'name': 'Messor', 'species_text': 'x', 'location_id': regalA},
      intervals: {'water': 2},
    );
    final a2 = repo.createColony(
      {'name': 'Lasius', 'species_text': 'x', 'location_id': regalA},
      intervals: {'water': 7},
    );
    final b1 = repo.createColony(
      {'name': 'Camponotus', 'species_text': 'x', 'location_id': regalB},
      intervals: {'water': 2},
    );
    now = now.add(const Duration(days: 3));
    return (a1, a2, b1);
  }

  test('candidates: with tasks, all active, by location', () {
    final (a1, a2, b1) = shelf();
    expect(repo.roundCandidates(RoundScope.withTasks).map((c) => c.id), unorderedEquals([a1, b1]));
    expect(repo.roundCandidates(RoundScope.allActive), hasLength(3));
    final regalA = repo.locations().firstWhere((l) => l.name == 'Regal A').id;
    expect(repo.roundCandidates(RoundScope.location, locationId: regalA).map((c) => c.id), unorderedEquals([a1, a2]));
  });

  test('a round: scan, document, rescan, extra colony, summary', () {
    final (a1, a2, b1) = shelf();
    final round = repo.startRound([a1, b1]);
    expect(repo.activeRound()!.id, round);
    expect(repo.roundProgress(round)!.total, 2);

    // Scan → counts as checked, without an event.
    expect(repo.visit(round, a1), VisitResult.first);
    expect(repo.events(a1), isEmpty);
    // Actions carry the round and are shown as done.
    final water = repo.logEvent(
      a1,
      'water',
      details: {
        'water': {
          'kinds': ['drinker_refilled'],
        },
      },
    );
    expect(water.json['care_round_id'], round);
    repo.logEvent(
      a1,
      'feeding',
      details: {
        'feeding': {
          'items': [
            {'food_name': 'Schabe', 'category': 'protein'},
          ],
        },
      },
    );
    expect(repo.doneInRound(round, a1), {'water', 'feeding'});
    expect(repo.visit(round, a1), VisitResult.again);

    // A colony outside the plan is added.
    expect(repo.visit(round, a2), VisitResult.added);
    repo.logEvent(
      a2,
      'water',
      details: {
        'water': {
          'kinds': ['drinker_refilled'],
        },
      },
    );
    final p = repo.roundProgress(round)!;
    expect(p.visited, 2);
    expect(p.total, 3);
    expect(p.open.map((s) => s.$2.id), [b1]);

    now = now.add(const Duration(minutes: 23));
    repo.endRound(round);
    expect(repo.activeRound(), isNull);
    // Documented after the round → not part of it.
    expect(repo.logEvent(b1, 'water').json['care_round_id'], isNull);

    final s = repo.roundSummary(round)!;
    expect((s.visited, s.total), (2, 3));
    expect(s.colonies, {'water': 2, 'feeding': 1});
    expect(s.missing.map((c) => c.id), [b1]);
    expect(s.duration, const Duration(minutes: 23));

    repo.skipUnvisited(round);
    final after = repo.roundSummary(round)!;
    expect(after.missing, isEmpty);
    expect(after.skipped.map((c) => c.id), [b1]);
  });

  test('stops are sorted by location (walking order)', () {
    final (a1, a2, b1) = shelf();
    final round = repo.startRound([b1, a2, a1]);
    expect(repo.roundProgress(round)!.stops.map((s) => s.$2.id), [a1, a2, b1]);
  });

  test('a round left alone for more than 12 hours ends by itself', () {
    final (a1, _, b1) = shelf();
    final round = repo.startRound([a1, b1]);
    now = now.add(const Duration(hours: 2));
    repo.visit(round, a1);
    now = now.add(const Duration(hours: 11));
    expect(repo.activeRound()?.id, round, reason: '11 h after the last scan it is still running');
    now = now.add(const Duration(hours: 2));
    expect(repo.activeRound(), isNull);
    repo.closeStaleRounds();
    final r = CareRound(db.record('care_rounds', round)!.json);
    expect(r.endedAt, DateTime.utc(2026, 9, 29, 10), reason: 'ended at the last activity');
    expect(repo.roundSummary(round)!.visited, 1);
  });

  test('starting a new round ends the old one', () {
    final (a1, _, b1) = shelf();
    final first = repo.startRound([a1]);
    final second = repo.startRound([b1]);
    expect(repo.activeRound()!.id, second);
    expect(CareRound(db.record('care_rounds', first)!.json).open, isFalse);
  });

  test('a round recorded offline reaches the second device with its summary', () async {
    final server = FakeServer();
    SyncEngine engine(AppDatabase d, String name) => SyncEngine(
      db: d,
      api: ApiClient(baseUrl: 'https://ants.test', tokens: MemoryTokens(), isWeb: false, client: server.client)
        ..setAccessToken('a1'),
      userId: 'u1',
      device: DeviceIdentity(id: 'dev-$name', name: name, platform: 'android', appVersion: 'test'),
    );
    final phone = engine(db, 'phone');
    final (a1, _, b1) = shelf();
    server.online = false;
    final round = repo.startRound([a1, b1]);
    repo.visit(round, a1);
    repo.logEvent(
      a1,
      'water',
      details: {
        'water': {
          'kinds': ['drinker_refilled'],
        },
      },
    );
    repo.endRound(round);
    server.online = true;
    await phone.sync(resetBackoff: true);
    expect(db.pendingOpCount(), 0);

    final webDb = memoryDb();
    final web = ColonyRepository(webDb, userId: 'u1', onChanged: () {}, clock: () => now);
    await engine(webDb, 'web').sync();
    final s = web.roundSummary(round)!;
    expect((s.visited, s.total), (1, 2));
    expect(s.colonies, {'water': 1});
    expect(s.missing.map((c) => c.id), [b1]);
    webDb.dispose();
  });
}
