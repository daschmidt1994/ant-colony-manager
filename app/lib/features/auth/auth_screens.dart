import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'sso.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/api_client.dart';
import '../../core/session.dart';
import '../../shared/widgets.dart';
import '../../app/i18n.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}

/// Common layout: centred card with logo, works on phones and desktops.
class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({required this.title, this.subtitle, required this.children});
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const AppLogo(size: 72),
                  const SizedBox(height: 12),
                  Text(S.appName, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 28),
                  Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 6),
                    Text(subtitle!, style: TextStyle(color: context.colors.muted)),
                  ],
                  const SizedBox(height: 20),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Mixin for simple async forms with busy state and error text.
mixin _Busy<T extends StatefulWidget> on State<T> {
  bool busy = false;
  String? error;

  Future<void> run(Future<void> Function() fn) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await fn();
    } on ApiException catch (e) {
      setState(() => error = _friendly(e));
    } on NetworkException {
      setState(() => error = tr('Server nicht erreichbar. Gleiches WLAN? Adresse und Port richtig?'));
    } catch (e) {
      setState(() => error = errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _friendly(ApiException e) => switch (e.code) {
    'auth.invalid_credentials' => tr('E-Mail oder Passwort ist falsch.'),
    'rate_limited' => tr('Zu viele Versuche – bitte kurz warten.'),
    'setup.invalid_token' => tr('Der Setup-Code stimmt nicht (siehe docker compose logs app).'),
    'registration.closed' => tr('Registrierung nur mit Einladung.'),
    'user.exists' => tr('Für diese E-Mail gibt es bereits ein Konto.'),
    'user.disabled' => tr('Dieses Konto ist gesperrt.'),
    _ => e.title,
  };

  Widget errorBox() => error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(error!, style: TextStyle(color: context.colors.overdue)),
        );
}

// -----------------------------------------------------------------------------

class ServerScreen extends ConsumerStatefulWidget {
  const ServerScreen({super.key});
  @override
  ConsumerState<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends ConsumerState<ServerScreen> with _Busy {
  final _url = TextEditingController();

  @override
  Widget build(BuildContext context) => _AuthScaffold(
    title: tr('Server verbinden'),
    subtitle: tr('Deine Kolonien. Ein Scan.'),
    children: [
      TextField(
        controller: _url,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: InputDecoration(labelText: tr('Server-Adresse'), hintText: 'https://ants.example.com'),
        onSubmitted: (_) => _connect(),
      ),
      const SizedBox(height: 8),
      Text(tr('Im Heimnetz z. B. http://192.168.1.50:8080'), style: TextStyle(color: context.colors.muted)),
      const SizedBox(height: 20),
      errorBox(),
      FilledButton(onPressed: busy ? null : _connect, child: Text(busy ? tr('Verbinde …') : tr('Weiter'))),
      const SizedBox(height: 12),
      if (!kIsWeb)
        OutlinedButton.icon(
          onPressed: () => context.push('/connect/scan'),
          icon: const Icon(Icons.qr_code_scanner),
          label: Text(tr('QR-Code aus der Web-App scannen')),
        ),
      const SizedBox(height: 8),
      Text(
        tr('In der Web-App: „Mehr → Android-App verbinden“ – dann ist kein Passwort nötig.'),
        style: TextStyle(color: context.colors.muted, fontSize: 13),
      ),
    ],
  );

  void _connect() => run(() => ref.read(authProvider.notifier).connect(_url.text));
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> with _Busy {
  final _email = TextEditingController();
  final _pw = TextEditingController();
  bool _show = false;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final server = auth is SignedOut ? auth.serverUrl : '';
    return _AuthScaffold(
      title: tr('Anmelden'),
      subtitle: kIsWeb ? null : server,
      children: [
        if (auth is SignedOut && auth.notice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(auth.notice!, style: TextStyle(color: context.colors.soon)),
          ),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'E-Mail'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pw,
          obscureText: !_show,
          autofillHints: const [AutofillHints.password],
          decoration: InputDecoration(
            labelText: tr('Passwort'),
            suffixIcon: IconButton(
              icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _show = !_show),
            ),
          ),
          onSubmitted: (_) => _login(),
        ),
        const SizedBox(height: 20),
        errorBox(),
        FilledButton(onPressed: busy ? null : _login, child: Text(busy ? tr('Anmelden …') : tr('Anmelden'))),
        const SsoButton(),
        const SizedBox(height: 8),
        TextButton(onPressed: _forgot, child: Text(tr('Passwort vergessen?'))),
        TextButton(onPressed: () => context.go('/register'), child: Text(tr('Einladung erhalten? Konto erstellen'))),
        if (!kIsWeb)
          TextButton(
            onPressed: () => ref.read(authProvider.notifier).changeServer(),
            child: Text(tr('Anderen Server verwenden')),
          ),
      ],
    );
  }

  void _login() => run(() => ref.read(authProvider.notifier).login(_email.text, _pw.text));

  Future<void> _forgot() async {
    if (_email.text.trim().isEmpty) {
      setState(() => error = tr('Bitte zuerst die E-Mail-Adresse eingeben.'));
      return;
    }
    await run(() async {
      final res =
          await ref.read(authProvider.notifier).api.public('POST', '/api/v1/auth/password/forgot', {
                'email': _email.text.trim(),
              })
              as Map<String, dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('Passwort zurücksetzen')),
          content: Text(
            res['email_enabled'] == true
                ? tr('Wenn es ein Konto mit dieser Adresse gibt, ist eine E-Mail mit einem Link unterwegs.')
                : tr(
                    'Auf diesem Server ist kein E-Mail-Versand eingerichtet. Bitte den Administrator um einen '
                    'Reset-Link bitten.',
                  ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );
    });
  }
}

class _AccountFields extends StatelessWidget {
  const _AccountFields({required this.name, required this.email, required this.pw});
  final TextEditingController name, email, pw;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextField(
        controller: name,
        autofillHints: const [AutofillHints.name],
        decoration: InputDecoration(labelText: tr('Name')),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: email,
        keyboardType: TextInputType.emailAddress,
        autofillHints: const [AutofillHints.email],
        decoration: const InputDecoration(labelText: 'E-Mail'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: pw,
        obscureText: true,
        autofillHints: const [AutofillHints.newPassword],
        decoration: InputDecoration(labelText: tr('Passwort'), helperText: tr('Mindestens 10 Zeichen')),
      ),
    ],
  );
}

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});
  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> with _Busy {
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _pw = TextEditingController();

  @override
  Widget build(BuildContext context) => _AuthScaffold(
    title: tr('Ersteinrichtung'),
    subtitle: tr(
      'Lege das Administrator-Konto an. Den Setup-Code zeigt der Server beim Start an:\n'
      'docker compose logs app | grep -A1 Setup-Code',
    ),
    children: [
      TextField(
        controller: _code,
        decoration: InputDecoration(labelText: tr('Setup-Code')),
      ),
      const SizedBox(height: 12),
      _AccountFields(name: _name, email: _email, pw: _pw),
      const SizedBox(height: 20),
      errorBox(),
      FilledButton(
        onPressed: busy
            ? null
            : () => run(() => ref.read(authProvider.notifier).setup(_code.text, _email.text, _pw.text, _name.text)),
        child: Text(tr('Konto anlegen')),
      ),
    ],
  );
}

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key, this.invite});
  final String? invite;
  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> with _Busy {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _pw = TextEditingController();

  @override
  Widget build(BuildContext context) => _AuthScaffold(
    title: tr('Konto erstellen'),
    subtitle: widget.invite != null ? tr('Du wurdest eingeladen.') : null,
    children: [
      _AccountFields(name: _name, email: _email, pw: _pw),
      const SizedBox(height: 20),
      errorBox(),
      FilledButton(
        onPressed: busy
            ? null
            : () => run(
                () =>
                    ref.read(authProvider.notifier).register(_email.text, _pw.text, _name.text, invite: widget.invite),
              ),
        child: Text(tr('Registrieren')),
      ),
      TextButton(onPressed: () => context.go('/login'), child: Text(tr('Zur Anmeldung'))),
    ],
  );
}

class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key, this.token});
  final String? token;
  @override
  ConsumerState<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> with _Busy {
  final _pw = TextEditingController();
  bool _done = false;

  @override
  Widget build(BuildContext context) => _AuthScaffold(
    title: tr('Neues Passwort'),
    children: [
      if (_done) ...[
        Text(tr('Passwort geändert. Du kannst dich jetzt anmelden.')),
        const SizedBox(height: 16),
        FilledButton(onPressed: () => context.go('/login'), child: Text(tr('Zur Anmeldung'))),
      ] else ...[
        TextField(
          controller: _pw,
          obscureText: true,
          autofillHints: const [AutofillHints.newPassword],
          decoration: InputDecoration(labelText: tr('Neues Passwort'), helperText: tr('Mindestens 10 Zeichen')),
        ),
        const SizedBox(height: 20),
        errorBox(),
        FilledButton(
          onPressed: busy || widget.token == null
              ? null
              : () => run(() async {
                  await ref.read(authProvider.notifier).api.public('POST', '/api/v1/auth/password/reset', {
                    'token': widget.token,
                    'password': _pw.text,
                  });
                  setState(() => _done = true);
                }),
          child: Text(tr('Passwort speichern')),
        ),
      ],
    ],
  );
}
