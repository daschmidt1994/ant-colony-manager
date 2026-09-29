import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/i18n.dart';
import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../domain/food_stock.dart';
import '../../shared/widgets.dart';

/// Food stock and feeder cultures – with „open since“, best-before, reorder
/// limit and culture care interval (docs/23-futtervorrat.md).
class FoodStockScreen extends ConsumerWidget {
  const FoodStockScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(foodStocksProvider).value ?? const <FoodStock>[];
    final stock = list.where((s) => !s.isCulture).toList();
    final cultures = list.where((s) => s.isCulture).toList();
    return Scaffold(
      appBar: AppBar(title: Text(tr('Futtervorrat'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showFoodStockSheet(context),
        icon: const Icon(Icons.add),
        label: Text(tr('Eintrag')),
      ),
      body: list.isEmpty
          ? EmptyState(
              icon: Icons.inventory_2_outlined,
              title: tr('Noch kein Vorrat erfasst'),
              text: tr(
                'Futtertiere, Zucker- oder Honigwasser und Zuchten eintragen – die App erinnert, '
                'wenn etwas zu lange offen ist, abläuft, knapp wird oder die Zucht versorgt werden muss.',
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
              children: [
                ContentWidth(
                  maxWidth: 640,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (stock.isNotEmpty) ...[
                        SectionHeader(tr('Vorrat')),
                        for (final s in stock) _StockCard(stock: s),
                      ],
                      if (cultures.isNotEmpty) ...[
                        SectionHeader(tr('Zuchten')),
                        for (final s in cultures) _StockCard(stock: s),
                      ],
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _StockCard extends ConsumerWidget {
  const _StockCard({required this.stock});
  final FoodStock stock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(repositoryProvider)!;
    final now = DateTime.now();
    final s = stock;
    final issues = s.issues(now);
    final open = s.openDays(now);
    final facts = [
      ?s.amountText,
      if (open != null) open == 0 ? tr('heute geöffnet') : tr('seit {0} Tagen offen', [open]),
      if (s.bestBefore != null) tr('MHD {0}', [S.date(s.bestBefore!)]),
      if (s.isCulture && s.nextCare() != null) tr('nächste Versorgung {0}', [S.date(s.nextCare()!)]),
    ];
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showFoodStockSheet(context, edit: s),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Icon(
                s.isCulture ? Icons.bug_report_outlined : Icons.inventory_2_outlined,
                color: issues.isEmpty ? context.colors.muted : context.colors.overdue,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                    if (facts.isNotEmpty) Text(facts.join(' · '), style: TextStyle(color: context.colors.muted)),
                    for (final i in issues) Text(s.issueText(i, now), style: TextStyle(color: context.colors.overdue)),
                  ],
                ),
              ),
              if (s.isCulture)
                TextButton(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    repo.careFoodStock(s.id);
                  },
                  child: Text(tr('Versorgt')),
                )
              else if (s.useWithinDays != null)
                TextButton(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    repo.openFoodStock(s.id);
                  },
                  child: Text(tr('Frisch')),
                ),
              if (!s.isCulture && s.quantity != null) ...[
                IconButton(
                  tooltip: tr('Weniger'),
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: s.quantity! <= 0 ? null : () => repo.adjustFoodStock(s.id, -1),
                ),
                IconButton(
                  tooltip: tr('Mehr'),
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => repo.adjustFoodStock(s.id, 1),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Quick starts for new entries – typical shelf lives and care intervals.
List<(String, Map<String, dynamic>)> get _presets => [
  (tr('Zuckerwasser'), {'name': tr('Zuckerwasser'), 'use_within_days': 5}),
  (tr('Honigwasser'), {'name': tr('Honigwasser'), 'use_within_days': 5}),
  (tr('Heimchen'), {'name': tr('Heimchen'), 'unit': 'piece', 'reorder_below': 10}),
  (tr('Schaben'), {'name': tr('Schaben'), 'unit': 'piece', 'reorder_below': 10}),
  (tr('Samen'), {'name': tr('Samen'), 'unit': 'g'}),
  (tr('Drosophila-Zucht'), {'name': tr('Drosophila-Zucht'), 'kind': 'culture', 'care_interval_days': 14}),
  (tr('Schabenzucht'), {'name': tr('Schabenzucht'), 'kind': 'culture', 'care_interval_days': 7}),
];

Future<void> showFoodStockSheet(BuildContext context, {FoodStock? edit}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (c) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
    child: ContentWidth(maxWidth: 640, child: _StockSheet(edit: edit)),
  ),
);

class _StockSheet extends ConsumerStatefulWidget {
  const _StockSheet({this.edit});
  final FoodStock? edit;
  @override
  ConsumerState<_StockSheet> createState() => _StockSheetState();
}

class _StockSheetState extends ConsumerState<_StockSheet> {
  late final Map<String, dynamic> _v = {'kind': 'stock', ...?widget.edit?.json};
  late final _name = TextEditingController(text: _v['name'] as String? ?? '');
  late final _quantity = TextEditingController(text: _numText(_v['quantity']));
  late final _reorder = TextEditingController(text: _numText(_v['reorder_below']));
  late final _useWithin = TextEditingController(text: _numText(_v['use_within_days']));
  late final _interval = TextEditingController(text: _numText(_v['care_interval_days']));
  late final _notes = TextEditingController(text: _v['notes'] as String? ?? '');

  static String _numText(Object? v) => v is num ? S.number(v) : (v is String ? v : '');
  static double? _parse(String t) => double.tryParse(t.trim().replaceAll(',', '.'));

  bool get _culture => _v['kind'] == 'culture';

  @override
  void dispose() {
    for (final c in [_name, _quantity, _reorder, _useWithin, _interval, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  void _preset(Map<String, dynamic> p) => setState(() {
    _v
      ..['kind'] = p['kind'] ?? 'stock'
      ..['unit'] = p['unit'];
    _name.text = p['name'] as String;
    _useWithin.text = _numText(p['use_within_days']);
    _reorder.text = _numText(p['reorder_below']);
    _interval.text = _numText(p['care_interval_days']);
  });

  Future<void> _pickDate(String key) async {
    final current = DateTime.tryParse(_v[key] as String? ?? '');
    final d = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _v[key] = _date(d));
  }

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void _save() {
    final repo = ref.read(repositoryProvider)!;
    final name = _name.text.trim();
    if (name.isEmpty) return;
    int? whole(TextEditingController c) => _parse(c.text)?.round();
    final fields = <String, dynamic>{
      'name': name,
      'kind': _v['kind'],
      'quantity': _culture ? null : _parse(_quantity.text),
      'unit': _culture ? null : _v['unit'],
      'reorder_below': _culture ? null : _parse(_reorder.text),
      'opened_on': _culture ? null : _v['opened_on'],
      'use_within_days': _culture ? null : whole(_useWithin),
      'best_before': _culture ? null : _v['best_before'],
      'care_interval_days': _culture ? whole(_interval) : null,
      'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    };
    final e = widget.edit;
    if (e == null) {
      repo.createFoodStock({
        ...fields..removeWhere((_, v) => v == null),
        if (_culture) 'last_cared_at': DateTime.now().toUtc().toIso8601String(),
      });
    } else {
      repo.updateFoodStock(e.id, fields);
    }
    Navigator.pop(context);
  }

  void _delete() {
    final e = widget.edit!;
    final m = ScaffoldMessenger.of(context);
    final repo = ref.read(repositoryProvider)!;
    Navigator.pop(context);
    repo.updateFoodStock(e.id, {'archived_at': DateTime.now().toUtc().toIso8601String()});
    showUndoSnackOn(m, tr('„{0}“ entfernt', [e.name]), onUndo: () => repo.updateFoodStock(e.id, {'archived_at': null}));
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: context.colors.muted);
    Widget dateRow(String key, String label) {
      final d = DateTime.tryParse(_v[key] as String? ?? '');
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: Text(d == null ? tr('nicht gesetzt') : S.date(d)),
        onTap: () => _pickDate(key),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (key == 'opened_on')
              TextButton(onPressed: () => setState(() => _v[key] = _date(DateTime.now())), child: Text(tr('Heute'))),
            if (d != null)
              IconButton(
                tooltip: tr('Entfernen'),
                icon: const Icon(Icons.clear),
                onPressed: () => setState(() => _v[key] = null),
              ),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.edit == null ? tr('Neuer Eintrag') : tr('Eintrag bearbeiten'),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                if (widget.edit == null) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (label, p) in _presets) ActionChip(label: Text(label), onPressed: () => _preset(p)),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'stock',
                      label: Text(tr('Vorrat')),
                      icon: const Icon(Icons.inventory_2_outlined),
                    ),
                    ButtonSegment(
                      value: 'culture',
                      label: Text(tr('Zucht')),
                      icon: const Icon(Icons.bug_report_outlined),
                    ),
                  ],
                  selected: {_v['kind'] as String},
                  onSelectionChanged: (v) => setState(() => _v['kind'] = v.first),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: tr('Name')),
                  onChanged: (_) => setState(() {}),
                ),
                if (_culture) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _interval,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: tr('Versorgen alle … Tage'),
                      helperText: tr('Füttern, Substrat wechseln, neu ansetzen – „Versorgt“ setzt die Frist zurück.'),
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _quantity,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(labelText: tr('Menge')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      DropdownButton<String?>(
                        value: _v['unit'] as String?,
                        hint: Text(tr('Einheit')),
                        items: [
                          DropdownMenuItem(value: null, child: Text(tr('–'))),
                          for (final e in S.unitNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                        ],
                        onChanged: (v) => setState(() => _v['unit'] = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _reorder,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: tr('Nachbestellen ab'),
                      helperText: tr('Erinnerung, sobald die Menge darunter fällt'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  dateRow('opened_on', tr('Geöffnet / angesetzt am')),
                  TextField(
                    controller: _useWithin,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: tr('Nach dem Öffnen haltbar (Tage)'),
                      helperText: tr('Zucker- und Honigwasser gären – alle paar Tage frisch ansetzen.'),
                    ),
                  ),
                  dateRow('best_before', tr('Mindesthaltbarkeit')),
                ],
                const SizedBox(height: 8),
                TextField(
                  controller: _notes,
                  maxLines: 3,
                  minLines: 1,
                  decoration: InputDecoration(labelText: tr('Notiz (optional)')),
                ),
                if (widget.edit != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _delete,
                      icon: const Icon(Icons.delete_outline),
                      label: Text(tr('Entfernen')),
                    ),
                  ),
                ],
                Text(
                  tr('Hinweise erscheinen in der Übersicht und als App-Benachrichtigung (Thema „Überfällige Pflege“).'),
                  style: muted,
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: FilledButton(onPressed: _name.text.trim().isEmpty ? null : _save, child: Text(tr('Speichern'))),
        ),
      ],
    );
  }
}

/// Dashboard: „Futtervorrat: 2 Hinweise“ – only when something needs doing.
class FoodStockHintCard extends ConsumerWidget {
  const FoodStockHintCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(foodStocksProvider).value ?? const <FoodStock>[];
    final now = DateTime.now();
    final lines = [
      for (final s in list)
        for (final i in s.issues(now)) '${s.name}: ${s.issueText(i, now)}',
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: ListTile(
          leading: Icon(Icons.inventory_2_outlined, color: context.colors.soon),
          title: Text(tr('Futtervorrat')),
          subtitle: Text(lines.take(3).join('\n') + (lines.length > 3 ? '\n…' : '')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/food-stock'),
        ),
      ),
    );
  }
}
