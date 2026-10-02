import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/session.dart';
import 'i18n.dart';
import '../data/repositories/colony_repository.dart';
import '../domain/due.dart';
import '../domain/food_stock.dart';
import '../domain/models.dart';

/// Repository of the signed-in user. Writes trigger a background sync.
final repositoryProvider = Provider<ColonyRepository?>((ref) {
  final auth = ref.watch(authProvider);
  if (auth is! SignedIn) return null;
  final engine = ref.watch(syncEngineProvider);
  return ColonyRepository(ref.read(databaseProvider), userId: auth.user.id, onChanged: () => engine?.schedule());
});

/// A query on the local DB that re-runs whenever records change. Per-colony
/// queries are autoDispose: a colony page that was left must not keep
/// re-running its queries on every change.
Stream<T> watchRepo<T>(Ref ref, T Function(ColonyRepository repo) query) => _watch(ref, query);

Stream<T> _watch<T>(Ref ref, T Function(ColonyRepository repo) query) {
  final repo = ref.watch(repositoryProvider);
  if (repo == null) return const Stream.empty();
  return repo.db.watch(() => query(repo));
}

final coloniesProvider = StreamProvider<List<Colony>>((ref) => _watch(ref, (r) => r.colonies()));

final archivedColoniesProvider = StreamProvider<List<Colony>>(
  (ref) => _watch(ref, (r) => r.colonies(includeArchived: true).where((c) => c.archived).toList()),
);

final colonyProvider = StreamProvider.autoDispose.family<Colony?, String>(
  (ref, id) => _watch(ref, (r) => r.colony(id)),
);

final colonyEventsProvider = StreamProvider.autoDispose.family<List<ColonyEvent>, String>(
  (ref, id) => _watch(ref, (r) => r.events(id)),
);

final colonyDueProvider = StreamProvider.autoDispose.family<List<DueTask>, String>(
  (ref, id) => _watch(ref, (r) => r.due(id)),
);

final colonyWinterProvider = StreamProvider.autoDispose.family<WinterRest?, String>(
  (ref, id) => _watch(ref, (r) => r.winterRest(id)),
);

final dueAllProvider = StreamProvider<Map<String, List<DueTask>>>((ref) => _watch(ref, (r) => r.dueAll()));

final dashboardProvider = StreamProvider<DashboardData>((ref) => _watch(ref, (r) => r.dashboard()));

final foodStocksProvider = StreamProvider<List<FoodStock>>((ref) => _watch(ref, (r) => r.foodStocks()));

final foodItemsProvider = StreamProvider<List<FoodItem>>((ref) => _watch(ref, (r) => r.foodItems()));

final locationsProvider = StreamProvider<List<Location>>((ref) => _watch(ref, (r) => r.locations()));

final scanLinksProvider = StreamProvider.autoDispose.family<List<ScanLink>, String>(
  (ref, id) => _watch(ref, (r) => r.scanLinks(id)),
);

final roleProvider = StreamProvider.autoDispose.family<String, String>((ref, id) => _watch(ref, (r) => r.roleOn(id)));

final schedulesProvider = StreamProvider.autoDispose.family<List<Schedule>, String>(
  (ref, id) => _watch(ref, (r) => r.schedules(colonyId: id)),
);

final speciesListProvider = StreamProvider<List<Species>>((ref) => _watch(ref, (r) => r.species()));

final speciesProvider = StreamProvider.autoDispose.family<Species?, String>(
  (ref, id) => _watch(ref, (r) => r.speciesById(id)),
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

final roundSummaryProvider = StreamProvider.autoDispose.family<RoundSummary?, String>(
  (ref, id) => _watch(ref, (r) => r.roundSummary(id)),
);

final recentRoundsProvider = StreamProvider<List<RoundSummary>>(
  (ref) => _watch(ref, (r) => [for (final c in r.recentRounds()) ?r.roundSummary(c.id)]),
);

final colonyPhotosProvider = StreamProvider.autoDispose.family<List<Photo>, String>(
  (ref, id) => _watch(ref, (r) => r.photos(id)),
);

final settingsProvider = StreamProvider<UserSettings>((ref) => _watch(ref, (r) => r.settings()));

/// Language setting of this device: the synced user setting once signed in,
/// before that the last choice on this device ('system' = device language).
final languageSettingProvider = Provider<String>((ref) {
  final synced = ref.watch(settingsProvider).value?.locale;
  return synced ?? ref.read(databaseProvider).getMeta(languageMetaKey) ?? 'system';
});

/// The language actually shown.
final languageProvider = Provider<String>((ref) => resolveLanguage(ref.watch(languageSettingProvider)));

const languageMetaKey = 'language';

/// Server capabilities (e.g. whether it can send e-mail). Null when offline.
final instanceInfoProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  try {
    return await ref.read(authProvider.notifier).api.public('GET', '/api/v1/instance') as Map<String, dynamic>;
  } on Exception {
    return null;
  }
});
