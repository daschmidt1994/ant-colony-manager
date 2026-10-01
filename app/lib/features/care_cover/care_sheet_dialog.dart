import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/i18n.dart';
import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../core/session.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';
import '../reports/report_action.dart';
import 'care_sheet.dart';

/// „Pflegezettel drucken“: choose period, colonies, instructions and a
/// contact – then a PDF to print. Prefilled from a care cover if given.
Future<void> showCareSheetDialog(
  BuildContext context, {
  DateTimeRange? range,
  String instructions = '',
  Map<String, String>? colonies, // colony id → own instructions
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (c) => _CareSheetDialog(range: range, instructions: instructions, colonies: colonies),
);

class _CareSheetDialog extends ConsumerStatefulWidget {
  const _CareSheetDialog({this.range, required this.instructions, this.colonies});
  final DateTimeRange? range;
  final String instructions;
  final Map<String, String>? colonies;
  @override
  ConsumerState<_CareSheetDialog> createState() => _CareSheetDialogState();
}

class _CareSheetDialogState extends ConsumerState<_CareSheetDialog> {
  late DateTimeRange? _range = widget.range;
  late final _instructions = TextEditingController(text: widget.instructions);
  final _contact = TextEditingController();
  late final Map<String, String> _colonyNotes = {...?widget.colonies};
  Set<String>? _chosen;
  bool _busy = false;

  @override
  void dispose() {
    _instructions.dispose();
    _contact.dispose();
    super.dispose();
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day).subtract(const Duration(days: 30)),
      lastDate: now.add(const Duration(days: 365)),
      initialDateRange: _range,
    );
    if (r != null) setState(() => _range = r);
  }

  Future<void> _print(List<Colony> list) async {
    final range = _range;
    final chosen = list.where((c) => _chosen!.contains(c.id)).toList();
    if (range == null || chosen.isEmpty) {
      showUndoSnack(context, tr('Zeitraum und mindestens eine Kolonie wählen'));
      return;
    }
    if (range.duration.inDays > 62) {
      showUndoSnack(context, tr('Höchstens zwei Monate auf einmal'));
      return;
    }
    setState(() => _busy = true);
    try {
      final repo = ref.read(repositoryProvider)!;
      final auth = ref.read(authProvider);
      final bytes = await buildCareSheet(
        colonies: [
          for (final c in chosen)
            CareSheetColony(colony: c, due: repo.due(c.id), instructions: _colonyNotes[c.id] ?? ''),
        ],
        from: range.start,
        to: range.end,
        instructions: _instructions.text,
        contact: _contact.text,
        author: auth is SignedIn ? auth.user.displayName : null,
        now: DateTime.now(),
      );
      if (!mounted) return;
      await showPdf(context, bytes, name: 'pflegezettel.pdf', title: tr('Pflegezettel'));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(repositoryProvider)!;
    final list =
        (ref.watch(coloniesProvider).value ?? const <Colony>[])
            .where((c) => c.isCareActive && repo.roleOn(c.id) != 'viewer')
            .toList()
          ..sort((a, b) => a.number.compareTo(b.number));
    _chosen ??= widget.colonies?.keys.toSet() ?? {for (final c in list) c.id};
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('Pflegezettel drucken'), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            tr(
              'Für Nachbarn oder Familie ohne Konto: ein Zettel mit allem, was an welchem Tag zu tun ist – '
              'aus deinen Pflegeintervallen, zum Abhaken.',
            ),
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickRange,
            icon: const Icon(Icons.date_range),
            label: Text(_range == null ? tr('Zeitraum wählen') : '${S.date(_range!.start)} – ${S.date(_range!.end)}'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _instructions,
            minLines: 2,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: tr('Pflegeanweisungen (für alle Kolonien)'),
              hintText: tr('z. B. Proteinfutter nur jeden zweiten Tag, Honigwasser nachfüllen'),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _contact,
            decoration: InputDecoration(
              labelText: tr('Erreichbar unter (optional)'),
              hintText: tr('z. B. Telefonnummer'),
            ),
          ),
          SectionHeader(tr('Kolonien')),
          if (list.isEmpty) Text(tr('Noch keine Kolonien')),
          for (final c in list)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _chosen!.contains(c.id),
              title: Text('${c.name} (#${c.number})'),
              subtitle: c.species.isEmpty ? null : Text(c.species),
              onChanged: (v) => setState(() => v == true ? _chosen!.add(c.id) : _chosen!.remove(c.id)),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : () => _print(list),
            icon: const Icon(Icons.print_outlined),
            label: Text(tr('Pflegezettel erstellen')),
          ),
        ],
      ),
    );
  }
}
