import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/domain/models.dart';
import 'package:ant_colony_manager/features/species/species_screens.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  final catalog = [
    Species({'id': 'n', 'scientific_name': 'Lasius niger', 'genus': 'Lasius', 'german_name': 'Schwarzgraue Wegameise'}),
    Species({'id': 'f', 'scientific_name': 'Lasius flavus', 'genus': 'Lasius', 'german_name': 'Gelbe Wiesenameise'}),
    Species({'id': 'm', 'scientific_name': 'Messor barbarus', 'genus': 'Messor'}),
  ];

  test('edit distance', () {
    expect(editDistance('lassius niger', 'lasius niger'), 1);
    expect(editDistance('', 'abc'), 3);
    expect(editDistance('messor', 'messor'), 0);
  });

  test('suggestions: typos find the right species, partial matches first', () {
    expect(speciesSuggestions(catalog, 'Lassius niger').first.id, 'n');
    expect(speciesSuggestions(catalog, 'Mesor barbarus').map((s) => s.id), ['m']);
    expect(speciesSuggestions(catalog, 'lasius').map((s) => s.id), ['n', 'f']);
    expect(speciesSuggestions(catalog, 'wiesenameise').map((s) => s.id), ['f']);
    expect(speciesSuggestions(catalog, 'Camponotus ligniperda'), isEmpty);
    expect(speciesSuggestions(catalog, ''), hasLength(3));
  });

  test('link and unlink a colony; undo restores the previous fields', () {
    final AppDatabase db = memoryDb();
    final repo = ColonyRepository(db, userId: 'u1', onChanged: () {});
    for (final s in catalog) {
      db.putRecord('species', s.json);
    }
    final c = repo.createColony({'name': 'Lassius #2', 'species_text': 'Lassius niger'});
    final before = repo.linkSpecies(c, catalog.first);
    expect(repo.colony(c)!.speciesId, 'n');
    expect(repo.colony(c)!.species, 'Lasius niger'); // catalog spelling
    expect(before, {'species_id': null, 'species_text': 'Lassius niger'});

    repo.unlinkSpecies(c);
    expect(repo.colony(c)!.speciesId, isNull);
    expect(repo.colony(c)!.species, 'Lasius niger'); // the name stays

    repo.updateColony(c, before); // „Rückgängig“ of the first link
    expect(repo.colony(c)!.species, 'Lassius niger');
    db.dispose();
  });
}
