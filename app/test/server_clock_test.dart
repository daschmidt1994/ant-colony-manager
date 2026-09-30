import 'package:ant_colony_manager/features/settings/server_clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clock skew: quiet within two minutes, otherwise ahead or behind', () {
    final server = DateTime.utc(2026, 9, 30, 12);
    expect(clockSkew(server, server.add(const Duration(seconds: 90))), isNull);
    expect(clockSkew(server, server.add(const Duration(minutes: 10))), const Duration(minutes: 10));
    expect(clockSkew(server, server.subtract(const Duration(hours: 1)))!.isNegative, isTrue);
    expect(skewText(const Duration(minutes: 10)), '10 Min.');
    expect(skewText(const Duration(minutes: -125)), '2 Std. 5 Min.');
    expect(skewText(const Duration(hours: 1)), '1 Std.');
    expect(offsetText(const Duration(hours: 2)), 'UTC+2');
    expect(offsetText(const Duration(hours: -5, minutes: -30)), 'UTC−5:30');
    expect(zoneOffsetNow('Europe/Vienna'), isNotNull);
    expect(zoneOffsetNow('Mars/Olympus'), isNull);
  });
}
