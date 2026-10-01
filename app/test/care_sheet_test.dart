import 'dart:io';

import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/domain/due.dart';
import 'package:ant_colony_manager/features/care_cover/care_sheet.dart';
import 'package:ant_colony_manager/features/labels/labels.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'helpers.dart';

DueTask task(String type, double every, DateTime? next) => DueTask(
  schedule: Schedule(id: type, colonyId: 'c', taskType: type, intervalDays: every, startsAt: DateTime(2026)),
  lastDone: null,
  nextDue: next,
  classification: const Classification(DueStatus.ok, DueGroup.later, 0),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  test('plan: from the next due date every interval, overdue on the first day, paused left out', () {
    final from = DateTime(2026, 10, 10), to = DateTime(2026, 10, 20);
    final plan = careSheetPlan(
      [
        task('protein', 3, DateTime(2026, 10, 11, 18)),
        task('water', 7, DateTime(2026, 10, 2)), // overdue before the holiday
        task('check', 1, DateTime(2026, 10, 25)), // after the period
        task('cleaning', 30, null), // winter rest pause
      ],
      from,
      to,
    );
    List<int> days(String name) =>
        plan.firstWhere((t) => t.task.schedule.taskType == name).days.map((d) => d.day).toList();
    expect(days('protein'), [11, 14, 17, 20]);
    expect(days('water'), [10, 17]);
    expect(days('check'), isEmpty);
    expect(plan.any((t) => t.task.schedule.taskType == 'cleaning'), isFalse);
  });

  test('care sheet PDF from the local database', () async {
    final db = memoryDb();
    final now = DateTime(2026, 10, 1, 9);
    final repo = ColonyRepository(db, userId: 'u1', onChanged: () {}, clock: () => now);
    final id = repo.createColony(
      {'name': 'Messor', 'species_text': 'Messor barbarus'},
      intervals: {'protein': 3, 'carbohydrate': 4, 'water': 7},
    );
    final bytes = await buildCareSheet(
      colonies: [CareSheetColony(colony: repo.colony(id)!, due: repo.due(id), instructions: 'Körner nachlegen')],
      from: DateTime(2026, 10, 5),
      to: DateTime(2026, 10, 26),
      instructions: 'Nicht klopfen, Deckel immer schließen.',
      contact: '+43 660 0000000',
      author: 'Anna',
      now: now,
      fonts: await LabelFonts.load(),
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    Directory('build/label-previews').createSync(recursive: true);
    File('build/label-previews/pflegezettel.pdf').writeAsBytesSync(bytes);
    db.dispose();
  });
}
