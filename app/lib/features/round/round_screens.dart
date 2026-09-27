import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../data/repositories/colony_repository.dart';
import '../../domain/models.dart';
import '../../nfc/nfc_driver.dart';
import '../../nfc/nfc_controller.dart';
import '../../shared/widgets.dart';
import '../actions/actions.dart';
import '../photos/photos.dart';
import '../scan/scan_screens.dart';
import '../scan/scanner_view.dart';

/// Wording of the summary per event type („24 gefüttert“).
const _doneWords = {
  'feeding': 'gefüttert',
  'water': 'Wasser',
  'cleaning': 'gereinigt',
  'check': 'kontrolliert',
  'problem': 'Problem',
  'note': 'Notiz',
  'measurement': 'Messung',
  'photo': 'Fotos',
};

/// S18 – Pflege-Rundgang. Without a running round: choose colonies and start.
/// With one: the card of the scanned colony; the next scan (NFC, camera or a
/// tap in the „Offen“ list) moves on. [colonyId] is set by scans elsewhere
/// in the app (see [scanTarget]), [nonce] makes a repeated scan distinct.
class RoundScreen extends ConsumerStatefulWidget {
  const RoundScreen({super.key, this.colonyId, this.nonce});
  final String? colonyId;
  final String? nonce;

  @override
  ConsumerState<RoundScreen> createState() => _RoundScreenState();
}

class _RoundScreenState extends ConsumerState<RoundScreen> {
  static const _currentKey = 'round_current';
  String? _handled;

  ColonyRepository get _repo => ref.read(repositoryProvider)!;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      _repo.closeStaleRounds();
      _takeScan();
    });
  }

  @override
  void didUpdateWidget(RoundScreen old) {
    super.didUpdateWidget(old);
    if (old.colonyId != widget.colonyId || old.nonce != widget.nonce) Future.microtask(_takeScan);
  }

  void _takeScan() {
    final id = widget.colonyId;
    final key = '$id/${widget.nonce}';
    if (id == null || _handled == key || !mounted) return;
    _handled = key;
    arrive(id);
  }

  String? get _current => _repo.db.getMeta(_currentKey);
  set _current(String? id) {
    _repo.db.setMeta(_currentKey, id);
    setState(() {});
  }

  /// A colony was scanned (or picked from the list).
  Future<void> arrive(String colonyId) async {
    final repo = _repo;
    final round = repo.activeRound();
    if (round == null) return;
    if (colonyId == _current) return;
    final stop = repo.roundProgress(round.id)?.stopOf(colonyId);
    if (stop != null && stop.visited) {
      final done = repo.doneInRound(round.id, colonyId).map((t) => S.eventTypes[t] ?? t).join(', ');
      final open = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(repo.colony(colonyId)?.name ?? 'Kolonie'),
          content: Text(
            done.isEmpty ? 'Schon kontrolliert – trotzdem öffnen?' : 'Schon erledigt ($done) – trotzdem öffnen?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Nein')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Öffnen')),
          ],
        ),
      );
      if (open == true && mounted) _current = colonyId;
      return;
    }
    final r = repo.visit(round.id, colonyId);
    HapticFeedback.mediumImpact();
    if (!mounted) return;
    _current = colonyId;
    if (r == VisitResult.added) {
      showUndoSnack(context, '${repo.colony(colonyId)?.name ?? 'Kolonie'} zum Rundgang hinzugefügt');
    }
  }

  Future<void> _finish(String roundId) async {
    _repo.endRound(roundId);
    _repo.db.setMeta(_currentKey, null);
    if (mounted) context.go('/round/$roundId');
  }

  @override
  Widget build(BuildContext context) {
    final progress = ref.watch(activeRoundProvider);
    return progress.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        body: EmptyState(icon: Icons.error_outline, title: 'Fehler', text: '$e'),
      ),
      data: (p) => p == null
          ? const _RoundStart()
          : _ActiveRound(
              progress: p,
              current: p.stops.where((s) => s.$2.id == _current).firstOrNull?.$2,
              onArrive: arrive,
              onFinish: () => _finish(p.round.id),
            ),
    );
  }
}

// -----------------------------------------------------------------------------
// Start

class _RoundStart extends ConsumerStatefulWidget {
  const _RoundStart();
  @override
  ConsumerState<_RoundStart> createState() => _RoundStartState();
}

class _RoundStartState extends ConsumerState<_RoundStart> {
  RoundScope _scope = RoundScope.withTasks;
  String? _location;

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider)!;
    ref.watch(dueAllProvider); // re-count when data changes
    final locations = ref.watch(locationsProvider).value ?? const <Location>[];
    final location = _location ?? locations.firstOrNull?.id;
    int count(RoundScope s) => repo.roundCandidates(s, locationId: location).length;
    final chosen = repo.roundCandidates(_scope, locationId: location);
    final recent = ref.watch(recentRoundsProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('Pflege-Rundgang'), actions: const [SyncBadge()]),
      body: ContentWidth(
        maxWidth: 560,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Scanne die Kolonien nacheinander und dokumentiere mit 1–2 Taps. '
              'Am Ende siehst du, was erledigt ist und welche Kolonien fehlen.',
              style: TextStyle(color: context.colors.muted),
            ),
            const SectionHeader('Welche Kolonien?'),
            RadioGroup<RoundScope>(
              groupValue: _scope,
              onChanged: (v) => setState(() => _scope = v!),
              child: Card(
                child: Column(
                  children: [
                    RadioListTile(
                      value: RoundScope.withTasks,
                      title: const Text('Alle mit Aufgaben'),
                      subtitle: const Text('heute fällig oder überfällig'),
                      secondary: Text('${count(RoundScope.withTasks)}'),
                    ),
                    RadioListTile(
                      value: RoundScope.allActive,
                      title: const Text('Alle aktiven'),
                      secondary: Text('${count(RoundScope.allActive)}'),
                    ),
                    if (locations.isNotEmpty)
                      RadioListTile(
                        value: RoundScope.location,
                        title: Row(
                          children: [
                            const Text('Standort: '),
                            Flexible(
                              child: DropdownButton<String>(
                                value: location,
                                isExpanded: true,
                                underline: const SizedBox.shrink(),
                                items: [
                                  for (final l in locations)
                                    DropdownMenuItem(
                                      value: l.id,
                                      child: Text(l.path, overflow: TextOverflow.ellipsis),
                                    ),
                                ],
                                onChanged: (v) => setState(() {
                                  _location = v;
                                  _scope = RoundScope.location;
                                }),
                              ),
                            ),
                          ],
                        ),
                        secondary: Text('${count(RoundScope.location)}'),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: chosen.isEmpty
                  ? null
                  : () {
                      repo.startRound(
                        chosen.map((c) => c.id).toList(),
                        locationId: _scope == RoundScope.location ? location : null,
                      );
                      HapticFeedback.mediumImpact();
                    },
              icon: const Icon(Icons.play_arrow),
              label: Text(chosen.isEmpty ? 'Keine Kolonien ausgewählt' : 'Rundgang starten (${chosen.length})'),
            ),
            if (_scope == RoundScope.withTasks && chosen.isEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Heute ist nichts fällig. Wähle „Alle aktiven“ für eine Kontrollrunde.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.colors.muted),
              ),
            ],
            if (recent.isNotEmpty) ...[
              const SectionHeader('Letzte Rundgänge'),
              Card(
                child: Column(
                  children: [
                    for (final s in recent)
                      ListTile(
                        leading: const Icon(Icons.route_outlined),
                        title: Text('${S.relativeDay(s.round.startedAt, DateTime.now())} ${S.time(s.round.startedAt)}'),
                        subtitle: Text('${s.visited} / ${s.total} Kolonien · ${_minutes(s.duration)}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.go('/round/${s.round.id}'),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _minutes(Duration d) =>
    d.inMinutes < 60 ? '${d.inMinutes} min' : '${d.inHours} h ${(d.inMinutes % 60).toString().padLeft(2, '0')} min';

// -----------------------------------------------------------------------------
// Active round

class _ActiveRound extends ConsumerStatefulWidget {
  const _ActiveRound({required this.progress, required this.current, required this.onArrive, required this.onFinish});
  final RoundProgress progress;
  final Colony? current;
  final Future<void> Function(String colonyId) onArrive;
  final VoidCallback onFinish;

  @override
  ConsumerState<_ActiveRound> createState() => _ActiveRoundState();
}

class _ActiveRoundState extends ConsumerState<_ActiveRound> {
  @override
  void initState() {
    super.initState();
    // Screen stays on while walking from colony to colony (Android).
    if (!kIsWeb) WakelockPlus.enable().catchError((_) {});
  }

  @override
  void dispose() {
    if (!kIsWeb) WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  Future<void> _confirmFinish() async {
    final open = widget.progress.open.length;
    if (open == 0) return widget.onFinish();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rundgang beenden?'),
        content: Text('$open ${open == 1 ? 'Kolonie wurde' : 'Kolonien wurden'} noch nicht gescannt.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Weiter')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Beenden')),
        ],
      ),
    );
    if (ok == true) widget.onFinish();
  }

  Future<void> _scanCamera() async {
    final repo = ref.read(repositoryProvider)!;
    final id = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (c) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Nächste Kolonie scannen', style: Theme.of(c).textTheme.titleLarge),
            const SizedBox(height: 12),
            ScannerView(
              onCode: (raw) async {
                final token = parseScanInput(raw);
                if (token == null) return;
                switch (await resolveScan(ref, token)) {
                  case OpenColony(:final id):
                    if (c.mounted) Navigator.pop(c, id);
                  case ScanMessage(:final text):
                    if (c.mounted) showUndoSnack(c, text);
                }
              },
            ),
          ],
        ),
      ),
    );
    if (id != null && repo.colony(id) != null) await widget.onArrive(id);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.progress;
    final c = widget.current;
    final nfc = ref.watch(nfcControllerProvider);
    final done = c == null ? const <String>{} : (p.done[c.id] ?? const <String>{});
    return Scaffold(
      appBar: AppBar(
        title: Text('Rundgang  ${p.visited} / ${p.total}'),
        actions: [
          IconButton(
            tooltip: 'Pause – der Rundgang bleibt aktiv',
            onPressed: () => context.go('/'),
            icon: const Icon(Icons.pause),
          ),
          TextButton(onPressed: _confirmFinish, child: const Text('Beenden')),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(value: p.total == 0 ? 0 : p.visited / p.total),
        ),
      ),
      body: ContentWidth(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            if (c == null)
              _Hint(
                icon: nfc == NfcState.ready ? Icons.contactless_outlined : Icons.qr_code_scanner,
                text: kIsWeb
                    ? 'Wähle unten eine Kolonie aus der Liste.'
                    : nfc == NfcState.ready
                    ? 'Scanne die erste Kolonie – Tag antippen oder QR-Code.'
                    : 'Scanne die erste Kolonie per QR-Code oder wähle sie aus der Liste.',
              )
            else
              _ColonyCard(colony: c, done: done),
            const SizedBox(height: 16),
            _NextScan(nfcReady: nfc == NfcState.ready, onCamera: cameraScanSupported ? _scanCamera : null),
            if (p.open.isEmpty && p.visited > 0) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: widget.onFinish,
                icon: const Icon(Icons.flag_outlined),
                label: const Text('Rundgang abschließen'),
              ),
            ],
            if (p.open.isNotEmpty) ...[
              SectionHeader('Offen · ${p.open.length}'),
              Card(
                child: Column(
                  children: [
                    for (final (_, col) in p.open)
                      ListTile(
                        dense: true,
                        title: Text(col.name),
                        subtitle: Text(col.locationPath ?? col.species),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => widget.onArrive(col.id),
                      ),
                  ],
                ),
              ),
            ],
            if (p.visited > 0) ...[
              SectionHeader('Erledigt · ${p.visited}'),
              Card(
                child: Column(
                  children: [
                    for (final (s, col) in p.stops.where((s) => s.$1.visited))
                      ListTile(
                        dense: true,
                        leading: Icon(Icons.check_circle, color: context.colors.ok, size: 20),
                        title: Text(col.name),
                        subtitle: Text(
                          (p.done[col.id] ?? const {})
                              .map((t) => S.eventTypes[t] ?? t)
                              .join(', ')
                              .ifEmpty('kontrolliert'),
                        ),
                        trailing: s.planned ? null : const Text('ergänzt'),
                        onTap: col.id == c?.id ? null : () => widget.onArrive(col.id),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
      child: Column(
        children: [
          Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    ),
  );
}

/// The scanned colony: traffic light and quick actions; ✓ = done in this round.
class _ColonyCard extends ConsumerWidget {
  const _ColonyCard({required this.colony, required this.done});
  final Colony colony;
  final Set<String> done;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final due = ref.watch(colonyDueProvider(colony.id)).value ?? const [];
    final role = ref.watch(roleProvider(colony.id)).value ?? 'owner';
    final repo = ref.watch(repositoryProvider)!;
    ref.watch(colonyEventsProvider(colony.id));
    final last = repo.lastFeeding(colony.id);
    final canEdit = role != 'viewer';
    final shown = due.where((t) => t.status.index <= 1).take(4).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: ColonyTitle(colony, large: true)),
                IconButton(
                  tooltip: 'Kolonie öffnen',
                  onPressed: () => context.go('/colonies/${colony.id}'),
                  icon: const Icon(Icons.open_in_new),
                ),
              ],
            ),
            if (colony.locationPath != null) Text(colony.locationPath!, style: TextStyle(color: context.colors.muted)),
            const SizedBox(height: 10),
            if (shown.isEmpty)
              Text(
                'Nichts fällig',
                style: TextStyle(color: context.colors.ok, fontWeight: FontWeight.w600),
              )
            else
              Wrap(spacing: 6, runSpacing: 6, children: [for (final t in shown) DueChip(t)]),
            if (!canEdit) ...[
              const SizedBox(height: 12),
              Text('Nur Lesezugriff auf diese Kolonie.', style: TextStyle(color: context.colors.muted)),
            ] else ...[
              if (last != null) ...[
                const SizedBox(height: 14),
                Card(
                  margin: EdgeInsets.zero,
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: ListTile(
                    leading: Icon(done.contains('feeding') ? Icons.check_circle : Icons.replay),
                    title: const Text('Wie letztes Mal füttern'),
                    subtitle: Text(S.eventSummary(last), maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => repeatFeeding(context, ref, colony),
                  ),
                ),
              ],
              const SizedBox(height: 12),
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
                    done: done.contains('feeding'),
                    onTap: () => showFeedingSheet(context, ref, colony),
                  ),
                  QuickActionTile(
                    icon: Icons.water_drop_outlined,
                    label: 'Wasser',
                    done: done.contains('water'),
                    onTap: () => quickWater(context, ref, colony),
                    onLongPress: () => showWaterSheet(context, ref, colony),
                  ),
                  QuickActionTile(
                    icon: Icons.cleaning_services_outlined,
                    label: 'Reinigen',
                    done: done.contains('cleaning'),
                    onTap: () => showCleaningSheet(context, ref, colony),
                  ),
                  QuickActionTile(
                    icon: Icons.visibility_outlined,
                    label: 'Kontrolle',
                    done: done.contains('check'),
                    onTap: () => quickCheck(context, ref, colony),
                    onLongPress: () => showNoteSheet(context, ref, colony, type: 'check'),
                  ),
                  QuickActionTile(
                    icon: Icons.sticky_note_2_outlined,
                    label: 'Notiz',
                    done: done.contains('note'),
                    onTap: () => showNoteSheet(context, ref, colony),
                  ),
                  QuickActionTile(
                    icon: Icons.photo_camera_outlined,
                    label: 'Foto',
                    done: done.contains('photo'),
                    onTap: () => takePhoto(context, ref, colony),
                    onLongPress: () => takePhoto(context, ref, colony, fromGallery: true),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NextScan extends StatelessWidget {
  const _NextScan({required this.nfcReady, required this.onCamera});
  final bool nfcReady;
  final VoidCallback? onCamera;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onCamera,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Icon(nfcReady ? Icons.contactless_outlined : Icons.qr_code_scanner, size: 36),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('NÄCHSTE KOLONIE', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: .5)),
                    Text(
                      [
                        if (nfcReady) 'Tag antippen',
                        if (onCamera != null) 'hier tippen für QR-Code',
                        if (kIsWeb) 'aus der Liste unten wählen',
                      ].join(' · ').ifEmpty('aus der Liste unten wählen'),
                    ),
                  ],
                ),
              ),
              if (onCamera != null) const Icon(Icons.photo_camera_outlined),
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Summary

class RoundSummaryScreen extends ConsumerWidget {
  const RoundSummaryScreen({super.key, required this.roundId});
  final String roundId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(roundSummaryProvider(roundId));
    return Scaffold(
      appBar: AppBar(title: const Text('Rundgang'), actions: const [SyncBadge()]),
      body: s.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(icon: Icons.error_outline, title: 'Fehler', text: '$e'),
        data: (s) =>
            s == null ? const EmptyState(icon: Icons.route_outlined, title: 'Rundgang nicht gefunden') : _Summary(s),
      ),
    );
  }
}

class _Summary extends ConsumerWidget {
  const _Summary(this.s);
  final RoundSummary s;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ['feeding', 'water', 'cleaning', 'check', 'problem', 'note', 'measurement'];
    final types = s.colonies.keys.toList()..sort((a, b) => (order.indexOf(a) % 99).compareTo(order.indexOf(b) % 99));
    return ContentWidth(
      maxWidth: 560,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.check_circle, color: context.colors.ok),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          s.round.open ? 'Rundgang läuft' : 'Pflege-Rundgang abgeschlossen',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${s.visited} / ${s.total} Kolonien kontrolliert',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      for (final t in types)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              eventIcon(t),
                              size: 20,
                              color: t == 'problem' ? context.colors.soon : Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Text('${s.colonies[t]} ${_doneWords[t] ?? S.eventTypes[t] ?? t}'),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${S.relativeDay(s.round.startedAt, DateTime.now())} ${S.time(s.round.startedAt)} · Dauer ${_minutes(s.duration)}',
                    style: TextStyle(color: context.colors.muted),
                  ),
                ],
              ),
            ),
          ),
          if (s.missing.isNotEmpty) ...[
            SectionHeader('Nicht gescannt · ${s.missing.length}'),
            Card(
              child: Column(
                children: [
                  for (final c in s.missing)
                    ListTile(
                      title: Text(c.name),
                      subtitle: Text(c.locationPath ?? c.species),
                      trailing: TextButton(
                        onPressed: () => context.go('/colonies/${c.id}'),
                        child: const Text('Öffnen'),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => ref.read(repositoryProvider)!.skipUnvisited(s.round.id),
              child: const Text('Als übersprungen markieren'),
            ),
          ],
          if (s.skipped.isNotEmpty) ...[
            SectionHeader('Übersprungen · ${s.skipped.length}'),
            Card(
              child: Column(
                children: [
                  for (final c in s.skipped)
                    ListTile(
                      dense: true,
                      title: Text(c.name),
                      subtitle: Text(c.locationPath ?? c.species),
                      onTap: () => context.go('/colonies/${c.id}'),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(onPressed: () => context.go('/'), child: const Text('Fertig')),
        ],
      ),
    );
  }
}
