import 'package:ant_colony_manager/core/api_client.dart';
import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/data/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late AppDatabase db;
  late FakeServer server;
  late SyncEngine engine;
  late ColonyRepository repo;
  const user = 'user-1';

  setUp(() {
    db = memoryDb();
    server = FakeServer();
    final api = ApiClient(baseUrl: 'https://ants.test', tokens: MemoryTokens(), isWeb: false, client: server.client)
      ..setAccessToken('a1');
    engine = SyncEngine(
      db: db,
      api: api,
      userId: user,
      device: const DeviceIdentity(id: 'dev-1', name: 'Test', platform: 'android', appVersion: 'test'),
    );
    repo = ColonyRepository(db, userId: user, onChanged: () {});
  });

  tearDown(() => db.dispose());

  test('offline feeding reaches the server exactly once – even when a response is lost', () async {
    final colony = repo.createColony({'name': 'Messor #12', 'species_text': 'Messor barbarus'});
    await engine.sync();
    expect(server.count('colonies'), 1);

    // In the cellar without network: feed.
    server.online = false;
    final ev = repo.repeatLastFeeding(colony) ??
        repo.logEvent(colony, 'feeding', details: {
          'feeding': {
            'items': [
              {'food_name': 'Schabe', 'category': 'protein', 'quantity': 2},
            ],
          },
        });
    await engine.sync();
    expect(engine.current.phase, SyncPhase.offline);
    expect(db.pendingOpCount(), 1, reason: 'kept in the outbox');
    expect(db.record('colony_events', ev.id)!.pending, isTrue);

    // Network is back, but the first answer gets lost after the server applied it.
    server.online = true;
    server.dropNextResponse = true;
    await engine.sync(resetBackoff: true);
    expect(engine.current.phase, SyncPhase.offline);
    expect(server.count('colony_events'), 1);

    // Retry: same op_id → duplicate, still exactly one feeding.
    await engine.sync(resetBackoff: true);
    expect(engine.current.phase, SyncPhase.idle);
    expect(server.count('colony_events'), 1);
    expect(db.pendingOpCount(), 0);
    expect(db.record('colony_events', ev.id)!.pending, isFalse);
  });

  test('pull applies remote changes and deletions', () async {
    server.put('colonies', {'id': 'c1', 'name': 'Remote', 'number': 1, 'status': 'active'});
    server.put('colony_events', {'id': 'e1', 'colony_id': 'c1', 'type': 'note', 'occurred_at': '2026-09-26T10:00:00Z', 'note': 'x'});
    await engine.sync(); // first sync = snapshot
    expect(repo.colony('c1')!.name, 'Remote');
    expect(repo.events('c1'), hasLength(1));

    server.put('colonies', {'id': 'c1', 'name': 'Umbenannt', 'number': 1, 'status': 'active'});
    server.put('colony_events', server.rows['colony_events']!['e1']!, deleted: true);
    await engine.sync();
    expect(repo.colony('c1')!.name, 'Umbenannt');
    expect(repo.events('c1'), isEmpty);
  });

  test('local unsent edits are not overwritten by a pull', () async {
    server.put('colonies', {'id': 'c1', 'name': 'A', 'number': 1, 'status': 'active'});
    await engine.sync();
    server.online = false;
    repo.updateColony('c1', {'notes': 'lokal'});
    server.online = true;
    server.put('colonies', {'id': 'c1', 'name': 'B', 'number': 1, 'status': 'active'});
    // Pull would bring "B" – but the local edit must survive until pushed.
    await engine.sync(resetBackoff: true);
    expect(server.rows['colonies']!['c1']!['notes'], 'lokal');
  });

  test('cursor older than the horizon triggers a full snapshot', () async {
    server.put('colonies', {'id': 'c1', 'name': 'A', 'number': 1, 'status': 'active'});
    await engine.sync();
    server.rows.clear();
    server.log.clear();
    server.put('colonies', {'id': 'c2', 'name': 'Nach Restore', 'number': 1, 'status': 'active'});
    server.horizon = 1000;
    await engine.sync();
    expect(repo.colony('c1'), isNull);
    expect(repo.colony('c2')!.name, 'Nach Restore');
  });

  test('losing access removes the shared colony locally', () async {
    server.put('colonies', {'id': 'c9', 'name': 'Geteilt', 'number': 1, 'status': 'active'});
    server.put('colony_members', {'id': 'm1', 'colony_id': 'c9', 'user_id': user, 'role': 'editor'});
    await engine.sync();
    expect(repo.colony('c9'), isNotNull);
    expect(repo.roleOn('c9'), 'editor');
    server.put('colony_members', server.rows['colony_members']!['m1']!, deleted: true);
    await engine.sync();
    expect(repo.colony('c9'), isNull);
  });

  test('rejected create is removed locally and reported', () async {
    server.rejectEntities.add('locations');
    final id = repo.createLocation('Regal A');
    await engine.sync();
    expect(db.record('locations', id), isNull);
    expect(db.failedOps(), hasLength(1));
    expect(engine.current.failed, 1);
  });
}
