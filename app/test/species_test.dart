import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/domain/models.dart';
import 'package:ant_colony_manager/features/species/species_screens.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  final nico = Species({
    'id': 's1',
    'owner_id': null,
    'scientific_name': 'Camponotus nicobarensis',
    'genus': 'Camponotus',
    'german_name': null,
    'temp_nest_min': 24.0,
    'temp_nest_max': 28.0,
    'humidity_nest_min': 50,
    'humidity_nest_max': 70,
    'hibernation': 'none',
    'difficulty': 1,
    'sources': [
      {'title': 'AntWiki', 'url': 'https://www.antwiki.org/wiki/Camponotus_nicobarensis'},
      {'title': 'Buch'},
      {'url': 'no title – skipped'},
    ],
  });

  test('care summary and ranges', () {
    expect(speciesSummary(nico), 'Nest 24–28 °C · 50–70 % · Winterruhe keine · Einsteiger');
    expect(rangeText(null, null, '°C'), isNull);
    expect(rangeText(5, null, '°C'), 'ab 5 °C');
    expect(rangeText(null, 8.5, '°C'), 'bis 8,5 °C');
    expect(rangeText(20, 20, '%'), '20 %');
    expect(speciesSummary(Species({'id': 'x', 'scientific_name': 'Y z'})), '');
  });

  test('search matches scientific name, German name and genus', () {
    final niger = Species({
      'id': 'n',
      'scientific_name': 'Lasius niger',
      'genus': 'Lasius',
      'german_name': 'Schwarzgraue Wegameise',
    });
    expect(niger.matches('wegameise'), isTrue);
    expect(niger.matches('LASIUS'), isTrue);
    expect(niger.matches(' '), isTrue);
    expect(niger.matches('messor'), isFalse);
    expect(nico.isCatalog, isTrue);
    expect(nico.sources.map((s) => s.title), ['AntWiki', 'Buch']);
  });

  test('sources round-trip through the text field', () {
    final list = sourcesFromText('AntWiki | https://a.org/x\n\nSeifert 2018\nhttps://b.org\n | https://c.org');
    expect(list, [
      {'title': 'AntWiki', 'url': 'https://a.org/x'},
      {'title': 'Seifert 2018'},
      {'title': 'https://b.org', 'url': 'https://b.org'},
      {'title': 'https://c.org', 'url': 'https://c.org'},
    ]);
    expect(sourcesToText(nico.sources), 'AntWiki | https://www.antwiki.org/wiki/Camponotus_nicobarensis\nBuch');
  });

  group('repository', () {
    late AppDatabase db;
    late ColonyRepository repo;
    setUp(() {
      db = memoryDb();
      repo = ColonyRepository(db, userId: 'u1', onChanged: () {});
      db.putRecord('species', nico.json);
    });
    tearDown(() => db.dispose());

    test('colonies show the linked species name; own species sync as creates', () {
      final c = repo.createColony({'name': 'Nico #1', 'species_id': 's1', 'species_text': 'Camponotus nicobarensis'});
      expect(repo.colony(c)!.species, 'Camponotus nicobarensis');
      expect(repo.colony(c)!.speciesId, 's1');

      final own = repo.createSpecies({'scientific_name': 'Camponotus sp. rot', 'difficulty': 2});
      expect(repo.species().map((s) => s.scientificName), ['Camponotus nicobarensis', 'Camponotus sp. rot']);
      expect(repo.speciesById(own)!.isCatalog, isFalse);
      repo.updateSpecies(own, {'notes': 'aus Thailand'});
      expect(repo.speciesById(own)!.text('notes'), 'aus Thailand');
      repo.deleteSpecies(own);
      expect(repo.speciesById(own), isNull);
    });
  });
}
