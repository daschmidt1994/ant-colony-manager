import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../data/repositories/colony_repository.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';
import '../species/species_screens.dart';

/// Default care intervals for new colonies (days).
const defaultIntervals = {'protein': 3.0, 'carbohydrate': 5.0, 'water': 2.0, 'cleaning': 7.0};

class ColonyFormScreen extends ConsumerStatefulWidget {
  const ColonyFormScreen({super.key, this.colonyId, this.speciesId});
  final String? colonyId;

  /// Preselected catalog species (from the species care sheet).
  final String? speciesId;
  @override
  ConsumerState<ColonyFormScreen> createState() => _ColonyFormScreenState();
}

class _ColonyFormScreenState extends ConsumerState<ColonyFormScreen> {
  final _form = GlobalKey<FormState>();
  final _species = TextEditingController();
  final _name = TextEditingController();
  final _code = TextEditingController();
  final _notes = TextEditingController();
  final _seller = TextEditingController();
  final _findLocation = TextEditingController();
  final _intervals = <String, TextEditingController>{for (final t in defaultIntervals.keys) t: TextEditingController()};
  String _status = 'active';
  String _gyne = 'unknown';
  String? _origin;
  String? _locationId;
  String? _speciesId;
  (int, int?)? _workers;
  DateTime? _founded;
  bool _loaded = false;
  bool _nameTouched = false;
  final _speciesFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _species.addListener(_suggestName);
    _species.addListener(_dropStaleLink);
  }

  /// Typing a different name unlinks the care sheet.
  void _dropStaleLink() {
    if (_speciesId == null) return;
    final linked = ref.read(repositoryProvider)!.speciesById(_speciesId!);
    if (linked?.scientificName != _species.text.trim()) setState(() => _speciesId = null);
  }

  @override
  void dispose() {
    _species.removeListener(_suggestName);
    _species.removeListener(_dropStaleLink);
    _speciesFocus.dispose();
    super.dispose();
  }

  bool get _isNew => widget.colonyId == null;

  void _load() {
    if (_loaded) return;
    _loaded = true;
    final repo = ref.read(repositoryProvider)!;
    if (_isNew) {
      defaultIntervals.forEach((t, d) => _intervals[t]!.text = d.toInt().toString());
      final preset = widget.speciesId == null ? null : repo.speciesById(widget.speciesId!);
      if (preset != null) {
        _species.text = preset.scientificName;
        _speciesId = preset.id;
      }
      return;
    }
    final c = repo.colony(widget.colonyId!);
    if (c == null) return;
    _species.text = c.species;
    _speciesId = c.speciesId;
    _name.text = c.name;
    _nameTouched = true;
    _code.text = c.internalCode ?? '';
    _notes.text = c.notes ?? '';
    _seller.text = c.json['seller'] as String? ?? '';
    _findLocation.text = c.json['find_location'] as String? ?? '';
    _status = c.status;
    _gyne = c.gyneType;
    _origin = c.origin;
    _locationId = c.locationId;
    _founded = DateTime.tryParse(c.json['founded_on'] as String? ?? '');
    for (final s in repo.schedules(colonyId: c.id)) {
      final ctl = _intervals[s.taskType];
      if (ctl != null) ctl.text = _fmt(s.intervalDays);
    }
  }

  static String _fmt(double d) => d == d.roundToDouble() ? d.toInt().toString() : S.decimal(d);

  /// Name suggestion: genus + next number, e.g. „Messor #12“.
  void _suggestName() {
    if (_nameTouched || !_isNew) return;
    final genus = _species.text.trim().split(' ').first;
    final next =
        (ref
            .read(repositoryProvider)!
            .colonies(includeArchived: true)
            .map((c) => c.number)
            .fold<int>(0, (a, b) => a > b ? a : b)) +
        1;
    _name.text = genus.isEmpty ? '' : '$genus #$next';
  }

  @override
  Widget build(BuildContext context) {
    _load();
    final locations = ref.watch(locationsProvider).value ?? const <Location>[];
    final used = ref.watch(speciesSuggestionsProvider).value ?? const <String>[];
    final catalog = ref.watch(speciesListProvider).value ?? const <Species>[];
    final catalogNames = {for (final sp in catalog) sp.scientificName};
    final linked = catalog.where((sp) => sp.id == _speciesId).firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Neue Kolonie' : 'Kolonie bearbeiten'),
        actions: [TextButton(onPressed: _save, child: const Text('Speichern'))],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            ContentWidth(
              maxWidth: 640,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  RawAutocomplete<(String, Species?)>(
                    textEditingController: _species,
                    focusNode: _speciesFocus,
                    displayStringForOption: (o) => o.$1,
                    onSelected: (o) => setState(() => _speciesId = o.$2?.id),
                    optionsBuilder: (v) => v.text.isEmpty
                        ? const Iterable.empty()
                        : [
                            for (final sp in catalog)
                              if (sp.matches(v.text) && sp.id != _speciesId) (sp.scientificName, sp),
                            for (final name in used)
                              if (!catalogNames.contains(name) &&
                                  name.toLowerCase().contains(v.text.toLowerCase()) &&
                                  name != v.text)
                                (name, null),
                          ].take(12),
                    fieldViewBuilder: (context, ctl, focus, onSubmit) => TextFormField(
                      controller: ctl,
                      focusNode: focus,
                      autofocus: _isNew,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(labelText: 'Art *', hintText: 'Messor barbarus'),
                      validator: (v) => (v ?? '').trim().isEmpty ? 'Bitte die Art angeben' : null,
                    ),
                    optionsViewBuilder: (context, onSelected, options) => Align(
                      alignment: Alignment.topLeft,
                      child: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(12),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 240, maxWidth: 420),
                          child: ListView(
                            padding: EdgeInsets.zero,
                            shrinkWrap: true,
                            children: [
                              for (final o in options)
                                ListTile(
                                  leading: Icon(o.$2 == null ? Icons.history : Icons.menu_book_outlined, size: 20),
                                  title: Text(o.$1, style: const TextStyle(fontStyle: FontStyle.italic)),
                                  subtitle: o.$2?.germanName == null ? null : Text(o.$2!.germanName!),
                                  onTap: () => onSelected(o),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                    child: Row(
                      children: [
                        Icon(
                          linked != null ? Icons.check_circle_outline : Icons.info_outline,
                          size: 16,
                          color: linked != null ? context.colors.ok : context.colors.muted,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            linked != null
                                ? 'Steckbrief verknüpft${speciesSummary(linked).isEmpty ? '' : ': ${speciesSummary(linked)}'}'
                                : 'Art aus der Liste wählen, um den Steckbrief zu verknüpfen.',
                            style: TextStyle(fontSize: 12, color: context.colors.muted),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Name'),
                    onChanged: (_) => _nameTouched = true,
                    validator: (v) => (v ?? '').trim().isEmpty ? 'Bitte einen Namen angeben' : null,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _code,
                          decoration: const InputDecoration(labelText: 'Interner Code'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String?>(
                          initialValue: _locationId,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Standort'),
                          items: [
                            const DropdownMenuItem(value: null, child: Text('–')),
                            for (final l in locations)
                              DropdownMenuItem(
                                value: l.id,
                                child: Text(l.path, overflow: TextOverflow.ellipsis),
                              ),
                            const DropdownMenuItem(value: '__new', child: Text('+ Neuer Standort …')),
                          ],
                          onChanged: (v) async {
                            if (v == '__new') {
                              final id = await _newLocation(locations);
                              setState(() => _locationId = id ?? _locationId);
                            } else {
                              setState(() => _locationId = v);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SectionHeader('Status'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final s in const ['founding', 'active', 'paused', 'given_away', 'sold', 'deceased'])
                        ChoiceChip(
                          label: Text(S.statusNames[s]!),
                          selected: _status == s,
                          onSelected: (_) => setState(() => _status = s),
                        ),
                    ],
                  ),
                  const SectionHeader('Königinnen'),
                  SegmentedButton<String>(
                    segments: [
                      for (final g in const ['monogyne', 'polygyne', 'unknown'])
                        ButtonSegment(value: g, label: Text(S.gyneNames[g]!)),
                    ],
                    selected: {_gyne},
                    onSelectionChanged: (v) => setState(() => _gyne = v.first),
                    showSelectedIcon: false,
                  ),
                  if (_isNew) ...[
                    const SectionHeader('Koloniegröße (Schätzung)'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final r in workerRanges)
                          ChoiceChip(
                            label: Text(S.workers(r.$1, r.$2)),
                            selected: _workers == r,
                            onSelected: (v) => setState(() => _workers = v ? r : null),
                          ),
                      ],
                    ),
                  ],
                  const SectionHeader('Pflegeintervalle (Tage)'),
                  Row(
                    children: [
                      for (final t in defaultIntervals.keys) ...[
                        Expanded(
                          child: TextFormField(
                            controller: _intervals[t],
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                            decoration: InputDecoration(labelText: S.taskNames[t]),
                          ),
                        ),
                        if (t != defaultIntervals.keys.last) const SizedBox(width: 8),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('Leer lassen = keine Erinnerung.', style: TextStyle(color: context.colors.muted, fontSize: 12)),
                  const SizedBox(height: 8),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Herkunft & Daten'),
                    children: [
                      DropdownButtonFormField<String?>(
                        initialValue: _origin,
                        decoration: const InputDecoration(labelText: 'Herkunft'),
                        items: const [
                          DropdownMenuItem(value: null, child: Text('–')),
                          DropdownMenuItem(value: 'wild_caught', child: Text('Selbst gefangen')),
                          DropdownMenuItem(value: 'bought', child: Text('Gekauft')),
                          DropdownMenuItem(value: 'bred', child: Text('Eigene Zucht')),
                          DropdownMenuItem(value: 'traded', child: Text('Getauscht')),
                          DropdownMenuItem(value: 'gift', child: Text('Geschenkt')),
                          DropdownMenuItem(value: 'other', child: Text('Sonstiges')),
                        ],
                        onChanged: (v) => setState(() => _origin = v),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _findLocation,
                        decoration: const InputDecoration(labelText: 'Fundort (bleibt privat)'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _seller,
                        decoration: const InputDecoration(labelText: 'Verkäufer / Züchter'),
                      ),
                      const SizedBox(height: 12),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Gründungsdatum'),
                        subtitle: Text(_founded == null ? '–' : S.date(_founded!)),
                        trailing: const Icon(Icons.edit_calendar),
                        onTap: () async {
                          final d = await showDatePicker(
                            context: context,
                            firstDate: DateTime(1990),
                            lastDate: DateTime.now(),
                            initialDate: _founded ?? DateTime.now(),
                          );
                          if (d != null) setState(() => _founded = d);
                        },
                      ),
                    ],
                  ),
                  TextFormField(
                    controller: _notes,
                    minLines: 2,
                    maxLines: 6,
                    decoration: const InputDecoration(labelText: 'Notizen'),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(onPressed: _save, child: Text(_isNew ? 'Kolonie anlegen' : 'Speichern')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _newLocation(List<Location> existing) async {
    final name = TextEditingController();
    String? parent;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Neuer Standort'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name', hintText: 'Regal A'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: parent,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Liegt in'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('– (oberste Ebene)')),
                  for (final l in existing) DropdownMenuItem(value: l.id, child: Text(l.path)),
                ],
                onChanged: (v) => set(() => parent = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Anlegen')),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return null;
    return ref.read(repositoryProvider)!.createLocation(name.text, parentId: parent);
  }

  /// A typed name that exactly matches a species links it, too.
  static String? _catalogMatch(ColonyRepository repo, String name) {
    final n = name.trim().toLowerCase();
    final hits = repo.species().where((sp) => sp.scientificName.toLowerCase() == n).toList();
    // Prefer own species over the catalog entry of the same name.
    hits.sort((a, b) => (a.isCatalog ? 1 : 0).compareTo(b.isCatalog ? 1 : 0));
    return hits.firstOrNull?.id;
  }

  double _interval(String t) => double.tryParse(_intervals[t]!.text.trim().replaceAll(',', '.')) ?? 0;

  void _save() {
    if (!_form.currentState!.validate()) return;
    final repo = ref.read(repositoryProvider)!;
    String? v(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    final fields = <String, dynamic>{
      'name': _name.text.trim(),
      'species_id': _speciesId ?? _catalogMatch(repo, _species.text),
      'species_text': _species.text.trim(),
      'internal_code': v(_code),
      'location_id': _locationId,
      'status': _status,
      'gyne_type': _gyne,
      'origin': _origin,
      'find_location': v(_findLocation),
      'seller': v(_seller),
      'notes': v(_notes),
      'founded_on': _founded == null
          ? null
          : '${_founded!.year.toString().padLeft(4, '0')}-${_founded!.month.toString().padLeft(2, '0')}-${_founded!.day.toString().padLeft(2, '0')}',
    };
    final intervals = {for (final t in defaultIntervals.keys) t: _interval(t)};
    if (_isNew) {
      final id = repo.createColony(
        fields..removeWhere((_, v) => v == null),
        intervals: {
          for (final e in intervals.entries)
            if (e.value > 0) e.key: e.value,
        },
      );
      if (_workers != null) {
        repo.logEvent(
          id,
          'census',
          details: {
            'census': {'estimate_min': _workers!.$1, 'estimate_max': _workers!.$2},
          },
        );
      }
      context.go('/colonies/$id');
    } else {
      final c = repo.colony(widget.colonyId!)!;
      final changed = {
        for (final e in fields.entries)
          if (c.json[e.key] != e.value) e.key: e.value,
      };
      if (changed.isNotEmpty) repo.updateColony(c.id, changed);
      repo.setIntervals(c.id, intervals);
      context.pop();
    }
  }
}
