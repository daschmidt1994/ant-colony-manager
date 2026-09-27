import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/domain/stats.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late AppDatabase db;
  late ColonyRepository repo;
  var now = DateTime(2026, 9, 27, 12); // local time, a Sunday

  setUp(() {
    db = memoryDb();
    now = DateTime(2026, 9, 27, 12);
    repo = ColonyRepository(db, userId: 'u1', onChanged: () {}, clock: () => now);
  });
  tearDown(() => db.dispose());

  void feed(String c, List<String> categories, DateTime at, {String acceptance = 'unknown'}) => repo.logEvent(
    c,
    'feeding',
    at: at,
    details: {
      'feeding': {
        'acceptance': acceptance,
        'items': [
          for (final cat in categories) {'food_name': cat, 'category': cat},
        ],
      },
    },
  );

  test('buckets: days, ISO weeks from Monday, months', () {
    final w = Buckets.of(StatsRange.week, now);
    expect(w.starts, hasLength(7));
    expect(w.starts.last, DateTime(2026, 9, 27));
    expect(w.unit, BucketUnit.day);
    final q = Buckets.of(StatsRange.quarter, now);
    expect(q.starts, hasLength(13));
    expect(q.starts.last, DateTime(2026, 9, 21), reason: 'Monday of this week');
    expect(q.starts.every((d) => d.weekday == DateTime.monday), isTrue);
    final y = Buckets.of(StatsRange.year, now);
    expect((y.starts.first, y.starts.last), (DateTime(2025, 10), DateTime(2026, 9)));
    final all = Buckets.of(StatsRange.all, now, firstEvent: DateTime(2024, 3, 5));
    expect(all.starts.first, DateTime(2024, 3));
    expect(all.indexOf(DateTime(2026, 9, 1, 0, 30)), all.starts.length - 1);
    expect(w.indexOf(DateTime(2026, 9, 20, 23)), isNull, reason: 'before the range');
  });

  test('care counts per bucket: protein and carbs separately, water, cleaning, acceptance', () {
    final c = repo.createColony({'name': 'A', 'species_text': 'Messor barbarus'});
    feed(c, ['protein'], DateTime(2026, 9, 27, 8), acceptance: 'accepted');
    feed(c, ['protein', 'carbohydrate'], DateTime(2026, 9, 26, 8), acceptance: 'ignored');
    feed(c, ['other'], DateTime(2026, 9, 25, 8));
    feed(c, ['protein'], DateTime(2026, 8, 1)); // outside 7 days
    repo.logEvent(
      c,
      'water',
      at: DateTime(2026, 9, 26, 9),
      details: {
        'water': {
          'kinds': ['drinker_refilled'],
        },
      },
    );
    repo.logEvent(
      c,
      'cleaning',
      at: DateTime(2026, 9, 21, 9),
      details: {
        'cleaning': {
          'kinds': ['arena'],
        },
      },
    );

    final s = repo.colonyStatsFor(c, StatsRange.week);
    expect((s.feedings, s.protein, s.carbohydrate, s.water, s.cleaning), (3, 2, 1, 1, 1));
    expect(s.care.last.protein, 1);
    expect(s.care[5].protein + s.care[5].carbohydrate, 2);
    expect(s.care[4].otherFeeding, 1);
    expect((s.accepted, s.rated), (1, 2));
    expect(repo.colonyStatsFor(c, StatsRange.year).protein, 3);
  });

  test('growth starts with the last size before the range; brood levels; measurements', () {
    final c = repo.createColony({'name': 'A', 'species_text': 'x'});
    repo.logEvent(
      c,
      'census',
      at: DateTime(2026, 6, 1),
      details: {
        'census': {'estimate_min': 10, 'estimate_max': 50},
      },
    );
    repo.logEvent(
      c,
      'census',
      at: DateTime(2026, 9, 20),
      details: {
        'census': {'exact_count': 64},
      },
    );
    repo.logEvent(
      c,
      'brood',
      at: DateTime(2026, 9, 22),
      details: {
        'brood': [
          {'stage': 'larvae', 'level': 'many'},
          {'stage': 'eggs', 'level': 'few'},
        ],
      },
    );
    repo.logEvent(
      c,
      'measurement',
      at: DateTime(2026, 9, 23),
      details: {
        'measurements': [
          {'metric': 'temperature', 'value': 24.5, 'unit': 'celsius'},
          {'metric': 'humidity', 'value': 60, 'unit': 'percent'},
        ],
      },
    );
    final s = repo.colonyStatsFor(c, StatsRange.month);
    expect(s.workers.map((p) => (p.value, p.max)), [(10.0, 50.0), (64.0, null)]);
    expect(s.workers.first.at, s.buckets.from, reason: 'carried over to the start of the range');
    expect(s.brood['larvae']!.single.value, 3);
    expect(s.brood['eggs']!.single.value, 1);
    expect(s.temperature.single.value, 24.5);
    expect(s.humidity.single.value, 60);
  });

  test('collection: species, genera, workers, feedings this week and month, locations', () {
    final regal = repo.createLocation('Regal A');
    final a = repo.createColony({
      'name': 'A',
      'species_text': 'Messor barbarus',
      'location_id': regal,
      'worker_estimate_min': 100,
      'worker_estimate_max': 500,
    });
    repo.createColony({
      'name': 'B',
      'species_text': 'Messor structor',
      'worker_estimate_min': 10,
      'worker_estimate_max': 50,
    });
    repo.createColony({'name': 'C', 'species_text': 'Lasius niger', 'status': 'hibernating'}, intervals: {'water': 1});
    final gone = repo.createColony({'name': 'D', 'species_text': 'Camponotus ligniperda'});
    repo.updateColony(gone, {'status': 'deceased'});
    feed(a, ['protein'], DateTime(2026, 9, 22)); // this week (Mon 21.)
    feed(a, ['protein'], DateTime(2026, 9, 2)); // this month
    feed(a, ['protein'], DateTime(2026, 8, 30)); // earlier
    now = now.add(const Duration(days: 3));

    final g = repo.collectionStats();
    expect(g.colonies, 3);
    expect((g.species, g.genera), (3, 2));
    expect(
      g.byGenus.first,
      isA<MapEntry<String, int>>().having((e) => e.key, 'key', 'Messor').having((e) => e.value, 'value', 2),
    );
    expect((g.workersMin, g.workersMax, g.workersUnknown), (110, 550, 1));
    expect(g.hibernating, 1);
    expect(g.byLocation.map((e) => e.key), containsAll(['Regal A', 'ohne Standort']));
    now = DateTime(2026, 9, 27, 12);
    final h = repo.collectionStats();
    expect((h.feedingsWeek, h.feedingsMonth), (1, 2));
  });

  test('open worker range makes the total open-ended', () {
    repo.createColony({'name': 'A', 'species_text': 'x', 'worker_estimate_min': 10000});
    repo.createColony({'name': 'B', 'species_text': 'y', 'worker_estimate_min': 10, 'worker_estimate_max': 50});
    final g = repo.collectionStats();
    expect((g.workersMin, g.workersMax), (10010, null));
  });
}
