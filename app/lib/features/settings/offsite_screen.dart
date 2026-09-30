import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/i18n.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../shared/widgets.dart';

/// Off-site backup for administrators: each new nightly backup is copied to
/// a WebDAV folder (Nextcloud, NAS, storage box), an SMB share or a folder
/// mounted into the container (NFS, USB disk) – docs/25-backup-ausser-haus.md.
final offsiteProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return await ref.read(authProvider.notifier).api.get('/api/v1/admin/offsite') as Map<String, dynamic>;
});

/// Request body; the password only when typed or removed.
Map<String, dynamic> offsiteBody({
  required bool enabled,
  String type = 'webdav',
  required String url,
  required String user,
  required String keep,
  String password = '',
  bool removePassword = false,
  bool encrypt = false,
  String passphrase = '',
}) => {
  'enabled': enabled,
  'type': type,
  'url': url.trim(),
  if (type != 'folder') 'user': user.trim(),
  'keep': int.tryParse(keep.trim()) ?? 0,
  if (removePassword) 'password': '' else if (password.isNotEmpty) 'password': password,
  'encrypt': encrypt,
  if (passphrase.isNotEmpty) 'passphrase': passphrase,
};

/// Label, example and help for the address field of each target type.
(String, String, String) offsiteAddress(String type) => switch (type) {
  'smb' => (
    tr('SMB-Freigabe (Ordner)'),
    'smb://nas/backup/acm',
    tr('smb://Server/Freigabe/Ordner – Windows, Synology, QNAP, Unraid. Benutzer ggf. als DOMÄNE\\name.'),
  ),
  'folder' => (
    tr('Ordner im Container'),
    '/offsite',
    tr(
      'Für NFS oder eine USB-Platte: Docker bindet die Freigabe als Volume unter diesem Pfad ein '
      '(Beispiel für compose.yml in docs/25). Der Ordner muss existieren.',
    ),
  ),
  _ => (
    tr('WebDAV-Adresse (Ordner)'),
    'https://cloud.example.com/remote.php/dav/files/NAME/acm-backups',
    tr('Nextcloud: Dateien → Einstellungen (unten links) → WebDAV, dahinter ein Ordnername'),
  ),
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
  late String _type = _s['type'] as String? ?? 'webdav';
  late bool _encrypt = _s['encrypt'] == true;
  final _passphrase = TextEditingController();
  late final _url = TextEditingController(text: _s['url'] as String? ?? '');
  late final _user = TextEditingController(text: _s['user'] as String? ?? '');
  late final _keep = TextEditingController(text: '${_s['keep'] ?? 7}');
  final _password = TextEditingController();
  bool _removePassword = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_url, _user, _keep, _password, _passphrase]) {
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
              type: _type,
              url: _url.text,
              user: _user.text,
              keep: _keep.text,
              password: _password.text,
              removePassword: _removePassword,
              encrypt: _encrypt,
              passphrase: _passphrase.text,
            ),
          );
      setState(() {
        _s = r as Map<String, dynamic>;
        _password.clear();
        _passphrase.clear();
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
                    'Kopiert jedes neue nächtliche Backup zusätzlich an einen anderen Ort – per WebDAV (Nextcloud, '
                    'Storage Box), auf eine SMB-Freigabe (Windows, NAS) oder in einen per NFS eingebundenen Ordner. '
                    'So bleiben die Daten erhalten, wenn der Server selbst ausfällt. Fotos werden nur einmal '
                    'übertragen, danach nur neue.',
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
                SegmentedButton<String>(
                  segments: [
                    const ButtonSegment(value: 'webdav', label: Text('WebDAV'), icon: Icon(Icons.cloud_outlined)),
                    const ButtonSegment(value: 'smb', label: Text('SMB'), icon: Icon(Icons.dns_outlined)),
                    ButtonSegment(
                      value: 'folder',
                      label: Text(tr('NFS / Ordner')),
                      icon: const Icon(Icons.folder_outlined),
                    ),
                  ],
                  selected: {_type},
                  onSelectionChanged: (v) => setState(() => _type = v.first),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: offsiteAddress(_type).$1,
                    hintText: offsiteAddress(_type).$2,
                    helperText: offsiteAddress(_type).$3,
                    helperMaxLines: 3,
                  ),
                ),
                if (_type == 'folder') const _NfsHelp(),
                if (_type != 'folder') ...[
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
                      helperText: _type == 'webdav'
                          ? tr('Nextcloud: am besten ein App-Passwort (Einstellungen → Sicherheit)')
                          : null,
                      suffixIcon: passwordSet
                          ? IconButton(
                              tooltip: tr('Passwort entfernen'),
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => setState(() => _removePassword = true),
                            )
                          : null,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _keep,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: tr('Backups dort behalten'),
                    helperText: tr('Ältere werden dort gelöscht; Fotos bleiben.'),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Verschlüsselt speichern')),
                  subtitle: Text(
                    _encrypt
                        ? tr(
                            'Sinnvoll bei fremden Servern (Storage Box, Cloud). Zum Wiederherstellen wird die Passphrase '
                            'gebraucht – ohne sie sind die Backups verloren. Die Dateien lassen sich nur mit ACM '
                            '(restore.sh --from-offsite) oder dem Programm „age“ öffnen.',
                          )
                        : tr(
                            'Aus: normale Dateien – am einfachsten wiederherzustellen, auch ohne ACM einfach zurückkopieren. '
                            'Gut für das eigene NAS.',
                          ),
                  ),
                  value: _encrypt,
                  onChanged: (v) => setState(() => _encrypt = v),
                ),
                if (_encrypt)
                  TextField(
                    controller: _passphrase,
                    obscureText: true,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: tr('Passphrase'),
                      hintText: _s['passphrase_set'] == true ? tr('gesetzt – nur zum Ändern ausfüllen') : null,
                      helperText: tr(
                        'Mindestens 12 Zeichen. Wird nicht gespeichert – bitte sicher aufschreiben (Passwort-Manager). '
                        'Ändern: ältere Backups öffnen sich dann mit der neuen.',
                      ),
                      helperMaxLines: 3,
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

/// compose.override.yml that mounts an NFS share at /offsite in the app
/// container (Docker mounts it – the container itself runs without root).
String nfsComposeSnippet({required String server, required String export, String version = '4'}) {
  final addr = server.trim().isEmpty ? '192.168.178.10' : server.trim();
  var path = export.trim().isEmpty ? '/volume1/acm-backup' : export.trim();
  if (!path.startsWith('/')) path = '/$path';
  return 'services:\n'
      '  app:\n'
      '    volumes:\n'
      '      - offsite:/offsite\n'
      'volumes:\n'
      '  offsite:\n'
      '    driver: local\n'
      '    driver_opts:\n'
      '      type: nfs\n'
      '      o: "addr=$addr,rw,nfsvers=$version"\n'
      '      device: ":$path"\n';
}

/// Step-by-step help for NFS with a generated compose.override.yml.
class _NfsHelp extends StatefulWidget {
  const _NfsHelp();
  @override
  State<_NfsHelp> createState() => _NfsHelpState();
}

class _NfsHelpState extends State<_NfsHelp> {
  final _server = TextEditingController();
  final _export = TextEditingController();
  String _version = '4';

  @override
  void dispose() {
    _server.dispose();
    _export.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: context.colors.muted, fontSize: 13);
    final snippet = nfsComposeSnippet(server: _server.text, export: _export.text, version: _version);
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: ExpansionTile(
        leading: const Icon(Icons.help_outline),
        title: Text(tr('NFS einrichten – Anleitung')),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr(
              '1. Am NAS eine NFS-Freigabe anlegen und dem Docker-Host Schreibrecht geben. Geschrieben wird mit '
              'PUID/PGID aus der .env (Standard 1000) – am NAS diese ID erlauben oder alle Zugriffe auf einen Benutzer '
              'abbilden (Synology: Squash „Alle Benutzer zu admin zuordnen“, Unraid: all_squash).',
            ),
            style: muted,
          ),
          const SizedBox(height: 8),
          Text(tr('2. Adresse und Pfad der Freigabe eintragen:'), style: muted),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _server,
                  autocorrect: false,
                  decoration: InputDecoration(labelText: tr('NAS-Adresse'), hintText: '192.168.178.10', isDense: true),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _version,
                items: const [
                  DropdownMenuItem(value: '4', child: Text('NFS v4')),
                  DropdownMenuItem(value: '3', child: Text('NFS v3')),
                ],
                onChanged: (v) => setState(() => _version = v!),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _export,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: tr('Freigabe-Pfad'),
              hintText: '/volume1/acm-backup',
              helperText: tr('Synology: /volume1/<Freigabe> · Unraid: /mnt/user/<Freigabe> · QNAP: /<Freigabe>'),
              helperMaxLines: 2,
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Text(
            tr('3. Neben der compose.yml als compose.override.yml speichern (Updates überschreiben sie nicht):'),
            style: muted,
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(
              children: [
                SelectableText(snippet, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                Positioned(
                  right: 0,
                  top: 0,
                  child: IconButton(
                    tooltip: tr('Kopieren'),
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: snippet));
                      showUndoSnack(context, tr('Kopiert'));
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            tr(
              '4. „docker compose up -d“ ausführen (Unraid/Portainer: Stack neu bereitstellen). Dann oben „/offsite“ '
              'eintragen, speichern und „Verbindung testen“. USB-Platte statt NFS: unter volumes nur '
              '„- /mnt/usb/acm:/offsite“.',
            ),
            style: muted,
          ),
        ],
      ),
    );
  }
}
