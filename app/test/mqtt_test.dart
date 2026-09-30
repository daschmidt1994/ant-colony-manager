import 'package:ant_colony_manager/features/sensors/sensors_screen.dart';
import 'package:ant_colony_manager/features/settings/mqtt_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MQTT request body: trimmed, password only when typed or removed', () {
    expect(mqttBody(enabled: true, url: ' 192.168.178.199 ', user: ' acm ', prefix: ' homeassistant '), {
      'enabled': true,
      'url': '192.168.178.199',
      'user': 'acm',
      'prefix': 'homeassistant',
      'ha_url': '',
    });
    expect(mqttBody(enabled: true, url: 'u', user: '', prefix: 'p', password: 'geheim')['password'], 'geheim');
    expect(mqttBody(enabled: false, url: 'u', user: '', prefix: 'p', removePassword: true)['password'], '');
    final ha = mqttBody(enabled: true, url: 'u', user: '', prefix: 'p', haUrl: ' http://ha:8123 ', haToken: ' tok ');
    expect(ha['ha_url'], 'http://ha:8123');
    expect(ha['ha_token'], 'tok');
    expect(mqttBody(enabled: true, url: 'u', user: '', prefix: 'p', removeHaToken: true)['ha_token'], '');
    expect(validEntityId('sensor.formicarium_temperature'), isTrue);
    expect(validEntityId('Sensor.X'), isFalse);
  });
}
