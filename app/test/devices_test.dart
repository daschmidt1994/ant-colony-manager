import 'package:ant_colony_manager/features/settings/devices_screen.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
