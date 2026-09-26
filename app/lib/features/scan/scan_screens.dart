import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/api_client.dart';
import '../../core/session.dart';
import '../../core/web_meta.dart';
import '../../data/repositories/colony_repository.dart';
import '../../shared/widgets.dart';

final _tokenRe = RegExp(r'^[0-9A-Za-z]{16}$');

/// Extracts the scan token from a pasted link (…/c/<token>) or a bare code.
String? parseScanInput(String input) {
  final s = input.trim();
  if (_tokenRe.hasMatch(s)) return s;
  final m = RegExp(r'/c/([0-9A-Za-z]{16})(?:[/?#]|$)').firstMatch(s);
  return m?.group(1);
}

sealed class ScanOutcome {}

class OpenColony extends ScanOutcome {
  OpenColony(this.id);
  final String id;
}

class ScanMessage extends ScanOutcome {
  ScanMessage(this.text);
  final String text;
}

/// Resolves a token: first locally (works offline), then on the server.
Future<ScanOutcome> resolveScan(WidgetRef ref, String token) async {
  final repo = ref.read(repositoryProvider)!;
  switch (repo.resolveToken(token)) {
    case ScanFound(:final colonyId):
      return OpenColony(colonyId);
    case ScanRevoked():
      return ScanMessage('Dieser Code wurde deaktiviert. Weise der Kolonie einen neuen Code zu.');
    case ScanUnknown():
  }
  try {
    final res = await ref.read(authProvider.notifier).api.get('/api/v1/scan/$token') as Map<String, dynamic>;
    await ref.read(syncEngineProvider)?.sync();
    return OpenColony(res['colony_id'] as String);
  } on ApiException catch (e) {
    return ScanMessage(e.status == 410
        ? 'Dieser Code wurde deaktiviert.'
        : 'Kein Kolonie-Code von dir – oder die Kolonie ist nicht mit dir geteilt.');
  } on NetworkException {
    return ScanMessage('Unbekannter Code. Offline – wird beim nächsten Sync geprüft.');
  }
}

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});
  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  final _code = TextEditingController();
  String? _message;
  bool _busy = false;

  Future<void> _go() async {
    final token = parseScanInput(_code.text);
    if (token == null) {
      setState(() => _message = 'Das ist kein Kolonie-Code. Erwartet: 16 Zeichen oder ein Link mit /c/…');
      return;
    }
    setState(() => _busy = true);
    final r = await resolveScan(ref, token);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (r) {
      case OpenColony(:final id):
        _code.clear();
        setState(() => _message = null);
        context.go('/colonies/$id');
      case ScanMessage(:final text):
        setState(() => _message = text);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Kolonie scannen'), actions: const [SyncBadge()]),
        body: ContentWidth(
          maxWidth: 560,
          child: ListView(padding: const EdgeInsets.all(20), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(children: [
                  Icon(Icons.qr_code_scanner, size: 64, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 12),
                  const Text('Kamera- und NFC-Scan folgen mit dem nächsten Update.', textAlign: TextAlign.center),
                  const SizedBox(height: 4),
                  Text('Bis dahin: Code vom Etikett oder den Link eingeben.',
                      textAlign: TextAlign.center, style: TextStyle(color: context.colors.muted)),
                ]),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _code,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Code oder Link', hintText: 'https://…/c/7Kq2mZr9XbT4pLwA'),
              onSubmitted: (_) => _go(),
            ),
            const SizedBox(height: 12),
            if (_message != null)
              Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_message!, style: TextStyle(color: context.colors.soon))),
            FilledButton(onPressed: _busy ? null : _go, child: const Text('Kolonie öffnen')),
          ]),
        ),
      );
}

/// Target of QR/NFC links (…/c/<code>) – in the browser and, later, the app.
class ScanLandingScreen extends ConsumerStatefulWidget {
  const ScanLandingScreen({super.key, required this.token});
  final String token;
  @override
  ConsumerState<ScanLandingScreen> createState() => _ScanLandingScreenState();
}

class _ScanLandingScreenState extends ConsumerState<ScanLandingScreen> {
  String? _message;
  final _intent = kIsWeb ? appIntentLink() : null;

  @override
  void initState() {
    super.initState();
    if (_intent == null) Future.microtask(_resolve);
  }

  Future<void> _resolve() async {
    if (!_tokenRe.hasMatch(widget.token)) {
      setState(() => _message = 'Ungültiger Code.');
      return;
    }
    final r = await resolveScan(ref, widget.token);
    if (!mounted) return;
    switch (r) {
      case OpenColony(:final id):
        context.go('/colonies/$id');
      case ScanMessage(:final text):
        setState(() => _message = text);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: ContentWidth(
          maxWidth: 480,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_intent != null) ...[
                FilledButton.icon(
                  onPressed: () => openExternal(_intent),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('In der App öffnen'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () {
                    setState(() => _message = null);
                    _resolve();
                  },
                  child: const Text('Hier im Browser fortfahren'),
                ),
              ] else if (_message == null)
                const Center(child: CircularProgressIndicator()),
              if (_message != null) ...[
                const SizedBox(height: 16),
                Text(_message!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                OutlinedButton(onPressed: () => context.go('/'), child: const Text('Zur Übersicht')),
              ],
            ]),
          ),
        ),
      );
}

/// Opened when the „App verbinden“ QR is scanned with a normal camera app.
class DeviceLinkLandingScreen extends StatelessWidget {
  const DeviceLinkLandingScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.phone_android,
          title: 'Mit der Android-App scannen',
          text: 'Dieser Code verbindet die Ant-Colony-Manager-App. Öffne die App und scanne ihn dort.',
        ),
      );
}
