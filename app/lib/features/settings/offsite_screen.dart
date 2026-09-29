import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/i18n.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../shared/widgets.dart';

/// Off-site backup for administrators: each new nightly backup is copied to
/// a WebDAV folder (Nextcloud, NAS, storage box) – docs/25-backup-ausser-haus.md.
final offsiteProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return await ref.read(authProvider.notifier).api.get('/api/v1/admin/offsite') as Map<String, dynamic>;
});

/// Request body; the password only when typed or removed.
Map<String, dynamic> offsiteBody({
  required bool enabled,
  required String url,
  required String user,
  required String keep,
  String password = '',
  bool removePassword = false,
}) => {
  'enabled': enabled,
  'url': url.trim(),
  'user': user.trim(),
  'keep': int.tryParse(keep.trim()) ?? 0,
  if (removePassword) 'password': '' else if (password.isNotEmpty) 'password': password,
};

String _size(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble(), i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${i == 0 ? v.toStringAsFixed(0) : S.decimal(v)} ${units[i]}';
}

class OffsiteScreen extends ConsumerWidget {
  const OffsiteScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(offsiteProvider)
      .when(
        loading: () => Scaffold(
          appBar: AppBar(title: Text(tr('Backup außer Haus'))),
          body: const Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => Scaffold(
          appBar: AppBar(title: Text(tr('Backup außer Haus'))),
          body: EmptyState(
            icon: Icons.cloud_off,
            title: tr('Nur mit Verbindung zum Server'),
            text: errorText(e),
            action: FilledButton(onPressed: () => ref.invalidate(offsiteProvider), child: Text(tr('Erneut'))),
          ),
        ),
        data: (s) => _OffsiteForm(initial: s),
      );
}

class _OffsiteForm extends ConsumerStatefulWidget {
  const _OffsiteForm({required this.initial});
  final Map<String, dynamic> initial;
  @override
  ConsumerState<_OffsiteForm> createState() => _OffsiteFormState();
}

class _OffsiteFormState extends ConsumerState<_OffsiteForm> {
  late Map<String, dynamic> _s = widget.initial;
  late bool _enabled = _s['enabled'] == true;
  late final _url = TextEditingController(text: _s['url'] as String? ?? '');
  late final _user = TextEditingController(text: _s['user'] as String? ?? '');
  late final _keep = TextEditingController(text: '${_s['keep'] ?? 7}');
  final _password = TextEditingController();
  bool _removePassword = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_url, _user, _keep, _password]) {
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
            '/api/v1/admin/offsite',
            offsiteBody(
              enabled: _enabled,
              url: _url.text,
              user: _user.text,
              keep: _keep.text,
              password: _password.text,
              removePassword: _removePassword,
            ),
          );
      setState(() {
        _s = r as Map<String, dynamic>;
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

  Future<void> _action(String path, String done) async {
    if (!await _save(quiet: true)) return;
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).api.post(path);
      if (mounted) showUndoSnack(context, done);
      ref.invalidate(offsiteProvider);
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
    final ok = DateTime.tryParse(st['last_success'] as String? ?? '');
    final errAt = DateTime.tryParse(st['last_error_at'] as String? ?? '');
    final failed = errAt != null && (ok == null || errAt.isAfter(ok));
    final passwordSet = _s['password_set'] == true && !_removePassword;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Backup außer Haus')),
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
                    'Kopiert jedes neue nächtliche Backup zusätzlich in einen WebDAV-Ordner – z. B. Nextcloud, '
                    'NAS (Synology, QNAP, Unraid) oder eine Storage Box. So bleiben die Daten erhalten, wenn der '
                    'Server selbst ausfällt. Fotos werden nur einmal übertragen, danach nur neue.',
                  ),
                  style: muted,
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: Icon(
                      failed ? Icons.error_outline : (ok != null ? Icons.cloud_done_outlined : Icons.cloud_outlined),
                      color: failed ? context.colors.overdue : (ok != null ? context.colors.ok : context.colors.muted),
                    ),
                    title: Text(
                      st['running'] == true
                          ? tr('Wird gerade hochgeladen …')
                          : ok == null
                          ? tr('Noch nichts hochgeladen')
                          : tr('Zuletzt: {0}', [S.dateTime(ok)]),
                    ),
                    subtitle: Text(
                      [
                        if (ok != null && st['last_name'] != null)
                          tr('Backup {0} · {1} übertragen · {2} neue Fotos', [
                            st['last_name'],
                            _size(st['last_bytes'] as num? ?? 0),
                            st['last_photos'] ?? 0,
                          ]),
                        if (failed) tr('Fehler ({0}): {1}', [S.dateTime(errAt), st['last_error']]),
                        if (st['local_latest'] == null)
                          tr('Kein fertiges Backup sichtbar – ist der Backup-Ordner im App-Container eingebunden?')
                        else
                          tr('Neuestes Backup hier: {0}', [st['local_latest']]),
                      ].join('\n'),
                    ),
                    trailing: IconButton(
                      tooltip: tr('Aktualisieren'),
                      icon: const Icon(Icons.refresh),
                      onPressed: () => ref.invalidate(offsiteProvider),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Automatisch nach jedem Backup hochladen')),
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr('WebDAV-Adresse (Ordner)'),
                    hintText: 'https://cloud.example.com/remote.php/dav/files/NAME/acm-backups',
                    helperText: tr(
                      'Nextcloud: Dateien → Einstellungen (unten links) → WebDAV, dahinter ein Ordnername',
                    ),
                    helperMaxLines: 3,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _user,
                  autocorrect: false,
                  decoration: InputDecoration(labelText: tr('Benutzer')),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr('Passwort'),
                    hintText: passwordSet ? tr('gespeichert – leer lassen zum Behalten') : null,
                    helperText: tr('Nextcloud: am besten ein App-Passwort (Einstellungen → Sicherheit)'),
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
                  controller: _keep,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: tr('Backups dort behalten'),
                    helperText: tr('Ältere werden dort gelöscht; Fotos bleiben.'),
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _action('/api/v1/admin/offsite/test', tr('Verbindung klappt – Ordner ist bereit')),
                      icon: const Icon(Icons.wifi_tethering),
                      label: Text(tr('Verbindung testen')),
                    ),
                    FilledButton.icon(
                      onPressed: _busy || st['running'] == true
                          ? null
                          : () => _action(
                              '/api/v1/admin/offsite/run',
                              tr('Upload gestartet – Status mit ↻ aktualisieren'),
                            ),
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: Text(tr('Jetzt hochladen')),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  tr(
                    'Die unverschlüsselte Konfiguration (mit Passwörtern) wird nie hochgeladen. Wiederherstellen: '
                    'Backup-Ordner und „uploads“ herunterladen und wie ein lokales Backup einspielen (Anleitung in docs/25).',
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
