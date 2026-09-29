import 'package:ant_colony_manager/app/i18n.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/domain/models.dart';
import 'package:ant_colony_manager/domain/nuptial.dart';
import 'package:ant_colony_manager/features/species/species_screens.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  tearDown(() => setLanguage('de'));

  test('nuptial flight months from the care sheet text', () {
    expect(flightMonths('Juni – August'), [6, 7, 8]);
    expect(flightMonths('Mai-Juli'), [5, 6, 7]);
    expect(flightMonths('Juli'), [7]);
    expect(flightMonths('June – August'), [6, 7, 8]);
    expect(flightMonths('Mai – Juni, September'), [5, 6, 9]);
    expect(flightMonths('November bis Februar'), [1, 2, 11, 12]);
    expect(flightMonths('Aug. – Sept.'), [8, 9]);
    for (final vague in [
      'Herbst',
      'Herbst, nach den ersten Regenfällen',
      'Regenzeit',
      'Zu Beginn der Regenzeit',
      '',
      null,
    ]) {
      expect(flightMonths(vague), isNull, reason: '$vague');
    }
    expect(flightStarts([1, 2, 11, 12]), [11]);
    expect(flightStarts([5, 6, 9]), [5, 9]);
  });

  final lasius = Species({
    'id': 'l',
    'scientific_name': 'Lasius niger',
    'genus': 'Lasius',
    'german_name': 'Schwarzgraue Wegameise',
    'nuptial_flight': 'Juni – August',
    'translations': {
      'en': {'german_name': 'Black garden ant', 'nuptial_flight': 'June – August'},
    },
  });
  final fireAnt = Species({
    'id': 'f',
    'scientific_name': 'Solenopsis invicta',
    'genus': 'Solenopsis',
    'eu_invasive': true,
  });

  test('care sheet in the app language, German as fallback and for search', () {
    expect(lasius.germanName, 'Schwarzgraue Wegameise');
    setLanguage('en');
    expect(lasius.germanName, 'Black garden ant');
    expect(lasius.text('distribution'), isNull);
    expect(lasius.original('nuptial_flight'), 'Juni – August');
    expect(lasius.matches('wegameise'), isTrue);
    expect(lasius.matches('garden'), isTrue);
  });

  test('EU invasive species are recognised by link or free text', () {
    final catalog = [lasius, fireAnt];
    expect(invasiveSpeciesFor(catalog, speciesId: 'f'), fireAnt);
    expect(invasiveSpeciesFor(catalog, text: '  solenopsis   invicta  (Kolonie 2)'), fireAnt);
    expect(invasiveSpeciesFor(catalog, text: 'Solenopsis fugax'), isNull);
    expect(invasiveSpeciesFor(catalog, speciesId: 'l', text: 'Lasius niger'), isNull);
  });

  test('watched species: reminder in the first week of the flight season, once per year', () {
    final db = memoryDb();
    addTearDown(db.dispose);
    var now = DateTime(2026, 6, 2, 9);
    final repo = ColonyRepository(db, userId: 'u1', onChanged: () {}, clock: () => now);
    db.putRecord('species', {...lasius.json, 'owner_id': null});
    db.putRecord('user_settings', {'id': 'u1'});
    repo.setFlightWatch('l', true);
    final r = repo.reminders().where((r) => r.payload['kind'] == 'flight').single;
    expect(r.title, 'Schwarmflugzeit: Lasius niger');
    expect(r.key, 'flight:l:2026-6');
    now = DateTime(2026, 7, 2);
    expect(repo.reminders().where((r) => r.payload['kind'] == 'flight'), isEmpty, reason: 'July is not a start');
    now = DateTime(2026, 6, 10);
    expect(repo.reminders().where((r) => r.payload['kind'] == 'flight'), isEmpty, reason: 'only the first week');
    repo.setFlightWatch('l', false);
    now = DateTime(2026, 6, 2);
    expect(repo.reminders().where((r) => r.payload['kind'] == 'flight'), isEmpty);
  });
}
