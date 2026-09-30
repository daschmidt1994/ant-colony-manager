import 'package:ant_colony_manager/features/care_cover/care_cover_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('care cover body: dates as days, colonies with their instructions', () {
    final b = careCoverBody(
      email: ' ben@ants.test ',
      from: DateTime(2026, 10, 3),
      to: DateTime(2026, 10, 17),
      instructions: ' Protein jeden 2. Tag ',
      colonies: {'c1': ' Wasser prüfen ', 'c2': ''},
    );
    expect(b['email'], 'ben@ants.test');
    expect(b['starts_on'], '2026-10-03');
    expect(b['ends_on'], '2026-10-17');
    expect(b['instructions'], 'Protein jeden 2. Tag');
    expect(b['colonies'], [
      {'colony_id': 'c1', 'instructions': 'Wasser prüfen'},
      {'colony_id': 'c2', 'instructions': ''},
    ]);
    expect(coverStateText('active'), 'läuft');
    expect(coverStateText('planned'), 'geplant');
    expect(coverStateText('ended'), 'beendet');
  });
}
