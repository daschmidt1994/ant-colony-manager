import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';

const hibernationNames = {'none': 'keine', 'optional': 'kühlere Ruhephase empfohlen', 'required': 'nötig'};
const speciesGyneNames = {
  'monogyne': 'monogyn',
  'oligogyne': 'oligogyn',
  'polygyne': 'polygyn',
  'facultative': 'fakultativ polygyn',
};
const foundingNames = {
  'claustral': 'claustral – Königin gründet ohne Futter',
  'semi_claustral': 'semi-claustral – Königin braucht Futter',
  'parasitic': 'sozialparasitisch – braucht eine Hilfsart',
  'dependent': 'abhängig – nur mit Arbeiterinnen',
};
const difficultyNames = {1: 'Einsteiger', 2: 'Fortgeschritten', 3: 'Experte'};
const activityNames = {'diurnal': 'tagaktiv', 'nocturnal': 'nachtaktiv', 'both': 'tag- und nachtaktiv'};

/// „24–28 °C“, „ab 24 °C“, null when both are missing.
String? rangeText(double? min, double? max, String unit) {
  String f(double v) => v == v.roundToDouble() ? v.toInt().toString() : S.decimal(v);
  if (min == null && max == null) return null;
  if (min != null && max != null) return min == max ? '${f(min)} $unit' : '${f(min)}–${f(max)} $unit';
  return min != null ? 'ab ${f(min)} $unit' : 'bis ${f(max!)} $unit';
}

/// One-line care summary for colony cards: nest climate, winter rest, difficulty.
String speciesSummary(Species s) => [
  if (rangeText(s.number('temp_nest_min'), s.number('temp_nest_max'), '°C') case final t?) 'Nest $t',
  ?rangeText(s.number('humidity_nest_min'), s.number('humidity_nest_max'), '%'),
  if (s.text('hibernation') case final w?) 'Winterruhe ${hibernationNames[w] ?? w}',
  ?difficultyNames[s.difficulty],
].join(' · ');

Future<void> _open(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) return;
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && context.mounted) {
    showError(context, 'Link konnte nicht geöffnet werden: $url');
  }
}

class _DifficultyChip extends StatelessWidget {
  const _DifficultyChip(this.level);
  final int level;

  @override
  Widget build(BuildContext context) {
    final color = switch (level) {
      1 => context.colors.ok,
      2 => context.colors.soon,
      _ => context.colors.overdue,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: .14), borderRadius: BorderRadius.circular(8)),
      child: Text(
        difficultyNames[level] ?? '',
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Catalog search

class SpeciesListScreen extends ConsumerStatefulWidget {
  const SpeciesListScreen({super.key});
  @override
  ConsumerState<SpeciesListScreen> createState() => _SpeciesListScreenState();
}

class _SpeciesListScreenState extends ConsumerState<SpeciesListScreen> {
  final _search = TextEditingController();
  int? _difficulty;
  bool _noWinter = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(speciesListProvider).value ?? const <Species>[];
    final list = all
        .where(
          (s) =>
              s.matches(_search.text) &&
              (_difficulty == null || s.difficulty == _difficulty) &&
              (!_noWinter || s.text('hibernation') != 'required'),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Artenkatalog'),
        actions: [
          IconButton(
            tooltip: 'Futter-Ratgeber',
            icon: const Icon(Icons.restaurant_outlined),
            onPressed: () => context.go('/species/food'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/species/new'),
        icon: const Icon(Icons.add),
        label: const Text('Eigene Art'),
      ),
      body: ContentWidth(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _search,
                autofocus: false,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Art, Gattung oder deutscher Name',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  for (final e in difficultyNames.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(e.value),
                        selected: _difficulty == e.key,
                        onSelected: (on) => setState(() => _difficulty = on ? e.key : null),
                      ),
                    ),
                  FilterChip(
                    label: const Text('Ohne Winterruhe'),
                    selected: _noWinter,
                    onSelected: (on) => setState(() => _noWinter = on),
                  ),
                ],
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? EmptyState(
                      icon: Icons.search_off,
                      title: all.isEmpty ? 'Katalog wird geladen …' : 'Keine Art gefunden',
                      text: all.isEmpty ? null : 'Nicht dabei? Lege sie als eigene Art mit Steckbrief an.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) => _SpeciesTile(list[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpeciesTile extends StatelessWidget {
  const _SpeciesTile(this.s);
  final Species s;

  @override
  Widget build(BuildContext context) {
    final subtitle = [?s.germanName, if (!s.isCatalog) 'eigene Art', ?s.text('distribution')].join(' · ');
    return ListTile(
      title: Text(s.scientificName, style: const TextStyle(fontStyle: FontStyle.italic)),
      subtitle: subtitle.isEmpty ? null : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: s.difficulty == null ? null : _DifficultyChip(s.difficulty!),
      onTap: () => context.go('/species/${s.id}'),
    );
  }
}

// -----------------------------------------------------------------------------
// Care sheet

class SpeciesDetailScreen extends ConsumerWidget {
  const SpeciesDetailScreen({super.key, required this.speciesId});
  final String speciesId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(speciesProvider(speciesId)).value;
    if (s == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(icon: Icons.search_off, title: 'Art nicht gefunden'),
      );
    }
    final colonies = (ref.watch(coloniesProvider).value ?? const <Colony>[]).where((c) => c.speciesId == s.id).toList();
    final muted = TextStyle(color: context.colors.muted);
    final taxonomy = [?s.text('subfamily'), ?s.text('tribe')].join(' · ');

    String? range(String key, String unit) => rangeText(s.number('${key}_min'), s.number('${key}_max'), unit);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.scientificName, style: const TextStyle(fontStyle: FontStyle.italic)),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) => _menu(context, ref, s, v),
            itemBuilder: (_) => [
              if (!s.isCatalog) const PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
              const PopupMenuItem(value: 'copy', child: Text('Als eigene Art kopieren')),
              if (!s.isCatalog) const PopupMenuItem(value: 'delete', child: Text('Löschen')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/colonies/new?species=${s.id}'),
        icon: const Icon(Icons.add),
        label: const Text('Kolonie dieser Art'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
        children: [
          ContentWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (s.germanName != null) Text(s.germanName!, style: Theme.of(context).textTheme.titleLarge),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (taxonomy.isNotEmpty) Text(taxonomy, style: muted),
                    if (s.difficulty != null) _DifficultyChip(s.difficulty!),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  s.isCatalog
                      ? 'Richtwerte aus Fachliteratur und Haltungspraxis – Bezugsquelle und Herkunft deiner Tiere können abweichen.'
                      : 'Eigene Art – Werte von dir.',
                  style: muted.copyWith(fontSize: 12),
                ),
                if (colonies.isNotEmpty) ...[
                  const SectionHeader('Meine Kolonien'),
                  for (final c in colonies)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.bug_report_outlined),
                      title: Text(c.name),
                      subtitle: Text('Kolonie #${c.number}'),
                      onTap: () => context.go('/colonies/${c.id}'),
                    ),
                ],
                _Section('Herkunft', [('Verbreitung', s.text('distribution')), ('Lebensraum', s.text('habitat'))]),
                _Section('Aussehen', [
                  ('Königin', s.text('queen_size')),
                  ('Arbeiterin', s.text('worker_size')),
                  ('Männchen', s.text('male_size')),
                  ('Färbung', s.text('coloration')),
                  ('Polymorph', s.polymorphic == null ? null : (s.polymorphic! ? 'ja' : 'nein')),
                ]),
                _Section('Klima', [
                  ('Temperatur Nest', range('temp_nest', '°C')),
                  ('Temperatur Arena', range('temp_arena', '°C')),
                  ('Luftfeuchte Nest', range('humidity_nest', '%')),
                  ('Luftfeuchte Arena', range('humidity_arena', '%')),
                ]),
                _Section('Winterruhe', [
                  ('Winterruhe', hibernationNames[s.text('hibernation')]),
                  ('Zeitraum', s.text('hibernation_period')),
                  ('Temperatur', range('hibernation_temp', '°C')),
                ]),
                _Section('Kolonie', [
                  ('Koloniegründung', foundingNames[s.text('founding')]),
                  ('Königinnen', speciesGyneNames[s.text('gyne_type')]),
                  ('Koloniegröße', s.text('colony_size')),
                  ('Lebensdauer Königin', s.text('queen_lifespan')),
                  ('Entwicklung', s.text('development')),
                  ('Hochzeitsflug', s.text('nuptial_flight')),
                  ('Aktivität', activityNames[s.text('activity')]),
                ]),
                _Section(
                  'Futter',
                  [
                    ('Protein', s.text('diet_protein')),
                    ('Kohlenhydrate', s.text('diet_carbohydrate')),
                    ('Hinweis', s.text('diet_notes')),
                  ],
                  trailing: TextButton(
                    onPressed: () => context.go('/species/food'),
                    child: const Text('Futter-Ratgeber'),
                  ),
                ),
                _Section('Haltung', [
                  ('Nestbau in der Natur', s.text('nesting')),
                  ('Geeignete Nester', s.text('formicarium')),
                  ('Formicariumgröße', s.text('formicarium_size')),
                  ('Substrat', s.text('substrate')),
                ]),
                _Section('Rechtliches', [('Hinweis', s.text('legal_note'))]),
                _Section('Notizen', [(null, s.text('notes'))]),
                if (s.sources.isNotEmpty) ...[
                  const SectionHeader('Quellen'),
                  for (final src in s.sources)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Icon(src.url == null ? Icons.menu_book_outlined : Icons.open_in_new, size: 20),
                      title: Text(src.title),
                      subtitle: src.url == null ? null : Text(src.url!, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: src.url == null ? null : () => _open(context, src.url!),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _menu(BuildContext context, WidgetRef ref, Species s, String v) async {
    final repo = ref.read(repositoryProvider)!;
    switch (v) {
      case 'edit':
        context.go('/species/${s.id}/edit');
      case 'copy':
        final fields = Map<String, dynamic>.of(s.json)
          ..removeWhere(
            (k, _) => const {'id', 'owner_id', 'version', 'created_at', 'updated_at', 'deleted_at'}.contains(k),
          );
        final id = repo.createSpecies(fields);
        context.go('/species/$id/edit');
      case 'delete':
        final used = repo.colonies(includeArchived: true).where((c) => c.speciesId == s.id).length;
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('${s.scientificName} löschen?'),
            content: Text(
              used == 0
                  ? 'Die eigene Art verschwindet auf allen Geräten.'
                  : '$used ${used == 1 ? 'Kolonie verweist' : 'Kolonien verweisen'} auf diese Art und '
                        'verlieren den Steckbrief (der Artname bleibt erhalten).',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Löschen')),
            ],
          ),
        );
        if (ok == true && context.mounted) {
          for (final c in repo.colonies(includeArchived: true).where((c) => c.speciesId == s.id)) {
            repo.updateColony(c.id, {'species_id': null, 'species_text': s.scientificName});
          }
          repo.deleteSpecies(s.id);
          context.go('/species');
        }
    }
  }
}

/// Label/value rows; hidden entirely when every value is empty.
class _Section extends StatelessWidget {
  const _Section(this.title, this.rows, {this.trailing});
  final String title;
  final List<(String?, String?)> rows;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final filled = rows.where((r) => r.$2 != null).toList();
    if (filled.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title, trailing: trailing),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                for (final (label, value) in filled)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: label == null
                        ? Align(alignment: Alignment.centerLeft, child: Text(value!))
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 150,
                                child: Text(label, style: TextStyle(color: context.colors.muted)),
                              ),
                              Expanded(child: Text(value!)),
                            ],
                          ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Own species

enum _Kind { text, multiline, decimal, integer }

/// Editable care-sheet fields, grouped like the detail view.
const _formGroups = <(String, List<(String, String, _Kind)>)>[
  (
    'Art',
    [
      ('german_name', 'Deutscher Name', _Kind.text),
      ('genus', 'Gattung (leer = aus dem Namen)', _Kind.text),
      ('subfamily', 'Unterfamilie', _Kind.text),
      ('tribe', 'Tribus', _Kind.text),
    ],
  ),
  ('Herkunft', [('distribution', 'Verbreitung', _Kind.text), ('habitat', 'Lebensraum', _Kind.multiline)]),
  (
    'Aussehen',
    [
      ('queen_size', 'Größe Königin', _Kind.text),
      ('worker_size', 'Größe Arbeiterin', _Kind.text),
      ('male_size', 'Größe Männchen', _Kind.text),
      ('coloration', 'Färbung', _Kind.text),
    ],
  ),
  (
    'Klima',
    [
      ('temp_nest_min', 'Nest min °C', _Kind.decimal),
      ('temp_nest_max', 'Nest max °C', _Kind.decimal),
      ('temp_arena_min', 'Arena min °C', _Kind.decimal),
      ('temp_arena_max', 'Arena max °C', _Kind.decimal),
      ('humidity_nest_min', 'Nest min %', _Kind.integer),
      ('humidity_nest_max', 'Nest max %', _Kind.integer),
      ('humidity_arena_min', 'Arena min %', _Kind.integer),
      ('humidity_arena_max', 'Arena max %', _Kind.integer),
    ],
  ),
  (
    'Winterruhe',
    [
      ('hibernation_period', 'Zeitraum', _Kind.text),
      ('hibernation_temp_min', 'min °C', _Kind.decimal),
      ('hibernation_temp_max', 'max °C', _Kind.decimal),
    ],
  ),
  (
    'Kolonie',
    [
      ('colony_size', 'Koloniegröße', _Kind.text),
      ('queen_lifespan', 'Lebensdauer Königin', _Kind.text),
      ('development', 'Entwicklung Ei → Arbeiterin', _Kind.text),
      ('nuptial_flight', 'Hochzeitsflug', _Kind.text),
    ],
  ),
  (
    'Futter',
    [
      ('diet_protein', 'Protein', _Kind.multiline),
      ('diet_carbohydrate', 'Kohlenhydrate', _Kind.multiline),
      ('diet_notes', 'Hinweis', _Kind.multiline),
    ],
  ),
  (
    'Haltung',
    [
      ('nesting', 'Nestbau in der Natur', _Kind.text),
      ('formicarium', 'Geeignete Nester', _Kind.text),
      ('formicarium_size', 'Formicariumgröße', _Kind.text),
      ('substrate', 'Substrat', _Kind.text),
      ('legal_note', 'Rechtlicher Hinweis', _Kind.multiline),
      ('notes', 'Notizen', _Kind.multiline),
    ],
  ),
];

const _choiceFields = <String, (String, Map<String, String>)>{
  'hibernation': ('Winterruhe', hibernationNames),
  'founding': ('Koloniegründung', foundingNames),
  'gyne_type': ('Königinnen', speciesGyneNames),
  'activity': ('Aktivität', activityNames),
};

/// „Titel | https://…“ per line ⇄ sources list.
String sourcesToText(List<({String title, String? url})> list) =>
    list.map((s) => s.url == null ? s.title : '${s.title} | ${s.url}').join('\n');

List<Map<String, String>> sourcesFromText(String text) => [
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty)
      switch (line.split('|').map((p) => p.trim()).toList()) {
        [final t, final u, ...] when u.isNotEmpty => {'title': t.isEmpty ? u : t, 'url': u},
        [final t, ...] when t.startsWith('http://') || t.startsWith('https://') => {'title': t, 'url': t},
        [final t, ...] => {'title': t},
        _ => {'title': line.trim()},
      },
];

class SpeciesFormScreen extends ConsumerStatefulWidget {
  const SpeciesFormScreen({super.key, this.speciesId});
  final String? speciesId;
  @override
  ConsumerState<SpeciesFormScreen> createState() => _SpeciesFormScreenState();
}

class _SpeciesFormScreenState extends ConsumerState<SpeciesFormScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _sources = TextEditingController();
  final _ctl = {
    for (final (_, fields) in _formGroups)
      for (final (key, _, _) in fields) key: TextEditingController(),
  };
  final _choice = <String, String?>{};
  int? _difficulty;
  bool? _polymorphic;
  Species? _initial;
  bool _loaded = false;

  @override
  void dispose() {
    for (final c in [_name, _sources, ..._ctl.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _load() {
    if (_loaded || widget.speciesId == null) return;
    final s = ref.read(repositoryProvider)!.speciesById(widget.speciesId!);
    if (s == null) return;
    _loaded = true;
    _initial = s;
    _name.text = s.scientificName;
    _sources.text = sourcesToText(s.sources);
    for (final (_, fields) in _formGroups) {
      for (final (key, _, kind) in fields) {
        _ctl[key]!.text = switch (s.json[key]) {
          final num n when kind == _Kind.integer || n == n.roundToDouble() => n.toInt().toString(),
          final num n => S.decimal(n),
          final String t => t,
          _ => '',
        };
      }
    }
    for (final k in _choiceFields.keys) {
      _choice[k] = s.text(k);
    }
    _difficulty = s.difficulty;
    _polymorphic = s.polymorphic;
  }

  @override
  Widget build(BuildContext context) {
    _load();
    final isNew = widget.speciesId == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'Eigene Art' : 'Art bearbeiten'),
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
                  TextFormField(
                    controller: _name,
                    autofocus: isNew,
                    decoration: const InputDecoration(
                      labelText: 'Wissenschaftlicher Name *',
                      hintText: 'Camponotus sp.',
                    ),
                    validator: (v) => (v ?? '').trim().isEmpty ? 'Bitte den Namen angeben' : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int?>(
                    initialValue: _difficulty,
                    decoration: const InputDecoration(labelText: 'Schwierigkeit'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('–')),
                      for (final e in difficultyNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) => setState(() => _difficulty = v),
                  ),
                  for (final (title, fields) in _formGroups) ...[
                    SectionHeader(title),
                    if (title == 'Aussehen')
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        tristate: true,
                        title: const Text('Polymorph (verschieden große Arbeiterinnen)'),
                        value: _polymorphic,
                        onChanged: (v) => setState(() => _polymorphic = v),
                      ),
                    for (final (key, (label, names)) in _choiceFields.entries.map((e) => (e.key, e.value)))
                      if (_groupOf(key) == title)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: DropdownButtonFormField<String?>(
                            initialValue: _choice[key],
                            isExpanded: true,
                            decoration: InputDecoration(labelText: label),
                            items: [
                              const DropdownMenuItem(value: null, child: Text('–')),
                              for (final e in names.entries)
                                DropdownMenuItem(
                                  value: e.key,
                                  child: Text(e.value, overflow: TextOverflow.ellipsis),
                                ),
                            ],
                            onChanged: (v) => setState(() => _choice[key] = v),
                          ),
                        ),
                    Wrap(
                      spacing: 12,
                      children: [
                        for (final (key, label, kind) in fields)
                          SizedBox(
                            width: kind == _Kind.decimal || kind == _Kind.integer ? 140 : 640,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: TextFormField(
                                controller: _ctl[key],
                                minLines: kind == _Kind.multiline ? 2 : 1,
                                maxLines: kind == _Kind.multiline ? 5 : 1,
                                keyboardType: switch (kind) {
                                  _Kind.decimal => const TextInputType.numberWithOptions(decimal: true, signed: true),
                                  _Kind.integer => TextInputType.number,
                                  _ => kind == _Kind.multiline ? TextInputType.multiline : TextInputType.text,
                                },
                                decoration: InputDecoration(labelText: label),
                                validator: (v) => _validate(kind, v),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SectionHeader('Quellen'),
                  TextFormField(
                    controller: _sources,
                    minLines: 2,
                    maxLines: 8,
                    keyboardType: TextInputType.multiline,
                    decoration: const InputDecoration(
                      labelText: 'Eine Quelle pro Zeile',
                      hintText: 'AntWiki | https://www.antwiki.org/wiki/…',
                      helperText: 'Format: Titel | Link (Link optional)',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _groupOf(String choiceKey) => choiceKey == 'hibernation' ? 'Winterruhe' : 'Kolonie';

  static num? _parse(_Kind kind, String text) {
    final t = text.trim().replaceAll(',', '.');
    if (t.isEmpty) return null;
    return kind == _Kind.integer ? int.tryParse(t) : double.tryParse(t);
  }

  static String? _validate(_Kind kind, String? v) {
    if (kind != _Kind.decimal && kind != _Kind.integer) return null;
    if ((v ?? '').trim().isEmpty) return null;
    final n = _parse(kind, v!);
    if (n == null) return 'Keine Zahl';
    if (kind == _Kind.integer && (n < 0 || n > 100)) return '0–100';
    return null;
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    for (final (key, label) in const [
      ('temp_nest', 'Temperatur Nest'),
      ('temp_arena', 'Temperatur Arena'),
      ('humidity_nest', 'Luftfeuchte Nest'),
      ('humidity_arena', 'Luftfeuchte Arena'),
      ('hibernation_temp', 'Winterruhe'),
    ]) {
      final kind = key.startsWith('humidity') ? _Kind.integer : _Kind.decimal;
      final a = _parse(kind, _ctl['${key}_min']!.text), b = _parse(kind, _ctl['${key}_max']!.text);
      if (a != null && b != null && a > b) {
        showError(context, '$label: Minimum ist größer als Maximum.');
        return;
      }
    }
    final fields = <String, dynamic>{
      'scientific_name': _name.text.trim(),
      'difficulty': _difficulty,
      'polymorphic': _polymorphic,
      ..._choice,
      'sources': sourcesFromText(_sources.text),
      for (final (_, group) in _formGroups)
        for (final (key, _, kind) in group)
          key: switch (kind) {
            _Kind.decimal || _Kind.integer => _parse(kind, _ctl[key]!.text),
            _ => _ctl[key]!.text.trim().isEmpty ? null : _ctl[key]!.text.trim(),
          },
    };
    final repo = ref.read(repositoryProvider)!;
    if (_initial == null) {
      if (fields['genus'] == null) fields.remove('genus');
      final id = repo.createSpecies(fields..removeWhere((_, v) => v == null));
      context.go('/species/$id');
    } else {
      fields['genus'] ??= _name.text.trim().split(' ').first;
      final changed = {
        for (final e in fields.entries)
          if (!_same(_initial!.json[e.key], e.value)) e.key: e.value,
      };
      if (changed.isNotEmpty) repo.updateSpecies(_initial!.id, changed);
      context.pop();
    }
  }

  static bool _same(Object? a, Object? b) {
    if (a is num && b is num) return a.toDouble() == b.toDouble();
    if (a is List || b is List) return a.toString() == b.toString();
    return a == b;
  }
}

// -----------------------------------------------------------------------------
// Feeding guide

class FoodGuideScreen extends StatelessWidget {
  const FoodGuideScreen({super.key});

  static const _sections = <(String, List<String>)>[
    (
      'Grundregeln',
      [
        'Kohlenhydrate sind der Treibstoff der Arbeiterinnen, Protein brauchen vor allem Larven und Königin. Viel Brut → mehr Protein, wenig Brut → wenig Protein.',
        'Zuckerwasser oder Honigwasser darf dauerhaft verfügbar sein. Protein nur so viel, wie in etwa einem Tag verbraucht wird: Zu viel Protein verkürzt die Lebensdauer der Arbeiterinnen (Dussutour & Simpson 2012).',
        'Futterreste nach spätestens 24 Stunden entfernen – sonst drohen Schimmel und Milben.',
        'Wasser immer anbieten, z. B. Reagenzglas mit Watte.',
      ],
    ),
    (
      'Protein: Futterinsekten',
      [
        'Am verlässlichsten sind Futterinsekten aus dem Zoofachhandel bzw. von Terraristik-Züchtern: Heimchen, Grillen, Schaben (z. B. Shelfordella lateralis), Fruchtfliegen und Mehlwürmer. Sie stammen aus kontrollierter Zucht und sind frei von Pestiziden.',
        'Vor dem Verfüttern einfrieren (mind. 24 h), dann auftauen lassen. Große Tiere anschneiden oder zerteilen, damit kleine Kolonien ans Innere kommen.',
        'Wild gefangene Insekten nur von unbehandelten Flächen – Pestizide und Parasiten sind das größte Risiko. Auch hier vorher einfrieren.',
        'Körnersammler (Messor, Pheidole): unbehandelte Samen wie Grassamen, Chia, Mohn, Leinsamen oder Löwenzahnsamen. Kein gebeiztes Saatgut – es ist mit Fungiziden und oft Insektiziden behandelt.',
      ],
    ),
    (
      'Kohlenhydrate',
      [
        'Zuckerwasser (etwa 1 Teil Zucker auf 2–3 Teile Wasser) oder verdünnter Honig; alle paar Tage frisch ansetzen, da es gärt und schimmelt.',
        'Süßes Obst in kleinen Stücken als Abwechslung.',
        'Keine Süßstoffe: Erythrit wirkt auf Insekten giftig (Baudier et al. 2014). Nichts Gesalzenes oder Gewürztes.',
        'Als Alternative für einen Futterbrei gibt es die Bhatkar-Diät (Ei, Honig, Vitamine, Agar), die 1970 für die Aufzucht verschiedener Ameisenarten entwickelt wurde (Bhatkar & Whitcomb 1970).',
      ],
    ),
    (
      'Verlässliche Informationsquellen',
      [
        'AntWiki (antwiki.org): Biologie, Verbreitung und Literatur zu jeder Art – wissenschaftlich gepflegt.',
        'AntCat (antcat.org): der Katalog der gültigen Ameisennamen.',
        'AntWeb (antweb.org): Fotos von Belegexemplaren, gut zum Bestimmen.',
        'Seifert (2018): The Ants of Central and North Europe – das Standardwerk für heimische Arten.',
        'Händler-Steckbriefe und Foren liefern Praxiswerte zur Haltung. Sie sind hilfreich, aber nicht immer geprüft – mehrere Quellen vergleichen.',
      ],
    ),
  ];

  static const _papers = <(String, String)>[
    (
      'Dussutour & Simpson (2012): Ant workers die young and colonies collapse when fed a high-protein diet. Proc. R. Soc. B 279',
      'https://doi.org/10.1098/rspb.2012.0051',
    ),
    (
      'Dussutour & Simpson (2009): Communal nutrition in ants. Current Biology 19',
      'https://doi.org/10.1016/j.cub.2009.03.015',
    ),
    (
      'Baudier et al. (2014): Erythritol … is a palatable ingested insecticide. PLoS ONE 9',
      'https://doi.org/10.1371/journal.pone.0098949',
    ),
    (
      'Bhatkar & Whitcomb (1970): Artificial diet for rearing various species of ants. Florida Entomologist 53',
      'https://doi.org/10.2307/3493193',
    ),
    ('AntWiki', 'https://www.antwiki.org'),
    ('AntCat', 'https://www.antcat.org'),
    ('AntWeb', 'https://www.antweb.org'),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Futter-Ratgeber')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        ContentWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (title, points) in _sections) ...[
                SectionHeader(title),
                for (final p in points)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(padding: EdgeInsets.only(top: 2, right: 8), child: Text('•')),
                        Expanded(child: Text(p)),
                      ],
                    ),
                  ),
              ],
              const SectionHeader('Studien & Links'),
              for (final (title, url) in _papers)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.open_in_new, size: 20),
                  title: Text(title),
                  onTap: () => _open(context, url),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
