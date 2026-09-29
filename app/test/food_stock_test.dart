import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/domain/food_stock.dart';
import 'package:ant_colony_manager/features/reminders/reminder_actions.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late AppDatabase db;
  late ColonyRepository repo;
  var now = DateTime(2026, 9, 20, 10);

  setUp(() {
    db = memoryDb();
    now = DateTime(2026, 9, 20, 10);
    repo = ColonyRepository(db, userId: 'u1', onChanged: () {}, clock: () => now);
  });
  tearDown(() => db.dispose());

  test('issues: expired, open too long, low, culture care', () {
    final s = FoodStock({
      'id': 'a',
      'name': 'Honigwasser',
      'opened_on': '2026-09-14',
      'use_within_days': 5,
      'best_before': '2026-09-19',
      'quantity': 2,
      'reorder_below': 2,
      'unit': 'piece',
    });
    expect(s.issues(now), [StockIssue.expired, StockIssue.openedTooLong, StockIssue.low]);
    expect(s.issueText(StockIssue.openedTooLong, now), 'Seit 6 Tagen offen – ersetzen (hält 5 Tage)');
    expect(s.issueText(StockIssue.low, now), 'Nur noch 2 Stück – nachbestellen');
    // fresh, enough, not expired → nothing
    expect(
      FoodStock({
        'id': 'b',
        'name': 'x',
        'opened_on': '2026-09-18',
        'use_within_days': 5,
        'quantity': 3,
        'reorder_below': 2,
      }).issues(now),
      isEmpty,
    );
    final culture = FoodStock({
      'id': 'c',
      'name': 'Drosophila',
      'kind': 'culture',
      'care_interval_days': 14,
      'last_cared_at': now.subtract(const Duration(days: 15)).toUtc().toIso8601String(),
    });
    expect(culture.issues(now), [StockIssue.cultureCare]);
    expect(FoodStock({...culture.json, 'archived_at': '2026-09-01T00:00:00Z'}).issues(now), isEmpty);
  });

  test('repository: create, adjust, open, reminders and „Erledigt“ for a culture', () {
    final id = repo.createFoodStock({'name': 'Heimchen', 'quantity': 11, 'unit': 'piece', 'reorder_below': 10});
    expect(repo.foodStockIssues(), isEmpty);
    repo.adjustFoodStock(id, -1);
    expect(repo.foodStocks().single.quantity, 10);
    expect(repo.foodStockIssues().single.$2, [StockIssue.low]);
    repo.adjustFoodStock(id, -20);
    expect(repo.foodStocks().single.quantity, 0, reason: 'never below zero');

    final water = repo.createFoodStock({'name': 'Zuckerwasser', 'use_within_days': 5, 'opened_on': '2026-09-10'});
    repo.openFoodStock(water);
    expect(repo.foodStocks().firstWhere((s) => s.id == water).openDays(now), 0);

    final culture = repo.createFoodStock({
      'name': 'Drosophila',
      'kind': 'culture',
      'care_interval_days': 7,
      'last_cared_at': now.toUtc().toIso8601String(),
    });
    now = now.add(const Duration(days: 8));
    final r = repo.reminders().where((r) => r.payload['kind'] == 'stock').toList();
    expect(r.map((x) => x.body), containsAll(['Zucht versorgen (alle 7 Tage)', 'Nur noch 0 Stück – nachbestellen']));
    final cultureReminder = r.firstWhere((x) => x.payload['stock'] == culture);
    expect(cultureReminder.canComplete, isTrue);
    expect(handleReminder(repo, actionId: 'done', payload: cultureReminder.payloadJson), isNull);
    expect(repo.foodStockIssues().any((e) => e.$1.id == culture), isFalse);
    expect(handleReminder(repo, payload: cultureReminder.payloadJson), '/settings/food-stock');
    expect(db.select('SELECT DISTINCT entity FROM outbox').map((r) => r['entity']), ['food_stocks']);
  });
}
