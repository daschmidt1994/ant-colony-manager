import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/i18n.dart';
import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';
import 'care_sheet_dialog.dart';

/// Pflegevertretung: hand chosen colonies to a person for a period – with
/// care instructions – and see what they documented. During the period the
/// person is a carer of those colonies; the server adds and removes that.
final careCoversProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final list = await ref.read(authProvider.notifier).api.get('/api/v1/care-covers') as List;
  return list.cast<Map<String, dynamic>>();
});

/// Running and planned covers of one colony that concern me (banner on the colony).
final careInstructionsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((
  ref,
  colonyId,
) async {
  try {
    final list = await ref.read(authProvider.notifier).api.get('/api/v1/colonies/$colonyId/care-instructions') as List;
    return list.cast<Map<String, dynamic>>();
  } on Exception {
    return const []; // offline or older server
  }
});

String _date(String? iso) => iso == null ? '' : S.date(DateTime.parse(iso));

/// „12.10. – 19.10.“ plus the state.
String coverPeriod(Map<String, dynamic> c) => '${_date(c['starts_on'] as String?)} – ${_date(c['ends_on'] as String?)}';

String coverStateText(String? state) => switch (state) {
  'planned' => tr('geplant'),
  'active' => tr('läuft'),
  _ => tr('beendet'),
};

/// A day as the server expects it: 2026-10-03.
String coverDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Request body for a new cover.
Map<String, dynamic> careCoverBody({
  required String email,
  required DateTime from,
  required DateTime to,
  required String instructions,
  required Map<String, String> colonies, // colony id → own instructions
}) {
  return {
    'email': email.trim(),
    'starts_on': coverDay(from),
    'ends_on': coverDay(to),
    'instructions': instructions.trim(),
    'colonies': [
      for (final e in colonies.entries) {'colony_id': e.key, 'instructions': e.value.trim()},
    ],
  };
}

class CareCoverScreen extends ConsumerWidget {
  const CareCoverScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final covers = ref.watch(careCoversProvider);
    final muted = TextStyle(color: context.colors.muted);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Pflegevertretung')),
        actions: [
          IconButton(
            tooltip: tr('Pflegezettel drucken'),
            icon: const Icon(Icons.print_outlined),
            onPressed: () => showCareSheetDialog(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (c) => const _NewCoverSheet(),
        ),
        icon: const Icon(Icons.add),
        label: Text(tr('Vertretung')),
      ),
      body: covers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.cloud_off,
          title: tr('Nur mit Verbindung zum Server'),
          text: errorText(e),
          action: FilledButton(onPressed: () => ref.invalidate(careCoversProvider), child: Text(tr('Erneut'))),
        ),
        data: (list) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            ContentWidth(
              maxWidth: 640,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    tr(
                      'Urlaub oder krank? Gib ausgewählte Kolonien für einen Zeitraum an jemanden ab – mit '
                      'Pflegeanweisungen. In dieser Zeit ist die Person Pfleger dieser Kolonien, danach nicht mehr. '
                      'Du siehst, was sie erledigt hat.',
                    ),
                    style: muted,
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.print_outlined),
                      title: Text(tr('Pflegezettel drucken')),
                      subtitle: Text(tr('Für jemanden ohne Konto: was an welchem Tag zu tun ist, zum Abhaken')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => showCareSheetDialog(context),
                    ),
                  ),
                  if (list.isEmpty)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.volunteer_activism_outlined),
                        title: Text(tr('Noch keine Vertretung')),
                        subtitle: Text(tr('Die Person braucht ein Konto auf diesem Server.')),
                      ),
                    ),
                  for (final c in list)
                    Card(
                      child: ListTile(
                        leading: Icon(
                          c['state'] == 'active' ? Icons.volunteer_activism : Icons.volunteer_activism_outlined,
                          color: c['state'] == 'active' ? context.colors.ok : context.colors.muted,
                        ),
                        title: Text(
                          c['mine'] == true
                              ? tr('{0} vertritt dich', [c['user_name']])
                              : tr('Du vertrittst {0}', [c['owner_name']]),
                        ),
                        subtitle: Text(
                          '${coverPeriod(c)} · ${coverStateText(c['state'] as String?)}\n'
                          '${(c['colonies'] as List).map((x) => (x as Map)['name']).join(', ')}',
                        ),
                        isThreeLine: true,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          useSafeArea: true,
                          builder: (s) => _CoverSheet(id: c['id'] as String),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewCoverSheet extends ConsumerStatefulWidget {
  const _NewCoverSheet();
  @override
  ConsumerState<_NewCoverSheet> createState() => _NewCoverSheetState();
}

class _NewCoverSheetState extends ConsumerState<_NewCoverSheet> {
  final _email = TextEditingController();
  final _instructions = TextEditingController();
  final _colonies = <String, TextEditingController>{};
  DateTimeRange? _range;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_email, _instructions, ..._colonies.values]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
      initialDateRange: _range,
    );
    if (r != null) setState(() => _range = r);
  }

  Future<void> _save() async {
    if (_range == null || _email.text.trim().isEmpty || _colonies.isEmpty) {
      showUndoSnack(context, tr('Person, Zeitraum und mindestens eine Kolonie wählen'));
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(authProvider.notifier)
          .api
          .post(
            '/api/v1/care-covers',
            careCoverBody(
              email: _email.text,
              from: _range!.start,
              to: _range!.end,
              instructions: _instructions.text,
              colonies: {for (final e in _colonies.entries) e.key: e.value.text},
            ),
          );
      ref.invalidate(careCoversProvider);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(repositoryProvider)!;
    final own =
        (ref.watch(coloniesProvider).value ?? const <Colony>[])
            .where((c) => c.isCareActive && repo.roleOn(c.id) == 'owner')
            .toList()
          ..sort((a, b) => a.number.compareTo(b.number));
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('Neue Vertretung'), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: tr('E-Mail der Vertretung'),
              helperText: tr('Die Person braucht ein Konto auf diesem Server.'),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickRange,
            icon: const Icon(Icons.date_range),
            label: Text(_range == null ? tr('Zeitraum wählen') : '${S.date(_range!.start)} – ${S.date(_range!.end)}'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _instructions,
            minLines: 2,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: tr('Pflegeanweisungen (für alle Kolonien)'),
              hintText: tr('z. B. Proteinfutter nur jeden zweiten Tag, Honigwasser nachfüllen'),
            ),
          ),
          SectionHeader(tr('Kolonien')),
          if (own.isEmpty) Text(tr('Noch keine Kolonien'), style: TextStyle(color: context.colors.muted)),
          for (final c in own) ...[
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _colonies.containsKey(c.id),
              title: Text('${c.name} (#${c.number})'),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _colonies[c.id] = TextEditingController();
                } else {
                  _colonies.remove(c.id)?.dispose();
                }
              }),
            ),
            if (_colonies.containsKey(c.id))
              Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 8),
                child: TextField(
                  controller: _colonies[c.id],
                  decoration: InputDecoration(labelText: tr('Anweisung für {0} (optional)', [c.name]), isDense: true),
                ),
              ),
          ],
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _save, child: Text(tr('Vertretung anlegen'))),
        ],
      ),
    );
  }
}

class _CoverSheet extends ConsumerStatefulWidget {
  const _CoverSheet({required this.id});
  final String id;
  @override
  ConsumerState<_CoverSheet> createState() => _CoverSheetState();
}

class _CoverSheetState extends ConsumerState<_CoverSheet> {
  Map<String, dynamic>? _c;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r =
          await ref.read(authProvider.notifier).api.get('/api/v1/care-covers/${widget.id}') as Map<String, dynamic>;
      if (mounted) setState(() => _c = r);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _extend() async {
    final end = DateTime.parse(_c!['ends_on'] as String);
    final d = await showDatePicker(
      context: context,
      initialDate: end,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    try {
      await ref.read(authProvider.notifier).api.patch('/api/v1/care-covers/${widget.id}', {'ends_on': coverDay(d)});
      ref.invalidate(careCoversProvider);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _end() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr('Vertretung beenden?')),
        content: Text(tr('Die Person ist dann sofort nicht mehr Pfleger dieser Kolonien.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Abbrechen'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Beenden'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(authProvider.notifier).api.post('/api/v1/care-covers/${widget.id}/end');
      ref.invalidate(careCoversProvider);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) {
      return SizedBox(
        height: 200,
        child: Center(child: _error == null ? const CircularProgressIndicator() : Text(errorText(_error!))),
      );
    }
    final muted = TextStyle(color: context.colors.muted);
    final names = {for (final x in (c['colonies'] as List).cast<Map<String, dynamic>>()) x['colony_id']: x['name']};
    final done = (c['done'] as List? ?? const []).cast<Map<String, dynamic>>();
    final mine = c['mine'] == true;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            mine ? tr('{0} vertritt dich', [c['user_name']]) : tr('Du vertrittst {0}', [c['owner_name']]),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Text('${coverPeriod(c)} · ${coverStateText(c['state'] as String?)}', style: muted),
          if ((c['instructions'] as String? ?? '').isNotEmpty) ...[
            SectionHeader(tr('Pflegeanweisungen')),
            Text(c['instructions'] as String),
          ],
          SectionHeader(tr('Kolonien')),
          for (final x in (c['colonies'] as List).cast<Map<String, dynamic>>())
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text('${x['name']} (#${x['number']})'),
              subtitle: (x['instructions'] as String? ?? '').isEmpty ? null : Text(x['instructions'] as String),
            ),
          SectionHeader(tr('Erledigt ({0})', [done.length])),
          if (done.isEmpty) Text(tr('Noch nichts eingetragen.'), style: muted),
          for (final d in done.take(100))
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(Icons.check_circle_outline, color: context.colors.ok),
              title: Text('${S.eventTypes[d['type']] ?? d['type']} · ${names[d['colony_id']] ?? ''}'),
              subtitle: Text(
                [
                  S.dateTime(DateTime.parse(d['occurred_at'] as String)),
                  if ((d['note'] as String? ?? '').isNotEmpty) d['note'] as String,
                ].join(' · '),
              ),
            ),
          const SizedBox(height: 16),
          if (mine && c['state'] != 'ended')
            OutlinedButton.icon(
              onPressed: () => showCareSheetDialog(
                context,
                range: DateTimeRange(
                  start: DateTime.parse(c['starts_on'] as String),
                  end: DateTime.parse(c['ends_on'] as String),
                ),
                instructions: c['instructions'] as String? ?? '',
                colonies: {
                  for (final x in (c['colonies'] as List).cast<Map<String, dynamic>>())
                    x['colony_id'] as String: x['instructions'] as String? ?? '',
                },
              ),
              icon: const Icon(Icons.print_outlined),
              label: Text(tr('Pflegezettel drucken')),
            ),
          const SizedBox(height: 8),
          if (c['state'] != 'ended') ...[
            if (mine)
              OutlinedButton.icon(onPressed: _extend, icon: const Icon(Icons.event), label: Text(tr('Ende ändern'))),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: context.colors.overdue),
              onPressed: _end,
              icon: const Icon(Icons.stop_circle_outlined),
              label: Text(tr('Vertretung beenden')),
            ),
          ],
        ],
      ),
    );
  }
}

/// On top of a colony: who stands in, until when, and the instructions.
class CareCoverBanner extends ConsumerWidget {
  const CareCoverBanner({super.key, required this.colonyId});
  final String colonyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(careInstructionsProvider(colonyId)).value ?? const [];
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final c in list)
          Card(
            color: Theme.of(context).colorScheme.secondaryContainer,
            margin: const EdgeInsets.only(top: 12),
            child: ListTile(
              leading: const Icon(Icons.volunteer_activism),
              title: Text(
                c['mine'] == true
                    ? tr('{0} vertritt dich: {1}', [c['user_name'], coverPeriod(c)])
                    : tr('Vertretung für {0}: {1}', [c['owner_name'], coverPeriod(c)]),
              ),
              subtitle: Text(
                [
                  if ((c['instructions'] as String? ?? '').isNotEmpty) c['instructions'] as String,
                  for (final x in (c['colonies'] as List).cast<Map<String, dynamic>>())
                    if ((x['instructions'] as String? ?? '').isNotEmpty) x['instructions'] as String,
                ].join('\n'),
              ),
            ),
          ),
      ],
    );
  }
}
