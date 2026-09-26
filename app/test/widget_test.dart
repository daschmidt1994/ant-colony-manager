import 'package:ant_colony_manager/app/theme.dart';
import 'package:ant_colony_manager/core/session.dart';
import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/features/colonies/colony_detail_screen.dart';
import 'package:ant_colony_manager/features/dashboard/dashboard_screen.dart';
import 'package:ant_colony_manager/shared/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'helpers.dart';

/// Signed in without a server (no sync) – enough for UI tests.
class _FakeAuth extends AuthController {
  @override
  AuthState build() => SignedIn('https://ants.test', User({'id': 'u1', 'email': 'a@ants.test', 'display_name': 'Anna'}));
}

Widget _app(AppDatabase db, Widget home) => ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        authProvider.overrideWith(_FakeAuth.new),
        syncEngineProvider.overrideWith((ref) => null),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        locale: const Locale('de'),
        supportedLocales: const [Locale('de')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: home,
      ),
    );

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('colony page: repeat last feeding and water are one tap each', (tester) async {
    final db = memoryDb();
    final repo = ColonyRepository(db, userId: 'u1', onChanged: () {});
    final id = repo.createColony({'name': 'Messor #12', 'species_text': 'Messor barbarus'}, intervals: {'water': 2});
    repo.logEvent(id, 'feeding', at: DateTime.now().subtract(const Duration(days: 2)), details: {
      'feeding': {
        'items': [
          {'food_name': 'Schabe', 'category': 'protein', 'quantity': 2, 'unit': 'piece', 'size': 'small'},
        ],
      },
    });

    await tester.binding.setSurfaceSize(const Size(430, 1600));
    await tester.pumpWidget(_app(db, ColonyDetailScreen(colonyId: id)));
    await tester.pumpAndSettle();

    expect(find.text('Messor barbarus'), findsOneWidget);
    expect(find.text('Letzte Fütterung wiederholen'), findsOneWidget);
    expect(find.textContaining('2× Schabe (klein)'), findsWidgets);

    await tester.tap(find.text('Letzte Fütterung wiederholen'));
    await tester.pumpAndSettle();
    expect(repo.events(id, types: {'feeding'}), hasLength(2));
    expect(find.textContaining('Fütterung gespeichert'), findsOneWidget);

    await tester.tap(find.widgetWithText(QuickActionTile, 'Wasser'));
    await tester.pumpAndSettle();
    final water = repo.events(id, types: {'water'});
    expect(water, hasLength(1));
    expect(water.first.waterKinds, ['drinker_refilled']);

    // Undo removes the entry again (it never reached the server).
    await tester.tap(find.text('Rückgängig'));
    await tester.pumpAndSettle();
    expect(repo.events(id, types: {'water'}), isEmpty);
    db.dispose();
  });

  testWidgets('dashboard groups colonies by urgency', (tester) async {
    final db = memoryDb();
    final repo = ColonyRepository(db, userId: 'u1', onChanged: () {});
    final id = repo.createColony({'name': 'Lasius #3', 'species_text': 'Lasius niger'}, intervals: {'water': 2});
    for (final r in db.records('care_schedules')) {
      db.putRecord('care_schedules', {...r.json, 'starts_at': DateTime.now().subtract(const Duration(days: 9)).toUtc().toIso8601String()});
    }
    repo.createColony({'name': 'Ohne Aufgaben', 'species_text': 'Camponotus ligniperda'});

    await tester.binding.setSurfaceSize(const Size(430, 1400));
    await tester.pumpWidget(_app(db, const DashboardScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Überfällig · 1'), findsOneWidget);
    expect(find.text('Lasius #3'), findsWidgets);
    expect(find.textContaining('Wasser · 7 Tage überfällig'), findsOneWidget);
    expect(repo.dueAll().containsKey(id), isTrue);
    db.dispose();
  });
}
