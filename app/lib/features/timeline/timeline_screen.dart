import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';
import '../photos/photos.dart';

const _filterTypes = [
  ('photo', 'Fotos'),
  ('feeding', 'Fütterung'),
  ('water', 'Wasser'),
  ('cleaning', 'Reinigung'),
  ('measurement', 'Messung'),
  ('check', 'Kontrolle'),
  ('note', 'Notizen'),
  ('problem', 'Probleme'),
  ('census', 'Größe'),
  ('brood', 'Brut'),
];

class TimelineScreen extends ConsumerStatefulWidget {
  const TimelineScreen({super.key, required this.colonyId});
  final String colonyId;
  @override
  ConsumerState<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends ConsumerState<TimelineScreen> {
  final _types = <String>{};

  @override
  Widget build(BuildContext context) {
    final colony = ref.watch(colonyProvider(widget.colonyId)).value;
    final role = ref.watch(roleProvider(widget.colonyId)).value ?? 'owner';
    final all = ref.watch(colonyEventsProvider(widget.colonyId)).value ?? const <ColonyEvent>[];
    final byEvent = photosByEvent(ref.watch(colonyPhotosProvider(widget.colonyId)).value ?? const <Photo>[]);
    final events = _types.isEmpty
        ? all
        : all.where((e) => _types.contains(e.type) || (_types.contains('photo') && byEvent.containsKey(e.id))).toList();

    // Group by calendar day.
    final now = DateTime.now();
    final rows = <Widget>[];
    String? day;
    for (final e in events) {
      final d = S.relativeDay(e.occurredAt, now);
      if (d != day) {
        rows.add(SectionHeader(d));
        day = d;
      }
      rows.add(
        Card(
          child: EventTile(event: e, canEdit: role != 'viewer', photos: byEvent[e.id] ?? const []),
        ),
      );
      rows.add(const SizedBox(height: 6));
    }

    return Scaffold(
      appBar: AppBar(title: Text(colony == null ? 'Timeline' : 'Timeline · ${colony.name}')),
      body: ContentWidth(
        child: Column(
          children: [
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final (type, label) in _filterTypes)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        avatar: Icon(eventIcon(type), size: 18),
                        label: Text(label),
                        selected: _types.contains(type),
                        onSelected: (v) => setState(() => v ? _types.add(type) : _types.remove(type)),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: events.isEmpty
                  ? const EmptyState(icon: Icons.timeline, title: 'Keine Einträge')
                  : ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: rows),
            ),
          ],
        ),
      ),
    );
  }
}

/// One timeline entry. Tap opens details (edit acceptance, note, delete).
class EventTile extends ConsumerWidget {
  const EventTile({super.key, required this.event, this.canEdit = true, this.photos = const []});
  final ColonyEvent event;
  final bool canEdit;
  final List<Photo> photos;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.read(repositoryProvider)?.db.hasPendingOps('colony_events', event.id) ?? false;
    final color = switch (event.type) {
      'problem' => context.colors.overdue,
      'water' => context.colors.winter,
      'feeding' when event.items.any((i) => i.category == 'protein') => context.colors.protein,
      'feeding' => context.colors.carbs,
      _ => context.colors.muted,
    };
    final acceptance = event.type == 'feeding' && event.acceptance != 'unknown'
        ? ' · ${S.acceptance[event.acceptance]}'
        : '';
    final tile = ListTile(
      leading: Icon(eventIcon(event.type), color: color),
      title: Text(S.eventSummary(event), maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${S.time(event.occurredAt)} · ${S.eventTypes[event.type] ?? event.type}$acceptance'
        '${event.note != null && event.type == 'feeding' ? ' · ${event.note}' : ''}',
      ),
      trailing: pending
          ? Tooltip(
              message: 'noch nicht synchronisiert',
              child: Icon(Icons.cloud_upload_outlined, size: 18, color: context.colors.muted),
            )
          : null,
      onTap: () => _details(context, ref),
    );
    if (photos.isEmpty) return tile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tile,
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
          child: PhotoStrip(photos: photos, size: 64),
        ),
      ],
    );
  }

  Future<void> _details(BuildContext context, WidgetRef ref) => showModalBottomSheet<void>(
    context: context,
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(eventIcon(event.type)),
                const SizedBox(width: 10),
                Expanded(child: Text(S.eventTypes[event.type] ?? event.type, style: Theme.of(c).textTheme.titleLarge)),
                Text(S.dateTime(event.occurredAt), style: TextStyle(color: c.colors.muted)),
              ],
            ),
            const SizedBox(height: 12),
            Text(S.eventSummary(event), style: const TextStyle(fontSize: 16)),
            if (event.note != null && event.type == 'feeding') ...[const SizedBox(height: 8), Text(event.note!)],
            if (canEdit && event.type == 'feeding') ...[
              const SectionHeader('Annahme'),
              Wrap(
                spacing: 8,
                children: [
                  for (final a in const ['accepted', 'partial', 'ignored', 'unknown'])
                    ChoiceChip(
                      label: Text(S.acceptance[a]!),
                      selected: event.acceptance == a,
                      onSelected: (_) {
                        ref.read(repositoryProvider)!.setAcceptance(event.id, a);
                        Navigator.pop(c);
                      },
                    ),
                ],
              ),
            ],
            if (canEdit) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: c.colors.overdue),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Eintrag löschen'),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: c,
                    builder: (d) => AlertDialog(
                      title: const Text('Eintrag löschen?'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Abbrechen')),
                        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Löschen')),
                      ],
                    ),
                  );
                  if (ok == true) {
                    ref.read(repositoryProvider)!.deleteEvent(event.id);
                    if (c.mounted) Navigator.pop(c);
                  }
                },
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
