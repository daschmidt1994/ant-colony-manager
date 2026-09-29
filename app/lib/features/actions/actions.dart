import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../data/repositories/colony_repository.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';
import '../../app/i18n.dart';

ColonyRepository _repo(WidgetRef ref) => ref.read(repositoryProvider)!;

/// Confirms a saved event with „Rückgängig“. Takes the messenger and
/// repository directly so it also works after a bottom sheet was closed.
void _undoable(ScaffoldMessengerState m, ColonyRepository repo, ColonyEvent e, {VoidCallback? details}) {
  HapticFeedback.mediumImpact();
  showUndoSnackOn(
    m,
    tr('{0} gespeichert: {1}', [S.eventTypes[e.type], S.eventSummary(e)]),
    onUndo: () => repo.deleteEvent(e.id),
    onDetails: details,
  );
}

/// „Letzte Fütterung wiederholen“ – one tap, with a guard against double taps.
Future<void> repeatFeeding(BuildContext context, WidgetRef ref, Colony colony, {DateTime? at}) async {
  final repo = _repo(ref);
  if (at == null && repo.fedJustNow(colony.id)) {
    final again = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Gerade eben gefüttert')),
        content: Text(tr('Vor weniger als 2 Minuten wurde bereits eine Fütterung gespeichert. Trotzdem nochmal?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Nein'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Ja, speichern'))),
        ],
      ),
    );
    if (again != true) return;
  }
  final e = repo.repeatLastFeeding(colony.id, at: at);
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

Future<T?> _sheet<T>(BuildContext context, Widget child) {
  // the „gespeichert – Rückgängig“ of the previous entry must not cover „Speichern“
  ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (c) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
      child: ContentWidth(maxWidth: 640, child: child),
    ),
  );
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({
    required this.title,
    required this.when,
    required this.onWhen,
    required this.children,
    required this.onSave,
  });
  final String title;
  final DateTime? when;
  final ValueChanged<DateTime?> onWhen;
  final List<Widget> children;
  final VoidCallback? onSave;

  // „Speichern“ stays below the scrolling content – always visible.
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  WhenChip(value: when, onChanged: onWhen),
                ],
              ),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: FilledButton(onPressed: onSave, child: Text(tr('Speichern'))),
      ),
    ],
  );
}

// -----------------------------------------------------------------------------
// Feeding

Future<void> showFeedingSheet(BuildContext context, WidgetRef ref, Colony colony, {DateTime? at}) async {
  final r = await _sheet<(String, DateTime?)>(context, _FeedingSheet(colony: colony, at: at));
  if (r?.$1 == 'repeat' && context.mounted) await repeatFeeding(context, ref, colony, at: r!.$2);
}

class _Selected {
  _Selected(this.food, this.quantity, this.size);
  final FoodItem food;
  double quantity;
  String? size;
}

class _FeedingSheet extends ConsumerStatefulWidget {
  const _FeedingSheet({required this.colony, this.at});
  final Colony colony;
  final DateTime? at;
  @override
  ConsumerState<_FeedingSheet> createState() => _FeedingSheetState();
}

class _FeedingSheetState extends ConsumerState<_FeedingSheet> {
  final _selected = <String, _Selected>{};
  String _acceptance = 'unknown';
  final _note = TextEditingController();
  late DateTime? _when = widget.at;
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
                  label: Text(S.foodName(f.name)),
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
      title: tr('Füttern · {0}', [widget.colony.name]),
      when: _when,
      onWhen: (v) => setState(() => _when = v),
      onSave: _selected.isEmpty ? null : _save,
      children: [
        if (last != null)
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: ListTile(
              leading: const Icon(Icons.replay),
              title: Text(tr('Wie letztes Mal')),
              subtitle: Text(S.eventSummary(last)),
              trailing: const Icon(Icons.check),
              onTap: () => Navigator.pop(context, ('repeat', _when)),
            ),
          ),
        group('protein', tr('Protein')),
        group('carbohydrate', tr('Kohlenhydrate')),
        group('other', tr('Sonstiges')),
        if (_selected.isNotEmpty) SectionHeader(tr('Menge')),
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
                  items: [
                    DropdownMenuItem(value: 'tiny', child: Text(tr('winzig'))),
                    DropdownMenuItem(value: 'small', child: Text(tr('klein'))),
                    DropdownMenuItem(value: 'medium', child: Text(tr('mittel'))),
                    DropdownMenuItem(value: 'large', child: Text(tr('groß'))),
                  ],
                  onChanged: (v) => setState(() => s.size = v),
                ),
              ],
            ],
          ),
        SectionHeader(tr('Annahme')),
        SegmentedButton<String>(
          segments: [
            for (final a in const ['unknown', 'accepted', 'partial', 'ignored'])
              ButtonSegment(
                value: a,
                label: FittedBox(fit: BoxFit.scaleDown, child: Text(S.acceptance[a]!, maxLines: 1)),
              ),
          ],
          selected: {_acceptance},
          onSelectionChanged: (v) => setState(() => _acceptance = v.first),
          showSelectedIcon: false,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _note,
          decoration: InputDecoration(labelText: tr('Notiz (optional)')),
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

Future<void> showWaterSheet(BuildContext context, WidgetRef ref, Colony colony, {ColonyEvent? edit, DateTime? at}) =>
    _sheet(
      context,
      _KindsSheet(colony: colony, type: 'water', kinds: S.waterKinds, edit: edit, at: at, withMeasurements: true),
    );

Future<void> showCleaningSheet(BuildContext context, WidgetRef ref, Colony colony, {DateTime? at}) =>
    _sheet(context, _KindsSheet(colony: colony, type: 'cleaning', kinds: S.cleaningKinds, at: at));

class _KindsSheet extends ConsumerStatefulWidget {
  const _KindsSheet({
    required this.colony,
    required this.type,
    required this.kinds,
    this.edit,
    this.at,
    this.withMeasurements = false,
  });
  final Colony colony;
  final String type;
  final Map<String, String> kinds;
  final ColonyEvent? edit;
  final DateTime? at;
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
    _when = widget.edit?.occurredAt ?? widget.at;
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
        SectionHeader(tr('Messwerte (optional)')),
        Row(
          children: [
            Expanded(child: _numberField(_temp, tr('Temperatur'), '°C')),
            const SizedBox(width: 12),
            Expanded(child: _numberField(_hum, tr('Luftfeuchte'), '%')),
          ],
        ),
      ],
      const SizedBox(height: 12),
      TextField(
        controller: _note,
        decoration: InputDecoration(labelText: tr('Notiz (optional)')),
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
  DateTime? at,
}) => _sheet(context, _NoteSheet(colony: colony, type: type, edit: edit, at: at));

class _NoteSheet extends ConsumerStatefulWidget {
  const _NoteSheet({required this.colony, required this.type, this.edit, this.at});
  final Colony colony;
  final String type;
  final ColonyEvent? edit;
  final DateTime? at;
  @override
  ConsumerState<_NoteSheet> createState() => _NoteSheetState();
}

class _NoteSheetState extends ConsumerState<_NoteSheet> {
  late final _text = TextEditingController(text: widget.edit?.note ?? '');
  late bool _problem = widget.type == 'problem';
  String _severity = 'warning';
  late DateTime? _when = widget.edit?.occurredAt ?? widget.at;

  @override
  Widget build(BuildContext context) => _SheetFrame(
    title: widget.type == 'check'
        ? tr('Kontrolle · {0}', [widget.colony.name])
        : tr('Notiz · {0}', [widget.colony.name]),
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
        decoration: InputDecoration(labelText: widget.type == 'check' ? tr('Befund (optional)') : tr('Notiz')),
      ),
      if (widget.type != 'check' && widget.edit == null) ...[
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('Als Problem markieren')),
          subtitle: Text(tr('erscheint als Warnung im Dashboard')),
          value: _problem,
          onChanged: (v) => setState(() => _problem = v),
        ),
        if (_problem)
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'info', label: Text(tr('Hinweis'))),
              ButtonSegment(value: 'warning', label: Text(tr('Warnung'))),
              ButtonSegment(value: 'critical', label: Text(tr('Kritisch'))),
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

Future<void> showMeasurementSheet(BuildContext context, WidgetRef ref, Colony colony, {DateTime? at}) =>
    _sheet(context, _MeasurementSheet(colony: colony, at: at));

class _MeasurementSheet extends ConsumerStatefulWidget {
  const _MeasurementSheet({required this.colony, this.at});
  final Colony colony;
  final DateTime? at;
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
  late DateTime? _when = widget.at;

  @override
  Widget build(BuildContext context) => _SheetFrame(
    title: tr('Messung · {0}', [widget.colony.name]),
    when: _when,
    onWhen: (v) => setState(() => _when = v),
    onSave: _save,
    children: [
      Row(
        children: [
          Expanded(child: _numberField(_temp, tr('Temperatur'), '°C')),
          const SizedBox(width: 12),
          Expanded(child: _numberField(_hum, tr('Luftfeuchte'), '%')),
        ],
      ),
      const SizedBox(height: 8),
      Text(tr('Vorausgefüllt mit den letzten Werten.'), style: TextStyle(color: context.colors.muted, fontSize: 13)),
    ],
  );

  void _save() {
    final m = _measurements(_temp, _hum);
    if (m == null) return;
    final t = _parse(_temp.text), h = _parse(_hum.text);
    if ((t != null && (t < -30 || t > 60)) || (h != null && (h < 0 || h > 100))) {
      showError(context, tr('Wert außerhalb des gültigen Bereichs'));
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final repo = _repo(ref);
    final e = repo.logEvent(widget.colony.id, 'measurement', details: m, at: _when);
    Navigator.pop(context);
    _undoable(messenger, repo, e);
  }
}

// -----------------------------------------------------------------------------
// Colony size and brood (spec §11, §12) – feeds the growth and brood charts.

Future<void> showCensusSheet(BuildContext context, WidgetRef ref, Colony colony, {DateTime? at}) =>
    _sheet(context, _CensusSheet(colony: colony, at: at));

class _CensusSheet extends ConsumerStatefulWidget {
  const _CensusSheet({required this.colony, this.at});
  final Colony colony;
  final DateTime? at;
  @override
  ConsumerState<_CensusSheet> createState() => _CensusSheetState();
}

class _CensusSheetState extends ConsumerState<_CensusSheet> {
  (int, int?)? _range;
  final _exact = TextEditingController();
  final _brood = <String, String>{};
  late DateTime? _when = widget.at;

  static Map<String, String> get _stages => {
    'eggs': tr('Eier'),
    'larvae': tr('Larven'),
    'pupae': tr('Puppen (Kokon)'),
    'naked_pupae': tr('Puppen (nackt)'),
  };
  static Map<String, String> get _levels => S.broodLevels;

  bool get _hasCensus => _range != null || int.tryParse(_exact.text.trim()) != null;

  void _save() {
    final repo = _repo(ref);
    final messenger = ScaffoldMessenger.of(context);
    final exact = int.tryParse(_exact.text.trim());
    ColonyEvent? last;
    if (_hasCensus) {
      last = repo.logEvent(
        widget.colony.id,
        'census',
        at: _when,
        details: {
          'census': exact != null ? {'exact_count': exact} : {'estimate_min': _range!.$1, 'estimate_max': _range!.$2},
        },
      );
    }
    if (_brood.isNotEmpty) {
      last = repo.logEvent(
        widget.colony.id,
        'brood',
        at: _when,
        details: {
          'brood': [
            for (final e in _brood.entries) {'stage': e.key, 'level': e.value},
          ],
        },
      );
    }
    Navigator.pop(context);
    if (last != null) _undoable(messenger, repo, last);
  }

  @override
  Widget build(BuildContext context) => _SheetFrame(
    title: tr('Größe & Brut · {0}', [widget.colony.name]),
    when: _when,
    onWhen: (v) => setState(() => _when = v),
    onSave: _hasCensus || _brood.isNotEmpty ? _save : null,
    children: [
      SectionHeader(tr('Arbeiterinnen')),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final r in workerRanges)
            ChoiceChip(
              label: Text(S.workers(r.$1, r.$2)),
              selected: _range == r,
              onSelected: (v) => setState(() {
                _range = v ? r : null;
                if (v) _exact.clear();
              }),
            ),
        ],
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _exact,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: tr('oder genau gezählt'), suffixText: tr('Arbeiterinnen')),
        onChanged: (_) => setState(() => _range = null),
      ),
      SectionHeader(tr('Brut')),
      for (final st in _stages.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              SizedBox(width: 120, child: Text(st.value)),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  children: [
                    for (final l in _levels.entries)
                      ChoiceChip(
                        label: Text(l.value),
                        selected: _brood[st.key] == l.key,
                        onSelected: (v) => setState(() => v ? _brood[st.key] = l.key : _brood.remove(st.key)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

// -----------------------------------------------------------------------------
// Logging afterwards

/// „Nachtragen“: forgot to log something – pick when, then what; the matching
/// sheet opens with that time (still changeable there).
Future<void> showBackdateFlow(BuildContext context, WidgetRef ref, Colony colony) async {
  final now = DateTime.now();
  final at = await pickPastDateTime(context, initial: DateTime(now.year, now.month, now.day - 1, now.hour, now.minute));
  if (at == null || !context.mounted) return;
  final kinds = <(String, IconData, String)>[
    ('feeding', Icons.pest_control_outlined, tr('Fütterung')),
    ('water', Icons.water_drop_outlined, tr('Wasser')),
    ('cleaning', Icons.cleaning_services_outlined, tr('Reinigung')),
    ('check', Icons.visibility_outlined, tr('Kontrolle')),
    ('note', Icons.sticky_note_2_outlined, tr('Notiz')),
    ('measurement', Icons.thermostat_outlined, tr('Messung')),
    ('census', Icons.groups_outlined, tr('Größe & Brut')),
  ];
  final type = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    builder: (c) => SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(
              tr('Nachtragen · {0} {1}', [S.relativeDay(at, now), S.time(at)]),
              style: Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          for (final (id, icon, label) in kinds)
            ListTile(leading: Icon(icon), title: Text(label), onTap: () => Navigator.pop(c, id)),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (type == null || !context.mounted) return;
  switch (type) {
    case 'feeding':
      await showFeedingSheet(context, ref, colony, at: at);
    case 'water':
      await showWaterSheet(context, ref, colony, at: at);
    case 'cleaning':
      await showCleaningSheet(context, ref, colony, at: at);
    case 'check' || 'note':
      await showNoteSheet(context, ref, colony, type: type, at: at);
    case 'measurement':
      await showMeasurementSheet(context, ref, colony, at: at);
    case 'census':
      await showCensusSheet(context, ref, colony, at: at);
  }
}
