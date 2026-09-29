import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../data/sync/sync_engine.dart';
import '../../shared/widgets.dart';
import '../../app/i18n.dart';

/// One signed-in device or browser (a session family on the server).
class DeviceSession {
  DeviceSession(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String? get platform => json['platform'] as String?;
  bool get current => json['current'] == true;
  DateTime? get createdAt => DateTime.tryParse(json['created_at'] as String? ?? '');
  DateTime? get lastUsedAt => DateTime.tryParse(json['last_used_at'] as String? ?? '');

  /// A name the user gave the device; else the browser for web sessions,
  /// else the app's default name.
  String get name {
    final n = (json['device_name'] as String?)?.trim() ?? '';
    final browser = describeUserAgent(json['user_agent'] as String?);
    if (n.isNotEmpty && !_defaultNames.contains(n)) return n;
    if (platform == 'web' || (n.isEmpty && browser != null)) return browser ?? tr('Web-Browser');
    return n.isEmpty ? tr('Unbekanntes Gerät') : n;
  }

  static const _defaultNames = {'Web-Browser', 'Android', 'android', 'web', 'ios'};

  IconData get icon => switch (platform) {
    'android' => Icons.phone_android,
    'web' => Icons.laptop,
    _ => json['user_agent'] != null ? Icons.laptop : Icons.devices_other,
  };
}

/// „Firefox auf Windows“ from a user agent – good enough to recognise a device.
String? describeUserAgent(String? ua) {
  if (ua == null || ua.isEmpty || ua.startsWith('Dart/')) return null;
  // Scripts and tools (curl, a sensor gateway …): their own name.
  if (!ua.startsWith('Mozilla/')) return ua.split(' ').first;
  final browser = ua.contains('Edg/')
      ? tr('Edge')
      : ua.contains('Firefox/')
      ? tr('Firefox')
      : ua.contains('Chrome/') || ua.contains('Chromium/')
      ? tr('Chrome')
      : ua.contains('Safari/')
      ? tr('Safari')
      : ua.startsWith('Dart/') || ua.contains('okhttp')
      ? null
      : tr('Browser');
  final os = ua.contains(tr('Android'))
      ? tr('Android')
      : ua.contains('iPhone') || ua.contains('iPad')
      ? 'iOS'
      : ua.contains(tr('Windows'))
      ? tr('Windows')
      : ua.contains(tr('Mac OS'))
      ? 'macOS'
      : ua.contains(tr('Linux'))
      ? tr('Linux')
      : null;
  if (browser == null) return null;
  return os == null ? browser : tr('{0} auf {1}', [browser, os]);
}

final deviceSessionsProvider = FutureProvider.autoDispose<List<DeviceSession>>((ref) async {
  final res = await ref.read(authProvider.notifier).api.get('/api/v1/auth/sessions') as Map<String, dynamic>;
  final list = [for (final s in (res['sessions'] as List).cast<Map<String, dynamic>>()) DeviceSession(s)];
  list.sort((a, b) {
    if (a.current != b.current) return a.current ? -1 : 1;
    return (b.lastUsedAt ?? DateTime(0)).compareTo(a.lastUsedAt ?? DateTime(0));
  });
  return list;
});

/// S20 „Geräte & Sitzungen“: where am I signed in – and sign out a lost phone.
/// A signed-out Android app deletes its local data on its next contact.
class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final db = ref.read(databaseProvider);
    final c = TextEditingController(text: db.getMeta(deviceNameKey) ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr('Name dieses Geräts')),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 60,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: kIsWeb ? tr('z. B. Laptop Wohnzimmer') : tr('z. B. Pixel 7 von Anna')),
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Abbrechen'))),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: Text(tr('Speichern'))),
        ],
      ),
    );
    if (name == null) return;
    final v = name.trim();
    db.setMeta(deviceNameKey, v.isEmpty ? null : v);
    // The next sync reports the name to the server, also without new entries.
    await ref.read(syncEngineProvider)?.sync(resetBackoff: true);
    ref.invalidate(deviceSessionsProvider);
  }

  Future<void> _revoke(BuildContext context, WidgetRef ref, List<DeviceSession> which) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(
          which.length == 1 ? '„${which.single.name}“ abmelden?' : tr('{0} Geräte abmelden?', [which.length]),
        ),
        content: Text(
          tr(
            'Das Gerät muss sich danach neu anmelden. Eine Android-App löscht dabei ihre lokalen Daten – '
            'noch nicht synchronisierte Einträge dieses Geräts gehen verloren.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Abbrechen'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Abmelden'))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final api = ref.read(authProvider.notifier).api;
    try {
      for (final s in which) {
        await api.delete('/api/v1/auth/sessions/${s.id}');
      }
      if (context.mounted) {
        showUndoSnack(
          context,
          which.length == 1 ? '„${which.single.name}“ abgemeldet' : tr('{0} Geräte abgemeldet', [which.length]),
        );
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
    ref.invalidate(deviceSessionsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(deviceSessionsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Geräte & Sitzungen')),
        actions: [
          IconButton(
            tooltip: tr('Aktualisieren'),
            onPressed: () => ref.invalidate(deviceSessionsProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: sessions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.cloud_off,
          title: tr('Nicht verfügbar'),
          text: tr('{0}\nDie Geräteliste braucht eine Verbindung zum Server.', [errorText(e)]),
          action: OutlinedButton(
            onPressed: () => ref.invalidate(deviceSessionsProvider),
            child: Text(tr('Erneut versuchen')),
          ),
        ),
        data: (list) {
          final others = list.where((s) => !s.current).toList();
          final now = DateTime.now();
          return ContentWidth(
            maxWidth: 640,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Text(
                  tr(
                    'Überall, wo du angemeldet bist. Ein verlorenes Handy hier abmelden – '
                    'die App löscht dann beim nächsten Kontakt ihre lokalen Daten.',
                  ),
                  style: TextStyle(color: context.colors.muted),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    children: [
                      for (final s in list)
                        ListTile(
                          leading: Icon(s.icon, color: s.current ? Theme.of(context).colorScheme.primary : null),
                          title: Text(s.current ? tr('{0} · dieses Gerät', [s.name]) : s.name),
                          subtitle: Text(
                            [
                              if (s.lastUsedAt != null)
                                'aktiv ${S.relativeDayInline(s.lastUsedAt!, now)} ${S.time(s.lastUsedAt!)}',
                              if (s.createdAt != null) tr('angemeldet seit {0}', [S.date(s.createdAt!)]),
                            ].join(' · '),
                          ),
                          trailing: s.current
                              ? IconButton(
                                  tooltip: tr('Umbenennen'),
                                  onPressed: () => _rename(context, ref),
                                  icon: const Icon(Icons.edit_outlined),
                                )
                              : TextButton(onPressed: () => _revoke(context, ref, [s]), child: Text(tr('Abmelden'))),
                        ),
                    ],
                  ),
                ),
                if (others.length > 1) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: context.colors.overdue),
                    onPressed: () => _revoke(context, ref, others),
                    icon: const Icon(Icons.logout),
                    label: Text(tr('Alle anderen abmelden ({0})', [others.length])),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
