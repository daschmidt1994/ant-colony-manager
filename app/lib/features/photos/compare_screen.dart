import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/i18n.dart';
import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../domain/growth.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';
import 'photos.dart';

/// Growth at a glance: two photos side by side (first and latest by default)
/// with date and worker count at that time – or all photos as a time-lapse.
class PhotoCompareScreen extends ConsumerStatefulWidget {
  const PhotoCompareScreen({super.key, required this.colonyId});
  final String colonyId;
  @override
  ConsumerState<PhotoCompareScreen> createState() => _PhotoCompareScreenState();
}

class _PhotoCompareScreenState extends ConsumerState<PhotoCompareScreen> {
  String _mode = 'compare';
  String? _leftId, _rightId;
  int _frame = 0;
  Timer? _play;

  @override
  void dispose() {
    _play?.cancel();
    super.dispose();
  }

  void _toggle(int count) {
    if (_play != null) {
      setState(() {
        _play!.cancel();
        _play = null;
      });
      return;
    }
    if (_frame >= count - 1) _frame = 0;
    setState(() {
      _play = Timer.periodic(const Duration(milliseconds: 900), (t) {
        if (!mounted) return t.cancel();
        setState(() {
          if (_frame < count - 1) {
            _frame++;
          } else {
            t.cancel();
            _play = null;
          }
        });
      });
    });
  }

  Future<void> _pick(List<Photo> photos, bool left) async {
    final p = await showModalBottomSheet<Photo>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .6,
        builder: (c, scroll) => GridView.builder(
          controller: scroll,
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 140,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          itemCount: photos.length,
          itemBuilder: (c, i) => LayoutBuilder(
            builder: (c, box) => PhotoThumb(photos[i], size: box.maxWidth, onTap: () => Navigator.pop(c, photos[i])),
          ),
        ),
      ),
    );
    if (p != null) setState(() => left ? _leftId = p.id : _rightId = p.id);
  }

  @override
  Widget build(BuildContext context) {
    final photos = [...?ref.watch(colonyPhotosProvider(widget.colonyId)).value]
      ..sort((a, b) => a.takenAt.compareTo(b.takenAt));
    ref.watch(colonyEventsProvider(widget.colonyId)); // census changes
    final census = ref.read(repositoryProvider)?.events(widget.colonyId, types: {'census'}) ?? const <ColonyEvent>[];
    return Scaffold(
      appBar: AppBar(title: Text(tr('Wachstum im Vergleich'))),
      body: photos.length < 2
          ? EmptyState(
              icon: Icons.compare_outlined,
              title: tr('Mindestens zwei Fotos nötig'),
              text: tr(
                'Mach regelmäßig ein Foto aus demselben Blickwinkel – dann siehst du hier, wie die Kolonie wächst.',
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                ContentWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SegmentedButton<String>(
                        segments: [
                          ButtonSegment(
                            value: 'compare',
                            label: Text(tr('Vergleich')),
                            icon: const Icon(Icons.compare),
                          ),
                          ButtonSegment(
                            value: 'timelapse',
                            label: Text(tr('Zeitraffer')),
                            icon: const Icon(Icons.slideshow_outlined),
                          ),
                        ],
                        selected: {_mode},
                        onSelectionChanged: (v) => setState(() {
                          _mode = v.first;
                          _play?.cancel();
                          _play = null;
                        }),
                      ),
                      const SizedBox(height: 16),
                      if (_mode == 'compare') _compare(photos, census) else _timelapse(photos, census),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _compare(List<Photo> photos, List<ColonyEvent> census) {
    final left = photos.firstWhere((p) => p.id == _leftId, orElse: () => photos.first);
    final right = photos.firstWhere((p) => p.id == _rightId, orElse: () => photos.last);
    final a = workersAt(census, left.takenAt), b = workersAt(census, right.takenAt);
    final span = timeBetween(left.takenAt, right.takenAt);
    final spanText = [
      if (span.years > 0) span.years == 1 ? tr('1 Jahr') : tr('{0} Jahre', [span.years]),
      if (span.months > 0) span.months == 1 ? tr('1 Monat') : tr('{0} Monate', [span.months]),
      if (span.years == 0 && (span.days > 0 || span.months == 0))
        span.days == 1 ? tr('1 Tag') : tr('{0} Tage', [span.days]),
    ].join(' ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _Panel(photo: left, workers: a, onPick: () => _pick(photos, true)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Panel(photo: right, workers: b, onPick: () => _pick(photos, false)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.trending_up),
            title: Text(tr('{0} dazwischen', [spanText])),
            subtitle: Text(
              a == null || b == null
                  ? tr('Arbeiterinnen: für einen Vergleich eine Zählung vor beiden Fotos eintragen')
                  : tr('Arbeiterinnen: {0} → {1}', [S.workers(a.min, a.max), S.workers(b.min, b.max)]),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(tr('Tippe auf „Anderes Foto“, um ein Bild zu wählen.'), style: TextStyle(color: context.colors.muted)),
      ],
    );
  }

  Widget _timelapse(List<Photo> photos, List<ColonyEvent> census) {
    final i = _frame.clamp(0, photos.length - 1);
    final p = photos[i];
    final w = workersAt(census, p.takenAt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 3 / 4,
          child: _FullImage(photo: p),
        ),
        const SizedBox(height: 8),
        Text(
          [
            S.date(p.takenAt),
            if (w != null) tr('{0} Arbeiterinnen', [S.workers(w.min, w.max)]),
          ].join(' · '),
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Row(
          children: [
            IconButton.filledTonal(
              tooltip: _play == null ? tr('Abspielen') : tr('Anhalten'),
              icon: Icon(_play == null ? Icons.play_arrow : Icons.pause),
              onPressed: () => _toggle(photos.length),
            ),
            Expanded(
              child: Slider(
                value: i.toDouble(),
                max: (photos.length - 1).toDouble(),
                divisions: photos.length - 1,
                label: S.date(p.takenAt),
                onChanged: (v) => setState(() => _frame = v.round()),
              ),
            ),
            Text('${i + 1}/${photos.length}', style: TextStyle(color: context.colors.muted)),
          ],
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.photo, required this.workers, required this.onPick});
  final Photo photo;
  final ({int min, int? max, DateTime at})? workers;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      AspectRatio(
        aspectRatio: 3 / 4,
        child: _FullImage(photo: photo),
      ),
      const SizedBox(height: 6),
      Text(S.date(photo.takenAt), style: const TextStyle(fontWeight: FontWeight.w600)),
      Text(
        workers == null ? tr('keine Zählung') : tr('{0} Arbeiterinnen', [S.workers(workers!.min, workers!.max)]),
        style: TextStyle(color: context.colors.muted),
      ),
      if (photo.caption != null)
        Text(
          photo.caption!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: context.colors.muted),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(onPressed: onPick, child: Text(tr('Anderes Foto'))),
      ),
    ],
  );
}

/// Full-size image (thumbnail while it loads).
class _FullImage extends ConsumerWidget {
  const _FullImage({required this.photo});
  final Photo photo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (id: photo.id, stored: photo.stored);
    final full = ref.watch(photoFullProvider(key)).value;
    final thumb = ref.watch(photoThumbProvider(key)).value;
    final bytes = full ?? thumb;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: context.colors.surface2,
        child: bytes == null
            ? Icon(Icons.image_outlined, color: context.colors.muted)
            : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
      ),
    );
  }
}
