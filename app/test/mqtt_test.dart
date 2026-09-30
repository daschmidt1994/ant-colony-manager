import 'package:ant_colony_manager/features/settings/mqtt_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MQTT request body: trimmed, password only when typed or removed', () {
    expect(mqttBody(enabled: true, url: ' 192.168.178.199 ', user: ' acm ', prefix: ' homeassistant '), {
      'enabled': true,
      'url': '192.168.178.199',
      'user': 'acm',
      'prefix': 'homeassistant',
    });
    expect(mqttBody(enabled: true, url: 'u', user: '', prefix: 'p', password: 'geheim')['password'], 'geheim');
    expect(mqttBody(enabled: false, url: 'u', user: '', prefix: 'p', removePassword: true)['password'], '');
  });
}
