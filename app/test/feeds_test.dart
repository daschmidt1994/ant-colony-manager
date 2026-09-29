import 'package:ant_colony_manager/domain/models.dart';
import 'package:ant_colony_manager/features/settings/feeds_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Home Assistant configuration has totals and one entry per colony', () {
    final yaml = homeAssistantYaml('https://ants.example/api/v1/feeds/acm_fk_a_b/status.json', [
      Colony({'id': 'x', 'number': 3, 'name': 'Messor'}),
    ]);
    expect(yaml, contains('resource: "https://ants.example/api/v1/feeds/acm_fk_a_b/status.json"'));
    expect(yaml, contains('value_template: "{{ value_json.overdue }}"'));
    expect(yaml, contains("value_json.by_number['3'].overdue | default(0)"));
    expect(yaml, contains('binary_sensor:'));
    expect(yaml, contains("value_json.by_number['3'].hibernating | default(false)"));
    expect(yaml, isNot(contains('\t')));
  });

  test('without colonies there is no empty binary_sensor block', () {
    expect(homeAssistantYaml('u', const []), isNot(contains('binary_sensor')));
  });
}
