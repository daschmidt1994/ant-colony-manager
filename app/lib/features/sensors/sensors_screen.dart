import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';
import '../../app/i18n.dart';

final sensorsProvider = StreamProvider<List<Map<String, dynamic>>>((ref) => watchRepo(ref, (r) => r.sensors()));

Map<String, String> get _kinds => {
  'esp32': 'ESP32',
  'wifi': 'WLAN-Sensor',
  'bluetooth': tr('Bluetooth (über Gateway)'),
  'home_assistant': 'Home Assistant',
  'generic': tr('Sonstiges'),
};

/// Entity ID as Home Assistant shows it: domain.name (e.g. sensor.formicarium_temperature).
bool validEntityId(String v) => RegExp(r'^[a-z_]+\.[a-z0-9_]+$').hasMatch(v);

/// Sensors (spec §23): temperature/humidity from an ESP32 or similar, sent
/// with its own API key to `POST /api/v1/sensors/{id}/measurements` – or read
/// by the server from Home Assistant entities (kind home_assistant).
class SensorsScreen extends ConsumerWidget {
  const SensorsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sensors = ref.watch(sensorsProvider).value ?? const [];
    final colonies = {for (final c in ref.watch(coloniesProvider).value ?? const <Colony>[]) c.id: c};
    return Scaffold(
      appBar: AppBar(title: Text(tr('Sensoren'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context, ref),
        icon: const Icon(Icons.add),
        label: Text(tr('Sensor')),
      ),
      body: sensors.isEmpty
          ? EmptyState(
              icon: Icons.sensors,
              title: tr('Noch keine Sensoren'),
              text: tr(
                'Ein ESP32 oder ein anderer WLAN-Sensor kann Temperatur und Luftfeuchtigkeit direkt an deinen '
                'Server senden. Die Werte erscheinen in der Statistik der Kolonie.',
              ),
            )
          : ContentWidth(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: [
                  for (final s in sensors)
                    Card(
                      child: ListTile(
                        leading: Icon(
                          Icons.sensors,
                          color: s['active'] == false ? context.colors.muted : Theme.of(context).colorScheme.primary,
                        ),
                        title: Text(s['name'] as String? ?? tr('Sensor')),
                        subtitle: Text(
                          [
                            _kinds[s['kind']] ?? tr('Sonstiges'),
                            colonies[s['colony_id']]?.name ?? tr('keiner Kolonie zugeordnet'),
                            _seen(s['last_seen_at'] as String?),
                            if (s['active'] == false) 'deaktiviert',
                          ].join(' · '),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _details(context, ref, s),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  static String _seen(String? at) {
    final t = at == null ? null : DateTime.tryParse(at);
    if (t == null) return tr('noch keine Daten');
    return tr('zuletzt {0} {1}', [S.relativeDayInline(t, DateTime.now()), S.time(t)]);
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    final haTemp = TextEditingController();
    final haHumid = TextEditingController();
    var kind = 'esp32';
    String? colony;
    final owned = (ref.read(coloniesProvider).value ?? const <Colony>[])
        .where((c) => ref.read(repositoryProvider)!.roleOn(c.id) == 'owner')
        .toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: Text(tr('Sensor hinzufügen')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: InputDecoration(labelText: tr('Name'), hintText: tr('z. B. Regal A oben')),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: kind,
                decoration: InputDecoration(labelText: tr('Art')),
                items: [for (final e in _kinds.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) => set(() => kind = v!),
              ),
              if (kind == 'home_assistant') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: haTemp,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr('Entität Temperatur'),
                    hintText: 'sensor.formicarium_temperature',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: haHumid,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr('Entität Luftfeuchtigkeit'),
                    hintText: 'sensor.formicarium_humidity',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: colony,
                isExpanded: true,
                decoration: InputDecoration(labelText: tr('Kolonie')),
                items: [
                  DropdownMenuItem(value: null, child: Text(tr('– keine –'))),
                  for (final c in owned) DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => set(() => colony = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Abbrechen'))),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Anlegen'))),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty || !context.mounted) return;
    final ha = kind == 'home_assistant';
    final temp = haTemp.text.trim(), humid = haHumid.text.trim();
    if (ha && ((temp.isEmpty && humid.isEmpty) || [temp, humid].any((e) => e.isNotEmpty && !validEntityId(e)))) {
      showUndoSnack(context, tr('Mindestens eine Entität angeben, z. B. sensor.formicarium_temperature'));
      return;
    }
    try {
      // Online only: the key is created by the server and shown exactly once.
      final res =
          await ref.read(authProvider.notifier).api.post('/api/v1/sensors', {
                'name': name.text.trim(),
                'kind': kind,
                'colony_id': ?colony,
                if (ha && temp.isNotEmpty) 'ha_temperature_entity': temp,
                if (ha && humid.isNotEmpty) 'ha_humidity_entity': humid,
              })
              as Map<String, dynamic>;
      final data = (res['data'] as Map).cast<String, dynamic>();
      ref.read(repositoryProvider)!.adoptServerRecord('sensors', data);
      if (ha) {
        if (context.mounted) {
          showUndoSnack(context, tr('Der Server liest die Werte alle 5 Minuten aus Home Assistant'));
        }
      } else if (context.mounted) {
        await _showKey(context, ref, data['id'] as String, (res['extra'] as Map)['api_key'] as String);
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _details(BuildContext context, WidgetRef ref, Map<String, dynamic> s) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (c) => _SensorSheet(sensor: s),
  );
}

Future<void> _showKey(BuildContext context, WidgetRef ref, String id, String key) {
  final auth = ref.read(authProvider);
  final url = '${auth is SignedIn ? auth.serverUrl : ''}/api/v1/sensors/$id/measurements';
  final curl =
      "curl -X POST '$url' \\\n  -H 'Authorization: Bearer $key' \\\n  -H 'Content-Type: application/json' \\\n"
      "  -d '{\"readings\":[{\"metric\":\"temperature\",\"value\":24.5},{\"metric\":\"humidity\",\"value\":62}]}'";
  Widget copyable(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              SelectableText(value, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ],
          ),
        ),
        IconButton(
          tooltip: tr('Kopieren'),
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () => Clipboard.setData(ClipboardData(text: value)),
        ),
      ],
    ),
  );
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (d) => AlertDialog(
      title: Text(tr('API-Schlüssel des Sensors')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr(
                'Der Schlüssel wird nur jetzt angezeigt. Trage ihn im Sensor ein – geht er verloren, '
                'erzeugst du einfach einen neuen.',
              ),
              style: TextStyle(color: d.colors.soon),
            ),
            const SizedBox(height: 12),
            copyable(tr('Adresse'), url),
            copyable(tr('Schlüssel (Header „Authorization: Bearer …“)'), key),
            copyable(tr('Test mit curl'), curl),
            Text(
              tr(
                'Werte: metric „temperature“ (°C) oder „humidity“ (%), optional measured_at (ISO 8601). '
                'Bis zu 500 Werte pro Anfrage, doppelte Sendungen werden ignoriert.',
              ),
              style: TextStyle(color: d.colors.muted, fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(d), child: Text(tr('Gespeichert')))],
    ),
  );
}

class _SensorSheet extends ConsumerWidget {
  const _SensorSheet({required this.sensor});
  final Map<String, dynamic> sensor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(repositoryProvider)!;
    final s = ref.watch(sensorsProvider).value?.where((x) => x['id'] == sensor['id']).firstOrNull ?? sensor;
    final owned = (ref.watch(coloniesProvider).value ?? const <Colony>[])
        .where((c) => repo.roleOn(c.id) == 'owner')
        .toList();
    final id = s['id'] as String;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(s['name'] as String? ?? tr('Sensor'), style: Theme.of(context).textTheme.titleLarge),
          Text(
            tr('Kennung {0} · {1}', [s['api_key_prefix'] ?? '', SensorsScreen._seen(s['last_seen_at'] as String?)]),
            style: TextStyle(color: context.colors.muted),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String?>(
            initialValue: owned.any((c) => c.id == s['colony_id']) ? s['colony_id'] as String? : null,
            isExpanded: true,
            decoration: InputDecoration(labelText: tr('Kolonie')),
            items: [
              DropdownMenuItem(value: null, child: Text(tr('– keine –'))),
              for (final c in owned) DropdownMenuItem(value: c.id, child: Text(c.name)),
            ],
            onChanged: (v) => repo.updateSensor(id, {'colony_id': v}),
          ),
          if (s['kind'] == 'home_assistant') ...[
            const SizedBox(height: 12),
            _EntityField(sensor: s, field: 'ha_temperature_entity', label: tr('Entität Temperatur')),
            const SizedBox(height: 8),
            _EntityField(sensor: s, field: 'ha_humidity_entity', label: tr('Entität Luftfeuchtigkeit')),
            const SizedBox(height: 4),
            Text(
              tr(
                'Der Server liest die Werte alle 5 Minuten aus Home Assistant (Adresse und Zugriffstoken: '
                'Server-Verwaltung → Home Assistant (MQTT)).',
              ),
              style: TextStyle(color: context.colors.muted, fontSize: 12),
            ),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Aktiv')),
            subtitle: Text(tr('Deaktivierte Sensoren werden abgewiesen')),
            value: s['active'] != false,
            onChanged: (v) => repo.updateSensor(id, {'active': v}),
          ),
          SectionHeader(tr('Grenzwerte')),
          Text(
            tr(
              'Liegt ein Messwert außerhalb, entsteht automatisch ein „Problem“-Eintrag bei der Kolonie '
              'und eine Benachrichtigung (höchstens alle 6 Stunden).',
            ),
            style: TextStyle(color: context.colors.muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _LimitField(sensor: s, field: 'temp_min', label: tr('Temp. min'), suffix: '°C'),
              const SizedBox(width: 8),
              _LimitField(sensor: s, field: 'temp_max', label: tr('Temp. max'), suffix: '°C'),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _LimitField(sensor: s, field: 'humidity_min', label: tr('Feuchte min'), suffix: '%'),
              const SizedBox(width: 8),
              _LimitField(sensor: s, field: 'humidity_max', label: tr('Feuchte max'), suffix: '%'),
            ],
          ),
          const SizedBox(height: 16),
          if (s['kind'] != 'home_assistant')
            OutlinedButton.icon(
              icon: const Icon(Icons.key),
              label: Text(tr('Neuen Schlüssel erzeugen')),
              onPressed: () async {
                try {
                  final res =
                      await ref.read(authProvider.notifier).api.post('/api/v1/sensors/$id/rotate-key')
                          as Map<String, dynamic>;
                  if (context.mounted) await _showKey(context, ref, id, res['api_key'] as String);
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: context.colors.overdue),
            icon: const Icon(Icons.delete_outline),
            label: Text(tr('Sensor löschen')),
            onPressed: () {
              repo.deleteSensor(id);
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }
}

/// Saves when editing is finished; empty = no limit.
class _LimitField extends ConsumerStatefulWidget {
  const _LimitField({required this.sensor, required this.field, required this.label, required this.suffix});
  final Map<String, dynamic> sensor;
  final String field, label, suffix;
  @override
  ConsumerState<_LimitField> createState() => _LimitFieldState();
}

class _LimitFieldState extends ConsumerState<_LimitField> {
  late final _c = TextEditingController(text: _text(widget.sensor[widget.field]));
  final _focus = FocusNode();

  static String _text(Object? v) => v == null ? '' : S.decimal((v as num).toDouble()).replaceAll(',0', '');

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _save();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _save() {
    final t = _c.text.trim().replaceAll(',', '.');
    final v = t.isEmpty ? null : double.tryParse(t);
    if (t.isNotEmpty && v == null) return;
    final old = (widget.sensor[widget.field] as num?)?.toDouble();
    if (v == old) return;
    ref.read(repositoryProvider)!.updateSensor(widget.sensor['id'] as String, {widget.field: v});
  }

  @override
  Widget build(BuildContext context) => Expanded(
    child: TextField(
      controller: _c,
      focusNode: _focus,
      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
      decoration: InputDecoration(labelText: widget.label, suffixText: widget.suffix, isDense: true),
      onSubmitted: (_) => _save(),
    ),
  );
}

/// Home Assistant entity of a sensor; saves when editing is finished (empty = none).
class _EntityField extends ConsumerStatefulWidget {
  const _EntityField({required this.sensor, required this.field, required this.label});
  final Map<String, dynamic> sensor;
  final String field, label;
  @override
  ConsumerState<_EntityField> createState() => _EntityFieldState();
}

class _EntityFieldState extends ConsumerState<_EntityField> {
  late final _c = TextEditingController(text: widget.sensor[widget.field] as String? ?? '');
  final _focus = FocusNode();
  bool _bad = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _save();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _save() {
    final v = _c.text.trim();
    setState(() => _bad = v.isNotEmpty && !validEntityId(v));
    if (_bad || v == (widget.sensor[widget.field] ?? '')) return;
    ref.read(repositoryProvider)!.updateSensor(widget.sensor['id'] as String, {widget.field: v.isEmpty ? null : v});
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _c,
    focusNode: _focus,
    autocorrect: false,
    decoration: InputDecoration(
      labelText: widget.label,
      hintText: 'sensor.…',
      isDense: true,
      errorText: _bad ? tr('Format: sensor.name') : null,
    ),
    onSubmitted: (_) => _save(),
  );
}
