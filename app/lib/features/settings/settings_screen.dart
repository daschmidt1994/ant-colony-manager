import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/app.dart';
import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../core/web_meta.dart';
import '../../data/sync/sync_engine.dart';
import '../../data/sync/upload_policy.dart';
import '../../shared/widgets.dart';
import 'mqtt_screen.dart';
import 'updates.dart';
import '../../app/i18n.dart';

/// Conflicts the server resolved automatically (docs/05 §5) – losing values stay visible.
final conflictsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await ref.read(authProvider.notifier).api.get('/api/v1/sync/conflicts') as Map<String, dynamic>;
  return (res['conflicts'] as List).cast<Map<String, dynamic>>();
});

Map<String, String> get _entityNames => {
  'colonies': tr('Kolonie'),
  'colony_events': tr('Eintrag'),
  'locations': tr('Standort'),
  'care_schedules': tr('Intervall'),
  'queens': tr('Königin'),
  'food_items': tr('Futtermittel'),
};

Map<String, String> get _fieldNames => {
  'name': tr('Name'),
  'notes': tr('Notizen'),
  'note': tr('Notiz'),
  'status': tr('Status'),
  'location_id': tr('Standort'),
  'interval_days': tr('Intervall'),
  'occurred_at': tr('Zeitpunkt'),
  'details_rev': tr('Details'),
};

/// ERINNERUNGEN (S20). Stored in user_settings, so they apply to all devices.
class _ReminderSettings extends ConsumerWidget {
  const _ReminderSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider).value;
    final repo = ref.watch(repositoryProvider);
    if (s == null || repo == null) return const SizedBox.shrink();
    final mail = ref.watch(instanceInfoProvider).value?['password_reset'] == true;
    final (h, m) = s.digestTime;
    final time = '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(tr('Erinnerungen')),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.schedule),
                title: Text(tr('Tages-Überblick')),
                subtitle: Text(
                  kIsWeb
                      ? tr('Uhrzeit für den Überblick (Android-App und E-Mail)')
                      : tr('„7 Kolonien brauchen heute Aufmerksamkeit“ – einmal täglich'),
                ),
                trailing: Text(time, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                onTap: () async {
                  final t = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(hour: h, minute: m),
                  );
                  if (t == null) return;
                  repo.updateSettings({
                    'digest_time': '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
                  });
                },
              ),
              ListTile(
                leading: const Icon(Icons.campaign_outlined),
                title: Text(tr('Benachrichtigungen')),
                subtitle: Text(
                  mail
                      ? tr(
                          'Tages-Überblick, überfällige Pflege, Sensor-Alarm, Winterruhe – App, ntfy, E-Mail; Häufigkeit, Ruhezeiten',
                        )
                      : tr(
                          'Tages-Überblick, überfällige Pflege, Sensor-Alarm, Winterruhe – App, ntfy; Häufigkeit, Ruhezeiten',
                        ),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/notifications'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// „Fotos nur im WLAN“ – a device setting, not synced.
class _WifiOnlySwitch extends ConsumerStatefulWidget {
  const _WifiOnlySwitch();
  @override
  ConsumerState<_WifiOnlySwitch> createState() => _WifiOnlySwitchState();
}

class _WifiOnlySwitchState extends ConsumerState<_WifiOnlySwitch> {
  @override
  Widget build(BuildContext context) {
    final db = ref.read(databaseProvider);
    final on = db.getMeta(photosWifiOnlyKey) == '1';
    return Card(
      child: SwitchListTile(
        secondary: const Icon(Icons.wifi),
        title: Text(tr('Fotos nur im WLAN hochladen')),
        subtitle: Text(
          db.pendingUploadCount() == 0
              ? tr('Alle Fotos sind hochgeladen')
              : tr('{0} Fotos warten', [db.pendingUploadCount()]),
        ),
        value: on,
        onChanged: (v) {
          db.setMeta(photosWifiOnlyKey, v ? '1' : null);
          setState(() {});
          if (!v) ref.read(syncEngineProvider)?.sync(resetBackoff: true);
        },
      ),
    );
  }
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final sync = ref.watch(syncStatusProvider).value ?? const SyncStatus();
    final theme = ref.watch(themeModeProvider);
    if (auth is! SignedIn) return const SizedBox.shrink();
    return Scaffold(
      appBar: AppBar(title: Text(tr('Mehr'))),
      body: ContentWidth(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            SectionHeader(tr('Konto')),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: CircleAvatar(child: Text(auth.user.displayName.characters.first.toUpperCase())),
                    title: Text(auth.user.displayName),
                    subtitle: Text('${auth.user.email}${auth.user.isAdmin ? ' · Administrator' : ''}'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.devices),
                    title: Text(tr('Geräte & Sitzungen')),
                    subtitle: Text(tr('Wo du angemeldet bist – verlorenes Handy abmelden')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/settings/devices'),
                  ),
                ],
              ),
            ),
            SectionHeader(tr('Auswertung')),
            Card(
              child: ListTile(
                leading: const Icon(Icons.bar_chart),
                title: Text(tr('Statistiken')),
                subtitle: Text(tr('Kolonien, Arten, Fütterungen, Verteilung nach Standort')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/stats'),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.sensors),
                title: Text(tr('Sensoren')),
                subtitle: Text(tr('Temperatur und Luftfeuchte automatisch erfassen (ESP32 …)')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/sensors'),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.inventory_2_outlined),
                title: Text(tr('Futtervorrat')),
                subtitle: Text(tr('Futtertiere, Zuckerwasser, Zuchten – mit Haltbarkeit und Nachbestell-Hinweis')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/food-stock'),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.event_available),
                title: Text(tr('Kalender-Abo')),
                subtitle: Text(tr('Fälligkeiten in Google Kalender, Outlook oder Home Assistant')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/feeds'),
              ),
            ),
            const HomeAssistantMeTile(),
            SectionHeader(tr('Synchronisierung')),
            Card(
              child: ListTile(
                leading: const Icon(Icons.sync),
                title: Text(_syncTitle(sync)),
                subtitle: Text(
                  sync.lastSync == null
                      ? tr('Noch nie synchronisiert')
                      : tr('Zuletzt {0} {1}', [
                          S.relativeDayInline(sync.lastSync!, DateTime.now()),
                          S.time(sync.lastSync!),
                        ]),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/sync'),
              ),
            ),
            if (!kIsWeb) const _WifiOnlySwitch(),
            if (kIsWeb) ...[
              SectionHeader(tr('Geräte')),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.phone_android),
                  title: Text(tr('Android-App verbinden')),
                  subtitle: Text(tr('QR-Code mit der App scannen – ohne Passwort-Eingabe')),
                  onTap: () => _deviceLink(context, ref),
                ),
              ),
            ],
            const _ReminderSettings(),
            if (auth.user.isAdmin) ...[
              SectionHeader(tr('Server-Verwaltung')),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.outgoing_mail),
                  title: const Text('E-Mail-Versand'),
                  subtitle: Text(tr('Postausgangsserver für Passwort vergessen, Überblick und Benachrichtigungen')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/settings/smtp'),
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.cloud_upload_outlined),
                  title: Text(tr('Backup außer Haus')),
                  subtitle: Text(
                    tr('Jedes Backup zusätzlich in Nextcloud, auf ein NAS oder eine Storage Box (WebDAV, SMB, NFS)'),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/settings/offsite'),
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.home_outlined),
                  title: Text(tr('Home Assistant (MQTT)')),
                  subtitle: Text(tr('Jede Kolonie als Gerät in Home Assistant – neue kommen von selbst dazu')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/settings/mqtt'),
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.auto_awesome),
                  title: Text(tr('KI-Zählung')),
                  subtitle: Text(tr('Ameisen auf Fotos zählen lassen (Anthropic Claude)')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/settings/ai'),
                ),
              ),
            ],
            SectionHeader(tr('Etiketten')),
            Card(
              child: ListTile(
                leading: const Icon(Icons.print_outlined),
                title: Text(tr('Etiketten drucken')),
                subtitle: Text(tr('QR-Etiketten als PDF – einzeln oder als Bogen')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/labels'),
              ),
            ),
            SectionHeader(tr('Daten')),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: Text(tr('Alles exportieren (ZIP)')),
                    subtitle: Text(tr('JSON, CSV-Tabellen für Excel und alle Fotos – deine Daten gehören dir')),
                    onTap: () => _export(context, ref, photos: true),
                  ),
                  ListTile(
                    leading: const Icon(Icons.table_chart_outlined),
                    title: Text(tr('Nur Daten (ohne Fotos)')),
                    onTap: () => _export(context, ref, photos: false),
                  ),
                ],
              ),
            ),
            SectionHeader(tr('Darstellung')),
            SegmentedButton<ThemeMode>(
              segments: [
                ButtonSegment(value: ThemeMode.dark, label: Text(tr('Dunkel')), icon: Icon(Icons.dark_mode_outlined)),
                ButtonSegment(value: ThemeMode.light, label: Text(tr('Hell')), icon: Icon(Icons.light_mode_outlined)),
                ButtonSegment(value: ThemeMode.system, label: Text(tr('System'))),
              ],
              selected: {theme},
              onSelectionChanged: (v) => ref.read(themeModeProvider.notifier).set(v.first),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.translate),
                title: Text(tr('Sprache')),
                trailing: DropdownButton<String>(
                  value: ref.watch(languageSettingProvider),
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem(value: 'system', child: Text(tr('Gerätesprache'))),
                    for (final e in languages.entries) DropdownMenuItem(value: e.key, child: Text(e.value.$1)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    ref.read(databaseProvider).setMeta(languageMetaKey, v);
                    ref.read(repositoryProvider)?.updateSettings({'locale': v});
                    ref.invalidate(languageSettingProvider);
                  },
                ),
              ),
            ),
            SectionHeader(tr('Server')),
            Card(
              child: Column(
                children: [
                  Consumer(
                    builder: (context, ref, _) {
                      final server = ref.watch(instanceInfoProvider).value?['version'] as String?;
                      final ok = versionsMatch(appVersion, server);
                      final updates = ref.watch(updatesProvider).value;
                      final update = updateLine(updates);
                      return ListTile(
                        leading: const Icon(Icons.dns_outlined),
                        title: Text(auth.serverUrl),
                        subtitle: Text(
                          'App $appVersion · Server ${server ?? '–'}'
                          '${ok ? '' : '\nVersionen passen nicht zusammen – App oder Server aktualisieren'}'
                          '${update == null ? '' : '\n$update'}',
                          style: ok && updates?['breaking'] != true ? null : TextStyle(color: context.colors.overdue),
                        ),
                      );
                    },
                  ),
                  if (auth.user.isAdmin) const UpdateNowTile(),
                  if (!kIsWeb)
                    ListTile(
                      leading: const Icon(Icons.swap_horiz),
                      title: Text(tr('Anderen Server verwenden')),
                      onTap: () => _confirmLogout(context, ref, changeServer: true),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () => _confirmLogout(context, ref),
              icon: const Icon(Icons.logout),
              label: Text(tr('Abmelden')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _export(BuildContext context, WidgetRef ref, {required bool photos}) async {
    final m = ScaffoldMessenger.of(context);
    if (!kIsWeb) {
      // Android has no convenient place for a large ZIP: the browser downloads
      // it via a signed 5-minute link – no login needed there.
      try {
        final api = ref.read(authProvider.notifier).api;
        final res = await api.post('/api/v1/export/link?photos=${photos ? 1 : 0}') as Map<String, dynamic>;
        final url = Uri.parse('${api.baseUrl}${res['url']}');
        if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
          m.showSnackBar(SnackBar(content: Text(tr('Kein Browser gefunden'))));
        }
      } catch (e) {
        m.showSnackBar(SnackBar(content: Text(errorText(e))));
      }
      return;
    }
    m.showSnackBar(SnackBar(content: Text(tr('Export wird erstellt …'))));
    try {
      final bytes = await ref
          .read(authProvider.notifier)
          .api
          .getBytes('/api/v1/export.zip', query: {'photos': photos ? '1' : '0'});
      final day = DateTime.now().toIso8601String().substring(0, 10);
      downloadFile('ant-colony-manager-export-$day.zip', bytes, 'application/zip');
      m.hideCurrentSnackBar();
    } catch (e) {
      m.showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  static String _syncTitle(SyncStatus s) => switch (s.phase) {
    SyncPhase.syncing => tr('Synchronisiere …'),
    SyncPhase.offline => tr('Offline · {0} Änderung(en) warten', [s.pending]),
    SyncPhase.error || SyncPhase.loginRequired => s.message ?? tr('Fehler'),
    _ when s.failed > 0 => tr('{0} Änderung(en) abgelehnt', [s.failed]),
    _ when s.pending > 0 => tr('{0} Änderung(en) ausstehend', [s.pending]),
    _ => tr('Alles synchron'),
  };

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref, {bool changeServer = false}) async {
    final pending = ref.read(syncStatusProvider).value?.pending ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(changeServer ? tr('Server wechseln?') : tr('Abmelden?')),
        content: Text(
          pending > 0
              ? tr(
                  '{0} Änderung(en) wurden noch nicht zum Server übertragen und gehen beim Abmelden verloren. '
                  'Stelle zuerst eine Verbindung her.',
                  [pending],
                )
              : tr(
                  'Die lokal gespeicherten Daten werden von diesem Gerät entfernt. Auf dem Server bleibt alles erhalten.',
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Abbrechen'))),
          FilledButton(
            style: pending > 0 ? FilledButton.styleFrom(backgroundColor: c.colors.overdue) : null,
            onPressed: () => Navigator.pop(c, true),
            child: Text(pending > 0 ? tr('Trotzdem abmelden') : tr('Abmelden')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final ctrl = ref.read(authProvider.notifier);
    changeServer ? await ctrl.changeServer() : await ctrl.logout();
  }

  Future<void> _deviceLink(BuildContext context, WidgetRef ref) async {
    try {
      final link = await ref.read(authProvider.notifier).api.post('/api/v1/auth/device-link') as Map<String, dynamic>;
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('Android-App verbinden')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(data: link['qr_payload'] as String, size: 240, backgroundColor: Colors.white),
              ),
              const SizedBox(height: 12),
              Text(
                tr(
                  'In der App „QR-Code aus Web-App scannen“ wählen. Der Code ist 2 Minuten gültig und nur einmal verwendbar.',
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('Schließen')))],
        ),
      );
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

class SyncDetailsScreen extends ConsumerWidget {
  const SyncDetailsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(syncStatusProvider).value ?? const SyncStatus();
    final engine = ref.watch(syncEngineProvider);
    final db = ref.watch(databaseProvider);
    final failed = db.failedOps();
    return Scaffold(
      appBar: AppBar(title: Text(tr('Synchronisierung'))),
      body: ContentWidth(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Column(
                children: [
                  ListTile(title: Text(tr('Status')), trailing: Text(SettingsScreen._syncTitle(s))),
                  ListTile(title: Text(tr('Ausstehende Änderungen')), trailing: Text('${s.pending}')),
                  ListTile(
                    title: Text(tr('Letzte Synchronisierung')),
                    trailing: Text(s.lastSync == null ? '–' : S.dateTime(s.lastSync!)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: engine == null ? null : () => engine.sync(resetBackoff: true),
              icon: const Icon(Icons.sync),
              label: Text(tr('Jetzt synchronisieren')),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: engine == null
                  ? null
                  : () async {
                      try {
                        await engine.snapshot();
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
              icon: const Icon(Icons.cloud_download_outlined),
              label: Text(tr('Alles neu vom Server laden')),
            ),
            ...ref
                .watch(conflictsProvider)
                .maybeWhen(
                  data: (list) => list.isEmpty
                      ? <Widget>[]
                      : [
                          SectionHeader(tr('Gleichzeitig geändert')),
                          Text(
                            tr('Diese Felder wurden auf zwei Geräten geändert. Die neuere Änderung wurde übernommen.'),
                            style: TextStyle(color: context.colors.muted),
                          ),
                          const SizedBox(height: 8),
                          for (final c in list)
                            Card(
                              child: ListTile(
                                leading: Icon(Icons.merge_type, color: context.colors.soon),
                                title: Text(
                                  '${_entityNames[c['entity']] ?? c['entity']} · ${_fieldNames[c['field']] ?? c['field']}',
                                ),
                                subtitle: Text(
                                  tr('übernommen: {0}\nverworfen: {1}', [
                                    _show(c['kept_value']),
                                    _show(c['lost_value']),
                                  ]),
                                ),
                                isThreeLine: true,
                                trailing: IconButton(
                                  tooltip: tr('Hinweis entfernen'),
                                  icon: const Icon(Icons.close),
                                  onPressed: () async {
                                    await ref
                                        .read(authProvider.notifier)
                                        .api
                                        .delete('/api/v1/sync/conflicts/${c['id']}');
                                    ref.invalidate(conflictsProvider);
                                  },
                                ),
                              ),
                            ),
                        ],
                  orElse: () => <Widget>[],
                ),
            if (failed.isNotEmpty) ...[
              SectionHeader(tr('Vom Server abgelehnt')),
              for (final op in failed)
                Card(
                  child: ListTile(
                    leading: Icon(Icons.error_outline, color: context.colors.overdue),
                    title: Text('${op.entity} · ${op.op}'),
                    subtitle: Text(op.lastError ?? ''),
                  ),
                ),
              TextButton(onPressed: db.dismissFailed, child: Text(tr('Hinweise entfernen'))),
            ],
            const SizedBox(height: 16),
            Text(
              tr(
                'Alle Einträge werden zuerst auf diesem Gerät gespeichert und im Hintergrund übertragen – '
                'auch ohne Internet geht nichts verloren.',
              ),
              style: TextStyle(color: context.colors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

String _show(Object? v) => v == null ? '–' : (v is String ? v : v.toString());
