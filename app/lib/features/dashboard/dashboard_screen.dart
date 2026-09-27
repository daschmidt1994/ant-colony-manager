import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../data/repositories/colony_repository.dart';
import '../../domain/due.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(dashboardProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Übersicht'), actions: const [SyncBadge()]),
      body: RefreshIndicator(
        onRefresh: () async => ref.read(syncEngineProvider)?.sync(resetBackoff: true),
        child: data.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => EmptyState(icon: Icons.error_outline, title: 'Fehler', text: '$e'),
          data: (d) => d.colonies.isEmpty ? const _Welcome() : _Dashboard(d),
        ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome();
  @override
  Widget build(BuildContext context) => ListView(
    children: [
      const SizedBox(height: 60),
      EmptyState(
        icon: Icons.hive_outlined,
        title: 'Willkommen!',
        text: 'Lege deine erste Kolonie an. Sie bekommt automatisch einen QR-Code.',
        action: FilledButton.icon(
          onPressed: () => context.go('/colonies/new'),
          icon: const Icon(Icons.add),
          label: const Text('Erste Kolonie anlegen'),
        ),
      ),
    ],
  );
}

class _Dashboard extends StatelessWidget {
  const _Dashboard(this.d);
  final DashboardData d;

  static const _groups = [
    (DueGroup.overdue, 'Überfällig', true),
    (DueGroup.today, 'Heute', true),
    (DueGroup.tomorrow, 'Morgen', false),
    (DueGroup.thisWeek, 'Diese Woche', false),
    (DueGroup.later, 'Später', false),
  ];

  @override
  Widget build(BuildContext context) {
    final byId = {for (final c in d.colonies) c.id: c};
    final grouped = <DueGroup, List<(Colony, List<DueTask>)>>{};
    d.due.forEach((id, tasks) {
      final w = worstOf(tasks);
      final c = byId[id];
      if (w != null && c != null) (grouped[w.classification.group] ??= []).add((c, tasks));
    });
    for (final l in grouped.values) {
      l.sort((a, b) => worstOf(a.$2)!.days.compareTo(worstOf(b.$2)!.days));
    }
    final active = d.count('active') + d.count('founding');
    final overdue = grouped[DueGroup.overdue]?.length ?? 0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        ContentWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _Stat(value: '$active', label: 'aktiv', icon: Icons.pest_control_outlined),
                  const SizedBox(width: 12),
                  _Stat(
                    value: '${d.count('hibernating')}',
                    label: 'Winterruhe',
                    icon: Icons.ac_unit,
                    color: context.colors.winter,
                  ),
                  const SizedBox(width: 12),
                  _Stat(
                    value: '$overdue',
                    label: 'überfällig',
                    icon: Icons.error_outline,
                    color: overdue > 0 ? context.colors.overdue : null,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _RoundCard(needsAttention: d.needsAttention),
              for (final (group, title, open) in _groups)
                if (grouped[group]?.isNotEmpty == true)
                  _GroupSection(
                    title: title,
                    initiallyOpen: open,
                    entries: grouped[group]!,
                    color: _groupColor(context, group),
                  ),
              if (d.hibernating.isNotEmpty) ...[
                const SectionHeader('Winterruhe'),
                Card(
                  child: Column(
                    children: [
                      for (final (c, since) in d.hibernating)
                        ListTile(
                          leading: Icon(Icons.ac_unit, color: context.colors.winter),
                          title: Text(c.name),
                          subtitle: Text(
                            since == null
                                ? c.species
                                : '${c.species} · seit ${DateTime.now().difference(since).inDays} Tagen',
                          ),
                          onTap: () => context.go('/colonies/${c.id}'),
                        ),
                    ],
                  ),
                ),
              ],
              if (d.recent.isNotEmpty) ...[
                const SectionHeader('Letzte Aktivitäten'),
                Card(
                  child: Column(
                    children: [
                      for (final (e, c) in d.recent)
                        ListTile(
                          dense: true,
                          leading: Icon(eventIcon(e.type)),
                          title: Text(S.eventSummary(e), maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${c!.name} · ${S.relativeDay(e.occurredAt, DateTime.now())} ${S.time(e.occurredAt)}',
                          ),
                          onTap: () => context.go('/colonies/${c.id}'),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Color? _groupColor(BuildContext context, DueGroup g) => switch (g) {
    DueGroup.overdue => context.colors.overdue,
    DueGroup.today || DueGroup.tomorrow => context.colors.soon,
    _ => null,
  };
}

/// „Pflege-Rundgang starten“ – or continue the one in progress.
class _RoundCard extends ConsumerWidget {
  const _RoundCard({required this.needsAttention});
  final int needsAttention;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeRoundProvider).value;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: active != null || needsAttention > 0 ? scheme.primaryContainer : null,
      child: ListTile(
        leading: Icon(active != null ? Icons.play_circle_outline : Icons.route_outlined, color: scheme.primary),
        title: Text(
          active != null ? 'Rundgang fortsetzen (${active.visited}/${active.total})' : 'Pflege-Rundgang starten',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: active != null
            ? null
            : Text(
                needsAttention > 0
                    ? '$needsAttention ${needsAttention == 1 ? 'Kolonie braucht' : 'Kolonien brauchen'} heute Pflege'
                    : 'Heute ist nichts fällig',
              ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.go('/round'),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.icon, this.color});
  final String value, label;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        child: Column(
          children: [
            Icon(icon, color: color ?? context.colors.muted, size: 20),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: color),
            ),
            Text(label, style: TextStyle(color: context.colors.muted, fontSize: 13)),
          ],
        ),
      ),
    ),
  );
}

class _GroupSection extends StatelessWidget {
  const _GroupSection({required this.title, required this.initiallyOpen, required this.entries, this.color});
  final String title;
  final bool initiallyOpen;
  final List<(Colony, List<DueTask>)> entries;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: initiallyOpen,
        shape: const Border(),
        title: Text(
          '$title · ${entries.length}',
          style: TextStyle(fontWeight: FontWeight.w700, color: color, letterSpacing: .3),
        ),
        children: [for (final (c, tasks) in entries) ColonyDueTile(colony: c, tasks: tasks)],
      ),
    ),
  );
}

/// Colony row with its most urgent tasks (used on dashboard and list).
class ColonyDueTile extends StatelessWidget {
  const ColonyDueTile({super.key, required this.colony, required this.tasks, this.showAll = false});
  final Colony colony;
  final List<DueTask> tasks;
  final bool showAll;

  @override
  Widget build(BuildContext context) {
    final shown = tasks.where((t) => showAll || t.status == DueStatus.overdue || t.status == DueStatus.soon).take(3);
    final worst = worstOf(tasks);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        radius: 6,
        backgroundColor: colony.status == 'hibernating'
            ? context.colors.winter
            : worst == null
            ? context.colors.muted
            : context.colors.due(worst.status),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(colony.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (colony.locationPath != null)
            Flexible(
              child: Text(
                colony.locationPath!,
                style: TextStyle(color: context.colors.muted, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (colony.species.isNotEmpty && colony.species != colony.name)
            Text(colony.species, style: const TextStyle(fontStyle: FontStyle.italic)),
          if (shown.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [for (final t in shown) DueChip(t)]),
          ],
        ],
      ),
      onTap: () => context.go('/colonies/${colony.id}'),
    );
  }
}
