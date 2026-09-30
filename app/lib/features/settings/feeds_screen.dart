import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/i18n.dart';
import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';

/// Calendar subscriptions (iCal): up to 10 read-only addresses, each with a
/// name, a choice of entry kinds and optionally only some colonies – e.g. one
/// calendar for the winter rest and one for the feedings, each with its own
/// colour in Google or Outlook. An address is shown only right after it was
/// created. Home Assistant gets the colonies via MQTT instead (mqtt_screen.dart).
final feedsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final list = await ref.read(authProvider.notifier).api.get('/api/v1/me/feeds') as List;
  return list.cast<Map<String, dynamic>>();
});

/// What the calendar can show: care task types, winter rest, one-off tasks.
Map<String, String> get calendarTypes => {
  'feeding': tr('Fütterung'),
  'protein': tr('Proteinfütterung'),
  'carbohydrate': tr('Kohlenhydratfütterung'),
  'water': tr('Wasser'),
  'cleaning': tr('Reinigung'),
  'check': tr('Kontrolle'),
  'custom': tr('Eigene Pflegepläne'),
  'winter': tr('Winterruhe'),
  'tasks': tr('Einmalige Aufgaben'),
};

/// The selection after tapping [type]; null = everything. Never empty.
List<String>? toggleCalendarType(List<String>? current, String type) {
  final all = calendarTypes.keys.toList();
  final set = {...current ?? all};
  if (!set.remove(type)) set.add(type);
  if (set.isEmpty) return current;
  if (set.length == all.length) return null;
  return [
    for (final t in all)
      if (set.contains(t)) t,
  ];
}

/// Colonies after tapping [id]; null = all colonies. Never empty.
List<String>? toggleCalendarColony(List<String>? current, String id, List<String> all) {
  final set = {...current ?? all};
  if (!set.remove(id)) set.add(id);
  if (set.isEmpty) return current;
  if (all.every(set.contains)) return null;
  return [
    for (final c in all)
      if (set.contains(c)) c,
  ];
}

/// Short description of a calendar's choice for the list.
String calendarSummary(Map<String, dynamic> feed, Map<String, Colony> colonies) {
  final types = (feed['calendar_types'] as List?)?.cast<String>();
  final ids = (feed['colony_ids'] as List?)?.cast<String>();
  final what = types == null ? tr('alles') : types.map((t) => calendarTypes[t] ?? t).join(', ');
  final which = ids == null
      ? tr('alle Kolonien')
      : ids.length == 1
      ? (colonies[ids.first]?.name ?? tr('1 Kolonie'))
      : tr('{0} Kolonien', [ids.length]);
  return '$what · $which';
}

class FeedsScreen extends ConsumerStatefulWidget {
  const FeedsScreen({super.key});
  @override
  ConsumerState<FeedsScreen> createState() => _FeedsScreenState();
}

class _FeedsScreenState extends ConsumerState<FeedsScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final name = TextEditingController(text: tr('Ameisen'));
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr('Neuer Kalender')),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: InputDecoration(
            labelText: tr('Name'),
            helperText: tr('So heißt der Kalender in Google, Outlook & Co., z. B. „Winterruhe“'),
            helperMaxLines: 2,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Abbrechen'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Anlegen'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(() async {
      final r =
          await ref.read(authProvider.notifier).api.post('/api/v1/me/feeds', {'name': name.text.trim()})
              as Map<String, dynamic>;
      ref.invalidate(feedsProvider);
      if (mounted) await _showAddress(r['calendar_url'] as String);
    });
  }

  Future<void> _showAddress(String url) => showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(tr('Kalender-Adresse')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber, color: d.colors.soon),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr('Nur jetzt sichtbar – kopieren und wie ein Passwort behandeln.'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SelectableText(url, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.copy, size: 18),
          label: Text(tr('Kopieren')),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: url));
            showUndoSnack(context, tr('Kopiert'));
          },
        ),
        FilledButton(onPressed: () => Navigator.pop(d), child: Text(tr('Fertig'))),
      ],
    ),
  );

  Future<void> _edit(Map<String, dynamic> feed) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (c) => _FeedSheet(feed: feed, onAddress: _showAddress),
  );

  @override
  Widget build(BuildContext context) {
    final feeds = ref.watch(feedsProvider);
    final colonies = {for (final c in ref.watch(coloniesProvider).value ?? const <Colony>[]) c.id: c};
    final muted = TextStyle(color: context.colors.muted);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Kalender-Abo'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy || (feeds.value?.length ?? 0) >= 10 ? null : _create,
        icon: const Icon(Icons.add),
        label: Text(tr('Kalender')),
      ),
      body: feeds.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.cloud_off,
          title: tr('Nur mit Verbindung zum Server'),
          text: errorText(e),
          action: FilledButton(onPressed: () => ref.invalidate(feedsProvider), child: Text(tr('Erneut'))),
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
                      'Private Adressen, über die Kalender-Apps die Fälligkeiten deiner Kolonien zeigen – nur lesen, '
                      'nichts ändern. Mehrere Kalender sind möglich, z. B. einer nur für die Winterruhe und einer für '
                      'die Fütterungen – jeder mit eigener Farbe in der Kalender-App.',
                    ),
                    style: muted,
                  ),
                  const SizedBox(height: 12),
                  if (list.isEmpty)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.event_available),
                        title: Text(tr('Noch kein Kalender')),
                        subtitle: Text(tr('Mit „+ Kalender“ die erste Adresse erzeugen.')),
                      ),
                    ),
                  for (final f in list)
                    Card(
                      child: ListTile(
                        leading: Icon(Icons.event_available, color: Theme.of(context).colorScheme.primary),
                        title: Text(f['name'] as String? ?? ''),
                        subtitle: Text(
                          [
                            calendarSummary(f, colonies),
                            switch (DateTime.tryParse(f['last_used_at'] as String? ?? '')) {
                              null => tr('noch nicht abgerufen'),
                              final used => tr('zuletzt abgerufen {0}', [S.dateTime(used)]),
                            },
                          ].join('\n'),
                        ),
                        isThreeLine: true,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _edit(f),
                      ),
                    ),
                  SectionHeader(tr('Kalender')),
                  Text(
                    tr(
                      'Google Kalender: „Weitere Kalender“ → „Per URL“. Outlook: „Kalender hinzufügen“ → „Aus dem Internet“. '
                      'Thunderbird, Apple: „Kalender abonnieren“. Enthält den nächsten Termin jedes Pflegeplans '
                      '(überfällige heute), geplanten Beginn und Ende der Winterruhe und offene Aufgaben. '
                      'Kalender-Apps aktualisieren Abos selbst – Google teils nur alle 12–24 Stunden.',
                    ),
                    style: muted,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr(
                      'Home Assistant: Integration „Remote Calendar“ mit der Kalender-Adresse. Den Status jeder '
                      'Kolonie (z. B. Winterruhe → Heizung aus) bekommt Home Assistant über MQTT – einzurichten '
                      'vom Administrator unter Mehr → Server-Verwaltung → Home Assistant (MQTT).',
                    ),
                    style: muted,
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

/// Name, entry kinds and colonies of one calendar; changes apply at once.
class _FeedSheet extends ConsumerStatefulWidget {
  const _FeedSheet({required this.feed, required this.onAddress});
  final Map<String, dynamic> feed;
  final Future<void> Function(String url) onAddress;
  @override
  ConsumerState<_FeedSheet> createState() => _FeedSheetState();
}

class _FeedSheetState extends ConsumerState<_FeedSheet> {
  late Map<String, dynamic> _f = widget.feed;
  late final _name = TextEditingController(text: _f['name'] as String? ?? '');
  bool _busy = false;

  String get _id => _f['id'] as String;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _patch(Map<String, dynamic> body) async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(authProvider.notifier).api.patch('/api/v1/me/feeds/$_id', body) as Map<String, dynamic>;
      setState(() => _f = r);
      ref.invalidate(feedsProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rotate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr('Neue Adresse erzeugen?')),
        content: Text(tr('Die bisherige Adresse funktioniert danach nicht mehr – der Kalender braucht die neue.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Abbrechen'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Neue Adresse'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await ref.read(authProvider.notifier).api.post('/api/v1/me/feeds/$_id/rotate') as Map<String, dynamic>;
      ref.invalidate(feedsProvider);
      if (mounted) {
        Navigator.pop(context);
        await widget.onAddress(r['calendar_url'] as String);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _delete() async {
    try {
      await ref.read(authProvider.notifier).api.delete('/api/v1/me/feeds/$_id');
      ref.invalidate(feedsProvider);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = (_f['calendar_types'] as List?)?.cast<String>();
    final ids = (_f['colony_ids'] as List?)?.cast<String>();
    final colonies = (ref.watch(coloniesProvider).value ?? const <Colony>[]).where((c) => c.isCareActive).toList()
      ..sort((a, b) => a.number.compareTo(b.number));
    final allIds = colonies.map((c) => c.id).toList();
    final muted = TextStyle(color: context.colors.muted, fontSize: 12);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            decoration: InputDecoration(labelText: tr('Name')),
            onSubmitted: (v) => _patch({'name': v.trim()}),
            onTapOutside: (_) {
              if (_name.text.trim() != _f['name'] && _name.text.trim().isNotEmpty) _patch({'name': _name.text.trim()});
            },
          ),
          SectionHeader(tr('Im Kalender anzeigen')),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final MapEntry(key: type, value: label) in calendarTypes.entries)
                FilterChip(
                  label: Text(label),
                  selected: types == null || types.contains(type),
                  onSelected: _busy
                      ? null
                      : (_) {
                          final next = toggleCalendarType(types, type);
                          if (identical(next, types)) {
                            showUndoSnack(context, tr('Mindestens eine Art muss ausgewählt bleiben'));
                          } else {
                            _patch({'calendar_types': next ?? calendarTypes.keys.toList()});
                          }
                        },
                ),
            ],
          ),
          SectionHeader(tr('Kolonien')),
          if (colonies.isEmpty)
            Text(tr('Noch keine Kolonien'), style: muted)
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in colonies)
                  FilterChip(
                    label: Text('${c.name} (#${c.number})'),
                    selected: ids == null || ids.contains(c.id),
                    onSelected: _busy
                        ? null
                        : (_) {
                            final next = toggleCalendarColony(ids, c.id, allIds);
                            if (identical(next, ids)) {
                              showUndoSnack(context, tr('Mindestens eine Kolonie muss ausgewählt bleiben'));
                            } else {
                              _patch({'colony_ids': next ?? <String>[]});
                            }
                          },
                  ),
              ],
            ),
          const SizedBox(height: 4),
          Text(
            tr(
              'Gilt sofort für die bestehende Adresse – Kalender-Apps zeigen es beim nächsten Abruf. Mit Auswahl von '
              'Kolonien fehlen Aufgaben, die zu keiner Kolonie gehören.',
            ),
            style: muted,
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _rotate,
            icon: const Icon(Icons.link),
            label: Text(tr('Neue Adresse erzeugen')),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: context.colors.overdue),
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline),
            label: Text(tr('Kalender löschen')),
          ),
        ],
      ),
    );
  }
}
