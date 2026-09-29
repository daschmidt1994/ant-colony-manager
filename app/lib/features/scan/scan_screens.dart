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
import '../../domain/scan.dart';
export '../../domain/scan.dart' show parseScanInput;
import '../../nfc/nfc_controller.dart';
import '../../nfc/nfc_driver.dart';
import '../../shared/widgets.dart';
import 'scanner_view.dart';
import '../../app/i18n.dart';

sealed class ScanOutcome {}

class OpenColony extends ScanOutcome {
  OpenColony(this.id);
  final String id;
}

class ScanMessage extends ScanOutcome {
  ScanMessage(this.text);
  final String text;
}

/// Where a scanned colony opens: during a care round the scan means „next
/// colony“ and lands on the round card, otherwise on the colony.
String scanTarget(ColonyRepository repo, String colonyId) => repo.activeRound() == null
    ? '/colonies/$colonyId'
    : '/round?colony=$colonyId&t=${DateTime.now().microsecondsSinceEpoch}';

/// Resolves a token: first locally (works offline), then on the server.
Future<ScanOutcome> resolveScan(WidgetRef ref, String token) async {
  final repo = ref.read(repositoryProvider)!;
  switch (repo.resolveToken(token)) {
    case ScanFound(:final colonyId):
      return OpenColony(colonyId);
    case ScanRevoked():
      return ScanMessage(tr('Dieser Code wurde deaktiviert. Weise der Kolonie einen neuen Code zu.'));
    case ScanUnknown():
  }
  try {
    final res = await ref.read(authProvider.notifier).api.get('/api/v1/scan/$token') as Map<String, dynamic>;
    await ref.read(syncEngineProvider)?.sync();
    return OpenColony(res['colony_id'] as String);
  } on ApiException catch (e) {
    return ScanMessage(
      e.status == 410
          ? tr('Dieser Code wurde deaktiviert.')
          : tr('Kein Kolonie-Code von dir – oder die Kolonie ist nicht mit dir geteilt.'),
    );
  } on NetworkException {
    return ScanMessage(tr('Unbekannter Code. Offline – wird beim nächsten Sync geprüft.'));
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
      setState(() => _message = tr('Das ist kein Kolonie-Code. Erwartet: 16 Zeichen oder ein Link mit /c/…'));
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
        context.go(scanTarget(ref.read(repositoryProvider)!, id));
      case ScanMessage(:final text):
        setState(() => _message = text);
    }
  }

  Future<void> _fromCamera(String raw) async {
    if (parseDeviceLink(raw) != null) {
      setState(() => _message = tr('Das ist ein Code zum Verbinden der App – du bist bereits angemeldet.'));
      return;
    }
    _code.text = raw;
    await _go();
  }

  @override
  Widget build(BuildContext context) {
    final nfc = ref.watch(nfcControllerProvider);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Kolonie scannen')), actions: const [SyncBadge()]),
      body: ContentWidth(
        maxWidth: 560,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (cameraScanSupported)
              ScannerView(onCode: _fromCamera)
            else
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Icon(Icons.qr_code_scanner, size: 64, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(height: 12),
                      Text(tr('Den Kamera-Scan gibt es in der Android-App.'), textAlign: TextAlign.center),
                      const SizedBox(height: 4),
                      Text(
                        tr('Hier: Code vom Etikett oder den Link eingeben.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.colors.muted),
                      ),
                    ],
                  ),
                ),
              ),
            if (nfc == NfcState.ready) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.contactless_outlined, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(tr('NFC ist bereit – Tag einfach antippen')),
                ],
              ),
            ] else if (nfc == NfcState.disabled) ...[
              const SizedBox(height: 12),
              Text(
                tr('NFC ist ausgeschaltet.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: context.colors.muted),
              ),
            ],
            const SizedBox(height: 20),
            TextField(
              controller: _code,
              autocorrect: false,
              decoration: InputDecoration(labelText: tr('Code oder Link'), hintText: 'https://…/c/7Kq2mZr9XbT4pLwA'),
              onSubmitted: (_) => _go(),
            ),
            const SizedBox(height: 12),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_message!, style: TextStyle(color: context.colors.soon)),
              ),
            FilledButton(onPressed: _busy ? null : _go, child: Text(tr('Kolonie öffnen'))),
          ],
        ),
      ),
    );
  }
}

/// Before sign-in (Android): scan the „Android-App verbinden“ QR of the web app.
class ConnectScanScreen extends ConsumerStatefulWidget {
  const ConnectScanScreen({super.key});
  @override
  ConsumerState<ConnectScanScreen> createState() => _ConnectScanScreenState();
}

class _ConnectScanScreenState extends ConsumerState<ConnectScanScreen> {
  String? _message;
  bool _busy = false;

  Future<void> _onCode(String raw) async {
    if (_busy) return;
    final link = parseDeviceLink(raw);
    if (link == null) {
      setState(() => _message = tr('Das ist kein Verbindungs-Code. In der Web-App: „Mehr → Android-App verbinden“.'));
      return;
    }
    setState(() {
      _busy = true;
      _message = tr('Verbinde mit {0} …', [link.server]);
    });
    try {
      await ref.read(authProvider.notifier).linkDevice(link.server, link.code);
    } catch (e) {
      if (mounted) setState(() => _message = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr('App verbinden'))),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(tr('Öffne in der Web-App „Mehr → Android-App verbinden“ und scanne den QR-Code.')),
        const SizedBox(height: 16),
        ScannerView(onCode: _onCode, height: 380),
        if (_message != null) ...[const SizedBox(height: 16), Text(_message!, textAlign: TextAlign.center)],
      ],
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
    if (!isScanToken(widget.token)) {
      setState(() => _message = tr('Ungültiger Code.'));
      return;
    }
    final r = await resolveScan(ref, widget.token);
    if (!mounted) return;
    switch (r) {
      case OpenColony(:final id):
        context.go(scanTarget(ref.read(repositoryProvider)!, id));
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_intent != null) ...[
              FilledButton.icon(
                onPressed: () => openExternal(_intent),
                icon: const Icon(Icons.open_in_new),
                label: Text(tr('In der App öffnen')),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () {
                  setState(() => _message = null);
                  _resolve();
                },
                child: Text(tr('Hier im Browser fortfahren')),
              ),
            ] else if (_message == null)
              const Center(child: CircularProgressIndicator()),
            if (_message != null) ...[
              const SizedBox(height: 16),
              Text(_message!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: () => context.go('/'), child: Text(tr('Zur Übersicht'))),
            ],
          ],
        ),
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
    body: EmptyState(
      icon: Icons.phone_android,
      title: tr('Mit der Android-App scannen'),
      text: tr('Dieser Code verbindet die Ant-Colony-Manager-App. Öffne die App und scanne ihn dort.'),
    ),
  );
}
