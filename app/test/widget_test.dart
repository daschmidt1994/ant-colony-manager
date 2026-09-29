import 'package:ant_colony_manager/app/theme.dart';
import 'package:ant_colony_manager/core/session.dart';
import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/features/colonies/colony_detail_screen.dart';
import 'package:ant_colony_manager/features/dashboard/dashboard_screen.dart';
import 'package:ant_colony_manager/features/round/round_screens.dart';
import 'package:ant_colony_manager/features/settings/notifications_screen.dart';
import 'package:ant_colony_manager/features/settings/updates.dart';
import 'package:ant_colony_manager/features/timeline/timeline_screen.dart';
import 'package:ant_colony_manager/shared/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'helpers.dart';

/// Signed in without a server (no sync) – enough for UI tests.
class _FakeAuth extends AuthController {
  @override
  AuthState build() =>
      SignedIn('https://ants.test', User({'id': 'u1', 'email': 'a@ants.test', 'display_name': 'Anna'}));
}

Widget _app(AppDatabase db, Widget home, {List<Override> extra = const []}) => ProviderScope(
  overrides: [
    ...extra,
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
    repo.logEvent(
      id,
      'feeding',
      at: DateTime.now().subtract(const Duration(days: 2)),
      details: {
        'feeding': {
          'items': [
            {'food_name': 'Schabe', 'category': 'protein', 'quantity': 2, 'unit': 'piece', 'size': 'small'},
          ],
        },
      },
    );

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
      db.putRecord('care_schedules', {
        ...r.json,
        'starts_at': DateTime.now().subtract(const Duration(days: 9)).toUtc().toIso8601String(),
      });
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

  testWidgets('care round: start, pick colony, water in one tap, summary', (tester) async {
    final db = memoryDb();
    final repo = ColonyRepository(db, userId: 'u1', onChanged: () {});
    final id = repo.createColony({'name': 'Lasius #3', 'species_text': 'Lasius niger'}, intervals: {'water': 2});
    for (final r in db.records('care_schedules')) {
      db.putRecord('care_schedules', {
        ...r.json,
        'starts_at': DateTime.now().subtract(const Duration(days: 9)).toUtc().toIso8601String(),
      });
    }
    repo.createColony({'name': 'Ohne Aufgaben', 'species_text': 'Camponotus ligniperda'});

    await tester.binding.setSurfaceSize(const Size(430, 1600));
    await tester.pumpWidget(_app(db, const RoundScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Alle mit Aufgaben'), findsOneWidget);
    await tester.tap(find.text('Rundgang starten (1)'));
    await tester.pumpAndSettle();

    expect(find.text('Rundgang  0 / 1'), findsOneWidget);
    expect(find.text('OFFEN · 1'), findsOneWidget);
    await tester.tap(find.text('Lasius #3')); // web: pick from the list instead of scanning
    await tester.pumpAndSettle();
    expect(find.text('Rundgang  1 / 1'), findsOneWidget);
    expect(find.textContaining('überfällig'), findsWidgets);

    await tester.tap(find.widgetWithText(QuickActionTile, 'Wasser'));
    await tester.pumpAndSettle();
    final round = repo.activeRound()!;
    expect(repo.doneInRound(round.id, id), {'water'});
    expect(repo.events(id).single.json['care_round_id'], round.id);
    expect(find.text('Rundgang abschließen'), findsOneWidget);

    repo.endRound(round.id);
    await tester.pumpWidget(_app(db, RoundSummaryScreen(roundId: round.id)));
    await tester.pumpAndSettle();
    expect(find.text('1 / 1 Kolonien kontrolliert'), findsOneWidget);
    expect(find.text('1 Wasser'), findsOneWidget);
    db.dispose();
  });

  testWidgets('timeline: swipe or long-press deletes an entry after asking', (tester) async {
    final db = memoryDb();
    final repo = ColonyRepository(db, userId: 'u1', onChanged: () {});
    final id = repo.createColony({'name': 'Lasius #1', 'species_text': 'Lasius niger'});
    repo.logEvent(id, 'water', at: DateTime.now().subtract(const Duration(hours: 2)));
    repo.logEvent(id, 'check', at: DateTime.now().subtract(const Duration(hours: 1)));

    await tester.binding.setSurfaceSize(const Size(430, 1200));
    await tester.pumpWidget(_app(db, TimelineScreen(colonyId: id)));
    await tester.pumpAndSettle();
    expect(find.byType(EventTile), findsNWidgets(2));

    // Swipe, then cancel: nothing happens.
    await tester.drag(find.byType(EventTile).first, const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('Eintrag löschen?'), findsOneWidget);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(repo.events(id), hasLength(2));

    // Swipe and confirm.
    await tester.drag(find.byType(EventTile).first, const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Löschen'));
    await tester.pumpAndSettle();
    expect(repo.events(id), hasLength(1));
    expect(find.text('Eintrag gelöscht'), findsOneWidget);

    // Long press works too.
    await tester.longPress(find.byType(EventTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Löschen'));
    await tester.pumpAndSettle();
    expect(repo.events(id), isEmpty);
    db.dispose();
  });

  testWidgets('notifications: ntfy needs server and topic; e-mail only with SMTP', (tester) async {
    final db = memoryDb();
    await tester.binding.setSurfaceSize(const Size(430, 2400));
    await tester.pumpWidget(
      _app(
        db,
        const NotificationsScreen(),
        extra: [
          notifyPrefsProvider.overrideWith(
            (ref) async => {
              'ntfy_url': '',
              'ntfy_token_set': false,
              'email_available': false,
              'overdue_repeat_hours': 24,
              'sensor_repeat_hours': 6,
              'winter_repeat_hours': 24,
              'quiet_start': '',
              'quiet_end': '',
              'quiet_except_sensor': true,
            },
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    SwitchListTile toggle(String label, int topic) =>
        tester.widgetList<SwitchListTile>(find.widgetWithText(SwitchListTile, label)).elementAt(topic);

    expect(find.text('https://ntfy.sh'), findsOneWidget); // default server
    expect(toggle('ntfy', 1).onChanged, isNull); // no topic yet
    expect(toggle('ntfy', 1).value, isFalse);
    expect(toggle('E-Mail', 1).onChanged, isNull); // no SMTP on the server
    expect(find.text('nicht eingerichtet (Server-Verwaltung)'), findsWidgets);
    expect(find.textContaining('keinen E-Mail-Versand'), findsOneWidget);
    // App is on by default – the summary says so.
    expect(toggle('App', 1).value, isTrue);
    expect(find.text('Aktiv: App'), findsWidgets);

    await tester.enterText(find.widgetWithText(TextField, 'Server'), 'ntfy.meinedomain.at');
    await tester.enterText(find.widgetWithText(TextField, 'Topic'), 'ameisen');
    await tester.pumpAndSettle();
    expect(toggle('ntfy', 1).onChanged, isNotNull);
    await tester.tap(find.widgetWithText(SwitchListTile, 'ntfy').at(1));
    await tester.pumpAndSettle();
    expect(toggle('ntfy', 1).value, isTrue);
    expect(find.text('Aktiv: App, ntfy'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Topic'), 'ameisen/x');
    await tester.pumpAndSettle();
    expect(find.text('Nur Buchstaben, Ziffern, _ und - (max. 64)'), findsOneWidget);
    db.dispose();
  });

  testWidgets('colony page: link a care sheet via search (typo), then unlink', (tester) async {
    final db = memoryDb();
    final repo = ColonyRepository(db, userId: 'u1', onChanged: () {});
    db.putRecord('species', {
      'id': 'n',
      'owner_id': null,
      'scientific_name': 'Lasius niger',
      'genus': 'Lasius',
      'hibernation': 'required',
      'difficulty': 1,
    });
    final id = repo.createColony({'name': 'Lassius #2', 'species_text': 'Lassius niger'});
    await tester.binding.setSurfaceSize(const Size(430, 1600));
    await tester.pumpWidget(_app(db, ColonyDetailScreen(colonyId: id)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Steckbrief aus dem Artenkatalog verknüpfen'));
    await tester.pumpAndSettle();
    expect(find.text('Meintest du …'), findsOneWidget);
    await tester.tap(find.text('Lasius niger').last);
    await tester.pumpAndSettle();
    expect(repo.colony(id)!.speciesId, 'n');
    expect(find.text('Steckbrief: Lasius niger'), findsOneWidget);

    await tester.tap(find.byTooltip('Verknüpfung'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verknüpfung lösen'));
    await tester.pumpAndSettle();
    expect(repo.colony(id)!.speciesId, isNull);
    expect(find.text('Steckbrief aus dem Artenkatalog verknüpfen'), findsOneWidget);
    db.dispose();
  });

  testWidgets('dashboard warns before a breaking update, until dismissed', (tester) async {
    Map<String, dynamic> info(bool breaking) => {
      'enabled': true,
      'current': '1.2.3',
      'latest': '2.0.0',
      'update_available': true,
      'breaking': breaking,
      'newer': [
        {
          'version': '2.0.0',
          'url': 'https://github.com/x/releases/v2.0.0',
          'breaking': breaking,
          'breaking_text': 'Datenbank neu aufgebaut.',
        },
      ],
    };
    final db = memoryDb();
    ColonyRepository(db, userId: 'u1', onChanged: () {}).createColony({'name': 'A', 'species_text': 'x'});
    await tester.binding.setSurfaceSize(const Size(430, 1200));
    await tester.pumpWidget(
      _app(db, const DashboardScreen(), extra: [updatesProvider.overrideWith((ref) async => info(true))]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Update 2.0.0: Breaking Change'), findsOneWidget);
    expect(find.text('Datenbank neu aufgebaut.'), findsOneWidget);
    expect(find.textContaining('1. Backup machen'), findsOneWidget);
    await tester.tap(find.text('Ausblenden'));
    await tester.pumpAndSettle();
    expect(find.text('Update 2.0.0: Breaking Change'), findsNothing);
    expect(db.getMeta('update_warning_dismissed'), '2.0.0');

    // A harmless update never shows the red card.
    final db2 = memoryDb();
    ColonyRepository(db2, userId: 'u1', onChanged: () {}).createColony({'name': 'A', 'species_text': 'x'});
    await tester.pumpWidget(
      _app(db2, const DashboardScreen(), extra: [updatesProvider.overrideWith((ref) async => info(false))]),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Breaking Change'), findsNothing);
    expect(updateLine(info(false)), 'Update 2.0.0 verfügbar');
    expect(updateLine(info(true)), contains('Breaking Change'));
    db.dispose();
    db2.dispose();
  });
}
