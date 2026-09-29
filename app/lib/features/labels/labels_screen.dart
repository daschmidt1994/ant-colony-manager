import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../app/providers.dart';
import '../../core/session.dart';
import '../../core/web_meta.dart';
import '../../domain/models.dart';
import '../../nfc/nfc_controller.dart';
import '../../shared/widgets.dart';
import 'labels.dart';
import '../../app/i18n.dart';

/// Label printing (docs/06 §6): one label, a selection or a full sheet.
class LabelsScreen extends ConsumerStatefulWidget {
  const LabelsScreen({super.key, this.preselected = const {}});
  final Set<String> preselected;
  @override
  ConsumerState<LabelsScreen> createState() => _LabelsScreenState();
}

class _LabelsScreenState extends ConsumerState<LabelsScreen> {
  late final Set<String> _selected = {...widget.preselected};
  LabelTemplate _template = labelTemplates.first;
  int _startAt = 1;
  bool _onA4 = true; // single labels: real size on A4 instead of one label per page

  LabelTemplate get _effective => !_template.isSheet && _onA4 ? _template.onA4() : _template;
  bool _species = true, _name = true, _location = true, _code = false, _nfc = false;
  final _search = TextEditingController();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final colonies = ref.watch(coloniesProvider).value ?? const <Colony>[];
    final q = _search.text.trim().toLowerCase();
    final shown = colonies
        .where(
          (c) => q.isEmpty || '${c.name} ${c.species} ${c.locationPath ?? ''} #${c.number}'.toLowerCase().contains(q),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: Text(tr('Etiketten drucken'))),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _selected.isEmpty || _busy ? null : _generate,
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: Text(
              _selected.isEmpty ? tr('Kolonien auswählen') : tr('PDF für {0} Etikett(en)', [_selected.length]),
            ),
          ),
        ),
      ),
      body: ContentWidth(
        maxWidth: 720,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            SectionHeader(tr('Format')),
            DropdownButtonFormField<LabelTemplate>(
              initialValue: _template,
              isExpanded: true,
              items: [for (final t in labelTemplates) DropdownMenuItem(value: t, child: Text(t.name))],
              onChanged: (t) => setState(() {
                _template = t!;
                _onA4 = !t.labelPrinter;
                _startAt = 1;
              }),
            ),
            if (!_template.isSheet)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _onA4,
                onChanged: (v) => setState(() {
                  _onA4 = v;
                  _startAt = 1;
                }),
                title: Text(tr('Auf A4-Papier in Originalgröße')),
                subtitle: Text(
                  _onA4
                      ? tr('{0} pro Blatt, mit Schnittlinien – für normale Drucker', [_effective.perPage])
                      : tr('Eine Seite pro Etikett – nur für Etikettendrucker'),
                ),
              ),
            if (_effective.isSheet) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: Text(tr('Beginnen bei Feld (angebrochener Bogen)'))),
                  IconButton(
                    onPressed: _startAt > 1 ? () => setState(() => _startAt--) : null,
                    icon: const Icon(Icons.remove),
                  ),
                  Text('$_startAt', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  IconButton(
                    onPressed: _startAt < _effective.perPage ? () => setState(() => _startAt++) : null,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ],
            SectionHeader(tr('Inhalt')),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilterChip(label: Text(tr('Art')), selected: _species, onSelected: (v) => setState(() => _species = v)),
                FilterChip(label: Text(tr('Name/Nr.')), selected: _name, onSelected: (v) => setState(() => _name = v)),
                FilterChip(
                  label: Text(tr('Standort')),
                  selected: _location,
                  onSelected: (v) => setState(() => _location = v),
                ),
                FilterChip(
                  label: Text(tr('Interner Code')),
                  selected: _code,
                  onSelected: (v) => setState(() => _code = v),
                ),
                FilterChip(
                  label: const Text('„NFC + QR“'),
                  selected: _nfc,
                  onSelected: (v) => setState(() => _nfc = v),
                ),
              ],
            ),
            SectionHeader(
              tr('Kolonien ({0})', [_selected.length]),
              trailing: TextButton(
                onPressed: () => setState(() {
                  if (_selected.length == shown.length) {
                    _selected.clear();
                  } else {
                    _selected.addAll(shown.map((c) => c.id));
                  }
                }),
                child: Text(_selected.length == shown.length && shown.isNotEmpty ? tr('Keine') : tr('Alle')),
              ),
            ),
            TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(prefixIcon: Icon(Icons.search), hintText: tr('Filtern (z. B. Regal A)')),
            ),
            const SizedBox(height: 8),
            for (final c in shown)
              CheckboxListTile(
                value: _selected.contains(c.id),
                onChanged: (v) => setState(() => v == true ? _selected.add(c.id) : _selected.remove(c.id)),
                title: Text(c.name),
                subtitle: Text([c.species, ?c.locationPath].where((s) => s.isNotEmpty).join(' · ')),
                controlAffinity: ListTileControlAffinity.leading,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _generate() async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(repositoryProvider)!;
      final auth = ref.read(authProvider);
      final base = publicUrl(repo.db, auth is SignedIn ? auth.serverUrl : '');
      final labels = <LabelData>[];
      for (final c in repo.colonies()..retainWhere((c) => _selected.contains(c.id))) {
        final link = repo.scanLinks(c.id).where((l) => l.kind == 'qr' && l.active).firstOrNull;
        final token = link?.token ?? repo.regenerateQr(c.id); // colonies without a QR code get one
        labels.add(
          LabelData(
            url: '$base/c/$token',
            name: c.name,
            number: c.number,
            species: c.species,
            location: c.locationPath,
            code: c.internalCode,
          ),
        );
      }
      final template = _effective;
      final bytes = await buildLabelsPdf(
        template,
        labels,
        startAt: template.isSheet ? _startAt - 1 : 0,
        options: LabelOptions(species: _species, name: _name, location: _location, code: _code, nfcHint: _nfc),
      );
      if (!mounted) return;
      if (kIsWeb) {
        downloadFile('etiketten.pdf', bytes, 'application/pdf');
        showUndoSnack(context, tr('PDF heruntergeladen – im PDF-Programm mit 100 % Skalierung drucken.'));
      } else {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              appBar: AppBar(title: Text(tr('Vorschau'))),
              body: PdfPreview(
                build: (_) async => bytes,
                canChangeOrientation: false,
                canChangePageFormat: false,
                canDebug: false,
                pdfFileName: 'etiketten.pdf',
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
