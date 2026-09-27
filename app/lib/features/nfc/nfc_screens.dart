import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../data/repositories/colony_repository.dart';
import '../../nfc/nfc_controller.dart';
import '../../nfc/nfc_driver.dart';
import '../../shared/widgets.dart';
import '../scan/scan_screens.dart';

/// Keeps the NFC reader running while the app is in the foreground and opens
/// the colony of any tag that is held to the phone – from every screen.
class NfcScope extends ConsumerStatefulWidget {
  const NfcScope({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<NfcScope> createState() => _NfcScopeState();
}

class _NfcScopeState extends ConsumerState<NfcScope> with WidgetsBindingObserver {
  late final NfcController _nfc = ref.read(nfcControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nfc.setDefaultHandler(_onTag);
    _nfc.resume();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nfc.pause();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      _nfc.resume();
    } else if (s == AppLifecycleState.paused) {
      _nfc.pause(); // outside the app, Android's NDEF dispatch opens us via the tag's link
    }
  }

  Future<void> _onTag(NfcTagHandle tag) async {
    final repo = ref.read(repositoryProvider);
    if (repo == null) return;
    List<String> uris;
    try {
      uris = await tag.readUris();
    } on Exception {
      uris = const [];
    }
    final res = repo.resolveTag(uris, tagUidHash(repo.db, tag), parseScanInput);
    final router = ref.read(routerProvider);
    void msg(String t) => rootMessengerKey.currentState?.showSnackBar(SnackBar(content: Text(t)));
    switch (res) {
      case ScanFound(:final colonyId):
        router.go(scanTarget(repo, colonyId));
      case ScanRevoked():
        msg('Dieser Tag wurde deaktiviert. Weise ihn in der Kolonie neu zu.');
      case ScanUnknown():
        final token = uris.map(parseScanInput).whereType<String>().firstOrNull;
        if (token == null) {
          msg('Unbekannter Tag – Kolonie öffnen und „NFC-Tag zuweisen“ wählen.');
          return;
        }
        final r = await resolveScan(ref, token);
        switch (r) {
          case OpenColony(:final id):
            router.go(scanTarget(repo, id));
          case ScanMessage(:final text):
            msg(text);
        }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// -----------------------------------------------------------------------------

enum _Step { waiting, working, done, confirm, readOnly, failed, nfcOff, unsupported }

class NfcAssignScreen extends ConsumerStatefulWidget {
  const NfcAssignScreen({super.key, required this.colonyId});
  final String colonyId;
  @override
  ConsumerState<NfcAssignScreen> createState() => _NfcAssignScreenState();
}

class _NfcAssignScreenState extends ConsumerState<NfcAssignScreen> {
  late final NfcController _nfc = ref.read(nfcControllerProvider.notifier);
  late final NfcAssigner _assigner;
  final _label = TextEditingController();
  _Step _step = _Step.waiting;
  String _text = '';
  Assigned? _result;
  NfcTagHandle? _lastTag;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(repositoryProvider)!;
    final auth = ref.read(authProvider);
    _assigner = NfcAssigner(
      repo: repo,
      baseUrl: publicUrl(repo.db, auth is SignedIn ? auth.serverUrl : ''),
      uidKey: repo.db.getMeta('nfc_uid_key'),
      colonyId: widget.colonyId,
    );
    _nfc.takeOver(_onTag);
    _checkState();
  }

  Future<void> _checkState() async {
    await _nfc.resume();
    if (!mounted) return;
    final s = ref.read(nfcControllerProvider);
    setState(
      () => _step = switch (s) {
        NfcState.unsupported => _Step.unsupported,
        NfcState.disabled => _Step.nfcOff,
        NfcState.ready => _step == _Step.nfcOff || _step == _Step.unsupported ? _Step.waiting : _step,
      },
    );
  }

  @override
  void dispose() {
    _nfc.release();
    super.dispose();
  }

  Future<void> _onTag(NfcTagHandle tag) async {
    if (_step == _Step.working || _step == _Step.done) return;
    _lastTag = tag;
    setState(() => _step = _Step.working);
    _assigner.label = _label.text.trim().isEmpty ? null : _label.text.trim();
    final r = await _assigner.handle(tag);
    if (!mounted) return;
    setState(() {
      switch (r) {
        case Assigned():
          _result = r;
          _step = _Step.done;
        case AlreadyAssigned():
          _step = _Step.done;
          _result = null;
          _text = 'Dieser Tag gehört bereits zu dieser Kolonie.';
        case BelongsToOther(:final colonyName):
          _step = _Step.confirm;
          _text = 'Dieser Tag gehört zu „$colonyName“.';
        case ReadOnlyTag(:final canUseSerial):
          _step = _Step.readOnly;
          _text = canUseSerial
              ? 'Der Tag lässt sich nicht beschreiben. Du kannst ihn per Seriennummer registrieren – '
                    'das funktioniert, solange die App geöffnet ist.'
              : 'Der Tag lässt sich nicht beschreiben.';
        case AssignFailed(:final message):
          _step = _Step.failed;
          _text = message;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colony = ref.watch(colonyProvider(widget.colonyId)).value;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('NFC-Tag zuweisen${colony == null ? '' : ' · ${colony.name}'}')),
      body: ContentWidth(
        maxWidth: 520,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 16),
            Icon(
              switch (_step) {
                _Step.done => Icons.check_circle,
                _Step.failed || _Step.readOnly => Icons.error_outline,
                _Step.confirm => Icons.swap_horiz,
                _Step.nfcOff || _Step.unsupported => Icons.nfc,
                _ => Icons.contactless_outlined,
              },
              size: 96,
              color: switch (_step) {
                _Step.done => context.colors.ok,
                _Step.failed || _Step.readOnly => context.colors.overdue,
                _Step.confirm => context.colors.soon,
                _ => scheme.primary,
              },
            ),
            const SizedBox(height: 20),
            ..._body(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    final title = Theme.of(context).textTheme.titleLarge;
    final muted = TextStyle(color: context.colors.muted);
    switch (_step) {
      case _Step.unsupported:
        return [Text('Dieses Gerät hat kein NFC.', style: title, textAlign: TextAlign.center)];
      case _Step.nfcOff:
        return [
          Text('NFC ist ausgeschaltet', style: title, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            'Schalte NFC in den Android-Einstellungen ein und komm dann zurück.',
            style: muted,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          OutlinedButton(onPressed: _checkState, child: const Text('Erneut prüfen')),
        ];
      case _Step.waiting:
        return [
          Text('Halte das Handy an den Tag', style: title, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            'Rückseite, meist oben in der Mitte. Ruhig halten, bis es vibriert.',
            style: muted,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _label,
            decoration: const InputDecoration(labelText: 'Bezeichnung (optional)', hintText: 'Nest vorne'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Tag danach schreibschützen'),
            subtitle: const Text('Endgültig – der Tag kann dann nie mehr geändert werden.'),
            value: _assigner.lockAfterWrite,
            onChanged: (v) => setState(() => _assigner.lockAfterWrite = v),
          ),
        ];
      case _Step.working:
        return [
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 16),
          Text('Schreibe … Tag nicht entfernen', style: title, textAlign: TextAlign.center),
        ];
      case _Step.done:
        final r = _result;
        return [
          Text(r == null ? _text : 'Tag zugewiesen', style: title, textAlign: TextAlign.center),
          if (r != null) ...[
            const SizedBox(height: 8),
            Text(
              '${r.tagType ?? 'NFC-Tag'} · ${r.bytes} von ${r.capacity} Byte${r.locked ? ' · schreibgeschützt' : ''}',
              style: muted,
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(onPressed: () => context.pop(), child: const Text('Fertig')),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => setState(() {
              _step = _Step.waiting;
              _label.clear();
            }),
            child: const Text('Weiteren Tag zuweisen'),
          ),
        ];
      case _Step.confirm:
        return [
          Text(_text, style: title, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text('Umhängen deaktiviert die alte Zuordnung.', style: muted, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => setState(() {
              _assigner.allowReassign = true;
              _step = _Step.waiting;
              _text = '';
            }),
            child: const Text('Umhängen – Tag erneut anhalten'),
          ),
          TextButton(onPressed: () => context.pop(), child: const Text('Abbrechen')),
        ];
      case _Step.readOnly:
        return [
          Text('Schreibgeschützter Tag', style: title, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(_text, style: muted, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          if (_lastTag != null && _text.contains('Seriennummer'))
            FilledButton(
              onPressed: () {
                if (_assigner.registerSerial(_lastTag!)) {
                  setState(() {
                    _step = _Step.done;
                    _result = null;
                    _text = 'Per Seriennummer registriert.';
                  });
                }
              },
              child: const Text('Per Seriennummer registrieren'),
            ),
          TextButton(
            onPressed: () => setState(() => _step = _Step.waiting),
            child: const Text('Anderen Tag verwenden'),
          ),
        ];
      case _Step.failed:
        return [
          Text('Hat nicht geklappt', style: title, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(_text, style: muted, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton(onPressed: () => setState(() => _step = _Step.waiting), child: const Text('Nochmal versuchen')),
        ];
    }
  }
}
