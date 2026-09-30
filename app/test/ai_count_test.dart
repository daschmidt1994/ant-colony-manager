import 'package:ant_colony_manager/features/ai/ai_count.dart';
import 'package:ant_colony_manager/features/settings/ai_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI result: exact when the range is closed, otherwise a range', () {
    expect(aiCensus({'total': 200, 'min': 170, 'max': 235}), (total: 200, min: 170, max: 235, exact: false));
    expect(aiCensus({'total': 12, 'min': 12, 'max': 12}).exact, isTrue);
    expect(aiCountText({'count': 120, 'min': 100, 'max': 140}), '120 (100–140)');
    expect(aiCountText({'total': 7, 'min': 7, 'max': 7}), '7');
  });

  test('AI settings body: key only when typed or removed', () {
    expect(aiBody(enabled: true, model: ' claude-opus-5-5 '), {
      'enabled': true,
      'provider': 'anthropic',
      'model': 'claude-opus-5-5',
    });
    expect(aiBody(enabled: true, provider: 'openrouter', model: 'openai/x')['provider'], 'openrouter');
    expect(aiProviderHelp('openrouter').keyHint, 'sk-or-…');
    expect(aiProviderHelp('openai').key, contains('platform.openai.com'));
    expect(aiBody(enabled: true, model: 'm', apiKey: ' sk-ant-x ')['api_key'], 'sk-ant-x');
    expect(aiBody(enabled: false, model: 'm', removeKey: true)['api_key'], '');
  });
}
