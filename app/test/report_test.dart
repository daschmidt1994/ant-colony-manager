import 'dart:convert';
import 'dart:io';

import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/features/labels/labels.dart';
import 'package:ant_colony_manager/features/reports/colony_report.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  test('colony report: all sections, several pages, bundled font', () async {
    final db = memoryDb();
    var now = DateTime(2025, 10, 1, 9);
    final repo = ColonyRepository(db, userId: 'u1', onChanged: () {}, clock: () => now);
    final id = repo.createColony(
      {
        'name': 'Messor #12',
        'species_text': 'Messor barbarus',
        'founded_on': '2025-06-01',
        'queen_count': 1,
        'worker_estimate_min': 500,
        'worker_estimate_max': 1000,
        'origin': 'Eigenfang, Südfrankreich',
        'notes': 'Sehr aktiv, Körnerkammer im Nest oben links.',
      },
      intervals: {'protein': 3, 'carbohydrate': 4, 'water': 7},
    );
    // A year of care.
    for (var d = 0; d < 360; d += 3) {
      now = DateTime(2025, 10, 1, 9).add(Duration(days: d));
      repo.logEvent(
        id,
        'feeding',
        details: {
          'feeding': {
            'acceptance': d % 9 == 0 ? 'accepted' : 'unknown',
            'items': [
              {
                'food_name': d % 2 == 0 ? 'Heimchen' : 'Honigwasser',
                'category': d % 2 == 0 ? 'protein' : 'carbohydrate',
              },
            ],
          },
        },
      );
      if (d % 7 == 0) {
        repo.logEvent(
          id,
          'water',
          details: {
            'water': {
              'kinds': ['drinker_refilled'],
            },
          },
        );
      }
      if (d % 30 == 0) {
        repo.logEvent(
          id,
          'census',
          details: {
            'census': {'estimate_min': 20 + d * 3, 'estimate_max': 50 + d * 5},
          },
        );
        repo.logEvent(
          id,
          'measurement',
          details: {
            'measurements': [
              {'metric': 'temperature', 'value': 22 + (d % 90) / 20, 'unit': 'celsius'},
              {'metric': 'humidity', 'value': 55 + d % 20, 'unit': 'percent'},
            ],
          },
        );
        repo.logEvent(
          id,
          'brood',
          details: {
            'brood': [
              {'stage': 'larvae', 'level': d % 60 == 0 ? 'many' : 'few'},
            ],
          },
        );
      }
    }
    repo.logEvent(id, 'problem', note: 'Milben am Nesteingang gesehen – beobachten.');
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    );
    final photo = repo.addPhoto(id, png, thumb: png, caption: 'Erste Majore');

    final bytes = await buildColonyReport(
      ReportData(
        colony: repo.colony(id)!,
        events: repo.events(id),
        due: repo.due(id),
        photos: [(photo, png)],
        now: now,
        author: 'Anna',
      ),
      fonts: await LabelFonts.load(),
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(20000), reason: 'charts, timeline and the embedded font');
    Directory('build/label-previews').createSync(recursive: true);
    File('build/label-previews/koloniebericht.pdf').writeAsBytesSync(bytes);
    db.dispose();
  });
}
