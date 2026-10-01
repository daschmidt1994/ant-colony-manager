import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/i18n.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../shared/widgets.dart';

/// Sign-in with SSO (OIDC), when the administrator set it up: the browser
/// goes to the provider and comes back to /sso?code=… (web) or into the app
/// (`<app id>://acm/sso?code=…`); the code is exchanged for a session.
final ssoInfoProvider = FutureProvider.autoDispose<Map<String, dynamic>?>((ref) async {
  final info = await ref.read(authProvider.notifier).instanceInfo();
  final sso = (info?['sso'] as Map?)?.cast<String, dynamic>();
  return sso?['enabled'] == true ? sso : null;
});

const _system = MethodChannel('acm/system');

/// „Mit `Anbieter` anmelden“ – only shown when SSO is set up.
class SsoButton extends ConsumerWidget {
  const SsoButton({super.key});

  Future<void> _start(BuildContext context, WidgetRef ref) async {
    final auth = ref.read(authProvider.notifier);
    String? app;
    if (!kIsWeb) {
      try {
        app = await _system.invokeMethod<String>('packageName');
      } on Exception {
        app = null;
      }
    }
    final url = auth.ssoStartUrl(app: app);
    final ok = await launchUrl(
      url,
      mode: kIsWeb ? LaunchMode.platformDefault : LaunchMode.externalApplication,
      webOnlyWindowName: '_self',
    );
    if (!ok && context.mounted) showError(context, tr('Der Browser ließ sich nicht öffnen.'));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sso = ref.watch(ssoInfoProvider).value;
    if (sso == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: OutlinedButton.icon(
        onPressed: () => _start(context, ref),
        icon: const Icon(Icons.key_outlined),
        label: Text(tr('Mit {0} anmelden', [sso['label'] ?? 'SSO'])),
      ),
    );
  }
}

/// /sso?code=… or ?error=…: the way back from the provider.
class SsoLandingScreen extends ConsumerStatefulWidget {
  const SsoLandingScreen({super.key, this.code, this.error});
  final String? code, error;
  @override
  ConsumerState<SsoLandingScreen> createState() => _SsoLandingScreenState();
}

class _SsoLandingScreenState extends ConsumerState<SsoLandingScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    _error = widget.error;
    final code = widget.code;
    if (code != null && code.isNotEmpty && _error == null) {
      Future.microtask(() async {
        try {
          await ref.read(authProvider.notifier).redeemSso(code); // the router then leaves this page
        } catch (e) {
          if (mounted) setState(() => _error = errorText(e));
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: _error == null && (widget.code ?? '').isNotEmpty
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [const CircularProgressIndicator(), const SizedBox(height: 16), Text(tr('Anmelden …'))],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.error_outline, color: context.colors.overdue, size: 40),
                    const SizedBox(height: 12),
                    Text(
                      tr('Anmeldung mit SSO fehlgeschlagen'),
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(_error ?? tr('Kein Anmelde-Code erhalten.'), textAlign: TextAlign.center),
                    const SizedBox(height: 20),
                    FilledButton(onPressed: () => context.go('/login'), child: Text(tr('Zur Anmeldung'))),
                  ],
                ),
        ),
      ),
    ),
  );
}
