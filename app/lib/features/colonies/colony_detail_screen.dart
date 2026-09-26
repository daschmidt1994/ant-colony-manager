import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../domain/due.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';
import '../actions/actions.dart';
import '../timeline/timeline_screen.dart';

class ColonyDetailScreen extends ConsumerWidget {
  const ColonyDetailScreen({super.key, required this.colonyId});
  final String colonyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colony = ref.watch(colonyProvider(colonyId));
    return colony.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        body: EmptyState(icon: Icons.error_outline, title: 'Fehler', text: '$e'),
      ),
      data: (c) => c == null
          ? Scaffold(
              appBar: AppBar(),
              body: EmptyState(
                icon: Icons.search_off,
                title: 'Kolonie nicht gefunden',
                text: 'Sie wurde gelöscht oder nicht mehr mit dir geteilt.',
                action: FilledButton(onPressed: () => context.go('/colonies'), child: const Text('Zur Liste')),
              ),
            )
          : _ColonyPage(colony: c),
    );
  }
}

class _ColonyPage extends ConsumerWidget {
  const _ColonyPage({required this.colony});
  final Colony colony;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final due = ref.watch(colonyDueProvider(colony.id)).value ?? const <DueTask>[];
    final events = ref.watch(colonyEventsProvider(colony.id)).value ?? const <ColonyEvent>[];
    final role = ref.watch(roleProvider(colony.id)).value ?? 'owner';
    final canEdit = role != 'viewer';
    final isOwner = role == 'owner';
    final lastFeeding = events.where((e) => e.type == 'feeding').firstOrNull;
    final now = DateTime.now();

    DateTime? lastOf(String type) => events.where((e) => e.type == type).firstOrNull?.occurredAt;
    String? ago(DateTime? t) => t == null ? null : 'zuletzt ${S.relativeDay(t, now).toLowerCase()}';

    final askAcceptance =
        canEdit &&
        lastFeeding != null &&
        lastFeeding.acceptance == 'unknown' &&
        now.difference(lastFeeding.occurredAt).inHours < 72 &&
        now.difference(lastFeeding.occurredAt).inMinutes > 30;

    return Scaffold(
      appBar: AppBar(
        title: Text(colony.name),
        actions: [
          IconButton(
            tooltip: 'QR-Code',
            icon: const Icon(Icons.qr_code_2),
            onPressed: () => showQrSheet(context, ref, colony),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => _menu(context, ref, v),
            itemBuilder: (_) => [
              if (canEdit) const PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
              const PopupMenuItem(value: 'timeline', child: Text('Timeline')),
              if (canEdit) const PopupMenuItem(value: 'measure', child: Text('Messung erfassen')),
              if (isOwner)
                PopupMenuItem(value: 'archive', child: Text(colony.archived ? 'Aus Archiv holen' : 'Archivieren')),
              if (isOwner) const PopupMenuItem(value: 'delete', child: Text('Löschen')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          ContentWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(colony: colony),
                if (colony.archived)
                  _Banner(icon: Icons.archive_outlined, text: 'Archiviert', color: context.colors.muted),
                if (colony.status == 'hibernating')
                  _Banner(
                    icon: Icons.ac_unit,
                    text: 'Winterruhe – Erinnerungen angepasst',
                    color: context.colors.winter,
                  ),
                SectionHeader(
                  'Nächste Aufgaben',
                  trailing: canEdit
                      ? TextButton(
                          onPressed: () => context.go('/colonies/${colony.id}/edit'),
                          child: const Text('Intervalle'),
                        )
                      : null,
                ),
                if (due.isEmpty)
                  Text('Keine Pflegeintervalle festgelegt.', style: TextStyle(color: context.colors.muted))
                else
                  for (final t in due) DueRow(t),
                if (canEdit) ...[
                  if (lastFeeding != null) ...[
                    const SizedBox(height: 16),
                    Card(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      child: ListTile(
                        leading: const Icon(Icons.replay),
                        title: Text(S.eventSummary(lastFeeding), maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: const Text('Letzte Fütterung wiederholen'),
                        trailing: const Icon(Icons.check_circle_outline),
                        onTap: () => repeatFeeding(context, ref, colony),
                      ),
                    ),
                  ],
                  const SectionHeader('Schnellaktionen'),
                  GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1.15,
                    children: [
                      QuickActionTile(
                        icon: Icons.pest_control_outlined,
                        label: 'Füttern',
                        subtitle: ago(lastFeeding?.occurredAt),
                        onTap: () => showFeedingSheet(context, ref, colony),
                      ),
                      QuickActionTile(
                        icon: Icons.water_drop_outlined,
                        label: 'Wasser',
                        subtitle: ago(lastOf('water')),
                        onTap: () => quickWater(context, ref, colony),
                        onLongPress: () => showWaterSheet(context, ref, colony),
                      ),
                      QuickActionTile(
                        icon: Icons.cleaning_services_outlined,
                        label: 'Reinigen',
                        subtitle: ago(lastOf('cleaning')),
                        onTap: () => showCleaningSheet(context, ref, colony),
                      ),
                      QuickActionTile(
                        icon: Icons.visibility_outlined,
                        label: 'Kontrolle',
                        subtitle: ago(lastOf('check')),
                        onTap: () => quickCheck(context, ref, colony),
                        onLongPress: () => showNoteSheet(context, ref, colony, type: 'check'),
                      ),
                      QuickActionTile(
                        icon: Icons.sticky_note_2_outlined,
                        label: 'Notiz',
                        onTap: () => showNoteSheet(context, ref, colony),
                      ),
                      QuickActionTile(
                        icon: Icons.thermostat_outlined,
                        label: 'Messung',
                        subtitle: ago(lastOf('measurement')),
                        onTap: () => showMeasurementSheet(context, ref, colony),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Wasser und Kontrolle speichern sofort – lange drücken für Details.',
                    style: TextStyle(color: context.colors.muted, fontSize: 12),
                  ),
                ],
                if (askAcceptance) ...[
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Fütterung von ${S.relativeDay(lastFeeding.occurredAt, now).toLowerCase()} angenommen?',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            children: [
                              for (final a in const ['accepted', 'partial', 'ignored'])
                                ActionChip(
                                  label: Text(S.acceptance[a]!),
                                  onPressed: () => ref.read(repositoryProvider)!.setAcceptance(lastFeeding.id, a),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                SectionHeader(
                  'Timeline',
                  trailing: TextButton(
                    onPressed: () => context.go('/colonies/${colony.id}/timeline'),
                    child: const Text('Alle'),
                  ),
                ),
                if (events.isEmpty)
                  Text('Noch keine Einträge.', style: TextStyle(color: context.colors.muted))
                else
                  Card(
                    child: Column(
                      children: [for (final e in events.take(8)) EventTile(event: e, canEdit: canEdit)],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _menu(BuildContext context, WidgetRef ref, String v) async {
    final repo = ref.read(repositoryProvider)!;
    switch (v) {
      case 'edit':
        context.go('/colonies/${colony.id}/edit');
      case 'timeline':
        context.go('/colonies/${colony.id}/timeline');
      case 'measure':
        showMeasurementSheet(context, ref, colony);
      case 'archive':
        repo.archiveColony(colony.id, !colony.archived);
        showUndoSnack(
          context,
          colony.archived ? 'Aus dem Archiv geholt' : 'Archiviert',
          onUndo: () => repo.archiveColony(colony.id, colony.archived),
        );
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('${colony.name} löschen?'),
            content: const Text(
              'Die Kolonie und ihre Timeline verschwinden auf allen Geräten. '
              'Archivieren behält die Daten.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: context.colors.overdue),
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Löschen'),
              ),
            ],
          ),
        );
        if (ok == true && context.mounted) {
          repo.deleteColony(colony.id);
          context.go('/colonies');
        }
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.colony});
  final Colony colony;

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: context.colors.muted);
    final facts = <(IconData, String)>[
      if (colony.queenCount != null)
        (Icons.workspace_premium_outlined, '${colony.queenCount} ${colony.queenCount == 1 ? 'Königin' : 'Königinnen'}'),
      if (colony.workerMin != null || colony.workerMax != null)
        (Icons.groups_outlined, 'ca. ${S.workers(colony.workerMin, colony.workerMax)}'),
      if (colony.lastTemperature != null) (Icons.thermostat_outlined, '${S.decimal(colony.lastTemperature!)} °C'),
      if (colony.lastHumidity != null) (Icons.water_drop_outlined, '${colony.lastHumidity!.round()} %'),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (colony.species.isNotEmpty)
            Text(colony.species, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontStyle: FontStyle.italic)),
          Text(
            [
              'Kolonie #${colony.number}',
              if (colony.locationPath != null) colony.locationPath!,
              S.statusNames[colony.status] ?? colony.status,
            ].join(' · '),
            style: muted,
          ),
          if (facts.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                for (final (icon, text) in facts)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 18, color: context.colors.muted),
                      const SizedBox(width: 4),
                      Text(text),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    ),
  );
}

/// QR code of the colony (label printing follows with the QR/NFC update).
Future<void> showQrSheet(BuildContext context, WidgetRef ref, Colony colony) {
  final auth = ref.read(authProvider);
  final server = auth is SignedIn ? auth.serverUrl : '';
  final link =
      ref.read(scanLinksProvider(colony.id)).value?.where((l) => l.kind == 'qr' && l.active).firstOrNull ??
      ref.read(repositoryProvider)!.scanLinks(colony.id).where((l) => l.kind == 'qr' && l.active).firstOrNull;
  return showModalBottomSheet<void>(
    context: context,
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: link == null
            ? const Text('Diese Kolonie hat noch keinen aktiven QR-Code.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(colony.name, style: Theme.of(c).textTheme.titleLarge),
                  if (colony.species.isNotEmpty)
                    Text(colony.species, style: const TextStyle(fontStyle: FontStyle.italic)),
                  const SizedBox(height: 16),
                  Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(12),
                    child: QrImageView(data: '$server/c/${link.token}', size: 220, backgroundColor: Colors.white),
                  ),
                  const SizedBox(height: 12),
                  SelectableText('$server/c/${link.token}', textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: '$server/c/${link.token}'));
                      Navigator.pop(c);
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link kopiert')));
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Link kopieren'),
                  ),
                ],
              ),
      ),
    ),
  );
}
