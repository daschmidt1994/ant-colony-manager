import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/i18n.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';
import '../photos/photos.dart';

/// Counting ants with AI (set up by the administrator): choose up to 6
/// uploaded photos of the colony – e.g. front and back of the nest – the
/// server has each counted by the AI (Claude, ChatGPT or via OpenRouter) and
/// the counts are added up.
final aiInfoProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  try {
    return await ref.read(authProvider.notifier).api.get('/api/v1/ai') as Map<String, dynamic>;
  } on Exception {
    return const {}; // offline or older server
  }
});

final aiAvailableProvider = FutureProvider.autoDispose<bool>(
  (ref) async => (await ref.watch(aiInfoProvider.future))['available'] == true,
);

/// Display names of the AI providers.
const aiProviders = {'anthropic': 'Anthropic Claude', 'openai': 'OpenAI ChatGPT', 'openrouter': 'OpenRouter'};

const aiMaxPhotos = 6;

/// What to take over into the colony size: exact when the range is closed.
({int total, int min, int max, bool exact}) aiCensus(Map<String, dynamic> result) {
  final total = (result['total'] as num?)?.toInt() ?? 0;
  final min = (result['min'] as num?)?.toInt() ?? total;
  final max = (result['max'] as num?)?.toInt() ?? total;
  return (total: total, min: min, max: max, exact: min == max);
}

/// „120 (100–140)“ – a count with its range.
String aiCountText(Map<String, dynamic> p) {
  final c = (p['count'] ?? p['total']) as num? ?? 0;
  final lo = p['min'] as num? ?? c, hi = p['max'] as num? ?? c;
  return lo == hi ? '$c' : '$c ($lo–$hi)';
}

/// Chooses photos, counts, shows the result. Returns the result when the
/// user takes it over.
Future<Map<String, dynamic>?> showAiCount(BuildContext context, Colony colony) => showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (c) => _AiCountSheet(colony: colony),
);

class _AiCountSheet extends ConsumerStatefulWidget {
  const _AiCountSheet({required this.colony});
  final Colony colony;
  @override
  ConsumerState<_AiCountSheet> createState() => _AiCountSheetState();
}

class _AiCountSheetState extends ConsumerState<_AiCountSheet> {
  final _chosen = <String>[];
  bool _busy = false;
  Map<String, dynamic>? _result;

  Future<void> _count() async {
    setState(() => _busy = true);
    try {
      final r =
          await ref.read(authProvider.notifier).api.post('/api/v1/colonies/${widget.colony.id}/ai-count', {
                'photo_ids': _chosen,
              })
              as Map<String, dynamic>;
      setState(() => _result = r);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(repositoryProvider)!;
    final photos = repo.photos(widget.colony.id).where((p) => p.stored).toList()
      ..sort((a, b) => b.takenAt.compareTo(a.takenAt));
    final byId = {for (final p in photos) p.id: p};
    final muted = TextStyle(color: context.colors.muted, fontSize: 12);
    final result = _result;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('Mit KI zählen'), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          if (result == null) ...[
            Text(
              tr(
                'Fotos wählen (bis zu {0}) – z. B. Vorder- und Rückseite des Nests. Jedes Foto wird einzeln gezählt, '
                'die Zahlen werden addiert. Die Fotos werden dafür an die KI ({1}) geschickt.',
                [aiMaxPhotos, aiProviders[ref.watch(aiInfoProvider).value?['provider']] ?? tr('KI-Anbieter')],
              ),
              style: muted,
            ),
            const SizedBox(height: 12),
            if (photos.isEmpty)
              Text(tr('Noch keine hochgeladenen Fotos dieser Kolonie.'))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in photos.take(60))
                    Stack(
                      children: [
                        PhotoThumb(
                          p,
                          size: 88,
                          onTap: _busy
                              ? null
                              : () => setState(() {
                                  if (!_chosen.remove(p.id) && _chosen.length < aiMaxPhotos) _chosen.add(p.id);
                                }),
                        ),
                        if (_chosen.contains(p.id))
                          Positioned(
                            right: 4,
                            top: 4,
                            child: CircleAvatar(
                              radius: 12,
                              backgroundColor: Theme.of(context).colorScheme.primary,
                              child: Text(
                                '${_chosen.indexOf(p.id) + 1}',
                                style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontSize: 12),
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy || _chosen.isEmpty ? null : _count,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome),
              label: Text(
                _busy
                    ? tr('Zählt … (bis zu einer Minute)')
                    : _chosen.isEmpty
                    ? tr('Fotos antippen')
                    : tr('{0} Fotos zählen', [_chosen.length]),
              ),
            ),
          ] else ...[
            for (final p in (result['photos'] as List).cast<Map<String, dynamic>>())
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: byId[p['photo_id']] == null ? null : PhotoThumb(byId[p['photo_id']]!, size: 48),
                title: Text(tr('{0} Ameisen', [aiCountText(p)])),
                subtitle: Text(
                  [
                    if ((p['queens'] as num? ?? 0) > 0) tr('Königinnen: {0}', [p['queens']]),
                    if ((p['note'] as String? ?? '').isNotEmpty) p['note'] as String,
                  ].join(' · '),
                ),
              ),
            const Divider(),
            Text(
              tr('Zusammen: {0}', [aiCountText(result)]),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (result['overlap'] == true)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  tr('⚠ Die Fotos zeigen offenbar teilweise dieselben Ameisen – die Summe ist dann zu hoch.'),
                  style: TextStyle(color: context.colors.soon),
                ),
              ),
            if ((result['note'] as String? ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(result['note'] as String, style: muted),
              ),
            const SizedBox(height: 4),
            Text(tr('Eine Schätzung der KI – bitte kurz prüfen.'), style: muted),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() => _result = null),
                    child: Text(tr('Andere Fotos')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(onPressed: () => Navigator.pop(context, result), child: Text(tr('Übernehmen'))),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
