import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/i18n.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../shared/widgets.dart';

/// Sign-in with OIDC/SSO (Authentik, Keycloak, Authelia, Google …) for administrators.
final oidcSettingsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return await ref.read(authProvider.notifier).api.get('/api/v1/admin/oidc') as Map<String, dynamic>;
});

/// Request body; the secret only when typed or removed.
Map<String, dynamic> oidcBody({
  required bool enabled,
  required String issuer,
  required String clientId,
  required String label,
  required bool allowSignup,
  String secret = '',
  bool removeSecret = false,
}) => {
  'enabled': enabled,
  'issuer': issuer.trim(),
  'client_id': clientId.trim(),
  'label': label.trim(),
  'allow_signup': allowSignup,
  if (removeSecret) 'client_secret': '' else if (secret.trim().isNotEmpty) 'client_secret': secret.trim(),
};

class OidcScreen extends ConsumerWidget {
  const OidcScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(oidcSettingsProvider)
      .when(
        loading: () => Scaffold(
          appBar: AppBar(title: Text(tr('Anmeldung mit SSO'))),
          body: const Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => Scaffold(
          appBar: AppBar(title: Text(tr('Anmeldung mit SSO'))),
          body: EmptyState(
            icon: Icons.cloud_off,
            title: tr('Nur mit Verbindung zum Server'),
            text: errorText(e),
            action: FilledButton(onPressed: () => ref.invalidate(oidcSettingsProvider), child: Text(tr('Erneut'))),
          ),
        ),
        data: (s) => _OidcForm(initial: s),
      );
}

class _OidcForm extends ConsumerStatefulWidget {
  const _OidcForm({required this.initial});
  final Map<String, dynamic> initial;
  @override
  ConsumerState<_OidcForm> createState() => _OidcFormState();
}

class _OidcFormState extends ConsumerState<_OidcForm> {
  late Map<String, dynamic> _s = widget.initial;
  late bool _enabled = _s['enabled'] == true;
  late bool _signup = _s['allow_signup'] == true;
  late final _issuer = TextEditingController(text: _s['issuer'] as String? ?? '');
  late final _client = TextEditingController(text: _s['client_id'] as String? ?? '');
  late final _label = TextEditingController(text: _s['label'] as String? ?? 'SSO');
  final _secret = TextEditingController();
  bool _removeSecret = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_issuer, _client, _label, _secret]) {
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
            '/api/v1/admin/oidc',
            oidcBody(
              enabled: _enabled,
              issuer: _issuer.text,
              clientId: _client.text,
              label: _label.text,
              allowSignup: _signup,
              secret: _secret.text,
              removeSecret: _removeSecret,
            ),
          );
      setState(() {
        _s = r as Map<String, dynamic>;
        _secret.clear();
        _removeSecret = false;
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
    if (!await _save(quiet: true)) return;
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).api.post('/api/v1/admin/oidc/test');
      if (mounted) showUndoSnack(context, tr('Der Anbieter antwortet'));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: context.colors.muted);
    final secretSet = _s['client_secret_set'] == true && !_removeSecret;
    final redirect = _s['redirect_url'] as String? ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Anmeldung mit SSO')),
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
                    'Anmelden über einen eigenen Identity-Provider (OpenID Connect) – z. B. Authentik, Keycloak, '
                    'Authelia, Google oder Microsoft. Die Anmeldung mit Passwort bleibt daneben möglich.',
                  ),
                  style: muted,
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    title: Text(tr('Weiterleitungs-URL (beim Anbieter eintragen)')),
                    subtitle: SelectableText(redirect, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                    trailing: IconButton(
                      tooltip: tr('Kopieren'),
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: redirect));
                        showUndoSnack(context, tr('Kopiert'));
                      },
                    ),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Anmeldung mit SSO anbieten')),
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
                TextField(
                  controller: _issuer,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr('Issuer-URL'),
                    hintText: 'https://auth.example.com/application/o/acm/',
                    helperText: tr('Die Adresse, unter der /.well-known/openid-configuration liegt'),
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _client,
                  autocorrect: false,
                  decoration: InputDecoration(labelText: tr('Client-ID')),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _secret,
                  obscureText: true,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr('Client-Secret'),
                    hintText: secretSet ? tr('gespeichert – leer lassen zum Behalten') : null,
                    helperText: tr('Leer bei einem „öffentlichen“ Client (nur PKCE)'),
                    suffixIcon: secretSet
                        ? IconButton(
                            tooltip: tr('Secret entfernen'),
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => setState(() => _removeSecret = true),
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _label,
                  decoration: InputDecoration(
                    labelText: tr('Name auf dem Knopf'),
                    helperText: tr('„Mit {0} anmelden“', [_label.text.isEmpty ? 'SSO' : _label.text]),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Neue Konten automatisch anlegen')),
                  subtitle: Text(
                    tr(
                      'Aus: nur wer schon ein Konto mit derselben E-Mail hat, kann sich anmelden. An: jede Person, '
                      'die der Anbieter zulässt, bekommt ein Konto.',
                    ),
                  ),
                  value: _signup,
                  onChanged: (v) => setState(() => _signup = v),
                ),
                const SizedBox(height: 8),
                Wrap(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _test,
                      icon: const Icon(Icons.wifi_tethering),
                      label: Text(tr('Verbindung testen')),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  tr(
                    'Beim Anbieter: Client vom Typ „OpenID Connect“, Weiterleitungs-URL von oben, Scopes openid, email, '
                    'profile. Bestehende Konten werden über die (bestätigte) E-Mail-Adresse verknüpft. Anleitung: docs/28.',
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
