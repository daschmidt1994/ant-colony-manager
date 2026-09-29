import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/domain/widget_summary.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late AppDatabase db;
  late ColonyRepository repo;
  var now = DateTime.utc(2026, 9, 20, 10);

  setUp(() {
    db = memoryDb();
    now = DateTime.utc(2026, 9, 20, 10);
    repo = ColonyRepository(db, userId: 'u1', onChanged: () {}, clock: () => now);
  });
  tearDown(() => db.dispose());

  WidgetSummary summary({int maxLines = 4}) {
    final cols = repo.colonies();
    return widgetSummary(
      colonies: cols,
      due: repo.dueAll(cols),
      readOnlyColonies: repo.readOnlyColonies(),
      maxLines: maxLines,
    );
  }

  test('counts overdue and due today, most urgent first', () {
    repo.createColony({'name': 'Messor', 'species_text': 'x'}, intervals: {'protein': 3, 'water': 5});
    repo.createColony({'name': 'Lasius', 'species_text': 'x'}, intervals: {'water': 2});
    now = now.add(const Duration(days: 5)); // Messor protein 2 overdue, water today; Lasius water 3 overdue
    final s = summary();
    expect(s.overdue, 2);
    expect(s.today, 1);
    expect(s.headline, '2 überfällig · 1 heute');
    expect(s.lines.first, 'Lasius · Wasser · 3 Tage überfällig');
    expect(s.lines.last, 'Messor · Wasser · heute');
    expect(summary(maxLines: 1).lines, hasLength(1));
  });

  test('nothing due, view-only colonies do not count', () {
    final shared = repo.createColony({'name': 'Geteilt', 'species_text': 'x'}, intervals: {'water': 1});
    db.putRecord('colony_members', {'id': 'm1', 'colony_id': shared, 'user_id': 'u1', 'role': 'viewer'});
    now = now.add(const Duration(days: 4));
    final s = summary();
    expect(s.overdue + s.today, 0);
    expect(s.headline, 'Alles erledigt');
    expect(s.lines, isEmpty);
  });
}
