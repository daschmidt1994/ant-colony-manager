import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../data/repositories/colony_repository.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';

ColonyRepository _repo(WidgetRef ref) => ref.read(repositoryProvider)!;

/// Confirms a saved event with „Rückgängig“. Takes the messenger and
/// repository directly so it also works after a bottom sheet was closed.
void _undoable(ScaffoldMessengerState m, ColonyRepository repo, ColonyEvent e, {VoidCallback? details}) {
  HapticFeedback.mediumImpact();
  showUndoSnackOn(
    m,
    '${S.eventTypes[e.type]} gespeichert: ${S.eventSummary(e)}',
    onUndo: () => repo.deleteEvent(e.id),
    onDetails: details,
  );
}

/// „Letzte Fütterung wiederholen“ – one tap, with a guard against double taps.
Future<void> repeatFeeding(BuildContext context, WidgetRef ref, Colony colony) async {
  final repo = _repo(ref);
  if (repo.fedJustNow(colony.id)) {
    final again = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Gerade eben gefüttert'),
        content: const Text('Vor weniger als 2 Minuten wurde bereits eine Fütterung gespeichert. Trotzdem nochmal?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Nein')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Ja, speichern')),
        ],
      ),
    );
    if (again != true) return;
  }
  final e = repo.repeatLastFeeding(colony.id);
  if (e != null && context.mounted) _undoable(ScaffoldMessenger.of(context), repo, e);
}

/// Water in one tap with the kinds used last time for this colony.
void quickWater(BuildContext context, WidgetRef ref, Colony colony) {
  final repo = _repo(ref);
  final last = repo.events(colony.id, types: {'water'}, limit: 1);
  final kinds = last.isNotEmpty && last.first.waterKinds.isNotEmpty
      ? last.first.waterKinds
      : const ['drinker_refilled'];
  final e = repo.logEvent(
    colony.id,
    'water',
    details: {
      'water': {'kinds': kinds},
    },
  );
  _undoable(ScaffoldMessenger.of(context), repo, e, details: () => showWaterSheet(context, ref, colony, edit: e));
}

void quickCheck(BuildContext context, WidgetRef ref, Colony colony) {
  final repo = _repo(ref);
  final e = repo.logEvent(colony.id, 'check');
  _undoable(
    ScaffoldMessenger.of(context),
    repo,
    e,
    details: () => showNoteSheet(context, ref, colony, type: 'check', edit: e),
  );
}

Future<T?> _sheet<T>(BuildContext context, Widget child) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (c) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
    child: ContentWidth(maxWidth: 640, child: child),
  ),
);

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({
    required this.title,
    required this.when,
    required this.onWhen,
    required this.children,
    required this.onSave,
    this.saveLabel = 'Speichern',
  });
  final String title;
  final DateTime? when;
  final ValueChanged<DateTime?> onWhen;
  final List<Widget> children;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            ),
            WhenChip(value: when, onChanged: onWhen),
          ],
        ),
        const SizedBox(height: 12),
        ...children,
        const SizedBox(height: 20),
        FilledButton(onPressed: onSave, child: const Text('Speichern')),
      ],
    ),
  );
}

// -----------------------------------------------------------------------------
// Feeding

Future<void> showFeedingSheet(BuildContext context, WidgetRef ref, Colony colony) async {
  final r = await _sheet<String>(context, _FeedingSheet(colony: colony));
  if (r == 'repeat' && context.mounted) await repeatFeeding(context, ref, colony);
}

class _Selected {
  _Selected(this.food, this.quantity, this.size);
  final FoodItem food;
  double quantity;
  String? size;
}

class _FeedingSheet extends ConsumerStatefulWidget {
  const _FeedingSheet({required this.colony});
  final Colony colony;
  @override
  ConsumerState<_FeedingSheet> createState() => _FeedingSheetState();
}

class _FeedingSheetState extends ConsumerState<_FeedingSheet> {
  final _selected = <String, _Selected>{};
  String _acceptance = 'unknown';
  final _note = TextEditingController();
  DateTime? _when;
  bool _showAll = false;

  /// Foods used for this colony come first.
  List<FoodItem> _ordered(List<FoodItem> all) {
    final used = <String, int>{};
    var rank = 0;
    for (final e in _repo(ref).events(widget.colony.id, types: {'feeding'}, limit: 20)) {
      for (final i in e.items) {
        if (i.foodItemId != null) used.putIfAbsent(i.foodItemId!, () => rank++);
      }
    }
    return [...all]..sort((a, b) => (used[a.id] ?? 1000 + a.sortOrder).compareTo(used[b.id] ?? 1000 + b.sortOrder));
  }

  @override
  Widget build(BuildContext context) {
    final foods = _ordered(ref.watch(foodItemsProvider).value ?? const []);
    final last = _repo(ref).lastFeeding(widget.colony.id);
    Widget group(String category, String title) {
      final list = foods.where((f) => f.category == category).toList();
      final visible = _showAll ? list : list.take(5).toList();
      if (list.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(title),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in visible)
                FilterChip(
                  label: Text(f.name),
                  selected: _selected.containsKey(f.id),
                  onSelected: (v) => setState(() {
                    if (v) {
                      _selected[f.id] = _Selected(f, 1, f.category == 'protein' ? 'small' : null);
                    } else {
                      _selected.remove(f.id);
                    }
                  }),
                ),
              if (!_showAll && list.length > 5)
                ActionChip(label: const Text('mehr …'), onPressed: () => setState(() => _showAll = true)),
            ],
          ),
        ],
      );
    }

    return _SheetFrame(
      title: 'Füttern · ${widget.colony.name}',
      when: _when,
      onWhen: (v) => setState(() => _when = v),
      onSave: _selected.isEmpty ? null : _save,
      children: [
        if (last != null)
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: ListTile(
              leading: const Icon(Icons.replay),
              title: const Text('Wie letztes Mal'),
              subtitle: Text(S.eventSummary(last)),
              trailing: const Icon(Icons.check),
              onTap: () => Navigator.pop(context, 'repeat'),
            ),
          ),
        group('protein', 'Protein'),
        group('carbohydrate', 'Kohlenhydrate'),
        group('other', 'Sonstiges'),
        if (_selected.isNotEmpty) const SectionHeader('Menge'),
        for (final s in _selected.values)
          Row(
            children: [
              Expanded(
                child: Text(s.food.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              IconButton.filledTonal(
                onPressed: s.quantity > 1 ? () => setState(() => s.quantity--) : null,
                icon: const Icon(Icons.remove),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  s.quantity.toInt().toString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton.filledTonal(onPressed: () => setState(() => s.quantity++), icon: const Icon(Icons.add)),
              if (s.food.category == 'protein') ...[
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: s.size,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 'tiny', child: Text('winzig')),
                    DropdownMenuItem(value: 'small', child: Text('klein')),
                    DropdownMenuItem(value: 'medium', child: Text('mittel')),
                    DropdownMenuItem(value: 'large', child: Text('groß')),
                  ],
                  onChanged: (v) => setState(() => s.size = v),
                ),
              ],
            ],
          ),
        const SectionHeader('Annahme'),
        SegmentedButton<String>(
          segments: [
            for (final a in const ['unknown', 'accepted', 'partial', 'ignored'])
              ButtonSegment(value: a, label: Text(S.acceptance[a]!)),
          ],
          selected: {_acceptance},
          onSelectionChanged: (v) => setState(() => _acceptance = v.first),
          showSelectedIcon: false,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _note,
          decoration: const InputDecoration(labelText: 'Notiz (optional)'),
        ),
      ],
    );
  }

  void _save() {
    final items = [
      for (final s in _selected.values)
        {
          'food_item_id': s.food.id,
          'food_name': s.food.name,
          'category': s.food.category,
          'quantity': s.quantity,
          'unit': s.food.defaultUnit,
          'size': ?s.size,
        },
    ];
    final m = ScaffoldMessenger.of(context);
    final repo = _repo(ref);
    final e = repo.logEvent(
      widget.colony.id,
      'feeding',
      details: {
        'feeding': {'acceptance': _acceptance, 'items': items},
      },
      note: _note.text,
      at: _when,
    );
    Navigator.pop(context);
    _undoable(m, repo, e);
  }
}

// -----------------------------------------------------------------------------
// Water & cleaning (kind chips)

Future<void> showWaterSheet(BuildContext context, WidgetRef ref, Colony colony, {ColonyEvent? edit}) => _sheet(
  context,
  _KindsSheet(colony: colony, type: 'water', kinds: S.waterKinds, edit: edit, withMeasurements: true),
);

Future<void> showCleaningSheet(BuildContext context, WidgetRef ref, Colony colony) =>
    _sheet(context, _KindsSheet(colony: colony, type: 'cleaning', kinds: S.cleaningKinds));

class _KindsSheet extends ConsumerStatefulWidget {
  const _KindsSheet({
    required this.colony,
    required this.type,
    required this.kinds,
    this.edit,
    this.withMeasurements = false,
  });
  final Colony colony;
  final String type;
  final Map<String, String> kinds;
  final ColonyEvent? edit;
  final bool withMeasurements;

  @override
  ConsumerState<_KindsSheet> createState() => _KindsSheetState();
}

class _KindsSheetState extends ConsumerState<_KindsSheet> {
  late final Set<String> _sel;
  final _note = TextEditingController();
  final _temp = TextEditingController();
  final _hum = TextEditingController();
  DateTime? _when;

  @override
  void initState() {
    super.initState();
    List<String> lastKinds() {
      final e = widget.edit ?? _repo(ref).events(widget.colony.id, types: {widget.type}, limit: 1).firstOrNull;
      if (e == null) return const [];
      return widget.type == 'water' ? e.waterKinds : e.cleaningKinds;
    }

    _sel = {...lastKinds()};
    if (_sel.isEmpty) _sel.add(widget.type == 'water' ? 'drinker_refilled' : 'food_remains');
    _note.text = widget.edit?.note ?? '';
    if (widget.edit != null) _when = widget.edit!.occurredAt;
  }

  @override
  Widget build(BuildContext context) => _SheetFrame(
    title: '${widget.type == 'water' ? 'Wasser' : 'Reinigen'} · ${widget.colony.name}',
    when: _when,
    onWhen: (v) => setState(() => _when = v),
    onSave: _sel.isEmpty ? null : _save,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final k in widget.kinds.entries)
            FilterChip(
              label: Text(k.value),
              selected: _sel.contains(k.key),
              onSelected: (v) => setState(() => v ? _sel.add(k.key) : _sel.remove(k.key)),
            ),
        ],
      ),
      if (widget.withMeasurements && widget.edit == null) ...[
        const SectionHeader('Messwerte (optional)'),
        Row(
          children: [
            Expanded(child: _numberField(_temp, 'Temperatur', '°C')),
            const SizedBox(width: 12),
            Expanded(child: _numberField(_hum, 'Luftfeuchte', '%')),
          ],
        ),
      ],
      const SizedBox(height: 12),
      TextField(
        controller: _note,
        decoration: const InputDecoration(labelText: 'Notiz (optional)'),
      ),
    ],
  );

  void _save() {
    final repo = _repo(ref);
    final m = ScaffoldMessenger.of(context);
    final details = <String, dynamic>{
      widget.type: {'kinds': _sel.toList()},
      if (widget.withMeasurements) ...?_measurements(_temp, _hum),
    };
    Navigator.pop(context);
    if (widget.edit != null) {
      repo.updateEvent(widget.edit!.id, {
        widget.type: {'kinds': _sel.toList()},
        'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
        if (_when != null) 'occurred_at': _when!.toUtc().toIso8601String(),
      });
      return;
    }
    final e = repo.logEvent(widget.colony.id, widget.type, details: details, note: _note.text, at: _when);
    _undoable(m, repo, e);
  }
}

Widget _numberField(TextEditingController c, String label, String suffix) => TextField(
  controller: c,
  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[-0-9.,]'))],
  decoration: InputDecoration(labelText: label, suffixText: suffix),
);

double? _parse(String s) => double.tryParse(s.trim().replaceAll(',', '.'));

Map<String, dynamic>? _measurements(TextEditingController temp, TextEditingController hum) {
  final t = _parse(temp.text), h = _parse(hum.text);
  if (t == null && h == null) return null;
  return {
    'measurements': [
      if (t != null) {'metric': 'temperature', 'value': t, 'unit': 'celsius'},
      if (h != null) {'metric': 'humidity', 'value': h, 'unit': 'percent'},
    ],
  };
}

// -----------------------------------------------------------------------------
// Note / problem / check details

Future<void> showNoteSheet(
  BuildContext context,
  WidgetRef ref,
  Colony colony, {
  String type = 'note',
  ColonyEvent? edit,
}) => _sheet(context, _NoteSheet(colony: colony, type: type, edit: edit));

class _NoteSheet extends ConsumerStatefulWidget {
  const _NoteSheet({required this.colony, required this.type, this.edit});
  final Colony colony;
  final String type;
  final ColonyEvent? edit;
  @override
  ConsumerState<_NoteSheet> createState() => _NoteSheetState();
}

class _NoteSheetState extends ConsumerState<_NoteSheet> {
  late final _text = TextEditingController(text: widget.edit?.note ?? '');
  late bool _problem = widget.type == 'problem';
  String _severity = 'warning';
  DateTime? _when;

  @override
  Widget build(BuildContext context) => _SheetFrame(
    title: widget.type == 'check' ? 'Kontrolle · ${widget.colony.name}' : 'Notiz · ${widget.colony.name}',
    when: _when,
    onWhen: (v) => setState(() => _when = v),
    onSave: _save,
    children: [
      TextField(
        controller: _text,
        autofocus: widget.edit == null,
        minLines: 3,
        maxLines: 8,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: widget.type == 'check' ? 'Befund (optional)' : 'Notiz'),
      ),
      if (widget.type != 'check' && widget.edit == null) ...[
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Als Problem markieren'),
          subtitle: const Text('erscheint als Warnung im Dashboard'),
          value: _problem,
          onChanged: (v) => setState(() => _problem = v),
        ),
        if (_problem)
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'info', label: Text('Hinweis')),
              ButtonSegment(value: 'warning', label: Text('Warnung')),
              ButtonSegment(value: 'critical', label: Text('Kritisch')),
            ],
            selected: {_severity},
            onSelectionChanged: (v) => setState(() => _severity = v.first),
          ),
      ],
    ],
  );

  void _save() {
    final repo = _repo(ref);
    final m = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    if (widget.edit != null) {
      repo.updateEvent(widget.edit!.id, {
        'note': _text.text.trim().isEmpty ? null : _text.text.trim(),
        if (_when != null) 'occurred_at': _when!.toUtc().toIso8601String(),
      });
      return;
    }
    if (widget.type != 'check' && _text.text.trim().isEmpty) return;
    final type = widget.type == 'check' ? 'check' : (_problem ? 'problem' : 'note');
    final e = repo.logEvent(
      widget.colony.id,
      type,
      details: {if (type == 'problem') 'severity': _severity},
      note: _text.text,
      at: _when,
    );
    _undoable(m, repo, e);
  }
}

// -----------------------------------------------------------------------------
// Measurement

Future<void> showMeasurementSheet(BuildContext context, WidgetRef ref, Colony colony) =>
    _sheet(context, _MeasurementSheet(colony: colony));

class _MeasurementSheet extends ConsumerStatefulWidget {
  const _MeasurementSheet({required this.colony});
  final Colony colony;
  @override
  ConsumerState<_MeasurementSheet> createState() => _MeasurementSheetState();
}

class _MeasurementSheetState extends ConsumerState<_MeasurementSheet> {
  late final _temp = TextEditingController(
    text: widget.colony.lastTemperature == null ? '' : S.decimal(widget.colony.lastTemperature!),
  );
  late final _hum = TextEditingController(
    text: widget.colony.lastHumidity == null ? '' : '${widget.colony.lastHumidity!.round()}',
  );
  DateTime? _when;

  @override
  Widget build(BuildContext context) => _SheetFrame(
    title: 'Messung · ${widget.colony.name}',
    when: _when,
    onWhen: (v) => setState(() => _when = v),
    onSave: _save,
    children: [
      Row(
        children: [
          Expanded(child: _numberField(_temp, 'Temperatur', '°C')),
          const SizedBox(width: 12),
          Expanded(child: _numberField(_hum, 'Luftfeuchte', '%')),
        ],
      ),
      const SizedBox(height: 8),
      Text('Vorausgefüllt mit den letzten Werten.', style: TextStyle(color: context.colors.muted, fontSize: 13)),
    ],
  );

  void _save() {
    final m = _measurements(_temp, _hum);
    if (m == null) return;
    final t = _parse(_temp.text), h = _parse(_hum.text);
    if ((t != null && (t < -30 || t > 60)) || (h != null && (h < 0 || h > 100))) {
      showError(context, 'Wert außerhalb des gültigen Bereichs');
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final repo = _repo(ref);
    final e = repo.logEvent(widget.colony.id, 'measurement', details: m, at: _when);
    Navigator.pop(context);
    _undoable(messenger, repo, e);
  }
}
