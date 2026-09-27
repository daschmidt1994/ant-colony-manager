import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/session.dart';
import '../data/repositories/colony_repository.dart';
import '../domain/due.dart';
import '../domain/models.dart';

/// Repository of the signed-in user. Writes trigger a background sync.
final repositoryProvider = Provider<ColonyRepository?>((ref) {
  final auth = ref.watch(authProvider);
  if (auth is! SignedIn) return null;
  final engine = ref.watch(syncEngineProvider);
  return ColonyRepository(ref.read(databaseProvider), userId: auth.user.id, onChanged: () => engine?.schedule());
});

/// Helper: a query on the local DB that re-runs whenever records change.
Stream<T> _watch<T>(Ref ref, T Function(ColonyRepository repo) query) {
  final repo = ref.watch(repositoryProvider);
  if (repo == null) return const Stream.empty();
  return repo.db.watch(() => query(repo));
}

final coloniesProvider = StreamProvider<List<Colony>>((ref) => _watch(ref, (r) => r.colonies()));

final archivedColoniesProvider = StreamProvider<List<Colony>>(
  (ref) => _watch(ref, (r) => r.colonies(includeArchived: true).where((c) => c.archived).toList()),
);

final colonyProvider = StreamProvider.family<Colony?, String>((ref, id) => _watch(ref, (r) => r.colony(id)));

final colonyEventsProvider = StreamProvider.family<List<ColonyEvent>, String>(
  (ref, id) => _watch(ref, (r) => r.events(id)),
);

final colonyDueProvider = StreamProvider.family<List<DueTask>, String>((ref, id) => _watch(ref, (r) => r.due(id)));

final dueAllProvider = StreamProvider<Map<String, List<DueTask>>>((ref) => _watch(ref, (r) => r.dueAll()));

final dashboardProvider = StreamProvider<DashboardData>((ref) => _watch(ref, (r) => r.dashboard()));

final foodItemsProvider = StreamProvider<List<FoodItem>>((ref) => _watch(ref, (r) => r.foodItems()));

final locationsProvider = StreamProvider<List<Location>>((ref) => _watch(ref, (r) => r.locations()));

final scanLinksProvider = StreamProvider.family<List<ScanLink>, String>(
  (ref, id) => _watch(ref, (r) => r.scanLinks(id)),
);

final roleProvider = StreamProvider.family<String, String>((ref, id) => _watch(ref, (r) => r.roleOn(id)));

final schedulesProvider = StreamProvider.family<List<Schedule>, String>(
  (ref, id) => _watch(ref, (r) => r.schedules(colonyId: id)),
);

/// Species names already used – suggestions for the colony form.
final speciesSuggestionsProvider = StreamProvider<List<String>>(
  (ref) => _watch(ref, (r) {
    final names = <String>{
      for (final c in r.colonies(includeArchived: true))
        if (c.species.isNotEmpty) c.species,
    };
    return names.toList()..sort();
  }),
);

/// The care round in progress, if any.
final activeRoundProvider = StreamProvider<RoundProgress?>(
  (ref) => _watch(ref, (r) {
    final a = r.activeRound();
    return a == null ? null : r.roundProgress(a.id);
  }),
);

final roundSummaryProvider = StreamProvider.family<RoundSummary?, String>(
  (ref, id) => _watch(ref, (r) => r.roundSummary(id)),
);

final recentRoundsProvider = StreamProvider<List<RoundSummary>>(
  (ref) => _watch(ref, (r) => [for (final c in r.recentRounds()) ?r.roundSummary(c.id)]),
);

final colonyPhotosProvider = StreamProvider.family<List<Photo>, String>((ref, id) => _watch(ref, (r) => r.photos(id)));
