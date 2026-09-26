// End-to-end contract test: the app's real sync engine against the real Go
// server. Runs only when ACM_TEST_SERVER is set (the "Contract" CI job starts
// PostgreSQL + server); skipped in normal `flutter test` runs.
import 'dart:io';

import 'package:ant_colony_manager/core/api_client.dart';
import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/data/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

final server = Platform.environment['ACM_TEST_SERVER'];
final setupToken = Platform.environment['ACM_TEST_SETUP_TOKEN'] ?? '';

class Device {
  Device(this.name, this.api, this.userId) : db = memoryDb() {
    engine = SyncEngine(
      db: db,
      api: api,
      userId: userId,
      device: DeviceIdentity(id: newId(), name: name, platform: 'android', appVersion: 'contract-test'),
    );
    repo = ColonyRepository(db, userId: userId, onChanged: () {});
  }
  final String name;
  final ApiClient api;
  final String userId;
  final AppDatabase db;
  late final SyncEngine engine;
  late final ColonyRepository repo;

  Future<void> sync() async {
    await engine.sync(resetBackoff: true);
    expect(engine.current.phase, SyncPhase.idle, reason: '$name: ${engine.current.message}');
    expect(db.failedOps(), isEmpty, reason: '$name: ${db.failedOps().map((o) => o.lastError)}');
  }
}

void main() {
  late ApiClient api;
  late String userId;

  setUpAll(() async {
    if (server == null) return;
    api = ApiClient(baseUrl: server!, tokens: MemoryTokens(), isWeb: false);
    final inst = await api.public('GET', '/api/v1/instance') as Map<String, dynamic>;
    final Map<String, dynamic> session;
    if (inst['setup_required'] == true) {
      session =
          await api.public('POST', '/api/v1/setup', {
                'email': 'contract@ants.test',
                'password': 'Contract-Test-2026',
                'setup_token': setupToken,
                'display_name': 'Contract',
              })
              as Map<String, dynamic>;
    } else {
      session =
          await api.public('POST', '/api/v1/auth/login', {
                'email': 'contract@ants.test',
                'password': 'Contract-Test-2026',
              })
              as Map<String, dynamic>;
    }
    await api.adopt(session);
    userId = (session['user'] as Map<String, dynamic>)['id'] as String;
  });

  test(
    'two devices stay in sync through the real server',
    () async {
      final phone = Device('phone', api, userId);
      final tablet = Device('tablet', api, userId);
      await phone.sync();

      // Phone, offline: new colony with schedules + QR, then a feeding.
      final colony = phone.repo.createColony(
        {'name': 'Messor #1', 'species_text': 'Messor barbarus'},
        intervals: {'protein': 3, 'water': 2},
      );
      final feeding = phone.repo.logEvent(
        colony,
        'feeding',
        details: {
          'feeding': {
            'items': [
              {'food_name': 'Schabe', 'category': 'protein', 'quantity': 2, 'unit': 'piece', 'size': 'small'},
              {'food_name': 'Zuckerwasser', 'category': 'carbohydrate'},
            ],
          },
        },
      );
      phone.repo.logEvent(
        colony,
        'water',
        details: {
          'water': {
            'kinds': ['drinker_refilled'],
          },
        },
        note: 'Kontrolle ok',
      );
      await phone.sync();
      expect(phone.db.pendingOpCount(), 0);

      // The server really has it – via the REST overview the web uses.
      final ov = await api.get('/api/v1/colonies/$colony') as Map<String, dynamic>;
      expect((ov['colony'] as Map)['name'], 'Messor #1');
      expect((ov['scan_links'] as List).single['kind'], 'qr');
      expect((ov['due'] as List).map((d) => d['task_type']), containsAll(['protein', 'water']));
      final lastFeeding = ov['last_feeding'] as Map<String, dynamic>;
      expect((lastFeeding['feeding'] as Map)['items'], hasLength(2));

      // Tablet: first sync is a snapshot; QR resolves offline afterwards.
      await tablet.sync();
      expect(tablet.repo.colony(colony)!.species, 'Messor barbarus');
      expect(tablet.repo.events(colony), hasLength(2));
      final token = tablet.repo.scanLinks(colony).single.token;
      expect((tablet.repo.resolveToken(token) as ScanFound).colonyId, colony);
      expect(tablet.repo.roleOn(colony), 'owner');
      expect(tablet.repo.due(colony).map((t) => t.schedule.taskType), containsAll(['protein', 'water']));

      // Acceptance entered later on the tablet reaches the phone.
      tablet.repo.setAcceptance(feeding.id, 'accepted');
      await tablet.sync();
      await phone.sync();
      expect(phone.repo.events(colony, types: {'feeding'}).single.acceptance, 'accepted');
      expect(phone.repo.events(colony, types: {'feeding'}).single.items, hasLength(2));

      // Exactly once: the same ops sent twice (lost response) → one record.
      final again = phone.repo.logEvent(colony, 'check');
      final ops = phone.db.takeOps(100);
      final body = {
        'device_id': phone.engine.device.id,
        'platform': 'android',
        'ops': ops.map((o) => o.toWire()).toList(),
      };
      final first = await api.post('/api/v1/sync/push', body) as Map<String, dynamic>;
      final second = await api.post('/api/v1/sync/push', body) as Map<String, dynamic>;
      expect((first['results'] as List).single['status'], 'applied');
      expect((second['results'] as List).single['status'], 'duplicate');
      phone.db.retryLater(ops.map((o) => o.seq).toList(), 'simulated');
      await phone.sync(); // third time through the engine – still one
      final timeline = await api.get('/api/v1/colonies/$colony/timeline', query: {'types': 'check'}) as Map;
      expect((timeline['events'] as List).where((e) => e['id'] == again.id), hasLength(1));

      // Deleting on one device removes it on the other.
      tablet.repo.deleteEvent(feeding.id);
      await tablet.sync();
      await phone.sync();
      expect(phone.repo.events(colony, types: {'feeding'}), isEmpty);

      // Colony edits merge field-wise.
      phone.repo.updateColony(colony, {'notes': 'vom Handy'});
      tablet.repo.updateColony(colony, {'status': 'founding'});
      await phone.sync();
      await tablet.sync();
      await phone.sync();
      expect(phone.repo.colony(colony)!.notes, 'vom Handy');
      expect(phone.repo.colony(colony)!.status, 'founding');
      expect(tablet.repo.colony(colony)!.notes, 'vom Handy');
    },
    skip: server == null ? 'set ACM_TEST_SERVER to run against a real server' : false,
  );
}
