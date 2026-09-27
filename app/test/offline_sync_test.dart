import 'dart:math';

import 'package:ant_colony_manager/core/api_client.dart';
import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/data/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

class _Device {
  _Device(this.name, FakeServer server, String userId) : db = memoryDb() {
    final api = ApiClient(baseUrl: 'https://ants.test', tokens: MemoryTokens(), isWeb: false, client: server.client)
      ..setAccessToken('a1');
    engine = SyncEngine(
      db: db,
      api: api,
      userId: userId,
      device: DeviceIdentity(id: 'dev-$name', name: name, platform: 'android', appVersion: 'test'),
    );
    repo = ColonyRepository(db, userId: userId, onChanged: () {});
  }
  final String name;
  final AppDatabase db;
  late final SyncEngine engine;
  late final ColonyRepository repo;

  Set<String> ids(String entity) => db.records(entity, orderBy: 'id').map((r) => r.id).toSet();
}

void main() {
  const user = 'user-1';

  for (final seed in [20260927, 1, 2, 3, 4]) {
    test('chaos (seed $seed): two devices, random network failures – both converge, nothing duplicated', () async {
      await _chaos(seed);
    });
  }

  test('edit after a lost response is sent separately and not swallowed as duplicate', () async {
    final server = FakeServer();
    final a = _Device('A', server, user);
    final c = a.repo.createColony({'name': 'A', 'species_text': 'x'});
    await a.engine.sync();
    final e = a.repo.logEvent(
      c,
      'feeding',
      details: {
        'feeding': {
          'items': [
            {'food_name': 'Schabe', 'category': 'protein'},
          ],
        },
      },
    );
    server.dropNextResponse = true; // server stores the feeding, the answer is lost
    await a.engine.sync();
    a.repo.setAcceptance(e.id, 'accepted'); // must not be merged into the already sent create
    expect(a.db.pendingOpCount(), 2);
    await a.engine.sync(resetBackoff: true);
    expect(server.rows['colony_events']![e.id]!['feeding']['acceptance'], 'accepted');
    expect(server.createCount[e.id], 1);
  });

  test('device signed out elsewhere: engine reports it, local data can be wiped', () async {
    final server = FakeServer();
    final a = _Device('A', server, user);
    a.repo.createColony({'name': 'A', 'species_text': 'x'});
    await a.engine.sync();
    server.deviceRevoked = true;
    a.repo.logEvent(a.repo.colonies().first.id, 'note', note: 'nach dem Abmelden');
    await a.engine.sync();
    expect(a.engine.current.phase, SyncPhase.deviceRevoked);
  });

  test('deleting a colony elsewhere removes its events and schedules locally', () async {
    final server = FakeServer();
    final a = _Device('A', server, user), b = _Device('B', server, user);
    final c = a.repo.createColony({'name': 'Weg', 'species_text': 'x'}, intervals: {'water': 2});
    a.repo.logEvent(c, 'note', note: 'hallo');
    await a.engine.sync();
    await b.engine.sync();
    expect(b.repo.events(c), hasLength(1));
    a.repo.deleteColony(c);
    await a.engine.sync();
    await b.engine.sync();
    expect(b.repo.colony(c), isNull);
    expect(b.db.records('colony_events', colonyId: c), isEmpty);
    expect(b.db.records('care_schedules', colonyId: c), isEmpty);
  });

  test('restore on the server (cursor below horizon): unsent entries survive the resync', () async {
    final server = FakeServer();
    final a = _Device('A', server, user);
    final c = a.repo.createColony({'name': 'A', 'species_text': 'x'});
    await a.engine.sync();
    server.online = false;
    final e = a.repo.logEvent(c, 'note', note: 'offline nach dem Backup');
    server.online = true;
    server.horizon = 1 << 30; // server restored from a backup
    await a.engine.sync(resetBackoff: true);
    expect(a.engine.current.phase, SyncPhase.idle);
    expect(server.rows['colony_events']![e.id], isNotNull, reason: 'pushed before the snapshot');
    expect(a.repo.events(c).map((x) => x.id), contains(e.id));
  });
}

/// Two devices, 400 random actions, 25 % of requests fail, 20 % of responses get
/// lost after the server applied them. Afterwards both devices must equal the
/// server and every record must have been created exactly once.
Future<void> _chaos(int seed) async {
  const user = 'user-1';
  final server = FakeServer();
  final a = _Device('A', server, user), b = _Device('B', server, user);
  final rand = Random(seed);

  a.repo.createColony({'name': 'Messor #1', 'species_text': 'Messor barbarus'}, intervals: {'water': 2});
  await a.engine.sync();
  server
    ..chaos = Random(seed * 31 + 7)
    ..failBefore = .25
    ..failAfter = .2;

  for (var step = 0; step < 400; step++) {
    final d = rand.nextBool() ? a : b;
    final colonies = d.repo.colonies();
    final roll = rand.nextInt(100);
    if (colonies.isEmpty || roll >= 70) {
      await d.engine.sync(resetBackoff: rand.nextBool());
      continue;
    }
    final c = colonies[rand.nextInt(colonies.length)];
    final events = d.repo.events(c.id);
    if (roll < 30) {
      d.repo.logEvent(
        c.id,
        'feeding',
        details: {
          'feeding': {
            'items': [
              {'food_name': 'Schabe', 'category': 'protein', 'quantity': 1 + rand.nextInt(3)},
            ],
          },
        },
      );
    } else if (roll < 40) {
      d.repo.logEvent(
        c.id,
        'water',
        details: {
          'water': {
            'kinds': ['drinker_refilled'],
          },
        },
      );
    } else if (roll < 47) {
      d.repo.logEvent(c.id, 'note', note: 'Notiz ${d.name}$step');
    } else if (roll < 55) {
      d.repo.updateColony(c.id, {'notes': 'geändert von ${d.name} in Schritt $step'});
    } else if (roll < 60 && events.isNotEmpty) {
      d.repo.deleteEvent(events[rand.nextInt(events.length)].id);
    } else if (roll < 65 && events.any((e) => e.type == 'feeding')) {
      final f = events.firstWhere((e) => e.type == 'feeding');
      d.repo.setAcceptance(f.id, ['accepted', 'partial', 'ignored'][rand.nextInt(3)]);
    } else if (roll < 67) {
      d.repo.createColony({'name': 'Neu ${d.name}$step', 'species_text': 'Lasius niger'});
    } else {
      await d.engine.sync();
    }
  }

  // Network is stable again: a few rounds bring everybody up to date.
  server
    ..failBefore = 0
    ..failAfter = 0;
  for (var i = 0; i < 3; i++) {
    await a.engine.sync(resetBackoff: true);
    await b.engine.sync(resetBackoff: true);
  }

  for (final d in [a, b]) {
    expect(d.db.pendingOpCount(), 0, reason: '${d.name}: outbox must be empty');
    for (final op in d.db.failedOps()) {
      // the only acceptable rejection: editing something the other device deleted
      expect(op.lastError, 'deleted', reason: '${d.name}: ${op.entity} ${op.op}');
    }
  }

  for (final entity in ['colonies', 'colony_events', 'care_schedules', 'scan_links']) {
    final onServer = {
      for (final r in (server.rows[entity] ?? const {}).values)
        if (r['deleted_at'] == null) r['id'] as String,
    };
    expect(a.ids(entity), onServer, reason: 'A $entity');
    expect(b.ids(entity), onServer, reason: 'B $entity');
  }
  // Field values converge too (last writer wins).
  for (final c in server.rows['colonies']!.values) {
    expect(a.repo.colony(c['id'] as String)!.notes, c['notes'], reason: 'A notes');
    expect(b.repo.colony(c['id'] as String)!.notes, c['notes'], reason: 'B notes');
  }
  for (final e in server.rows['colony_events']!.values.where((e) => e['deleted_at'] == null)) {
    final la = a.db.record('colony_events', e['id'] as String)!.json;
    final lb = b.db.record('colony_events', e['id'] as String)!.json;
    expect(la['feeding']?['acceptance'], e['feeding']?['acceptance']);
    expect(lb['feeding']?['acceptance'], e['feeding']?['acceptance']);
  }
  // Exactly once: every record was created a single time on the server,
  // although many pushes were repeated after lost responses.
  expect(server.createCount.values.where((n) => n != 1), isEmpty);
  expect(server.createCount.length, greaterThan(100), reason: 'the scenario must actually do something');
}
