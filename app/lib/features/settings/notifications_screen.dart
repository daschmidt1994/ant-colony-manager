import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../shared/widgets.dart';
import 'server_clock.dart';
import '../reminders/reminders.dart';
import '../../app/i18n.dart';

/// Notification settings on the server (ntfy, e-mail per topic). Not synced –
/// the ntfy token never leaves the server, so this screen needs a connection.
final notifyPrefsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return await ref.read(authProvider.notifier).api.get('/api/v1/me/notifications') as Map<String, dynamic>;
});

Map<int, String> get overdueRepeats => {
  0: tr('nur einmal'),
  6: tr('alle 6 Stunden'),
  12: tr('alle 12 Stunden'),
  24: tr('täglich'),
};
Map<int, String> get sensorRepeats => {
  0: tr('nur einmal'),
  1: tr('stündlich'),
  6: tr('alle 6 Stunden'),
  12: tr('alle 12 Stunden'),
  24: tr('täglich'),
};
Map<int, String> get winterRepeats => {0: tr('nur einmal'), 24: tr('täglich')};

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
          appBar: AppBar(title: Text(tr('Benachrichtigungen'))),
          body: const Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => Scaffold(
          appBar: AppBar(title: Text(tr('Benachrichtigungen'))),
          body: EmptyState(
            icon: Icons.cloud_off,
            title: tr('Nur mit Verbindung zum Server'),
            text: errorText(e),
            action: FilledButton(onPressed: () => ref.invalidate(notifyPrefsProvider), child: Text(tr('Erneut'))),
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
      showError(context, tr('Topic: nur Buchstaben, Ziffern, _ und - (max. 64 Zeichen)'));
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
    if ((_dirty || _token.text.isNotEmpty) && !await _save(quiet: true)) return;
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).api.post('/api/v1/me/notifications/test');
      if (mounted) showUndoSnack(context, tr('Testnachricht gesendet – schau in die ntfy-App'));
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

    // One switch per channel – on/off at a glance; unavailable channels are
    // off and say why. App (Android) is a synced user setting (saved at once,
    // works offline), e-mail and ntfy are saved with „Speichern“.
    Widget channels(String prefix, {required String appSetting, bool? emailValue, ValueChanged<bool>? onEmail}) {
      final app = settings?.json[appSetting] as bool? ?? true;
      final email = _emailAvailable && (emailValue ?? _p['${prefix}_email'] == true);
      final ntfy = hasNtfy && _p['${prefix}_ntfy'] == true;
      final active = [if (app) tr('App'), if (email) 'E-Mail', if (ntfy) 'ntfy'];
      final on = active.isNotEmpty;
      Widget row(IconData icon, String label, bool value, ValueChanged<bool>? onChanged, String? unavailable) =>
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
            secondary: Icon(icon, color: value ? context.colors.ok : context.colors.muted),
            title: Text(label, style: const TextStyle(fontSize: 15)),
            subtitle: unavailable == null ? null : Text(unavailable),
            value: value,
            onChanged: onChanged,
          );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: (on ? context.colors.ok : context.colors.muted).withValues(alpha: .14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  on ? Icons.notifications_active : Icons.notifications_off_outlined,
                  size: 18,
                  color: on ? context.colors.ok : context.colors.muted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    on ? tr('Aktiv: {0}', [active.join(', ')]) : tr('Aus – keine Benachrichtigung'),
                    style: TextStyle(fontWeight: FontWeight.w600, color: on ? context.colors.ok : context.colors.muted),
                  ),
                ),
              ],
            ),
          ),
          row(
            Icons.phone_android,
            tr('App'),
            app,
            repo == null
                ? null
                : (v) {
                    repo.updateSettings({appSetting: v});
                    if (v) requestReminderPermission().then((_) => ref.invalidate(reminderStatusProvider));
                  },
            null,
          ),
          row(
            Icons.mail_outline,
            'E-Mail',
            email,
            _emailAvailable ? (onEmail ?? (v) => _set('${prefix}_email', v)) : null,
            _emailAvailable ? null : tr('nicht eingerichtet (Server-Verwaltung)'),
          ),
          row(
            Icons.notifications_outlined,
            'ntfy',
            ntfy,
            hasNtfy ? (v) => _set('${prefix}_ntfy', v) : null,
            hasNtfy ? null : tr('oben Server und Topic eintragen'),
          ),
        ],
      );
    }

    Widget repeat(String key, Map<int, String> options) => DropdownButtonFormField<int>(
      initialValue: options.containsKey(_p[key]) ? _p[key] as int : options.keys.first,
      decoration: InputDecoration(labelText: tr('Solange es besteht, erinnern'), isDense: true),
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
            title: Text(tr('Änderungen speichern?')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Verwerfen'))),
              FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Speichern'))),
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
          title: Text(tr('Benachrichtigungen')),
          actions: [TextButton(onPressed: _busy || !_dirty ? null : _save, child: Text(tr('Speichern')))],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            ContentWidth(
              maxWidth: 640,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const DeviceNotificationsCard(),
                  const SectionHeader('ntfy'),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            tr(
                              'Die App „ntfy“ (F-Droid oder Play Store) installieren, dort denselben Server und '
                              'dasselbe Topic abonnieren. Eigener ntfy-Server: seine Adresse als Server eintragen, '
                              'dazu ein Token. Auf dem öffentlichen ntfy.sh kann jeder mitlesen, der den Topic-Namen '
                              'kennt – dort einen schwer zu erratenden Namen wählen (Würfel).',
                            ),
                            style: muted,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _server,
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            decoration: InputDecoration(
                              labelText: tr('Server'),
                              hintText: 'https://ntfy.meinedomain.at',
                              helperText: tr('Standard: https://ntfy.sh – eigener Server: dessen Domain'),
                            ),
                            onChanged: (_) => _addressChanged(),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _topic,
                            autocorrect: false,
                            decoration: InputDecoration(
                              labelText: tr('Topic'),
                              hintText: 'ameisen',
                              errorText: _topic.text.trim().isEmpty || ntfyTopicPattern.hasMatch(_topic.text.trim())
                                  ? null
                                  : tr('Nur Buchstaben, Ziffern, _ und - (max. 64)'),
                              suffixIcon: IconButton(
                                tooltip: tr('Zufälliger Topic-Name'),
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
                              labelText: tr('Token (für eigenen Server mit Zugriffsschutz)'),
                              hintText: _tokenSet
                                  ? tr('gespeichert – leer lassen zum Behalten')
                                  : tr('tk_… oder benutzer:passwort'),
                              suffixIcon: _tokenSet
                                  ? IconButton(
                                      tooltip: tr('Token entfernen'),
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
                              label: Text(tr('Testnachricht senden')),
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
                        tr(
                          'E-Mail ist nicht verfügbar: Der Server hat keinen E-Mail-Versand eingerichtet '
                          '(Administrator: Mehr → Server-Verwaltung → E-Mail-Versand).',
                        ),
                        style: muted.copyWith(fontSize: 12),
                      ),
                    ),
                  SectionHeader(tr('Themen')),
                  topic(
                    Icons.schedule,
                    tr('Tages-Überblick'),
                    tr(
                      'Täglich um {0}: welche Kolonien heute Pflege brauchen. '
                      'Uhrzeit unter Mehr → Erinnerungen.',
                      [digestTime],
                    ),
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
                    tr('Pflege überfällig'),
                    tr(
                      'Sobald eine Aufgabe (Fütterung, Wasser, Reinigung …) überfällig ist. '
                      'Mit „Erledigt“ und „Morgen“ (heute keine Zeit → um einen Tag verschieben).',
                    ),
                    [channels('overdue', appSetting: 'notify_overdue'), repeat('overdue_repeat_hours', overdueRepeats)],
                  ),
                  topic(
                    Icons.thermostat,
                    tr('Sensor-Alarm'),
                    tr('Temperatur oder Luftfeuchte außerhalb der Grenzwerte eines Sensors (Mehr → Sensoren).'),
                    [channels('sensor', appSetting: 'notify_sensor_app'), repeat('sensor_repeat_hours', sensorRepeats)],
                  ),
                  topic(
                    Icons.ac_unit,
                    tr('Winterruhe'),
                    tr(
                      'Am geplanten Tag ab {0}: „Winterruhe beginnen?“ bzw. „aufwecken?“ – '
                      'mit „Morgen“ um einen Tag verschieben.',
                      [digestTime],
                    ),
                    [channels('winter', appSetting: 'notify_winter_app'), repeat('winter_repeat_hours', winterRepeats)],
                  ),
                  SectionHeader(tr('Ruhezeiten')),
                  Card(
                    child: Column(
                      children: [
                        SwitchListTile(
                          secondary: const Icon(Icons.bedtime_outlined),
                          title: Text(tr('Ruhezeiten')),
                          subtitle: Text(
                            quietOn
                                ? tr('Von {0} bis {1} keine Meldungen – danach kommen sie gesammelt', [
                                    _p['quiet_start'],
                                    _p['quiet_end'],
                                  ])
                                : tr('z. B. nachts keine Meldungen'),
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
                            title: Text(tr('Von')),
                            trailing: Text(_p['quiet_start'] as String, style: const TextStyle(fontSize: 16)),
                            onTap: () => _pickTime('quiet_start', '22:00'),
                          ),
                          ListTile(
                            leading: const SizedBox(width: 24),
                            title: Text(tr('Bis')),
                            trailing: Text(_p['quiet_end'] as String, style: const TextStyle(fontSize: 16)),
                            onTap: () => _pickTime('quiet_end', '07:00'),
                          ),
                          SwitchListTile(
                            secondary: const SizedBox(width: 24),
                            title: Text(tr('Sensor-Alarme trotzdem melden')),
                            value: _p['quiet_except_sensor'] == true,
                            onChanged: (v) => _set('quiet_except_sensor', v),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr(
                      'Die Android-App erinnert zusätzlich selbst (Mehr → Erinnerungen). ntfy und E-Mail kommen '
                      'vom Server – auch wenn das Handy aus ist.',
                    ),
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

final reminderStatusProvider = FutureProvider.autoDispose<ReminderStatus?>(
  (ref) => reminderStatus(ref.read(databaseProvider)),
);

/// Android only: why app notifications might not arrive on this phone –
/// permission, battery optimisation, last background check, last error,
/// next daily overview – plus a test notification.
class DeviceNotificationsCard extends ConsumerStatefulWidget {
  const DeviceNotificationsCard({super.key});
  @override
  ConsumerState<DeviceNotificationsCard> createState() => _DeviceNotificationsCardState();
}

class _DeviceNotificationsCardState extends ConsumerState<DeviceNotificationsCard> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // back from the system settings → show the new state
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.invalidate(reminderStatusProvider);
  }

  Future<void> _allow() async {
    if (!await requestReminderPermission()) await openNotificationSettings();
    ref.invalidate(reminderStatusProvider);
  }

  Future<void> _test() async {
    try {
      await sendTestReminder();
      if (mounted) showUndoSnack(context, tr('Test-Benachrichtigung gesendet'));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _check() async {
    final repo = ref.read(repositoryProvider);
    if (repo == null) return;
    try {
      await syncReminders(repo);
    } catch (_) {
      // shown in the card
    }
    ref.invalidate(reminderStatusProvider);
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(reminderStatusProvider).value;
    if (st == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final muted = TextStyle(color: context.colors.muted);
    String when(DateTime t) {
      final day = DateTime(t.year, t.month, t.day).difference(DateTime(now.year, now.month, now.day)).inDays;
      final d = switch (day) {
        0 => tr('Heute'),
        -1 => tr('Gestern'),
        1 => tr('Morgen'),
        _ => S.date(t),
      };
      return '$d, ${S.time(t)}';
    }

    final xiaomi = RegExp('xiaomi|redmi|poco', caseSensitive: false).hasMatch(st.manufacturer);

    Widget line(bool? ok, String title, String? detail, [Widget? action]) => ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        ok == null ? Icons.info_outline : (ok ? Icons.check_circle : Icons.error_outline),
        color: ok == null ? context.colors.muted : (ok ? context.colors.ok : context.colors.overdue),
      ),
      title: Text(title, style: const TextStyle(fontSize: 15)),
      subtitle: detail == null ? null : Text(detail),
      trailing: action,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(tr('App auf diesem Gerät')),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                line(
                  st.allowed,
                  st.allowed ? tr('Benachrichtigungen erlaubt') : tr('Benachrichtigungen blockiert'),
                  st.allowed ? null : tr('Android zeigt nichts an, bis sie erlaubt sind.'),
                  st.allowed ? null : TextButton(onPressed: _allow, child: Text(tr('Erlauben'))),
                ),
                if (st.batteryUnrestricted != null)
                  line(
                    st.batteryUnrestricted! ? true : null,
                    st.batteryUnrestricted! ? tr('Akku: keine Einschränkung') : tr('Akku: optimiert'),
                    st.batteryUnrestricted!
                        ? null
                        : xiaomi
                        ? tr(
                            'Xiaomi: in den App-Infos „Autostart“ einschalten und bei „Akku“ „Keine Einschränkungen“ wählen – sonst beendet das System die Hintergrund-Prüfung.',
                          )
                        : tr(
                            'Die Hintergrund-Prüfung kann sich verzögern. In den App-Infos bei „Akku“ „Nicht eingeschränkt“ wählen.',
                          ),
                    st.batteryUnrestricted!
                        ? null
                        : TextButton(onPressed: openAppSettings, child: Text(tr('App-Infos'))),
                  ),
                line(
                  st.error == null ? (st.lastRun != null) : false,
                  st.lastRun == null ? tr('Noch keine Prüfung') : tr('Letzte Prüfung: {0}', [when(st.lastRun!)]),
                  st.error == null
                      ? tr('Prüft stündlich im Hintergrund und bei jedem Öffnen der App.')
                      : tr('Fehler: {0}', [st.error]),
                  TextButton(onPressed: _check, child: Text(tr('Jetzt prüfen'))),
                ),
                ClockCheck(
                  accountZone: ref.read(repositoryProvider)?.settings().timezone ?? 'Europe/Berlin',
                  line: (ok, title, detail) => line(ok, title, detail),
                ),
                line(
                  st.planned > 0 ? true : null,
                  st.planned == 0
                      ? tr('Keine Erinnerung vorgeplant')
                      : tr('{0} Erinnerungen vorgeplant – nächste: {1}', [st.planned, when(st.nextPlanned!)]),
                  tr(
                    'Überfällige Pflege wird um 8 Uhr beim Android-Wecker vorgemerkt und erscheint auch bei geschlossener App.',
                  ),
                ),
                line(
                  null,
                  st.digestAt == null
                      ? tr('Kein Tages-Überblick geplant')
                      : tr('Nächster Tages-Überblick: {0}', [when(st.digestAt!)]),
                  st.digestAt == null ? tr('Aus, oder zu diesem Zeitpunkt ist nichts fällig.') : null,
                ),
                const SizedBox(height: 8),
                Text(
                  tr(
                    'Die App meldet Pflege, sobald sie überfällig ist (bei der nächsten Prüfung). „Heute fällig“ steht nur im Tages-Überblick.',
                  ),
                  style: muted,
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _test,
                    icon: const Icon(Icons.notifications_outlined),
                    label: Text(tr('Test-Benachrichtigung')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
