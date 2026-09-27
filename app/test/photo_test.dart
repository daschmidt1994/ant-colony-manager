import 'dart:math';
import 'dart:typed_data';

import 'package:ant_colony_manager/core/api_client.dart';
import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/data/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

class _Device {
  _Device(this.name, FakeServer server) : db = memoryDb() {
    engine = SyncEngine(
      db: db,
      api: ApiClient(baseUrl: 'https://ants.test', tokens: MemoryTokens(), isWeb: false, client: server.client)
        ..setAccessToken('a1'),
      userId: 'u1',
      device: DeviceIdentity(id: 'dev-$name', name: name, platform: 'android', appVersion: 'test'),
    );
    repo = ColonyRepository(db, userId: 'u1', onChanged: () {});
  }
  final String name;
  final AppDatabase db;
  late final SyncEngine engine;
  late final ColonyRepository repo;
}

final _jpeg = Uint8List.fromList(List.generate(5000, (i) => i % 251));
final _thumb = Uint8List.fromList([1, 2, 3]);

void main() {
  test('photo offline: own timeline entry, visible at once, uploaded after the record', () async {
    final server = FakeServer()..online = false;
    final a = _Device('A', server);
    final c = a.repo.createColony({'name': 'A', 'species_text': 'x'});
    final p = a.repo.addPhoto(c, _jpeg, thumb: _thumb, caption: 'Larven');

    expect(a.repo.photos(c).single.id, p.id);
    expect(a.db.thumb(p.id), _thumb, reason: 'gallery works offline');
    final ev = a.repo.events(c).single;
    expect((ev.type, ev.note), ('photo', 'Larven'));
    expect(p.eventId, ev.id);
    await a.engine.sync();
    expect(a.engine.current.pending, greaterThan(0));

    server.online = true;
    await a.engine.sync(resetBackoff: true);
    expect(a.db.pendingUploadCount(), 0);
    expect(server.rows['photos']![p.id]!['upload_state'], 'stored');
    expect(server.uploads[p.id], 1);
    expect(a.repo.photos(c).single.stored, isTrue);

    final b = _Device('B', server);
    await b.engine.sync();
    expect(b.repo.photos(c).single.stored, isTrue);
    expect(b.db.thumb(p.id), isNull, reason: 'B downloads the thumbnail on demand');
  });

  test('photo attached to an existing event creates no extra entry', () async {
    final a = _Device('A', FakeServer());
    final c = a.repo.createColony({'name': 'A', 'species_text': 'x'});
    final e = a.repo.logEvent(
      c,
      'cleaning',
      details: {
        'cleaning': {
          'kinds': ['arena'],
        },
      },
    );
    a.repo.addPhoto(c, _jpeg, thumb: _thumb, eventId: e.id);
    expect(a.repo.events(c).map((x) => x.type), ['cleaning']);
    expect(a.repo.photosOfEvent(e.id), hasLength(1));
  });

  test('upload response lost → retry does not store twice', () async {
    final server = FakeServer();
    final a = _Device('A', server);
    final c = a.repo.createColony({'name': 'A', 'species_text': 'x'});
    final p = a.repo.addPhoto(c, _jpeg, thumb: _thumb);
    // Wi-Fi only and no Wi-Fi: the records are pushed, the photo waits.
    var allowed = false;
    final gated = SyncEngine(
      db: a.db,
      api: ApiClient(baseUrl: 'https://ants.test', tokens: MemoryTokens(), isWeb: false, client: server.client)
        ..setAccessToken('a1'),
      userId: 'u1',
      device: const DeviceIdentity(id: 'dev-A', name: 'A', platform: 'android', appVersion: 'test'),
      uploadAllowed: () async => allowed,
    );
    await gated.sync();
    expect(a.db.pendingUploadCount(), 1, reason: 'Wi-Fi only: photo waits');
    expect(server.rows['photos']![p.id]!['upload_state'], isNull);

    allowed = true;
    server.dropNextResponse = true; // the upload is stored, its answer lost
    await gated.sync();
    expect(a.db.pendingUploadCount(), 1);
    await gated.sync(resetBackoff: true);
    expect(a.db.pendingUploadCount(), 0);
    expect(server.uploads[p.id], 1);
  });

  test('deleting a photo before upload: nothing is sent, entry removed', () async {
    final server = FakeServer()..online = false;
    final a = _Device('A', server);
    final c = a.repo.createColony({'name': 'A', 'species_text': 'x'});
    final p = a.repo.addPhoto(c, _jpeg, thumb: _thumb);
    a.repo.deletePhoto(p.id);
    expect(a.db.pendingUploadCount(), 0);
    expect(a.db.thumb(p.id), isNull);
    expect(a.repo.events(c), isEmpty, reason: 'the „Foto“ entry goes with its last photo');
    server.online = true;
    await a.engine.sync(resetBackoff: true);
    expect(server.uploads, isEmpty);
    expect(server.count('photos'), 0);
  });

  test('deleting the timeline entry deletes its photos', () async {
    final a = _Device('A', FakeServer());
    final c = a.repo.createColony({'name': 'A', 'species_text': 'x'});
    final p = a.repo.addPhoto(c, _jpeg, thumb: _thumb);
    a.repo.deleteEvent(p.eventId!);
    expect(a.repo.photos(c), isEmpty);
    expect(a.db.pendingUploadCount(), 0);
  });

  test('chaos: photos from two devices under a bad network are each stored exactly once', () async {
    for (final seed in [1, 2, 3]) {
      final server = FakeServer();
      final a = _Device('A', server), b = _Device('B', server);
      final c = a.repo.createColony({'name': 'A', 'species_text': 'x'});
      await a.engine.sync();
      await b.engine.sync();
      server
        ..chaos = Random(seed)
        ..failBefore = .3
        ..failAfter = .3;
      final ids = <String>[];
      for (var i = 0; i < 40; i++) {
        final d = i.isEven ? a : b;
        ids.add(d.repo.addPhoto(c, _jpeg, thumb: _thumb).id);
        if (i % 3 == 0) {
          await a.engine.sync();
          await b.engine.sync();
        }
      }
      server
        ..failBefore = 0
        ..failAfter = 0;
      for (var i = 0; i < 3; i++) {
        await a.engine.sync(resetBackoff: true);
        await b.engine.sync(resetBackoff: true);
      }
      expect(a.db.pendingUploadCount() + b.db.pendingUploadCount(), 0, reason: 'seed $seed');
      expect(ids.map((id) => server.uploads[id]), everyElement(1), reason: 'seed $seed');
      expect(a.repo.photos(c).where((p) => p.stored), hasLength(40), reason: 'seed $seed');
      expect(b.repo.photos(c).where((p) => p.stored), hasLength(40), reason: 'seed $seed');
    }
  });
}
