import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../data/repositories/colony_repository.dart';
import '../../nfc/nfc_controller.dart';
import '../../nfc/nfc_driver.dart';
import '../../domain/due.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';
import '../actions/actions.dart';
import '../actions/defer.dart';
import '../care_cover/care_cover_screen.dart';
import '../photos/photos.dart';
import '../reports/report_action.dart';
import '../species/species_screens.dart';
import '../timeline/timeline_screen.dart';
import '../../app/i18n.dart';

class ColonyDetailScreen extends ConsumerWidget {
  const ColonyDetailScreen({super.key, required this.colonyId});
  final String colonyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colony = ref.watch(colonyProvider(colonyId));
    return colony.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        body: EmptyState(icon: Icons.error_outline, title: tr('Fehler'), text: '$e'),
      ),
      data: (c) => c == null
          ? Scaffold(
              appBar: AppBar(),
              body: EmptyState(
                icon: Icons.search_off,
                title: tr('Kolonie nicht gefunden'),
                text: tr('Sie wurde gelöscht oder nicht mehr mit dir geteilt.'),
                action: FilledButton(onPressed: () => context.go('/colonies'), child: Text(tr('Zur Liste'))),
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
    final photos = ref.watch(colonyPhotosProvider(colony.id)).value ?? const <Photo>[];
    final byEvent = photosByEvent(photos);
    final now = DateTime.now();

    DateTime? lastOf(String type) => events.where((e) => e.type == type).firstOrNull?.occurredAt;
    String? ago(DateTime? t) => t == null ? null : tr('zuletzt {0}', [S.relativeDayInline(t, now)]);

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
              if (canEdit) PopupMenuItem(value: 'backdate', child: Text(tr('Nachtragen …'))),
              if (canEdit) PopupMenuItem(value: 'edit', child: Text(tr('Bearbeiten'))),
              PopupMenuItem(value: 'timeline', child: Text(tr('Timeline'))),
              if (canEdit) PopupMenuItem(value: 'measure', child: Text(tr('Messung erfassen'))),
              if (canEdit) PopupMenuItem(value: 'census', child: Text(tr('Größe & Brut erfassen'))),
              PopupMenuItem(value: 'stats', child: Text(tr('Statistik'))),
              PopupMenuItem(value: 'report', child: Text(tr('Bericht als PDF'))),
              if (canEdit && ref.read(nfcControllerProvider) != NfcState.unsupported)
                PopupMenuItem(value: 'nfc', child: Text(tr('NFC-Tag zuweisen'))),
              PopupMenuItem(value: 'label', child: Text(tr('Etikett drucken'))),
              if (isOwner)
                PopupMenuItem(
                  value: 'archive',
                  child: Text(colony.archived ? tr('Aus Archiv holen') : tr('Archivieren')),
                ),
              if (isOwner) PopupMenuItem(value: 'delete', child: Text(tr('Löschen'))),
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
                _SpeciesCard(colony: colony, canEdit: canEdit),
                CareCoverBanner(colonyId: colony.id),
                if (colony.archived)
                  _Banner(icon: Icons.archive_outlined, text: tr('Archiviert'), color: context.colors.muted),
                if (!(canEdit && colony.isCareActive) && colony.status == 'hibernating')
                  _Banner(
                    icon: Icons.ac_unit,
                    text: tr('Winterruhe – Erinnerungen angepasst'),
                    color: context.colors.winter,
                  ),
                SectionHeader(
                  tr('Nächste Aufgaben'),
                  trailing: canEdit
                      ? TextButton(
                          onPressed: () => context.go('/colonies/${colony.id}/edit'),
                          child: Text(tr('Intervalle')),
                        )
                      : null,
                ),
                if (due.isEmpty)
                  Text(tr('Keine Pflegeintervalle festgelegt.'), style: TextStyle(color: context.colors.muted))
                else
                  for (final t in due)
                    DueRow(
                      t,
                      onSnooze: canEdit
                          ? () {
                              final repo = ref.read(repositoryProvider)!;
                              final previous = repo.snoozeSchedule(t.schedule.id);
                              showUndoSnack(
                                context,
                                tr('Auf morgen verschoben'),
                                onUndo: () => repo.setScheduleSnooze(t.schedule.id, previous),
                              );
                            }
                          : null,
                      onDefer: canEdit ? () => showDeferSheet(context, ref, t) : null,
                    ),
                if (canEdit) ...[
                  if (lastFeeding != null) ...[
                    const SizedBox(height: 16),
                    Card(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      child: ListTile(
                        leading: const Icon(Icons.replay),
                        title: Text(S.eventSummary(lastFeeding), maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(tr('Letzte Fütterung wiederholen')),
                        trailing: const Icon(Icons.check_circle_outline),
                        onTap: () => repeatFeeding(context, ref, colony),
                      ),
                    ),
                  ],
                  SectionHeader(tr('Schnellaktionen')),
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
                        label: tr('Füttern'),
                        subtitle: ago(lastFeeding?.occurredAt),
                        onTap: () => showFeedingSheet(context, ref, colony),
                      ),
                      QuickActionTile(
                        icon: Icons.water_drop_outlined,
                        label: tr('Wasser'),
                        subtitle: ago(lastOf('water')),
                        onTap: () => quickWater(context, ref, colony),
                        onLongPress: () => showWaterSheet(context, ref, colony),
                      ),
                      QuickActionTile(
                        icon: Icons.cleaning_services_outlined,
                        label: tr('Reinigen'),
                        subtitle: ago(lastOf('cleaning')),
                        onTap: () => showCleaningSheet(context, ref, colony),
                      ),
                      QuickActionTile(
                        icon: Icons.visibility_outlined,
                        label: tr('Kontrolle'),
                        subtitle: ago(lastOf('check')),
                        onTap: () => quickCheck(context, ref, colony),
                        onLongPress: () => showNoteSheet(context, ref, colony, type: 'check'),
                      ),
                      QuickActionTile(
                        icon: Icons.sticky_note_2_outlined,
                        label: tr('Notiz'),
                        onTap: () => showNoteSheet(context, ref, colony),
                      ),
                      QuickActionTile(
                        icon: Icons.photo_camera_outlined,
                        label: tr('Foto'),
                        subtitle: photos.isEmpty ? null : '${photos.length}',
                        onTap: () => addPhotos(context, ref, colony),
                      ),
                      QuickActionTile(
                        icon: Icons.thermostat_outlined,
                        label: tr('Messung'),
                        subtitle: ago(lastOf('measurement')),
                        onTap: () => showMeasurementSheet(context, ref, colony),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr(
                      'Wasser und Kontrolle speichern sofort – lange drücken für Details. '
                      'Vergessen einzutragen? Menü oben rechts → Nachtragen, oder im Dialog auf „Jetzt“ tippen.',
                    ),
                    style: TextStyle(color: context.colors.muted, fontSize: 12),
                  ),
                  if (colony.isCareActive) _WinterCard(colony: colony),
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
                            tr('Fütterung von {0} angenommen?', [S.relativeDayInline(lastFeeding.occurredAt, now)]),
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
                if (photos.isNotEmpty) ...[
                  SectionHeader(
                    tr('Fotos · {0}', [photos.length]),
                    trailing: TextButton(
                      onPressed: () => context.go('/colonies/${colony.id}/photos'),
                      child: Text(tr('Galerie')),
                    ),
                  ),
                  PhotoStrip(photos: photos.take(12).toList(), size: 88),
                ],
                SectionHeader(
                  tr('Timeline'),
                  trailing: TextButton(
                    onPressed: () => context.go('/colonies/${colony.id}/timeline'),
                    child: Text(tr('Alle')),
                  ),
                ),
                if (events.isEmpty)
                  Text(tr('Noch keine Einträge.'), style: TextStyle(color: context.colors.muted))
                else
                  Card(
                    child: Column(
                      children: [
                        for (final e in events.take(8))
                          EventTile(event: e, canEdit: canEdit, photos: byEvent[e.id] ?? const []),
                      ],
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
      case 'backdate':
        showBackdateFlow(context, ref, colony);
      case 'edit':
        context.go('/colonies/${colony.id}/edit');
      case 'timeline':
        context.go('/colonies/${colony.id}/timeline');
      case 'nfc':
        context.push('/colonies/${colony.id}/nfc');
      case 'label':
        context.push('/settings/labels?colony=${colony.id}');
      case 'measure':
        showMeasurementSheet(context, ref, colony);
      case 'census':
        showCensusSheet(context, ref, colony);
      case 'stats':
        context.go('/colonies/${colony.id}/stats');
      case 'report':
        openColonyReport(context, ref, colony);
      case 'archive':
        repo.archiveColony(colony.id, !colony.archived);
        showUndoSnack(
          context,
          colony.archived ? tr('Aus dem Archiv geholt') : tr('Archiviert'),
          onUndo: () => repo.archiveColony(colony.id, colony.archived),
        );
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(tr('{0} löschen?', [colony.name])),
            content: Text(
              tr(
                'Die Kolonie und ihre Timeline verschwinden auf allen Geräten. '
                'Archivieren behält die Daten.',
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Abbrechen'))),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: context.colors.overdue),
                onPressed: () => Navigator.pop(c, true),
                child: Text(tr('Löschen')),
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
        (Icons.groups_outlined, tr('ca. {0}', [S.workers(colony.workerMin, colony.workerMax)])),
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
              tr('Kolonie #{0}', [colony.number]),
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

/// Winter rest: switch on/off, plus a plan that reminds at start and wake-up.
class _WinterCard extends ConsumerWidget {
  const _WinterCard({required this.colony});
  final Colony colony;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = ref.watch(colonyWinterProvider(colony.id)).value;
    final running = w?.started ?? false;
    final end = w?.plannedEndOn == null ? '' : tr(' · aufwecken am {0}', [S.date(w!.plannedEndOn!)]);
    final text = switch (w) {
      null => tr('Aus · planen, um erinnert zu werden'),
      _ when running => tr('Seit {0}{1}', [S.date(w.startedOn!), end]),
      _ => tr('Geplant ab {0}{1}', [S.date(w.plannedStartOn!), end]),
    };
    final color = context.colors.winter;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        color: running ? color.withValues(alpha: .12) : null,
        child: ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          contentPadding: const EdgeInsets.only(left: 12, right: 4),
          leading: Icon(Icons.ac_unit, color: color, size: 20),
          title: Text(tr('Winterruhe')),
          subtitle: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: w == null ? tr('Planen') : tr('Plan ändern'),
                icon: const Icon(Icons.edit_calendar, size: 20),
                onPressed: () => _plan(context, ref, w),
              ),
              Switch(
                value: running,
                onChanged: (on) {
                  final repo = ref.read(repositoryProvider)!;
                  on ? repo.startWinter(colony.id) : repo.endWinter(colony.id);
                  showUndoSnack(
                    context,
                    on ? tr('Winterruhe begonnen') : tr('Winterruhe beendet – normale Intervalle ab jetzt'),
                  );
                },
              ),
            ],
          ),
          onTap: () => _plan(context, ref, w),
        ),
      ),
    );
  }

  Future<void> _plan(BuildContext context, WidgetRef ref, WinterRest? w) async {
    final today = DateUtils.dateOnly(DateTime.now());
    final running = w?.started ?? false;
    var start = w?.startedOn ?? w?.plannedStartOn ?? today;
    DateTime? end = w?.plannedEndOn ?? (w == null ? DateTime(start.year, start.month + 4, start.day) : null);
    Future<DateTime?> pick(BuildContext c, DateTime initial, DateTime first) => showDatePicker(
      context: c,
      firstDate: first,
      lastDate: DateTime(today.year + 2, 12, 31),
      initialDate: initial.isBefore(first) ? first : initial,
    );
    final result = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) {
          final valid = end == null || end!.isAfter(start);
          return AlertDialog(
            title: Text(tr('Winterruhe planen')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.bedtime_outlined),
                  title: Text(running ? tr('Begonnen') : tr('Beginn')),
                  subtitle: Text(S.date(start)),
                  trailing: running ? null : const Icon(Icons.edit_calendar),
                  onTap: running
                      ? null
                      : () async {
                          final d = await pick(c, start, today.subtract(const Duration(days: 30)));
                          if (d != null) set(() => start = d);
                        },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.wb_sunny_outlined),
                  title: Text(tr('Aufwecken')),
                  subtitle: Text(end == null ? 'offen' : S.date(end!)),
                  trailing: end == null
                      ? const Icon(Icons.edit_calendar)
                      : IconButton(
                          tooltip: tr('Kein Datum'),
                          icon: const Icon(Icons.clear),
                          onPressed: () => set(() => end = null),
                        ),
                  onTap: () async {
                    final d = await pick(
                      c,
                      end ?? start.add(const Duration(days: 120)),
                      start.add(const Duration(days: 1)),
                    );
                    if (d != null) set(() => end = d);
                  },
                ),
                if (!valid)
                  Text(tr('Aufwecken muss nach dem Beginn liegen.'), style: TextStyle(color: context.colors.overdue)),
                const SizedBox(height: 8),
                Text(
                  tr(
                    'Am geplanten Tag bekommst du eine Erinnerung – ein- und ausschalten tust du die Winterruhe selbst.',
                  ),
                  style: TextStyle(color: context.colors.muted),
                ),
              ],
            ),
            actions: [
              if (w != null && !running)
                TextButton(onPressed: () => Navigator.pop(c, 'cancel'), child: Text(tr('Plan löschen'))),
              TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('Abbrechen'))),
              FilledButton(onPressed: valid ? () => Navigator.pop(c, 'save') : null, child: Text(tr('Speichern'))),
            ],
          );
        },
      ),
    );
    final repo = ref.read(repositoryProvider);
    if (repo == null || result == null) return;
    if (result == 'cancel') {
      repo.cancelWinterPlan(colony.id);
    } else {
      repo.planWinter(colony.id, start: start, end: end);
    }
  }
}

/// Care sheet of the linked species – or a hint to link one.
class _SpeciesCard extends ConsumerWidget {
  const _SpeciesCard({required this.colony, required this.canEdit});
  final Colony colony;
  final bool canEdit;

  /// Search the catalog and link right away (no form, no „Speichern“).
  Future<void> _link(BuildContext context, WidgetRef ref) async {
    final s = await pickSpecies(context, initialQuery: colony.species);
    if (s == null || !context.mounted) return;
    final repo = ref.read(repositoryProvider)!;
    final previous = repo.linkSpecies(colony.id, s);
    showUndoSnack(
      context,
      tr('Verknüpft mit {0}', [s.scientificName]),
      onUndo: () => repo.updateColony(colony.id, previous),
    );
  }

  void _unlink(BuildContext context, WidgetRef ref) {
    final repo = ref.read(repositoryProvider)!;
    final previous = repo.unlinkSpecies(colony.id);
    showUndoSnack(context, tr('Verknüpfung gelöst'), onUndo: () => repo.updateColony(colony.id, previous));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invasive = invasiveSpeciesFor(
      ref.watch(speciesListProvider).value ?? const <Species>[],
      speciesId: colony.speciesId,
      text: colony.json['species_text'] as String?,
    );
    final card = _card(context, ref);
    if (invasive == null) return card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: InvasiveBanner(species: invasive, forColony: true),
        ),
        card,
      ],
    );
  }

  Widget _card(BuildContext context, WidgetRef ref) {
    final id = colony.speciesId;
    final species = id == null ? null : ref.watch(speciesProvider(id)).value;
    if (species == null) {
      if (!canEdit) return const SizedBox.shrink();
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: const Icon(Icons.menu_book_outlined, size: 18),
          label: Text(tr('Steckbrief aus dem Artenkatalog verknüpfen')),
          onPressed: () => _link(context, ref),
        ),
      );
    }
    final summary = speciesSummary(species);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: ListTile(
          leading: const Icon(Icons.menu_book_outlined),
          title: Text(tr('Steckbrief: {0}', [species.scientificName])),
          subtitle: summary.isEmpty ? null : Text(summary),
          onTap: () => context.go('/species/${species.id}'),
          trailing: canEdit
              ? PopupMenuButton<String>(
                  tooltip: tr('Verknüpfung'),
                  onSelected: (v) => switch (v) {
                    'open' => context.go('/species/${species.id}'),
                    'change' => _link(context, ref),
                    _ => _unlink(context, ref),
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'open', child: Text(tr('Steckbrief öffnen'))),
                    PopupMenuItem(value: 'change', child: Text(tr('Andere Art wählen'))),
                    PopupMenuItem(value: 'unlink', child: Text(tr('Verknüpfung lösen'))),
                  ],
                )
              : const Icon(Icons.chevron_right),
        ),
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

/// QR code, NFC tags and labels of a colony (docs/12 S11).
Future<void> showQrSheet(BuildContext context, WidgetRef ref, Colony colony) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => ContentWidth(maxWidth: 560, child: _QrSheet(colony: colony)),
);

class _QrSheet extends ConsumerWidget {
  const _QrSheet({required this.colony});
  final Colony colony;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider)!;
    final auth = ref.watch(authProvider);
    final base = publicUrl(repo.db, auth is SignedIn ? auth.serverUrl : '');
    final links = ref.watch(scanLinksProvider(colony.id)).value ?? repo.scanLinks(colony.id);
    final qr = links.where((l) => l.kind == 'qr' && l.active).firstOrNull;
    final tags = repo.nfcTags(colony.id);
    final canEdit = (ref.watch(roleProvider(colony.id)).value ?? 'owner') != 'viewer';
    final nfc = ref.watch(nfcControllerProvider);
    final url = qr == null ? null : '$base/c/${qr.token}';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(colony.name, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
          if (colony.species.isNotEmpty)
            Text(
              colony.species,
              style: const TextStyle(fontStyle: FontStyle.italic),
              textAlign: TextAlign.center,
            ),
          const SizedBox(height: 16),
          if (url == null)
            Text(tr('Kein aktiver QR-Code.'), textAlign: TextAlign.center)
          else ...[
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(data: url, size: 220, backgroundColor: Colors.white),
              ),
            ),
            const SizedBox(height: 10),
            SelectableText(
              url,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.colors.muted),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  context.push('/settings/labels?colony=${colony.id}');
                },
                icon: const Icon(Icons.print_outlined),
                label: Text(tr('Etikett drucken')),
              ),
              if (url != null)
                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: url));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Link kopiert'))));
                  },
                  icon: const Icon(Icons.copy),
                  label: Text(tr('Link kopieren')),
                ),
              if (canEdit)
                OutlinedButton.icon(
                  onPressed: () => _regenerate(context, repo),
                  icon: const Icon(Icons.autorenew),
                  label: Text(tr('Neu generieren')),
                ),
            ],
          ),
          SectionHeader(
            tr('NFC-Tags ({0})', [tags.length]),
            trailing: canEdit && nfc != NfcState.unsupported
                ? TextButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      context.push('/colonies/${colony.id}/nfc');
                    },
                    icon: const Icon(Icons.add),
                    label: Text(tr('Tag zuweisen')),
                  )
                : null,
          ),
          if (tags.isEmpty)
            Text(
              nfc == NfcState.unsupported
                  ? tr('NFC-Tags werden mit der Android-App zugewiesen.')
                  : tr('Noch kein Tag. Tipp: Aufkleber außen am Formicarium, etwas Abstand zu Metall und Heizmatten.'),
              style: TextStyle(color: context.colors.muted),
            )
          else
            for (final t in tags)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.contactless_outlined),
                title: Text(t['label'] as String? ?? t['tag_type'] as String? ?? 'NFC-Tag'),
                subtitle: Text(
                  [
                    if (t['scan_link_id'] == null) tr('nur Seriennummer'),
                    if (t['locked'] == true) tr('schreibgeschützt'),
                    if (t['written_at'] != null)
                      tr('beschrieben {0}', [S.date(DateTime.parse(t['written_at'] as String))]),
                  ].join(' · '),
                ),
                trailing: canEdit
                    ? IconButton(
                        tooltip: tr('Entfernen'),
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => repo.removeNfcTag(t['id'] as String),
                      )
                    : null,
              ),
        ],
      ),
    );
  }

  Future<void> _regenerate(BuildContext context, ColonyRepository repo) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('QR-Code neu generieren?')),
        content: Text(tr('Gedruckte Etiketten mit dem alten Code funktionieren danach nicht mehr.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Abbrechen'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Neu generieren'))),
        ],
      ),
    );
    if (ok == true) repo.regenerateQr(colony.id);
  }
}
