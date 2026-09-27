import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';

/// Long edge of the uploaded image and JPEG quality (docs/05 §7). The
/// server re-encodes anyway; compressing here saves mobile data and storage.
const _maxEdge = 2048.0;
const _quality = 82;
const _thumbEdge = 320;

/// Small preview kept locally so galleries work offline.
Future<Uint8List> makeThumb(Uint8List image) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(image);
  final codec = await ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (w, h) {
      if (w <= _thumbEdge && h <= _thumbEdge) return ui.TargetImageSize(width: w, height: h);
      return w >= h
          ? ui.TargetImageSize(width: _thumbEdge, height: (h * _thumbEdge / w).round())
          : ui.TargetImageSize(width: (w * _thumbEdge / h).round(), height: _thumbEdge);
    },
  );
  final frame = await codec.getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  return png!.buffer.asUint8List();
}

/// „Foto“: Android opens the camera (long press: gallery), the web a file
/// dialog (several at once). Saved without further questions – caption via
/// „Details“ in the confirmation.
Future<void> takePhoto(
  BuildContext context,
  WidgetRef ref,
  Colony colony, {
  String? eventId,
  bool fromGallery = false,
}) async {
  final repo = ref.read(repositoryProvider)!;
  final messenger = ScaffoldMessenger.of(context);
  final picker = ImagePicker();
  final List<XFile> files;
  try {
    if (kIsWeb || fromGallery) {
      files = await picker.pickMultiImage(maxWidth: _maxEdge, maxHeight: _maxEdge, imageQuality: _quality);
    } else {
      final f = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: _maxEdge,
        maxHeight: _maxEdge,
        imageQuality: _quality,
      );
      files = [?f];
    }
  } on PlatformException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Kamera nicht verfügbar: ${e.message ?? e.code}')));
    return;
  }
  if (files.isEmpty) return;
  final saved = <Photo>[];
  for (final f in files) {
    final bytes = await f.readAsBytes();
    Uint8List thumb;
    try {
      thumb = await makeThumb(bytes);
    } on Exception {
      messenger.showSnackBar(const SnackBar(content: Text('Dieses Bild kann nicht gelesen werden.')));
      continue;
    }
    saved.add(repo.addPhoto(colony.id, bytes, thumb: thumb, eventId: eventId));
  }
  if (saved.isEmpty) return;
  HapticFeedback.mediumImpact();
  showUndoSnackOn(
    messenger,
    saved.length == 1 ? 'Foto gespeichert' : '${saved.length} Fotos gespeichert',
    onUndo: () {
      for (final p in saved) {
        repo.deletePhoto(p.id);
      }
    },
    onDetails: saved.length == 1 && context.mounted ? () => editCaption(context, ref, saved.first) : null,
  );
}

Future<void> editCaption(BuildContext context, WidgetRef ref, Photo photo) async {
  final c = TextEditingController(text: photo.caption ?? '');
  final text = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Beschreibung'),
      content: TextField(
        controller: c,
        autofocus: true,
        maxLines: 3,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'z. B. erste Larven sichtbar'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Abbrechen')),
        FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Speichern')),
      ],
    ),
  );
  if (text != null) ref.read(repositoryProvider)!.setCaption(photo.id, text);
}

// -----------------------------------------------------------------------------
// Loading images: local first (offline), then the server.

typedef PhotoKey = ({String id, bool stored});

/// Thumbnail bytes: from the local cache, else downloaded once and cached.
final photoThumbProvider = FutureProvider.family<Uint8List?, PhotoKey>((ref, k) async {
  final db = ref.read(databaseProvider);
  final local = db.thumb(k.id);
  if (local != null) return local;
  if (!k.stored) return null; // not uploaded yet (by another device)
  try {
    final api = ref.read(authProvider.notifier).api;
    final u = await api.get('/api/v1/photos/${k.id}/url', query: {'variant': 'thumb'}) as Map<String, dynamic>;
    final bytes = await api.download(u['url'] as String);
    db.putThumb(k.id, bytes);
    return bytes;
  } on Exception {
    return null; // offline – placeholder
  }
});

/// Full image: the not yet uploaded original, else the server's display size.
final photoFullProvider = FutureProvider.autoDispose.family<Uint8List?, PhotoKey>((ref, k) async {
  final db = ref.read(databaseProvider);
  final local = db.photoUpload(k.id);
  if (local != null) return local;
  if (!k.stored) return db.thumb(k.id);
  try {
    final api = ref.read(authProvider.notifier).api;
    final u = await api.get('/api/v1/photos/${k.id}/url', query: {'variant': 'display'}) as Map<String, dynamic>;
    return await api.download(u['url'] as String);
  } on Exception {
    return db.thumb(k.id);
  }
});

class PhotoThumb extends ConsumerWidget {
  const PhotoThumb(this.photo, {super.key, this.size = 96, this.onTap});
  final Photo photo;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(photoThumbProvider((id: photo.id, stored: photo.stored))).value;
    final uploading = !photo.stored && ref.read(databaseProvider).photoUpload(photo.id) != null;
    return Semantics(
      image: true,
      label: photo.caption ?? 'Foto vom ${S.date(photo.takenAt)}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (bytes != null)
                  Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
                else
                  ColoredBox(
                    color: context.colors.surface2,
                    child: Icon(Icons.image_outlined, color: context.colors.muted),
                  ),
                if (uploading)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Tooltip(
                      message: 'wird hochgeladen, sobald Verbindung besteht',
                      child: CircleAvatar(
                        radius: 10,
                        backgroundColor: Colors.black54,
                        child: Icon(Icons.cloud_upload_outlined, size: 13, color: Colors.white.withValues(alpha: .9)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Map<String, List<Photo>> photosByEvent(List<Photo> photos) {
  final out = <String, List<Photo>>{};
  for (final p in photos) {
    if (p.eventId != null) (out[p.eventId!] ??= []).add(p);
  }
  return out;
}

/// Horizontal strip (colony page, timeline entries).
class PhotoStrip extends StatelessWidget {
  const PhotoStrip({super.key, required this.photos, this.size = 72});
  final List<Photo> photos;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: size,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: photos.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (c, i) => PhotoThumb(photos[i], size: size, onTap: () => openPhotoViewer(c, photos, i)),
    ),
  );
}

// -----------------------------------------------------------------------------
// Gallery (S16)

class GalleryScreen extends ConsumerWidget {
  const GalleryScreen({super.key, required this.colonyId});
  final String colonyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colony = ref.watch(colonyProvider(colonyId)).value;
    final photos = ref.watch(colonyPhotosProvider(colonyId)).value ?? const <Photo>[];
    final canEdit = (ref.watch(roleProvider(colonyId)).value ?? 'owner') != 'viewer';
    final month = DateFormat('MMMM y', 'de');
    final groups = <String, List<int>>{};
    for (var i = 0; i < photos.length; i++) {
      (groups[month.format(photos[i].takenAt.toLocal())] ??= []).add(i);
    }
    return Scaffold(
      appBar: AppBar(title: Text(colony == null ? 'Fotos' : 'Fotos · ${colony.name}')),
      floatingActionButton: canEdit && colony != null
          ? FloatingActionButton.extended(
              onPressed: () => takePhoto(context, ref, colony),
              icon: Icon(kIsWeb ? Icons.add_photo_alternate_outlined : Icons.photo_camera_outlined),
              label: Text(kIsWeb ? 'Fotos hinzufügen' : 'Foto'),
            )
          : null,
      body: photos.isEmpty
          ? const EmptyState(
              icon: Icons.photo_library_outlined,
              title: 'Noch keine Fotos',
              text: 'Fotos werden vor dem Hochladen verkleinert und sind auch offline sichtbar.',
            )
          : ContentWidth(
              child: CustomScrollView(
                slivers: [
                  for (final g in groups.entries) ...[
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      sliver: SliverToBoxAdapter(child: SectionHeader(g.key)),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      sliver: SliverGrid.builder(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 180,
                          mainAxisSpacing: 6,
                          crossAxisSpacing: 6,
                        ),
                        itemCount: g.value.length,
                        itemBuilder: (c, i) => LayoutBuilder(
                          builder: (c, box) => PhotoThumb(
                            photos[g.value[i]],
                            size: box.maxWidth,
                            onTap: () => openPhotoViewer(c, photos, g.value[i], canEdit: canEdit),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SliverToBoxAdapter(child: SizedBox(height: 96)),
                ],
              ),
            ),
    );
  }
}

void openPhotoViewer(BuildContext context, List<Photo> photos, int index, {bool canEdit = true}) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => _PhotoViewer(photos: photos, initial: index, canEdit: canEdit),
      ),
    );

/// Full screen, swipe between photos, pinch to zoom.
class _PhotoViewer extends ConsumerStatefulWidget {
  const _PhotoViewer({required this.photos, required this.initial, required this.canEdit});
  final List<Photo> photos;
  final int initial;
  final bool canEdit;
  @override
  ConsumerState<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends ConsumerState<_PhotoViewer> {
  late final _page = PageController(initialPage: widget.initial);
  late int _index = widget.initial;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  Future<void> _delete(Photo p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Foto löschen?'),
        content: const Text('Das Foto verschwindet auf allen Geräten.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Löschen')),
        ],
      ),
    );
    if (ok != true) return;
    ref.read(repositoryProvider)!.deletePhoto(p.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.photos[_index];
    // Caption edits arrive through the local database.
    final current = ref.watch(colonyPhotosProvider(p.colonyId)).value?.where((x) => x.id == p.id).firstOrNull ?? p;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} / ${widget.photos.length}'),
        actions: [
          if (widget.canEdit) ...[
            IconButton(
              tooltip: 'Beschreibung',
              onPressed: () => editCaption(context, ref, current),
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(tooltip: 'Löschen', onPressed: () => _delete(current), icon: const Icon(Icons.delete_outline)),
          ],
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _page,
              itemCount: widget.photos.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (c, i) {
                final ph = widget.photos[i];
                final img = ref.watch(photoFullProvider((id: ph.id, stored: ph.stored)));
                return img.when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (_, _) => const Center(child: Icon(Icons.broken_image_outlined, color: Colors.white54)),
                  data: (b) => b == null
                      ? const Center(
                          child: Text('Offline – Foto noch nicht geladen', style: TextStyle(color: Colors.white70)),
                        )
                      : InteractiveViewer(maxScale: 5, child: Center(child: Image.memory(b))),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (current.caption != null)
                    Text(current.caption!, style: const TextStyle(color: Colors.white, fontSize: 16)),
                  Text(S.dateTime(current.takenAt), style: const TextStyle(color: Colors.white60)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
