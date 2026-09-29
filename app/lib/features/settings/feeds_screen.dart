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

/// Calendar subscription (iCal) and status for Home Assistant: one secret,
/// read-only address per user. The token is shown only right after creation.
final feedInfoProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return await ref.read(authProvider.notifier).api.get('/api/v1/me/feed') as Map<String, dynamic>;
});

/// Home Assistant `rest:` configuration for the status address – totals plus
/// „overdue“ and „hibernating“ per colony (entity IDs from the colony number).
String homeAssistantYaml(String statusUrl, List<Colony> colonies) {
  final b = StringBuffer()
    ..writeln('rest:')
    ..writeln('  - resource: "$statusUrl"')
    ..writeln('    scan_interval: 300')
    ..writeln('    sensor:')
    ..writeln('      - name: "${tr('Ameisen überfällig')}"')
    ..writeln('        unique_id: acm_overdue')
    ..writeln('        icon: mdi:ant')
    ..writeln('        value_template: "{{ value_json.overdue }}"')
    ..writeln('      - name: "${tr('Ameisen heute fällig')}"')
    ..writeln('        unique_id: acm_due_today')
    ..writeln('        icon: mdi:ant')
    ..writeln('        value_template: "{{ value_json.due_today }}"');
  for (final c in colonies) {
    b
      ..writeln('      - name: "${tr('Kolonie {0} überfällig', [c.number])}"')
      ..writeln('        unique_id: acm_colony_${c.number}_overdue')
      ..writeln('        icon: mdi:ant')
      ..writeln("        value_template: \"{{ value_json.by_number['${c.number}'].overdue | default(0) }}\"");
  }
  if (colonies.isNotEmpty) b.writeln('    binary_sensor:');
  for (final c in colonies) {
    b
      ..writeln('      - name: "${tr('Kolonie {0} Winterruhe', [c.number])}"')
      ..writeln('        unique_id: acm_colony_${c.number}_hibernating')
      ..writeln('        icon: mdi:snowflake')
      ..writeln("        value_template: \"{{ value_json.by_number['${c.number}'].hibernating | default(false) }}\"");
  }
  return b.toString();
}

class FeedsScreen extends ConsumerStatefulWidget {
  const FeedsScreen({super.key});
  @override
  ConsumerState<FeedsScreen> createState() => _FeedsScreenState();
}

class _FeedsScreenState extends ConsumerState<FeedsScreen> {
  Map<String, dynamic>? _created; // {token, calendar_url, status_url} – only until the screen closes
  bool _busy = false;

  Future<void> _create({required bool replace}) async {
    if (replace) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(tr('Neue Adresse erzeugen?')),
          content: Text(
            tr('Die bisherige Adresse funktioniert danach nicht mehr – Kalender und Home Assistant brauchen die neue.'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Abbrechen'))),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Neue Adresse'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    try {
      final r = await ref.read(authProvider.notifier).api.post('/api/v1/me/feed') as Map<String, dynamic>;
      setState(() => _created = r);
      ref.invalidate(feedInfoProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).api.delete('/api/v1/me/feed');
      setState(() => _created = null);
      ref.invalidate(feedInfoProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = ref.watch(feedInfoProvider);
    final muted = TextStyle(color: context.colors.muted);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Kalender & Home Assistant'))),
      body: info.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.cloud_off,
          title: tr('Nur mit Verbindung zum Server'),
          text: errorText(e),
          action: FilledButton(onPressed: () => ref.invalidate(feedInfoProvider), child: Text(tr('Erneut'))),
        ),
        data: (i) {
          final active = i['active'] == true;
          final created = DateTime.tryParse(i['created_at'] as String? ?? '');
          final used = DateTime.tryParse(i['last_used_at'] as String? ?? '');
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              ContentWidth(
                maxWidth: 640,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      tr(
                        'Eine private Adresse, über die andere Programme deine Kolonien lesen können – nur lesen, '
                        'nichts ändern. Kalender-Apps zeigen damit alle Fälligkeiten, Home Assistant den Status '
                        'jeder Kolonie (z. B. Winterruhe → Heizung aus).',
                      ),
                      style: muted,
                    ),
                    const SizedBox(height: 16),
                    if (_created != null)
                      _Created(created: _created!)
                    else if (active)
                      Card(
                        child: ListTile(
                          leading: Icon(Icons.check_circle, color: context.colors.ok),
                          title: Text(tr('Adresse aktiv')),
                          subtitle: Text(
                            [
                              if (created != null) tr('erzeugt {0}', [S.dateTime(created)]),
                              used == null
                                  ? tr('noch nicht abgerufen')
                                  : tr('zuletzt abgerufen {0}', [S.dateTime(used)]),
                              tr('Die Adresse wird nur beim Erzeugen angezeigt.'),
                            ].join('\n'),
                          ),
                          isThreeLine: true,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _busy ? null : () => _create(replace: active),
                          icon: const Icon(Icons.link),
                          label: Text(active ? tr('Neue Adresse erzeugen') : tr('Adresse erzeugen')),
                        ),
                        if (active)
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _delete,
                            icon: const Icon(Icons.link_off),
                            label: Text(tr('Ausschalten')),
                          ),
                      ],
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
                    SectionHeader(tr('Home Assistant')),
                    Text(
                      tr(
                        'Die Konfiguration unten in configuration.yaml einfügen (bzw. zu einem vorhandenen „rest:“ ergänzen) '
                        'und Home Assistant neu starten. Dann gibt es pro Kolonie „… Winterruhe“ (an/aus) und „… überfällig“ '
                        '– z. B. als Auslöser, um die Heizmatte bei Winterruhe abzuschalten. Beispiele: docs/22-kalender-home-assistant.md.',
                      ),
                      style: muted,
                    ),
                    if (_created == null && !active) ...[
                      const SizedBox(height: 8),
                      Text(
                        tr('Erst eine Adresse erzeugen – dann erscheint hier die fertige Konfiguration.'),
                        style: muted,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Created extends ConsumerWidget {
  const _Created({required this.created});
  final Map<String, dynamic> created;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colonies = ref.read(repositoryProvider)?.colonies().where((c) => c.isCareActive).toList() ?? const <Colony>[];
    final statusUrl = created['status_url'] as String;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber, color: context.colors.soon),
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
            _Copyable(label: tr('Kalender-Adresse (iCal)'), value: created['calendar_url'] as String),
            _Copyable(label: tr('Status-Adresse (JSON)'), value: statusUrl),
            _Copyable(label: tr('Home Assistant (configuration.yaml)'), value: homeAssistantYaml(statusUrl, colonies)),
          ],
        ),
      ),
    );
  }
}

class _Copyable extends StatelessWidget {
  const _Copyable({required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              SelectableText(value, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ],
          ),
        ),
        IconButton(
          tooltip: tr('Kopieren'),
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: value));
            showUndoSnack(context, tr('Kopiert'));
          },
        ),
      ],
    ),
  );
}
