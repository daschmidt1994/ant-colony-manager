import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/app.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../data/sync/sync_engine.dart';
import '../../shared/widgets.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final sync = ref.watch(syncStatusProvider).value ?? const SyncStatus();
    final theme = ref.watch(themeModeProvider);
    if (auth is! SignedIn) return const SizedBox.shrink();
    return Scaffold(
      appBar: AppBar(title: const Text('Mehr')),
      body: ContentWidth(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            const SectionHeader('Konto'),
            Card(
              child: ListTile(
                leading: CircleAvatar(child: Text(auth.user.displayName.characters.first.toUpperCase())),
                title: Text(auth.user.displayName),
                subtitle: Text('${auth.user.email}${auth.user.isAdmin ? ' · Administrator' : ''}'),
              ),
            ),
            const SectionHeader('Synchronisierung'),
            Card(
              child: ListTile(
                leading: const Icon(Icons.sync),
                title: Text(_syncTitle(sync)),
                subtitle: Text(
                  sync.lastSync == null
                      ? 'Noch nie synchronisiert'
                      : 'Zuletzt ${S.relativeDay(sync.lastSync!, DateTime.now()).toLowerCase()} ${S.time(sync.lastSync!)}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/sync'),
              ),
            ),
            if (kIsWeb) ...[
              const SectionHeader('Geräte'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.phone_android),
                  title: const Text('Android-App verbinden'),
                  subtitle: const Text('QR-Code mit der App scannen – ohne Passwort-Eingabe'),
                  onTap: () => _deviceLink(context, ref),
                ),
              ),
            ],
            const SectionHeader('Etiketten'),
            Card(
              child: ListTile(
                leading: const Icon(Icons.print_outlined),
                title: const Text('Etiketten drucken'),
                subtitle: const Text('QR-Etiketten als PDF – einzeln oder als Bogen'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/labels'),
              ),
            ),
            const SectionHeader('Darstellung'),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.dark, label: Text('Dunkel'), icon: Icon(Icons.dark_mode_outlined)),
                ButtonSegment(value: ThemeMode.light, label: Text('Hell'), icon: Icon(Icons.light_mode_outlined)),
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
              ],
              selected: {theme},
              onSelectionChanged: (v) => ref.read(themeModeProvider.notifier).set(v.first),
            ),
            const SectionHeader('Server'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.dns_outlined),
                    title: Text(auth.serverUrl),
                    subtitle: const Text('App-Version $appVersion'),
                  ),
                  if (!kIsWeb)
                    ListTile(
                      leading: const Icon(Icons.swap_horiz),
                      title: const Text('Anderen Server verwenden'),
                      onTap: () => _confirmLogout(context, ref, changeServer: true),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () => _confirmLogout(context, ref),
              icon: const Icon(Icons.logout),
              label: const Text('Abmelden'),
            ),
          ],
        ),
      ),
    );
  }

  static String _syncTitle(SyncStatus s) => switch (s.phase) {
    SyncPhase.syncing => 'Synchronisiere …',
    SyncPhase.offline => 'Offline · ${s.pending} Änderung(en) warten',
    SyncPhase.error || SyncPhase.loginRequired => s.message ?? 'Fehler',
    _ when s.failed > 0 => '${s.failed} Änderung(en) abgelehnt',
    _ when s.pending > 0 => '${s.pending} Änderung(en) ausstehend',
    _ => 'Alles synchron',
  };

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref, {bool changeServer = false}) async {
    final pending = ref.read(syncStatusProvider).value?.pending ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(changeServer ? 'Server wechseln?' : 'Abmelden?'),
        content: Text(
          pending > 0
              ? '$pending Änderung(en) wurden noch nicht zum Server übertragen und gehen beim Abmelden verloren. '
                    'Stelle zuerst eine Verbindung her.'
              : 'Die lokal gespeicherten Daten werden von diesem Gerät entfernt. Auf dem Server bleibt alles erhalten.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
          FilledButton(
            style: pending > 0 ? FilledButton.styleFrom(backgroundColor: c.colors.overdue) : null,
            onPressed: () => Navigator.pop(c, true),
            child: Text(pending > 0 ? 'Trotzdem abmelden' : 'Abmelden'),
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
          title: const Text('Android-App verbinden'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(data: link['qr_payload'] as String, size: 240, backgroundColor: Colors.white),
              ),
              const SizedBox(height: 12),
              const Text(
                'In der App „QR-Code aus Web-App scannen“ wählen. Der Code ist 2 Minuten gültig und nur einmal verwendbar.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Schließen'))],
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
      appBar: AppBar(title: const Text('Synchronisierung')),
      body: ContentWidth(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Column(
                children: [
                  ListTile(title: const Text('Status'), trailing: Text(SettingsScreen._syncTitle(s))),
                  ListTile(title: const Text('Ausstehende Änderungen'), trailing: Text('${s.pending}')),
                  ListTile(
                    title: const Text('Letzte Synchronisierung'),
                    trailing: Text(s.lastSync == null ? '–' : S.dateTime(s.lastSync!)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: engine == null ? null : () => engine.sync(resetBackoff: true),
              icon: const Icon(Icons.sync),
              label: const Text('Jetzt synchronisieren'),
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
              label: const Text('Alles neu vom Server laden'),
            ),
            if (failed.isNotEmpty) ...[
              const SectionHeader('Vom Server abgelehnt'),
              for (final op in failed)
                Card(
                  child: ListTile(
                    leading: Icon(Icons.error_outline, color: context.colors.overdue),
                    title: Text('${op.entity} · ${op.op}'),
                    subtitle: Text(op.lastError ?? ''),
                  ),
                ),
              TextButton(onPressed: db.dismissFailed, child: const Text('Hinweise entfernen')),
            ],
            const SizedBox(height: 16),
            Text(
              'Alle Einträge werden zuerst auf diesem Gerät gespeichert und im Hintergrund übertragen – '
              'auch ohne Internet geht nichts verloren.',
              style: TextStyle(color: context.colors.muted),
            ),
          ],
        ),
      ),
    );
  }
}
