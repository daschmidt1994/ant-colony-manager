import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../app/providers.dart';
import '../../core/session.dart';
import '../../core/web_meta.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';
import '../photos/photos.dart';
import 'colony_report.dart';

/// „Bericht als PDF“: web downloads it, Android shows a preview with
/// print/share.
Future<void> openColonyReport(BuildContext context, WidgetRef ref, Colony colony) async {
  final repo = ref.read(repositoryProvider)!;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Bericht wird erstellt …'), duration: Duration(seconds: 2)));
  try {
    final photos = <(Photo, Uint8List)>[];
    for (final p in repo.photos(colony.id).take(12)) {
      final t = await ref.read(photoThumbProvider((id: p.id, stored: p.stored)).future);
      if (t != null) photos.add((p, t));
    }
    final auth = ref.read(authProvider);
    final bytes = await buildColonyReport(
      ReportData(
        colony: colony,
        events: repo.events(colony.id),
        due: repo.due(colony.id),
        photos: photos,
        now: DateTime.now(),
        author: auth is SignedIn ? auth.user.displayName : null,
      ),
    );
    final name = 'koloniebericht-${colony.name.replaceAll(RegExp(r'[^A-Za-z0-9äöüÄÖÜß_-]+'), '-')}.pdf';
    if (!context.mounted) return;
    if (kIsWeb) {
      downloadFile(name, bytes, 'application/pdf');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Koloniebericht')),
          body: PdfPreview(
            build: (_) async => bytes,
            canChangeOrientation: false,
            canChangePageFormat: false,
            canDebug: false,
            pdfFileName: name,
          ),
        ),
      ),
    );
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
