import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// A label format: either one label per page (label printers) or a sheet.
class LabelTemplate {
  const LabelTemplate({
    required this.id,
    required this.name,
    required this.labelWidth,
    required this.labelHeight,
    this.pageWidth,
    this.pageHeight,
    this.cols = 1,
    this.rows = 1,
    this.marginLeft = 0,
    this.marginTop = 0,
    this.gapX = 0,
    this.gapY = 0,
  });

  final String id, name;

  /// All sizes in millimetres.
  final double labelWidth, labelHeight;
  final double? pageWidth, pageHeight; // null = page is the label
  final int cols, rows;
  final double marginLeft, marginTop, gapX, gapY;

  bool get isSheet => cols * rows > 1;
  int get perPage => cols * rows;
  double get pageW => pageWidth ?? labelWidth;
  double get pageH => pageHeight ?? labelHeight;
}

const labelTemplates = <LabelTemplate>[
  LabelTemplate(id: 'single-50x30', name: 'Einzeletikett 50 × 30 mm', labelWidth: 50, labelHeight: 30),
  LabelTemplate(id: 'single-38x25', name: 'Einzeletikett 38 × 25 mm', labelWidth: 38, labelHeight: 25),
  LabelTemplate(id: 'single-25x25', name: 'Einzeletikett 25 × 25 mm (nur QR + Nr.)', labelWidth: 25, labelHeight: 25),
  LabelTemplate(id: 'brother-62', name: 'Brother 62 mm Endlos (62 × 40 mm)', labelWidth: 62, labelHeight: 40),
  LabelTemplate(
    id: 'a4-38x21',
    name: 'A4-Bogen 38,1 × 21,2 mm (5 × 13, z. B. Avery L7651)',
    labelWidth: 38.1,
    labelHeight: 21.2,
    pageWidth: 210,
    pageHeight: 297,
    cols: 5,
    rows: 13,
    marginLeft: 4.75,
    marginTop: 10.7,
    gapX: 2.5,
  ),
  LabelTemplate(
    id: 'a4-70x37',
    name: 'A4-Bogen 70 × 37 mm (3 × 8)',
    labelWidth: 70,
    labelHeight: 37,
    pageWidth: 210,
    pageHeight: 297,
    cols: 3,
    rows: 8,
    marginTop: 0.5,
  ),
  LabelTemplate(
    id: 'a4-99x38',
    name: 'A4-Bogen 99,1 × 38,1 mm (2 × 7, z. B. Avery L7163)',
    labelWidth: 99.1,
    labelHeight: 38.1,
    pageWidth: 210,
    pageHeight: 297,
    cols: 2,
    rows: 7,
    marginLeft: 4.65,
    marginTop: 15.15,
    gapX: 2.5,
  ),
];

class LabelSlot {
  const LabelSlot(this.page, this.x, this.y);
  final int page;
  final double x, y; // mm from the top-left corner of the page
}

/// Where [count] labels go, starting at field [startAt] (0-based) of the
/// first sheet – so partly used sheets can be reused.
List<LabelSlot> layoutLabels(LabelTemplate t, int count, {int startAt = 0}) {
  final slots = <LabelSlot>[];
  final first = t.isSheet ? startAt.clamp(0, t.perPage - 1) : 0;
  for (var i = 0; i < count; i++) {
    final n = first + i;
    final page = n ~/ t.perPage;
    final pos = n % t.perPage;
    final col = pos % t.cols, row = pos ~/ t.cols;
    slots.add(
      LabelSlot(page, t.marginLeft + col * (t.labelWidth + t.gapX), t.marginTop + row * (t.labelHeight + t.gapY)),
    );
  }
  return slots;
}

class LabelData {
  const LabelData({
    required this.url,
    required this.name,
    required this.number,
    this.species,
    this.location,
    this.code,
  });
  final String url, name;
  final int number;
  final String? species, location, code;
}

class LabelOptions {
  const LabelOptions({
    this.species = true,
    this.name = true,
    this.location = true,
    this.code = false,
    this.nfcHint = false,
  });
  final bool species, name, location, code, nfcHint;
}

class LabelFonts {
  const LabelFonts(this.regular, this.bold, this.italic);
  final pw.Font regular, bold, italic;

  /// The app's own font (Inter) – no external downloads, umlauts work.
  static Future<LabelFonts> load() async {
    try {
      final reg = pw.Font.ttf(await rootBundle.load('assets/fonts/InterVariable.ttf'));
      final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Inter-SemiBold.ttf'));
      final it = pw.Font.ttf(await rootBundle.load('assets/fonts/InterVariable-Italic.ttf'));
      return LabelFonts(reg, bold, it);
    } on Exception {
      return LabelFonts(pw.Font.helvetica(), pw.Font.helveticaBold(), pw.Font.helveticaOblique());
    }
  }
}

Future<Uint8List> buildLabelsPdf(
  LabelTemplate t,
  List<LabelData> labels, {
  LabelOptions options = const LabelOptions(),
  int startAt = 0,
  LabelFonts? fonts,
}) async {
  final f = fonts ?? await LabelFonts.load();
  final doc = pw.Document(title: 'Kolonie-Etiketten', creator: 'Ant Colony Manager');
  final slots = layoutLabels(t, labels.length, startAt: startAt);
  final pages = slots.isEmpty ? 0 : slots.last.page + 1;
  final format = PdfPageFormat(t.pageW * PdfPageFormat.mm, t.pageH * PdfPageFormat.mm, marginAll: 0);

  for (var p = 0; p < pages; p++) {
    doc.addPage(
      pw.Page(
        pageFormat: format,
        build: (_) => pw.Stack(
          children: [
            for (var i = 0; i < labels.length; i++)
              if (slots[i].page == p)
                pw.Positioned(
                  left: slots[i].x * PdfPageFormat.mm,
                  top: slots[i].y * PdfPageFormat.mm,
                  child: _label(t, labels[i], options, f),
                ),
          ],
        ),
      ),
    );
  }
  return doc.save();
}

/// The end of a location path is what you look for at the shelf:
/// „Ameisenraum/Regal A/Fach 3“ → „Regal A / Fach 3“.
String shortLocation(String path) {
  final parts = path.split('/').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  return parts.length <= 2 ? parts.join(' / ') : parts.sublist(parts.length - 2).join(' / ');
}

pw.Widget _label(LabelTemplate t, LabelData d, LabelOptions o, LabelFonts f) {
  const mm = PdfPageFormat.mm;
  final w = t.labelWidth * mm, h = t.labelHeight * mm;
  // The barcode widget draws no quiet zone – the padding around the QR code is it
  // (≈ 3 modules at typical label sizes, enough for phone cameras).
  final pad = (t.labelHeight < 26 ? 2.0 : 3.0) * mm;
  final qrSide = [h - 2 * pad, w * .5].reduce((a, b) => a < b ? a : b);
  final qr = pw.BarcodeWidget(
    barcode: pw.Barcode.qrCode(errorCorrectLevel: pw.BarcodeQRCorrectionLevel.medium),
    data: d.url,
    width: qrSide,
    height: qrSide,
    drawText: false,
  );
  final compact = t.labelWidth <= 26; // square mini label: QR + number only
  final base = (t.labelHeight / 30 * 8).clamp(5.0, 10.0);
  pw.Widget text(String s, {pw.Font? font, double scale = 1, int lines = 1}) => pw.Text(
    s,
    maxLines: lines,
    overflow: pw.TextOverflow.clip,
    style: pw.TextStyle(font: font ?? f.regular, fontSize: base * scale),
  );

  final lines = <pw.Widget>[
    if (o.species && (d.species ?? '').isNotEmpty) text(d.species!, font: f.italic, scale: 1.05, lines: 2),
    if (o.name)
      text(
        d.name == '' ? 'Kolonie #${d.number}' : '${d.name}${d.name.contains('#') ? '' : ' · #${d.number}'}',
        font: f.bold,
        scale: 1.15,
      ),
    if (o.location && (d.location ?? '').isNotEmpty) text(shortLocation(d.location!), scale: .9, lines: 2),
    if (o.code && (d.code ?? '').isNotEmpty) text(d.code!, scale: .9),
    if (o.nfcHint) text('NFC + QR', font: f.bold, scale: .8),
  ];

  return pw.Container(
    width: w,
    height: h,
    padding: pw.EdgeInsets.all(pad),
    child: compact
        ? pw.Column(
            mainAxisAlignment: pw.MainAxisAlignment.center,
            children: [
              pw.SizedBox(width: qrSide - 3 * mm, height: qrSide - 3 * mm, child: qr),
              text('#${d.number}', font: f.bold),
            ],
          )
        : pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              qr,
              pw.SizedBox(width: pad),
              pw.Expanded(
                child: pw.Column(
                  mainAxisAlignment: pw.MainAxisAlignment.center,
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: lines,
                ),
              ),
            ],
          ),
  );
}
