import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/i18n.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../shared/widgets.dart';

/// Benutzer (administrators): accounts with usage, disable, admin role,
/// password reset link, delete – and invitations to this server.
typedef AdminUsers = ({List<Map<String, dynamic>> users, List<Map<String, dynamic>> invitations});

final adminUsersProvider = FutureProvider.autoDispose<AdminUsers>((ref) async {
  final api = ref.read(authProvider.notifier).api;
  return parseAdminUsers(await api.get('/api/v1/admin/users'), await api.get('/api/v1/invitations'), DateTime.now());
});

/// The server answers {users: […]} and {invitations: […]} (null when empty).
/// Only open server invitations – colony invitations belong to their owners.
AdminUsers parseAdminUsers(Object? users, Object? invitations, DateTime now) {
  List<Map<String, dynamic>> list(Object? body, String key) =>
      ((body is Map ? body[key] : body) as List? ?? const []).cast<Map<String, dynamic>>();
  return (
    users: list(users, 'users'),
    invitations: list(invitations, 'invitations')
        .where((i) => i['accepted_at'] == null && i['colony_id'] == null)
        .where((i) => DateTime.parse(i['expires_at'] as String).isAfter(now))
        .toList(),
  );
}

/// Request body of a new invitation.
Map<String, dynamic> invitationBody(String email, int days) => {
  if (email.trim().isNotEmpty) 'email': email.trim(),
  'valid_days': days,
};

class UsersScreen extends ConsumerWidget {
  const UsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(adminUsersProvider);
    final auth = ref.watch(authProvider);
    final me = auth is SignedIn ? auth.user.id : null;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Benutzer'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _invite(context, ref),
        icon: const Icon(Icons.person_add_alt),
        label: Text(tr('Einladen')),
      ),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.cloud_off,
          title: tr('Nur mit Verbindung zum Server'),
          text: errorText(e),
          action: FilledButton(onPressed: () => ref.invalidate(adminUsersProvider), child: Text(tr('Erneut'))),
        ),
        data: (d) => RefreshIndicator(
          onRefresh: () => ref.refresh(adminUsersProvider.future),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              ContentWidth(
                maxWidth: 720,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      tr(
                        'Konten auf diesem Server. Kolonien und Daten der Personen siehst du hier nicht – nur, wie viel sie belegen.',
                      ),
                      style: TextStyle(color: context.colors.muted),
                    ),
                    const SizedBox(height: 8),
                    for (final u in d.users) _UserCard(user: u, isMe: u['id'] == me),
                    if (d.invitations.isNotEmpty) ...[
                      SectionHeader(tr('Offene Einladungen')),
                      for (final i in d.invitations)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.mail_outline),
                            title: Text(i['email'] as String? ?? tr('Link für jede Person')),
                            subtitle: Text(
                              tr('gültig bis {0}', [S.dateTime(DateTime.parse(i['expires_at'] as String))]),
                            ),
                            trailing: IconButton(
                              tooltip: tr('Zurückziehen'),
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                try {
                                  await ref.read(authProvider.notifier).api.delete('/api/v1/invitations/${i['id']}');
                                  ref.invalidate(adminUsersProvider);
                                } catch (e) {
                                  if (context.mounted) showError(context, e);
                                }
                              },
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _invite(BuildContext context, WidgetRef ref) async {
    final email = TextEditingController();
    var days = 7;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: Text(tr('Person einladen')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: tr('E-Mail (optional)'),
                  helperText: tr('Leer: der Link gilt für jede Person, die ihn bekommt'),
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: days,
                decoration: InputDecoration(labelText: tr('Gültig')),
                items: [
                  for (final n in const [1, 7, 14, 30])
                    DropdownMenuItem(value: n, child: Text(n == 1 ? tr('1 Tag') : tr('{0} Tage', [n]))),
                ],
                onChanged: (v) => set(() => days = v ?? 7),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Abbrechen'))),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Link erstellen'))),
          ],
        ),
      ),
    );
    final mail = email.text;
    email.dispose();
    if (ok != true || !context.mounted) return;
    try {
      final r =
          await ref.read(authProvider.notifier).api.post('/api/v1/invitations', invitationBody(mail, days))
              as Map<String, dynamic>;
      ref.invalidate(adminUsersProvider);
      if (context.mounted) {
        await _showLink(
          context,
          tr('Einladungslink'),
          r['link'] as String,
          tr('Schick den Link der Person – damit legt sie ihr Konto an. Er wird nur jetzt angezeigt.'),
        );
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

Future<void> _showLink(BuildContext context, String title, String link, String text) => showDialog<void>(
  context: context,
  builder: (d) => AlertDialog(
    title: Text(title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text),
        const SizedBox(height: 12),
        SelectableText(link, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Schließen'))),
      FilledButton.icon(
        onPressed: () {
          Clipboard.setData(ClipboardData(text: link));
          Navigator.pop(d);
          showUndoSnack(context, tr('Link kopiert'));
        },
        icon: const Icon(Icons.copy, size: 18),
        label: Text(tr('Kopieren')),
      ),
    ],
  ),
);

class _UserCard extends ConsumerWidget {
  const _UserCard({required this.user, required this.isMe});
  final Map<String, dynamic> user;
  final bool isMe;

  String get _id => user['id'] as String;
  String get _email => user['email'] as String;

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() f, [String? done]) async {
    try {
      await f();
      ref.invalidate(adminUsersProvider);
      if (done != null && context.mounted) showUndoSnack(context, done);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<bool> _confirm(BuildContext context, String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Abbrechen'))),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(action)),
          ],
        ),
      ) ==
      true;

  Future<void> _action(BuildContext context, WidgetRef ref, String action) async {
    final api = ref.read(authProvider.notifier).api;
    final name = user['display_name'] as String? ?? _email;
    switch (action) {
      case 'disable':
        if (!await _confirm(
              context,
              tr('{0} deaktivieren?', [name]),
              tr(
                'Die Person wird auf allen Geräten abgemeldet und kann sich nicht mehr anmelden. Ihre Daten bleiben erhalten.',
              ),
              tr('Deaktivieren'),
            ) ||
            !context.mounted) {
          return;
        }
        await _run(context, ref, () => api.patch('/api/v1/admin/users/$_id', {'disabled': true}), tr('Deaktiviert'));
      case 'enable':
        await _run(context, ref, () => api.patch('/api/v1/admin/users/$_id', {'disabled': false}), tr('Aktiviert'));
      case 'admin':
        if (!await _confirm(
              context,
              tr('{0} zum Admin machen?', [name]),
              tr(
                'Admins verwalten den Server: Benutzer, E-Mail, Backups, SSO. Kolonien anderer sehen sie trotzdem nicht.',
              ),
              tr('Zum Admin machen'),
            ) ||
            !context.mounted) {
          return;
        }
        await _run(context, ref, () => api.patch('/api/v1/admin/users/$_id', {'instance_role': 'admin'}));
      case 'user':
        await _run(context, ref, () => api.patch('/api/v1/admin/users/$_id', {'instance_role': 'user'}));
      case 'reset':
        try {
          final r = await api.post('/api/v1/admin/users/$_id/password-reset-link') as Map<String, dynamic>;
          if (context.mounted) {
            await _showLink(
              context,
              tr('Passwort-Link für {0}', [name]),
              r['link'] as String,
              tr('Damit setzt die Person ein neues Passwort. Gültig 30 Minuten, nur einmal.'),
            );
          }
        } catch (e) {
          if (context.mounted) showError(context, e);
        }
      case 'delete':
        final typed = await showDialog<String>(
          context: context,
          builder: (d) => _DeleteDialog(name: name, email: _email),
        );
        if (typed == null || !context.mounted) return;
        await _run(
          context,
          ref,
          () => api.post('/api/v1/admin/users/$_id/delete', {'confirm_email': typed}),
          tr('{0} gelöscht', [name]),
        );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final disabled = user['disabled'] == true;
    final admin = user['instance_role'] == 'admin';
    final last = DateTime.tryParse(user['last_login_at'] as String? ?? '');
    final muted = TextStyle(color: context.colors.muted, fontSize: 12);
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: disabled ? context.colors.muted.withValues(alpha: 0.2) : null,
          child: Icon(disabled ? Icons.block : (admin ? Icons.admin_panel_settings_outlined : Icons.person_outline)),
        ),
        title: Text(
          [user['display_name'] as String? ?? _email, if (isMe) tr('(du)')].join(' '),
          style: disabled ? TextStyle(color: context.colors.muted, decoration: TextDecoration.lineThrough) : null,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_email),
            Text(
              [
                if (admin) tr('Admin'),
                if (disabled) tr('deaktiviert'),
                tr('{0} Kolonien', [user['colonies']]),
                tr('{0} Fotos ({1})', [user['photos'], S.bytes(user['photo_bytes'] as num? ?? 0)]),
                last == null ? tr('noch nie angemeldet') : tr('zuletzt {0}', [S.dateTime(last)]),
              ].join(' · '),
              style: muted,
            ),
          ],
        ),
        isThreeLine: true,
        trailing: isMe
            ? null
            : PopupMenuButton<String>(
                onSelected: (a) => _action(context, ref, a),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'reset', child: Text(tr('Passwort-Link erstellen'))),
                  if (admin)
                    PopupMenuItem(value: 'user', child: Text(tr('Admin-Rechte entziehen')))
                  else
                    PopupMenuItem(value: 'admin', child: Text(tr('Zum Admin machen'))),
                  if (disabled)
                    PopupMenuItem(value: 'enable', child: Text(tr('Wieder aktivieren')))
                  else
                    PopupMenuItem(value: 'disable', child: Text(tr('Deaktivieren'))),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(tr('Konto löschen'), style: TextStyle(color: context.colors.overdue)),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Deleting needs the e-mail typed again – returns it, or null.
class _DeleteDialog extends StatefulWidget {
  const _DeleteDialog({required this.name, required this.email});
  final String name, email;
  @override
  State<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends State<_DeleteDialog> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  bool get _ok => _typed.text.trim().toLowerCase() == widget.email.toLowerCase();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('{0} endgültig löschen?', [widget.name])),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tr(
            'Das Konto wird mit allen eigenen Kolonien, Fotos, Chroniken und Einstellungen gelöscht – das lässt sich '
            'nicht rückgängig machen (nur über ein Backup). Mit anderen geteilte Kolonien verschwinden auch für sie. '
            'Nur sperren? Dann „Deaktivieren“.',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _typed,
          autocorrect: false,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(labelText: tr('Zur Bestätigung E-Mail eingeben'), hintText: widget.email),
          onChanged: (_) => setState(() {}),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Abbrechen'))),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: context.colors.overdue),
        onPressed: _ok ? () => Navigator.pop(context, _typed.text.trim()) : null,
        child: Text(tr('Endgültig löschen')),
      ),
    ],
  );
}
