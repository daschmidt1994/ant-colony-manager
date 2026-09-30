import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../app/i18n.dart';
import '../../shared/widgets.dart';

/// Newer releases, checked by the server (GitHub, cached there).
final updatesProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  try {
    return await ref.read(authProvider.notifier).api.get('/api/v1/updates') as Map<String, dynamic>;
  } on Exception {
    return null; // offline or old server
  }
});

const _dismissedKey = 'update_warning_dismissed';

/// Newest release with breaking changes that is ahead – what the warning shows.
Map<String, dynamic>? breakingRelease(Map<String, dynamic>? info) {
  if (info?['breaking'] != true) return null;
  for (final r in (info!['newer'] as List? ?? const [])) {
    if (r is Map<String, dynamic> && r['breaking'] == true) return r;
  }
  return null;
}

/// Red card on the dashboard before a breaking update – until dismissed for
/// that version.
class UpdateWarning extends ConsumerStatefulWidget {
  const UpdateWarning({super.key});
  @override
  ConsumerState<UpdateWarning> createState() => _UpdateWarningState();
}

class _UpdateWarningState extends ConsumerState<UpdateWarning> {
  @override
  Widget build(BuildContext context) {
    final r = breakingRelease(ref.watch(updatesProvider).value);
    if (r == null) return const SizedBox.shrink();
    final db = ref.read(databaseProvider);
    final version = r['version'] as String;
    if (db.getMeta(_dismissedKey) == version) return const SizedBox.shrink();
    final text = (r['breaking_text'] as String?)?.trim();
    final red = context.colors.overdue;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: red.withValues(alpha: .12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tr('Update {0}: Breaking Change', [version]),
                      style: TextStyle(color: red, fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (text != null && text.isNotEmpty) ...[Text(text), const SizedBox(height: 8)],
              Text(
                tr(
                  'Vor dem Update: 1. Backup machen · 2. Server aktualisieren · 3. dann erst die App. '
                  'App und Server müssen danach dieselbe Version haben.',
                ),
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (r['url'] is String && (r['url'] as String).startsWith('https://'))
                    TextButton(
                      onPressed: () => launchUrl(Uri.parse(r['url'] as String), mode: LaunchMode.externalApplication),
                      child: Text(tr('Details')),
                    ),
                  TextButton(
                    onPressed: () => setState(() => db.setMeta(_dismissedKey, version)),
                    child: Text(tr('Ausblenden')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One line for Mehr → Server: „Update 1.3.0 verfügbar“ (red if breaking).
String? updateLine(Map<String, dynamic>? info) {
  if (info == null || info['update_available'] != true) return null;
  final latest = info['latest'];
  return info['breaking'] == true
      ? tr('Update {0} verfügbar – ⚠ Breaking Change, vorher Backup', [latest])
      : tr('Update {0} verfügbar', [latest]);
}

/// Status of the optional update service (admins only).
final updaterProvider = FutureProvider.autoDispose<Map<String, dynamic>?>((ref) async {
  try {
    return await ref.read(authProvider.notifier).api.get('/api/v1/admin/update') as Map<String, dynamic>;
  } on Exception {
    return null; // old server or not reachable (e.g. while it restarts)
  }
});

/// Text for the updater state; null when there is nothing to say.
String? updaterStateText(Map<String, dynamic>? st) => switch (st?['state']) {
  'requested' => tr('Update angefordert …'),
  'running' => tr('Update läuft: {0}', [st?['message'] ?? '']),
  'done' => tr('Letztes Update abgeschlossen'),
  'failed' => tr('Letztes Update fehlgeschlagen – Protokoll antippen'),
  _ => null,
};

/// „Jetzt aktualisieren“ in Mehr → Server: shown to administrators when the
/// updater service runs. While an update runs, the status is polled – the
/// server restarts in between, errors are expected then.
class UpdateNowTile extends ConsumerStatefulWidget {
  const UpdateNowTile({super.key});
  @override
  ConsumerState<UpdateNowTile> createState() => _UpdateNowTileState();
}

class _UpdateNowTileState extends ConsumerState<UpdateNowTile> {
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _watch() {
    _poll?.cancel();
    var rounds = 0;
    _poll = Timer.periodic(const Duration(seconds: 3), (t) async {
      rounds++;
      ref.invalidate(updaterProvider);
      final st = await ref.read(updaterProvider.future);
      final state = st?['state'];
      if (state == 'done' || state == 'failed' || rounds > 200) {
        t.cancel();
        ref.invalidate(instanceInfoProvider);
        ref.invalidate(updatesProvider);
      }
    });
  }

  Future<void> _start(Map<String, dynamic>? updates) async {
    final breaking = updates?['breaking'] == true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr('Jetzt aktualisieren?')),
        content: Text(
          [
            tr(
              'Der Server macht ein Backup, holt die neuen Images und startet neu – die App ist dabei etwa eine '
              'Minute nicht erreichbar.',
            ),
            if (breaking) tr('⚠ Diese Version hat Breaking Changes – vorher die Hinweise lesen.'),
          ].join('\n\n'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Abbrechen'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Aktualisieren'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(authProvider.notifier).api.post('/api/v1/admin/update');
      ref.invalidate(updaterProvider);
      _watch();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _showLog(String log) => showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(tr('Update-Protokoll')),
      content: SingleChildScrollView(
        child: SelectableText(log, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(d), child: Text(tr('Schließen')))],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(updaterProvider).value;
    final updates = ref.watch(updatesProvider).value;
    if (st == null) return const SizedBox.shrink();
    final state = st['state'] as String?;
    final busy = state == 'requested' || state == 'running';
    // always visible for administrators – otherwise nobody finds the option
    if (st['available'] != true && !busy) {
      return ListTile(
        leading: const Icon(Icons.system_update_alt),
        title: Text(tr('Update mit Knopf')),
        subtitle: Text(
          tr(
            'Noch nicht eingerichtet: in der .env COMPOSE_PROFILES=updater und ACM_PROJECT_DIR setzen, dann '
            '„docker compose up -d“. Danach geht das Update hier per Knopf.',
          ),
        ),
      );
    }
    final at = DateTime.tryParse(st['at'] as String? ?? '');
    final text = updaterStateText(st);
    return ListTile(
      leading: busy
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.system_update_alt),
      title: Text(tr('Jetzt aktualisieren')),
      subtitle: text == null ? null : Text(at == null || busy ? text : '$text · ${S.dateTime(at)}'),
      onTap: busy
          ? null
          : state == 'failed' && (st['log'] as String?)?.isNotEmpty == true
          ? () => _showLog(st['log'] as String)
          : () => _start(updates),
      trailing: state == 'failed'
          ? IconButton(
              tooltip: tr('Erneut versuchen'),
              icon: const Icon(Icons.refresh),
              onPressed: () => _start(updates),
            )
          : null,
    );
  }
}
