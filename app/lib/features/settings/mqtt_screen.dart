import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/i18n.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../shared/widgets.dart';

/// Home Assistant via MQTT for administrators: the server announces every
/// colony as a device (MQTT discovery) – new colonies appear by themselves,
/// archived ones disappear. docs/22-kalender-home-assistant.md.
final mqttProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return await ref.read(authProvider.notifier).api.get('/api/v1/admin/mqtt') as Map<String, dynamic>;
});

/// Request body; the password only when typed or removed.
Map<String, dynamic> mqttBody({
  required bool enabled,
  required String url,
  required String user,
  required String prefix,
  String password = '',
  bool removePassword = false,
}) => {
  'enabled': enabled,
  'url': url.trim(),
  'user': user.trim(),
  'prefix': prefix.trim(),
  if (removePassword) 'password': '' else if (password.isNotEmpty) 'password': password,
};

class MqttScreen extends ConsumerWidget {
  const MqttScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(mqttProvider)
      .when(
        loading: () => Scaffold(
          appBar: AppBar(title: Text(tr('Home Assistant (MQTT)'))),
          body: const Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => Scaffold(
          appBar: AppBar(title: Text(tr('Home Assistant (MQTT)'))),
          body: EmptyState(
            icon: Icons.cloud_off,
            title: tr('Nur mit Verbindung zum Server'),
            text: errorText(e),
            action: FilledButton(onPressed: () => ref.invalidate(mqttProvider), child: Text(tr('Erneut'))),
          ),
        ),
        data: (s) => _MqttForm(initial: s),
      );
}

class _MqttForm extends ConsumerStatefulWidget {
  const _MqttForm({required this.initial});
  final Map<String, dynamic> initial;
  @override
  ConsumerState<_MqttForm> createState() => _MqttFormState();
}

class _MqttFormState extends ConsumerState<_MqttForm> {
  late Map<String, dynamic> _s = widget.initial;
  late bool _enabled = _s['enabled'] == true;
  late final _url = TextEditingController(text: _s['url'] as String? ?? '');
  late final _user = TextEditingController(text: _s['user'] as String? ?? '');
  late final _prefix = TextEditingController(text: _s['prefix'] as String? ?? 'homeassistant');
  final _password = TextEditingController();
  bool _removePassword = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_url, _user, _prefix, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<bool> _save({bool quiet = false}) async {
    setState(() => _busy = true);
    try {
      final r = await ref
          .read(authProvider.notifier)
          .api
          .put(
            '/api/v1/admin/mqtt',
            mqttBody(
              enabled: _enabled,
              url: _url.text,
              user: _user.text,
              prefix: _prefix.text,
              password: _password.text,
              removePassword: _removePassword,
            ),
          );
      setState(() {
        _s = r as Map<String, dynamic>;
        _url.text = _s['url'] as String? ?? '';
        _password.clear();
        _removePassword = false;
      });
      if (!quiet && mounted) showUndoSnack(context, tr('Gespeichert'));
      return true;
    } catch (e) {
      if (mounted) showError(context, e);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    if (!await _save(quiet: true)) return;
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).api.post('/api/v1/admin/mqtt/test');
      if (mounted) showUndoSnack(context, tr('Verbindung zum MQTT-Broker klappt'));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = (_s['status'] as Map?)?.cast<String, dynamic>() ?? const {};
    final muted = TextStyle(color: context.colors.muted);
    final synced = DateTime.tryParse(st['last_sync'] as String? ?? '');
    final errAt = DateTime.tryParse(st['last_error_at'] as String? ?? '');
    final connected = st['connected'] == true;
    final failed = errAt != null && !connected;
    final passwordSet = _s['password_set'] == true && !_removePassword;
    final owner = _s['owner'] as String?;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Home Assistant (MQTT)')),
        actions: [TextButton(onPressed: _busy ? null : _save, child: Text(tr('Speichern')))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          ContentWidth(
            maxWidth: 640,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr(
                    'Jede Kolonie erscheint in Home Assistant als eigenes Gerät – mit Winterruhe (an/aus), '
                    'überfälliger und heute fälliger Pflege, nächster Pflege und letztem Messwert. Neue Kolonien '
                    'kommen von selbst dazu, archivierte oder abgegebene verschwinden wieder. Voraussetzung: die '
                    'MQTT-Integration in Home Assistant (z. B. mit dem Mosquitto-Add-on).',
                  ),
                  style: muted,
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: Icon(
                      failed ? Icons.error_outline : (connected ? Icons.check_circle : Icons.cloud_outlined),
                      color: failed ? context.colors.overdue : (connected ? context.colors.ok : context.colors.muted),
                    ),
                    title: Text(
                      connected
                          ? tr('Verbunden – {0} Kolonien in Home Assistant', [st['colonies'] ?? 0])
                          : (_s['enabled'] == true ? tr('Nicht verbunden') : tr('Ausgeschaltet')),
                    ),
                    subtitle: Text(
                      [
                        if (synced != null) tr('Zuletzt gesendet: {0}', [S.dateTime(synced)]),
                        if (failed) tr('Fehler ({0}): {1}', [S.dateTime(errAt), st['last_error']]),
                        if (owner != null && owner.isNotEmpty) tr('Gesendet werden die Kolonien von {0}.', [owner]),
                      ].join('\n'),
                    ),
                    trailing: IconButton(
                      tooltip: tr('Aktualisieren'),
                      icon: const Icon(Icons.refresh),
                      onPressed: () => ref.invalidate(mqttProvider),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Kolonien an Home Assistant senden')),
                  subtitle: Text(tr('Ausschalten entfernt die Geräte wieder aus Home Assistant.')),
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr('MQTT-Broker'),
                    hintText: 'mqtt://192.168.1.10:1883',
                    helperText: tr(
                      'Adresse des Brokers, den Home Assistant nutzt – meist die Adresse von Home Assistant mit '
                      'Port 1883. mqtts:// für TLS.',
                    ),
                    helperMaxLines: 3,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _user,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr('Benutzer'),
                    helperText: tr('Mosquitto-Add-on: ein Home-Assistant-Benutzer (am besten ein eigener)'),
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr('Passwort'),
                    hintText: passwordSet ? tr('gespeichert – leer lassen zum Behalten') : null,
                    suffixIcon: passwordSet
                        ? IconButton(
                            tooltip: tr('Passwort entfernen'),
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => setState(() => _removePassword = true),
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _prefix,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr('Discovery-Präfix'),
                    helperText: tr('Nur ändern, wenn es in Home Assistant geändert wurde (Standard: homeassistant)'),
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _test,
                      icon: const Icon(Icons.wifi_tethering),
                      label: Text(tr('Verbindung testen')),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  tr(
                    'Gesendet werden die Kolonien, die du pflegst (Besitzer oder Pfleger). Entitäten z. B. '
                    'binary_sensor.acm_colony_3_hibernation und sensor.acm_colony_3_overdue (3 = Kolonie-Nummer); '
                    'Beispiele für Automationen in docs/22-kalender-home-assistant.md.',
                  ),
                  style: muted.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
