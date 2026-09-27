import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../shared/widgets.dart';

/// One signed-in device or browser (a session family on the server).
class DeviceSession {
  DeviceSession(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String? get platform => json['platform'] as String?;
  bool get current => json['current'] == true;
  DateTime? get createdAt => DateTime.tryParse(json['created_at'] as String? ?? '');
  DateTime? get lastUsedAt => DateTime.tryParse(json['last_used_at'] as String? ?? '');

  String get name {
    final n = (json['device_name'] as String?)?.trim();
    final browser = describeUserAgent(json['user_agent'] as String?);
    if (platform == 'web' || (n == null && browser != null)) return browser ?? 'Web-Browser';
    return n == null || n.isEmpty ? 'Unbekanntes Gerät' : n;
  }

  IconData get icon => switch (platform) {
    'android' => Icons.phone_android,
    'web' => Icons.laptop,
    _ => json['user_agent'] != null ? Icons.laptop : Icons.devices_other,
  };
}

/// „Firefox auf Windows“ from a user agent – good enough to recognise a device.
String? describeUserAgent(String? ua) {
  if (ua == null || ua.isEmpty) return null;
  final browser = ua.contains('Edg/')
      ? 'Edge'
      : ua.contains('Firefox/')
      ? 'Firefox'
      : ua.contains('Chrome/') || ua.contains('Chromium/')
      ? 'Chrome'
      : ua.contains('Safari/')
      ? 'Safari'
      : ua.startsWith('Dart/') || ua.contains('okhttp')
      ? null
      : 'Browser';
  final os = ua.contains('Android')
      ? 'Android'
      : ua.contains('iPhone') || ua.contains('iPad')
      ? 'iOS'
      : ua.contains('Windows')
      ? 'Windows'
      : ua.contains('Mac OS')
      ? 'macOS'
      : ua.contains('Linux')
      ? 'Linux'
      : null;
  if (browser == null) return null;
  return os == null ? browser : '$browser auf $os';
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

  Future<void> _revoke(BuildContext context, WidgetRef ref, List<DeviceSession> which) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(which.length == 1 ? '„${which.single.name}“ abmelden?' : '${which.length} Geräte abmelden?'),
        content: const Text(
          'Das Gerät muss sich danach neu anmelden. Eine Android-App löscht dabei ihre lokalen Daten – '
          'noch nicht synchronisierte Einträge dieses Geräts gehen verloren.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Abmelden')),
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
          which.length == 1 ? '„${which.single.name}“ abgemeldet' : '${which.length} Geräte abgemeldet',
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
        title: const Text('Geräte & Sitzungen'),
        actions: [
          IconButton(
            tooltip: 'Aktualisieren',
            onPressed: () => ref.invalidate(deviceSessionsProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: sessions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.cloud_off,
          title: 'Nicht verfügbar',
          text: '${errorText(e)}\nDie Geräteliste braucht eine Verbindung zum Server.',
          action: OutlinedButton(
            onPressed: () => ref.invalidate(deviceSessionsProvider),
            child: const Text('Erneut versuchen'),
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
                  'Überall, wo du angemeldet bist. Ein verlorenes Handy hier abmelden – '
                  'die App löscht dann beim nächsten Kontakt ihre lokalen Daten.',
                  style: TextStyle(color: context.colors.muted),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    children: [
                      for (final s in list)
                        ListTile(
                          leading: Icon(s.icon, color: s.current ? Theme.of(context).colorScheme.primary : null),
                          title: Text(s.current ? '${s.name} · dieses Gerät' : s.name),
                          subtitle: Text(
                            [
                              if (s.lastUsedAt != null)
                                'aktiv ${S.relativeDay(s.lastUsedAt!, now).toLowerCase()} ${S.time(s.lastUsedAt!)}',
                              if (s.createdAt != null) 'angemeldet seit ${S.date(s.createdAt!)}',
                            ].join(' · '),
                          ),
                          trailing: s.current
                              ? null
                              : TextButton(onPressed: () => _revoke(context, ref, [s]), child: const Text('Abmelden')),
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
                    label: Text('Alle anderen abmelden (${others.length})'),
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
