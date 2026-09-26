import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/due.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';
import '../dashboard/dashboard_screen.dart';

enum ColonyFilter { active, founding, hibernating, due, archived }

/// Pure filtering/sorting, unit-tested.
List<Colony> filterColonies(List<Colony> colonies, Map<String, List<DueTask>> due, String query, Set<ColonyFilter> f) {
  final q = query.trim().toLowerCase();
  final number = int.tryParse(q.startsWith('#') ? q.substring(1) : q);
  bool matches(Colony c) {
    if (q.isEmpty) return true;
    if (number != null && c.number == number) return true;
    return [
      c.name,
      c.species,
      c.internalCode ?? '',
      c.locationPath ?? '',
      c.notes ?? '',
    ].any((s) => s.toLowerCase().contains(q));
  }

  bool passes(Colony c) {
    if (f.contains(ColonyFilter.archived) != c.archived) return false;
    final statusFilters = {
      if (f.contains(ColonyFilter.active)) 'active',
      if (f.contains(ColonyFilter.founding)) 'founding',
      if (f.contains(ColonyFilter.hibernating)) 'hibernating',
    };
    if (statusFilters.isNotEmpty && !statusFilters.contains(c.status)) return false;
    if (f.contains(ColonyFilter.due) && (worstOf(due[c.id] ?? const [])?.days ?? 99) > 0) return false;
    return true;
  }

  int urgency(Colony c) => worstOf(due[c.id] ?? const [])?.days ?? 1 << 20;
  return colonies.where((c) => matches(c) && passes(c)).toList()..sort((a, b) {
    final u = urgency(a).compareTo(urgency(b));
    return u != 0 ? u : a.number.compareTo(b.number);
  });
}

class ColonyListScreen extends ConsumerStatefulWidget {
  const ColonyListScreen({super.key});
  @override
  ConsumerState<ColonyListScreen> createState() => _ColonyListScreenState();
}

class _ColonyListScreenState extends ConsumerState<ColonyListScreen> {
  final _search = TextEditingController();
  final _filters = <ColonyFilter>{};

  static const _labels = {
    ColonyFilter.active: 'Aktiv',
    ColonyFilter.founding: 'Gründung',
    ColonyFilter.hibernating: 'Winterruhe',
    ColonyFilter.due: 'Fällig',
    ColonyFilter.archived: 'Archiv',
  };

  @override
  Widget build(BuildContext context) {
    final archived = _filters.contains(ColonyFilter.archived);
    final colonies = ref.watch(archived ? archivedColoniesProvider : coloniesProvider).value ?? const [];
    final due = ref.watch(dueAllProvider).value ?? const {};
    final list = filterColonies(colonies, due, _search.text, _filters);

    return Scaffold(
      appBar: AppBar(title: Text('Kolonien (${colonies.length})'), actions: const [SyncBadge()]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/colonies/new'),
        icon: const Icon(Icons.add),
        label: const Text('Kolonie'),
      ),
      body: ContentWidth(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Name, Art, Standort, #Nummer',
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(_search.clear)),
                ),
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final f in ColonyFilter.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(_labels[f]!),
                        selected: _filters.contains(f),
                        onSelected: (v) => setState(() => v ? _filters.add(f) : _filters.remove(f)),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? EmptyState(
                      icon: Icons.search_off,
                      title: colonies.isEmpty ? 'Noch keine Kolonien' : 'Keine Treffer',
                      action: colonies.isEmpty
                          ? FilledButton(
                              onPressed: () => context.go('/colonies/new'),
                              child: const Text('Kolonie anlegen'),
                            )
                          : null,
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const Divider(indent: 16, endIndent: 16),
                      itemBuilder: (_, i) => ColonyDueTile(colony: list[i], tasks: due[list[i].id] ?? const []),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
