import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';

final sensorsProvider = StreamProvider<List<Map<String, dynamic>>>((ref) => watchRepo(ref, (r) => r.sensors()));

const _kinds = {
  'esp32': 'ESP32',
  'wifi': 'WLAN-Sensor',
  'bluetooth': 'Bluetooth (über Gateway)',
  'generic': 'Sonstiges',
};

/// Sensors (spec §23): temperature/humidity from an ESP32 or similar, sent
/// with its own API key to `POST /api/v1/sensors/{id}/measurements`.
class SensorsScreen extends ConsumerWidget {
  const SensorsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sensors = ref.watch(sensorsProvider).value ?? const [];
    final colonies = {for (final c in ref.watch(coloniesProvider).value ?? const <Colony>[]) c.id: c};
    return Scaffold(
      appBar: AppBar(title: const Text('Sensoren')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Sensor'),
      ),
      body: sensors.isEmpty
          ? const EmptyState(
              icon: Icons.sensors,
              title: 'Noch keine Sensoren',
              text:
                  'Ein ESP32 oder ein anderer WLAN-Sensor kann Temperatur und Luftfeuchtigkeit direkt an deinen '
                  'Server senden. Die Werte erscheinen in der Statistik der Kolonie.',
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
                        title: Text(s['name'] as String? ?? 'Sensor'),
                        subtitle: Text(
                          [
                            _kinds[s['kind']] ?? 'Sonstiges',
                            colonies[s['colony_id']]?.name ?? 'keiner Kolonie zugeordnet',
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
    if (t == null) return 'noch keine Daten';
    return 'zuletzt ${S.relativeDay(t, DateTime.now()).toLowerCase()} ${S.time(t)}';
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    var kind = 'esp32';
    String? colony;
    final owned = (ref.read(coloniesProvider).value ?? const <Colony>[])
        .where((c) => ref.read(repositoryProvider)!.roleOn(c.id) == 'owner')
        .toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: const Text('Sensor hinzufügen'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name', hintText: 'z. B. Regal A oben'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: kind,
                decoration: const InputDecoration(labelText: 'Art'),
                items: [for (final e in _kinds.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) => set(() => kind = v!),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: colony,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Kolonie'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('– keine –')),
                  for (final c in owned) DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => set(() => colony = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Anlegen')),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty || !context.mounted) return;
    try {
      // Online only: the key is created by the server and shown exactly once.
      final res =
          await ref.read(authProvider.notifier).api.post('/api/v1/sensors', {
                'name': name.text.trim(),
                'kind': kind,
                'colony_id': ?colony,
              })
              as Map<String, dynamic>;
      final data = (res['data'] as Map).cast<String, dynamic>();
      ref.read(repositoryProvider)!.adoptServerRecord('sensors', data);
      if (context.mounted) {
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
          tooltip: 'Kopieren',
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
      title: const Text('API-Schlüssel des Sensors'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Der Schlüssel wird nur jetzt angezeigt. Trage ihn im Sensor ein – geht er verloren, '
              'erzeugst du einfach einen neuen.',
              style: TextStyle(color: d.colors.soon),
            ),
            const SizedBox(height: 12),
            copyable('Adresse', url),
            copyable('Schlüssel (Header „Authorization: Bearer …“)', key),
            copyable('Test mit curl', curl),
            Text(
              'Werte: metric „temperature“ (°C) oder „humidity“ (%), optional measured_at (ISO 8601). '
              'Bis zu 500 Werte pro Anfrage, doppelte Sendungen werden ignoriert.',
              style: TextStyle(color: d.colors.muted, fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('Gespeichert'))],
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(s['name'] as String? ?? 'Sensor', style: Theme.of(context).textTheme.titleLarge),
          Text(
            'Kennung ${s['api_key_prefix'] ?? ''} · ${SensorsScreen._seen(s['last_seen_at'] as String?)}',
            style: TextStyle(color: context.colors.muted),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String?>(
            initialValue: owned.any((c) => c.id == s['colony_id']) ? s['colony_id'] as String? : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Kolonie'),
            items: [
              const DropdownMenuItem(value: null, child: Text('– keine –')),
              for (final c in owned) DropdownMenuItem(value: c.id, child: Text(c.name)),
            ],
            onChanged: (v) => repo.updateSensor(id, {'colony_id': v}),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Aktiv'),
            subtitle: const Text('Deaktivierte Sensoren werden abgewiesen'),
            value: s['active'] != false,
            onChanged: (v) => repo.updateSensor(id, {'active': v}),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.key),
            label: const Text('Neuen Schlüssel erzeugen'),
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
            label: const Text('Sensor löschen'),
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
