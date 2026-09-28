import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/session.dart';
import '../../shared/widgets.dart';

/// E-mail server (SMTP) for administrators – replaces SMTP_* in the compose file.
final smtpSettingsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return await ref.read(authProvider.notifier).api.get('/api/v1/admin/smtp') as Map<String, dynamic>;
});

const smtpSecurity = {'starttls': ('STARTTLS', 587), 'tls': ('SSL/TLS', 465), 'none': ('keine (nur Heimnetz)', 25)};

/// Request body; the password only when typed or removed.
Map<String, dynamic> smtpBody({
  required String host,
  required String port,
  required String tls,
  required String user,
  required String from,
  String password = '',
  bool removePassword = false,
}) => {
  'host': host.trim(),
  'port': int.tryParse(port.trim()) ?? 0,
  'tls': tls,
  'user': user.trim(),
  'from': from.trim(),
  if (removePassword) 'password': '' else if (password.isNotEmpty) 'password': password,
};

class SmtpScreen extends ConsumerWidget {
  const SmtpScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(smtpSettingsProvider)
      .when(
        loading: () => Scaffold(
          appBar: AppBar(title: const Text('E-Mail-Versand')),
          body: const Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => Scaffold(
          appBar: AppBar(title: const Text('E-Mail-Versand')),
          body: EmptyState(
            icon: Icons.cloud_off,
            title: 'Nur mit Verbindung zum Server',
            text: errorText(e),
            action: FilledButton(onPressed: () => ref.invalidate(smtpSettingsProvider), child: const Text('Erneut')),
          ),
        ),
        data: (s) => _SmtpForm(initial: s),
      );
}

class _SmtpForm extends ConsumerStatefulWidget {
  const _SmtpForm({required this.initial});
  final Map<String, dynamic> initial;
  @override
  ConsumerState<_SmtpForm> createState() => _SmtpFormState();
}

class _SmtpFormState extends ConsumerState<_SmtpForm> {
  late Map<String, dynamic> _s = widget.initial;
  late final _host = TextEditingController(text: _s['host'] as String? ?? '');
  late final _port = TextEditingController(text: '${_s['port'] ?? 587}');
  late final _user = TextEditingController(text: _s['user'] as String? ?? '');
  late final _from = TextEditingController(text: _s['from'] as String? ?? '');
  final _password = TextEditingController();
  late String _tls = smtpSecurity.containsKey(_s['tls']) ? _s['tls'] as String : 'starttls';
  bool _removePassword = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _from, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _passwordSet => _s['password_set'] == true && !_removePassword;

  Future<bool> _put(Map<String, dynamic> body, String done) async {
    setState(() => _busy = true);
    try {
      final res = await ref.read(authProvider.notifier).api.put('/api/v1/admin/smtp', body);
      setState(() {
        _s = res as Map<String, dynamic>;
        _password.clear();
        _removePassword = false;
      });
      if (mounted) showUndoSnack(context, done);
      return true;
    } catch (e) {
      if (mounted) showError(context, e);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _save() => _put(
    smtpBody(
      host: _host.text,
      port: _port.text,
      tls: _tls,
      user: _user.text,
      from: _from.text,
      password: _password.text,
      removePassword: _removePassword,
    ),
    'Gespeichert – gilt ab sofort',
  );

  Future<void> _test() async {
    if (!await _save()) return;
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).api.post('/api/v1/admin/smtp/test');
      final auth = ref.read(authProvider);
      if (mounted) showUndoSnack(context, 'Test-E-Mail gesendet an ${auth is SignedIn ? auth.user.email : 'dich'}');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('E-Mail-Einstellungen entfernen?'),
        content: Text(
          _s['env_configured'] == true
              ? 'Danach gelten wieder die Werte aus der Docker-Konfiguration (SMTP_*).'
              : 'Danach verschickt der Server keine E-Mails mehr.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Entfernen')),
        ],
      ),
    );
    if (ok == true && await _put({'host': ''}, 'Entfernt') && mounted) {
      _host.text = _s['host'] as String? ?? '';
      _user.text = _s['user'] as String? ?? '';
      _from.text = _s['from'] as String? ?? '';
      _port.text = '${_s['port'] ?? 587}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: context.colors.muted);
    final source = _s['source'] as String? ?? 'none';
    final (statusIcon, statusText, statusColor) = switch (source) {
      'app' => (Icons.check_circle_outline, 'Aktiv – eingerichtet in der App', context.colors.ok),
      'env' => (
        Icons.info_outline,
        'Aktiv – aus der Docker-Konfiguration (SMTP_*). Hier gespeichert hat Vorrang.',
        context.colors.soon,
      ),
      _ => (Icons.mail_lock_outlined, 'Kein E-Mail-Versand eingerichtet', context.colors.muted),
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('E-Mail-Versand'),
        actions: [TextButton(onPressed: _busy ? null : _save, child: const Text('Speichern'))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          ContentWidth(
            maxWidth: 640,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: ListTile(
                    leading: Icon(statusIcon, color: statusColor),
                    title: Text(statusText),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Für „Passwort vergessen“, den Tages-Überblick und Benachrichtigungen per E-Mail. '
                  'Die Daten stehen bei deinem Mail-Anbieter (Postausgangsserver / SMTP). '
                  'Bei Gmail, Outlook & Co. meist ein eigenes App-Passwort verwenden.',
                  style: muted,
                ),
                const SectionHeader('Server'),
                TextField(
                  controller: _host,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Postausgangsserver (SMTP)',
                    hintText: 'smtp.example.com',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: DropdownButtonFormField<String>(
                        initialValue: _tls,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Verschlüsselung'),
                        items: [
                          for (final e in smtpSecurity.entries)
                            DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value.$1, overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: (v) => setState(() {
                          // switch the port along if it was a standard one
                          if (smtpSecurity.values.any((x) => '${x.$2}' == _port.text.trim())) {
                            _port.text = '${smtpSecurity[v]!.$2}';
                          }
                          _tls = v!;
                        }),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Port'),
                      ),
                    ),
                  ],
                ),
                const SectionHeader('Anmeldung'),
                TextField(
                  controller: _user,
                  autocorrect: false,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Benutzer', hintText: 'meist die E-Mail-Adresse'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Passwort',
                    hintText: _passwordSet ? 'gespeichert – leer lassen zum Behalten' : null,
                    helperText: 'Wird verschlüsselt auf dem Server gespeichert und nie angezeigt',
                    suffixIcon: _passwordSet
                        ? IconButton(
                            tooltip: 'Passwort entfernen',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => setState(() => _removePassword = true),
                          )
                        : null,
                  ),
                ),
                const SectionHeader('Absender'),
                TextField(
                  controller: _from,
                  autocorrect: false,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Absender',
                    hintText: 'Ameisen <ameisen@example.com>',
                    helperText: 'Muss der Mail-Anbieter meist als Absender erlauben',
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  icon: const Icon(Icons.send_outlined),
                  label: const Text('Speichern und Test-E-Mail an mich senden'),
                  onPressed: _busy || _host.text.trim().isEmpty ? null : _test,
                ),
                if (source == 'app') ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: context.colors.overdue),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('E-Mail-Einstellungen entfernen'),
                    onPressed: _busy ? null : _remove,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
