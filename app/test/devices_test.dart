import 'package:ant_colony_manager/core/api_client.dart';
import 'package:ant_colony_manager/data/sync/sync_engine.dart';
import 'package:ant_colony_manager/features/settings/devices_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  test('user agents become readable device names', () {
    expect(
      describeUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36',
      ),
      'Chrome auf Windows',
    );
    expect(
      describeUserAgent('Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0'),
      'Firefox auf Linux',
    );
    expect(
      describeUserAgent(
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
      ),
      'Safari auf macOS',
    );
    expect(describeUserAgent('Mozilla/5.0 (Windows NT 10.0) Chrome/140.0 Safari/537.36 Edg/140.0'), 'Edge auf Windows');
    expect(describeUserAgent('Dart/3.12 (dart:io)'), isNull);
    expect(describeUserAgent('curl/8.5.0'), 'curl/8.5.0');
    expect(describeUserAgent(null), isNull);
  });

  test('the Android app shows its device name, the web its browser', () {
    final app = DeviceSession({
      'id': '1',
      'device_name': 'Android',
      'platform': 'android',
      'user_agent': 'Dart/3.12 (dart:io)',
    });
    expect(app.name, 'Android');
    final web = DeviceSession({
      'id': '2',
      'platform': 'web',
      'device_name': 'Web-Browser',
      'user_agent': 'Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0',
    });
    expect(web.name, 'Firefox auf Linux');
    expect(DeviceSession({'id': '3'}).name, 'Unbekanntes Gerät');
  });

  test('a name given by the user wins, also over the browser', () {
    final web = DeviceSession({
      'id': '2',
      'platform': 'web',
      'device_name': 'Laptop Wohnzimmer',
      'user_agent': 'Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0',
    });
    expect(web.name, 'Laptop Wohnzimmer');
    expect(
      DeviceSession({'id': '1', 'platform': 'android', 'device_name': 'Pixel 7 von Anna'}).name,
      'Pixel 7 von Anna',
    );
  });

  test('renamed device reports its name once, even with nothing to send; logout keeps it', () async {
    final server = FakeServer();
    final db = memoryDb();
    final engine = SyncEngine(
      db: db,
      api: ApiClient(baseUrl: 'https://ants.test', tokens: MemoryTokens(), isWeb: false, client: server.client)
        ..setAccessToken('a1'),
      userId: 'u1',
      device: const DeviceIdentity(id: 'dev-1', name: 'Android', platform: 'android', appVersion: 'test'),
    );
    await engine.sync();
    expect(server.lastDeviceName, 'Android');
    final before = server.pushes;
    await engine.sync();
    expect(server.pushes, before, reason: 'nothing new → no push');

    db.setMeta(deviceNameKey, 'Pixel 7 von Anna');
    await engine.sync();
    expect(server.lastDeviceName, 'Pixel 7 von Anna');
    expect(server.pushes, before + 1);
    await engine.sync();
    expect(server.pushes, before + 1, reason: 'announced once');

    db.wipe();
    expect(db.getMeta(deviceNameKey), 'Pixel 7 von Anna');
    db.dispose();
  });
}
