// End-to-end contract test: the app's real sync engine against the real Go
// server. Runs only when ACM_TEST_SERVER is set (the "Contract" CI job starts
// PostgreSQL + server); skipped in normal `flutter test` runs.
import 'dart:convert';
import 'dart:io';

import 'package:ant_colony_manager/core/api_client.dart';
import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/data/sync/sync_engine.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

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

      // Same field on both devices: they agree afterwards, the loser is logged.
      phone.repo.updateColony(colony, {'name': 'Vom Handy'});
      tablet.repo.updateColony(colony, {'name': 'Vom Tablet'});
      await phone.sync();
      await tablet.sync();
      await phone.sync();
      expect(phone.repo.colony(colony)!.name, tablet.repo.colony(colony)!.name);
      final conflicts = await api.get('/api/v1/sync/conflicts') as Map<String, dynamic>;
      expect((conflicts['conflicts'] as List).where((c) => c['field'] == 'name'), isNotEmpty);
    },
    skip: server == null ? 'set ACM_TEST_SERVER to run against a real server' : false,
  );

  test(
    'a device signed out in the web app is told to wipe its data',
    () async {
      final deviceId = newId();
      final phoneApi = ApiClient(baseUrl: server!, tokens: MemoryTokens(), isWeb: false);
      final session =
          await phoneApi.public('POST', '/api/v1/auth/login', {
                'email': 'contract@ants.test',
                'password': 'Contract-Test-2026',
                'device': {'device_id': deviceId, 'device_name': 'Pixel', 'platform': 'android'},
              })
              as Map<String, dynamic>;
      await phoneApi.adopt(session);
      final phone = Device('revoked-phone', phoneApi, userId);
      await phone.sync();

      final sessions = (await api.get('/api/v1/auth/sessions') as Map<String, dynamic>)['sessions'] as List;
      final mine = sessions.firstWhere((s) => s['device_id'] == deviceId);
      await api.delete('/api/v1/auth/sessions/${mine['id']}');

      phoneApi.setAccessToken(null);
      phone.repo.createColony({'name': 'Nach Abmeldung', 'species_text': 'x'});
      await phone.engine.sync();
      expect(phone.engine.current.phase, SyncPhase.deviceRevoked);
    },
    skip: server == null ? 'set ACM_TEST_SERVER to run against a real server' : false,
  );

  test(
    'photo taken offline is uploaded and visible on the second device',
    () async {
      final phone = Device('photo-phone', api, userId);
      final tablet = Device('photo-tablet', api, userId);
      await phone.sync();
      final colony = phone.repo.createColony({'name': 'Foto-Kolonie', 'species_text': 'Lasius niger'});
      final png = base64Decode(_tinyPng);
      final photo = phone.repo.addPhoto(colony, png, thumb: png, caption: 'erste Larven');
      expect(phone.db.pendingUploadCount(), 1);

      await phone.sync();
      expect(phone.db.pendingUploadCount(), 0, reason: 'uploaded after the metadata was pushed');
      expect(phone.repo.photos(colony).single.stored, isTrue);

      await tablet.sync();
      final seen = tablet.repo.photos(colony).single;
      expect((seen.id, seen.stored, seen.caption), (photo.id, true, 'erste Larven'));
      expect(tablet.repo.events(colony).single.type, 'photo');
      // The server re-encoded it as JPEG thumbnail behind a signed URL.
      final u = await api.get('/api/v1/photos/${photo.id}/url', query: {'variant': 'thumb'}) as Map<String, dynamic>;
      final thumb = await api.download(u['url'] as String);
      expect(thumb.sublist(0, 2), [0xFF, 0xD8]);

      // Uploading the same file again is harmless.
      final again = await api.putBytes(
        '/api/v1/photos/${photo.id}/content',
        png,
        headers: {'Content-SHA256': sha256.convert(png).toString()},
      );
      expect((again as Map)['upload_state'], 'stored');
    },
    skip: server == null ? 'set ACM_TEST_SERVER to run against a real server' : false,
  );
  test(
    'sensor: created with a one-time key, readings arrive, device sees it',
    () async {
      final phone = Device('sensor-phone', api, userId);
      await phone.sync();
      final colony = phone.repo.createColony({'name': 'Sensor-Kolonie', 'species_text': 'Messor barbarus'});
      await phone.sync();
      final res =
          await api.post('/api/v1/sensors', {'name': 'Regal A', 'kind': 'esp32', 'colony_id': colony})
              as Map<String, dynamic>;
      final id = (res['data'] as Map)['id'] as String;
      final key = (res['extra'] as Map)['api_key'] as String;
      expect(key, startsWith('acm_sk_'));

      // The sensor itself: no user session, only its key.
      final sensorApi = ApiClient(baseUrl: server!, tokens: MemoryTokens(), isWeb: false);
      final stored =
          await sensorApi.post(
                '/api/v1/sensors/$id/measurements',
                {
                  'readings': [
                    {'metric': 'temperature', 'value': 24.5},
                    {'metric': 'humidity', 'value': 61},
                  ],
                },
                {'Authorization': 'Bearer $key'},
              )
              as Map<String, dynamic>;
      expect(stored['stored'], 2);
      // A wrong key is refused (raw HTTP: the app client would try a session refresh on 401).
      final wrong = await http.post(
        Uri.parse('$server/api/v1/sensors/$id/measurements'),
        headers: {'Authorization': 'Bearer ${key.substring(0, key.length - 2)}xx', 'Content-Type': 'application/json'},
        body: jsonEncode({
          'readings': [
            {'metric': 'temperature', 'value': 20},
          ],
        }),
      );
      expect(wrong.statusCode, 401);

      final buckets =
          ((await api.get('/api/v1/sensors/$id/measurements', query: {'bucket': '1h'}) as Map)['buckets'] as List)
              .cast<Map<String, dynamic>>();
      expect(buckets.map((b) => b['metric']).toSet(), {'temperature', 'humidity'});

      await phone.sync();
      final local = phone.repo.sensorsOf(colony).single;
      expect(local['name'], 'Regal A');
      expect(local['last_seen_at'], isNotNull);
      expect(local.containsKey('api_key_hash'), isFalse, reason: 'the key never leaves the server');
    },
    skip: server == null ? 'set ACM_TEST_SERVER to run against a real server' : false,
  );
}

/// 1×1 pixel PNG.
const _tinyPng = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
