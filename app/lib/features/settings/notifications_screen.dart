import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../shared/widgets.dart';

/// Notification settings on the server (ntfy, e-mail per topic). Not synced –
/// the ntfy token never leaves the server, so this screen needs a connection.
final notifyPrefsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return await ref.read(authProvider.notifier).api.get('/api/v1/me/notifications') as Map<String, dynamic>;
});

const overdueRepeats = {0: 'nur einmal', 6: 'alle 6 Stunden', 12: 'alle 12 Stunden', 24: 'täglich'};
const sensorRepeats = {0: 'nur einmal', 1: 'stündlich', 6: 'alle 6 Stunden', 12: 'alle 12 Stunden', 24: 'täglich'};
const winterRepeats = {0: 'nur einmal', 24: 'täglich'};

const defaultNtfyServer = 'https://ntfy.sh';

/// ntfy topic names: letters, digits, _ and -, at most 64 characters.
final ntfyTopicPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Splits a stored topic address into server and topic
/// ("https://ntfy.example.com/sub/ameisen" → server …/sub, topic ameisen).
(String server, String topic) splitNtfyUrl(String url) {
  final u = url.trim();
  final i = u.lastIndexOf('/');
  if (u.isEmpty || i <= 'https://'.length - 1) return (defaultNtfyServer, '');
  return (u.substring(0, i), u.substring(i + 1));
}

/// Server + topic → topic address; "" without a topic. A server without
/// scheme gets https://.
String joinNtfyUrl(String server, String topic) {
  final t = topic.trim();
  if (t.isEmpty) return '';
  var s = server.trim().replaceAll(RegExp(r'/+$'), '');
  if (s.isEmpty) s = defaultNtfyServer;
  if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
  return '$s/$t';
}

/// A hard-to-guess topic name: on ntfy.sh anyone who knows it can read along.
String randomTopic([Random? rnd]) {
  const chars = 'abcdefghijkmnpqrstuvwxyz23456789';
  final r = rnd ?? Random.secure();
  return 'ameisen-${List.generate(12, (_) => chars[r.nextInt(chars.length)]).join()}';
}

/// Request body from the edited state; the token only when it was changed.
Map<String, dynamic> notifyPrefsBody(Map<String, dynamic> p, {String? newToken, bool removeToken = false}) => {
  for (final k in const [
    'ntfy_url',
    'digest_ntfy',
    'overdue_email',
    'overdue_ntfy',
    'overdue_repeat_hours',
    'sensor_email',
    'sensor_ntfy',
    'sensor_repeat_hours',
    'winter_email',
    'winter_ntfy',
    'winter_repeat_hours',
    'quiet_start',
    'quiet_end',
    'quiet_except_sensor',
  ])
    k: p[k],
  if (removeToken)
    'ntfy_token': ''
  else if (newToken != null && newToken.trim().isNotEmpty)
    'ntfy_token': newToken.trim(),
};

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(notifyPrefsProvider)
      .when(
        loading: () => Scaffold(
          appBar: AppBar(title: const Text('Benachrichtigungen')),
          body: const Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => Scaffold(
          appBar: AppBar(title: const Text('Benachrichtigungen')),
          body: EmptyState(
            icon: Icons.cloud_off,
            title: 'Nur mit Verbindung zum Server',
            text: errorText(e),
            action: FilledButton(onPressed: () => ref.invalidate(notifyPrefsProvider), child: const Text('Erneut')),
          ),
        ),
        data: (p) => _NotificationsForm(initial: p),
      );
}

class _NotificationsForm extends ConsumerStatefulWidget {
  const _NotificationsForm({required this.initial});
  final Map<String, dynamic> initial;
  @override
  ConsumerState<_NotificationsForm> createState() => _NotificationsFormState();
}

class _NotificationsFormState extends ConsumerState<_NotificationsForm> {
  late final Map<String, dynamic> _p = Map.of(widget.initial);
  late final (String, String) _split = splitNtfyUrl(_p['ntfy_url'] as String? ?? '');
  late final _server = TextEditingController(text: _split.$1);
  late final _topic = TextEditingController(text: _split.$2);
  final _token = TextEditingController();
  bool _removeToken = false;
  bool _dirty = false;
  bool _busy = false;

  @override
  void dispose() {
    _server.dispose();
    _topic.dispose();
    _token.dispose();
    super.dispose();
  }

  String get _ntfyUrl => joinNtfyUrl(_server.text, _topic.text);

  void _addressChanged() {
    _set('ntfy_url', _ntfyUrl);
    if (_ntfyUrl.isEmpty) {
      for (final k in const ['digest_ntfy', 'overdue_ntfy', 'sensor_ntfy', 'winter_ntfy']) {
        _p[k] = false;
      }
    }
  }

  void _set(String key, Object? value) => setState(() {
    _p[key] = value;
    _dirty = true;
  });

  bool get _emailAvailable => _p['email_available'] == true;
  bool get _tokenSet => _p['ntfy_token_set'] == true && !_removeToken;

  Future<bool> _save({bool quiet = false}) async {
    final topic = _topic.text.trim();
    if (topic.isNotEmpty && !ntfyTopicPattern.hasMatch(topic)) {
      showError(context, 'Topic: nur Buchstaben, Ziffern, _ und - (max. 64 Zeichen)');
      return false;
    }
    setState(() => _busy = true);
    try {
      _p['ntfy_url'] = _ntfyUrl;
      final res = await ref
          .read(authProvider.notifier)
          .api
          .put('/api/v1/me/notifications', notifyPrefsBody(_p, newToken: _token.text, removeToken: _removeToken));
      setState(() {
        _p
          ..clear()
          ..addAll(res as Map<String, dynamic>);
        _token.clear();
        _removeToken = false;
        _dirty = false;
      });
      if (!quiet && mounted) showUndoSnack(context, 'Gespeichert');
      return true;
    } catch (e) {
      if (mounted) showError(context, e);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    if ((_dirty || _token.text.isNotEmpty) && !await _save(quiet: true)) return;
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).api.post('/api/v1/me/notifications/test');
      if (mounted) showUndoSnack(context, 'Testnachricht gesendet – schau in die ntfy-App');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickTime(String key, String fallback) async {
    final parts = ((_p[key] as String?)?.isNotEmpty == true ? _p[key] as String : fallback).split(':');
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
    );
    if (t != null) _set(key, '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).value;
    final repo = ref.watch(repositoryProvider);
    final muted = TextStyle(color: context.colors.muted);
    final hasNtfy = _ntfyUrl.isNotEmpty;
    final (h, m) = settings?.digestTime ?? (18, 0);
    final digestTime = '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    final quietOn = (_p['quiet_start'] as String? ?? '').isNotEmpty;

    // App (Android) is a synced user setting – saved right away, works offline.
    Widget channels(String prefix, {required String appSetting, bool? emailValue, ValueChanged<bool>? onEmail}) => Wrap(
      spacing: 8,
      children: [
        FilterChip(
          avatar: const Icon(Icons.phone_android, size: 18),
          label: const Text('App'),
          selected: settings?.json[appSetting] as bool? ?? true,
          onSelected: repo == null ? null : (v) => repo.updateSettings({appSetting: v}),
        ),
        FilterChip(
          avatar: const Icon(Icons.mail_outline, size: 18),
          label: const Text('E-Mail'),
          selected: emailValue ?? _p['${prefix}_email'] == true,
          onSelected: _emailAvailable ? (onEmail ?? (v) => _set('${prefix}_email', v)) : null,
        ),
        FilterChip(
          avatar: const Icon(Icons.notifications_outlined, size: 18),
          label: const Text('ntfy'),
          selected: _p['${prefix}_ntfy'] == true,
          onSelected: hasNtfy ? (v) => _set('${prefix}_ntfy', v) : null,
        ),
      ],
    );

    Widget repeat(String key, Map<int, String> options) => DropdownButtonFormField<int>(
      initialValue: options.containsKey(_p[key]) ? _p[key] as int : options.keys.first,
      decoration: const InputDecoration(labelText: 'Solange es besteht, erinnern', isDense: true),
      items: [for (final e in options.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
      onChanged: (v) => _set(key, v),
    );

    Widget topic(IconData icon, String title, String subtitle, List<Widget> children) => Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: context.colors.muted),
                const SizedBox(width: 12),
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 2, bottom: 8),
              child: Text(subtitle, style: muted),
            ),
            for (final c in children) Padding(padding: const EdgeInsets.only(left: 36, top: 6), child: c),
          ],
        ),
      ),
    );

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final save = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('Änderungen speichern?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Verwerfen')),
              FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Speichern')),
            ],
          ),
        );
        if (save == null || !context.mounted) return;
        if (save && !await _save(quiet: true)) return;
        setState(() => _dirty = false);
        if (context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Benachrichtigungen'),
          actions: [TextButton(onPressed: _busy || !_dirty ? null : _save, child: const Text('Speichern'))],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            ContentWidth(
              maxWidth: 640,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionHeader('ntfy'),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Die App „ntfy“ (F-Droid oder Play Store) installieren, dort denselben Server und '
                            'dasselbe Topic abonnieren. Eigener ntfy-Server: seine Adresse als Server eintragen, '
                            'dazu ein Token. Auf dem öffentlichen ntfy.sh kann jeder mitlesen, der den Topic-Namen '
                            'kennt – dort einen schwer zu erratenden Namen wählen (Würfel).',
                            style: muted,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _server,
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            decoration: const InputDecoration(
                              labelText: 'Server',
                              hintText: 'https://ntfy.meinedomain.at',
                              helperText: 'Standard: https://ntfy.sh – eigener Server: dessen Domain',
                            ),
                            onChanged: (_) => _addressChanged(),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _topic,
                            autocorrect: false,
                            decoration: InputDecoration(
                              labelText: 'Topic',
                              hintText: 'ameisen',
                              errorText: _topic.text.trim().isEmpty || ntfyTopicPattern.hasMatch(_topic.text.trim())
                                  ? null
                                  : 'Nur Buchstaben, Ziffern, _ und - (max. 64)',
                              suffixIcon: IconButton(
                                tooltip: 'Zufälliger Topic-Name',
                                icon: const Icon(Icons.casino_outlined),
                                onPressed: () {
                                  _topic.text = randomTopic();
                                  _addressChanged();
                                },
                              ),
                            ),
                            onChanged: (_) => _addressChanged(),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _token,
                            obscureText: true,
                            autocorrect: false,
                            decoration: InputDecoration(
                              labelText: 'Token (für eigenen Server mit Zugriffsschutz)',
                              hintText: _tokenSet
                                  ? 'gespeichert – leer lassen zum Behalten'
                                  : 'tk_… oder benutzer:passwort',
                              suffixIcon: _tokenSet
                                  ? IconButton(
                                      tooltip: 'Token entfernen',
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () => setState(() {
                                        _removeToken = true;
                                        _dirty = true;
                                      }),
                                    )
                                  : null,
                            ),
                            onChanged: (_) => setState(() => _dirty = true),
                          ),
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.send_outlined),
                              label: const Text('Testnachricht senden'),
                              onPressed: _busy || !hasNtfy ? null : _test,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (!_emailAvailable)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'E-Mail ist nicht verfügbar: Der Server hat keinen E-Mail-Versand eingerichtet '
                        '(Administrator: Mehr → Server-Verwaltung → E-Mail-Versand).',
                        style: muted.copyWith(fontSize: 12),
                      ),
                    ),
                  const SectionHeader('Themen'),
                  topic(
                    Icons.schedule,
                    'Tages-Überblick',
                    'Täglich um $digestTime: welche Kolonien heute Pflege brauchen. '
                        'Uhrzeit unter Mehr → Erinnerungen.',
                    [
                      channels(
                        'digest',
                        appSetting: 'notify_digest_app',
                        emailValue: settings?.emailDigest ?? false,
                        onEmail: repo == null ? null : (v) => repo.updateSettings({'email_digest': v}),
                      ),
                    ],
                  ),
                  topic(
                    Icons.warning_amber_rounded,
                    'Pflege überfällig',
                    'Sobald eine Aufgabe (Fütterung, Wasser, Reinigung …) überfällig ist. '
                        'Mit „Erledigt“ und „Morgen“ (heute keine Zeit → um einen Tag verschieben).',
                    [channels('overdue', appSetting: 'notify_overdue'), repeat('overdue_repeat_hours', overdueRepeats)],
                  ),
                  topic(
                    Icons.thermostat,
                    'Sensor-Alarm',
                    'Temperatur oder Luftfeuchte außerhalb der Grenzwerte eines Sensors (Mehr → Sensoren).',
                    [channels('sensor', appSetting: 'notify_sensor_app'), repeat('sensor_repeat_hours', sensorRepeats)],
                  ),
                  topic(
                    Icons.ac_unit,
                    'Winterruhe',
                    'Am geplanten Tag ab $digestTime: „Winterruhe beginnen?“ bzw. „aufwecken?“ – '
                        'mit „Morgen“ um einen Tag verschieben.',
                    [channels('winter', appSetting: 'notify_winter_app'), repeat('winter_repeat_hours', winterRepeats)],
                  ),
                  const SectionHeader('Ruhezeiten'),
                  Card(
                    child: Column(
                      children: [
                        SwitchListTile(
                          secondary: const Icon(Icons.bedtime_outlined),
                          title: const Text('Ruhezeiten'),
                          subtitle: Text(
                            quietOn
                                ? 'Von ${_p['quiet_start']} bis ${_p['quiet_end']} keine Meldungen – danach kommen sie gesammelt'
                                : 'z. B. nachts keine Meldungen',
                          ),
                          value: quietOn,
                          onChanged: (v) => setState(() {
                            _p['quiet_start'] = v ? '22:00' : '';
                            _p['quiet_end'] = v ? '07:00' : '';
                            _dirty = true;
                          }),
                        ),
                        if (quietOn) ...[
                          ListTile(
                            leading: const SizedBox(width: 24),
                            title: const Text('Von'),
                            trailing: Text(_p['quiet_start'] as String, style: const TextStyle(fontSize: 16)),
                            onTap: () => _pickTime('quiet_start', '22:00'),
                          ),
                          ListTile(
                            leading: const SizedBox(width: 24),
                            title: const Text('Bis'),
                            trailing: Text(_p['quiet_end'] as String, style: const TextStyle(fontSize: 16)),
                            onTap: () => _pickTime('quiet_end', '07:00'),
                          ),
                          SwitchListTile(
                            secondary: const SizedBox(width: 24),
                            title: const Text('Sensor-Alarme trotzdem melden'),
                            value: _p['quiet_except_sensor'] == true,
                            onChanged: (v) => _set('quiet_except_sensor', v),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Die Android-App erinnert zusätzlich selbst (Mehr → Erinnerungen). ntfy und E-Mail kommen '
                    'vom Server – auch wenn das Handy aus ist.',
                    style: muted.copyWith(fontSize: 12),
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
