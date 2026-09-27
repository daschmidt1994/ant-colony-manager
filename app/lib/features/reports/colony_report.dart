import 'dart:math' as math;
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../app/strings.dart';
import '../../domain/due.dart';
import '../../domain/models.dart';
import '../../domain/stats.dart';
import '../labels/labels.dart' show LabelFonts;

/// Everything the colony report shows (spec §39) – collected from the local
/// database, so the report also works offline.
class ReportData {
  ReportData({
    required this.colony,
    required this.events,
    required this.due,
    required this.photos,
    required this.now,
    this.author,
  });
  final Colony colony;
  final List<ColonyEvent> events; // newest first
  final List<DueTask> due;
  final List<(Photo, Uint8List)> photos; // thumbnails
  final DateTime now;
  final String? author;
}

const _green = PdfColor.fromInt(0xFF4E7D3A);
const _protein = PdfColor.fromInt(0xFFA0522D);
const _carbs = PdfColor.fromInt(0xFFC8962A);
const _water = PdfColor.fromInt(0xFF3F7FA6);
const _muted = PdfColor.fromInt(0xFF6B6F6A);
const _grid = PdfColor.fromInt(0xFFDADCD8);

Future<Uint8List> buildColonyReport(ReportData d, {LabelFonts? fonts}) async {
  final f = fonts ?? await LabelFonts.load();
  final c = d.colony;
  final all = colonyStats(d.events, StatsRange.all, d.now);
  final year = colonyStats(d.events, StatsRange.year, d.now);
  final doc = pw.Document(
    title: 'Koloniebericht ${c.name}',
    author: d.author,
    creator: 'Ant Colony Manager',
    theme: pw.ThemeData.withFont(base: f.regular, bold: f.bold, italic: f.italic),
  );
  final dateFmt = DateFormat('dd.MM.yyyy', 'de');
  final small = pw.TextStyle(fontSize: 8, color: _muted);

  pw.Widget h2(String t) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 16, bottom: 6),
    child: pw.Text(
      t,
      style: pw.TextStyle(font: f.bold, fontSize: 13, color: _green),
    ),
  );

  final founded = DateTime.tryParse(c.json['founded_on'] as String? ?? '');
  final facts = <(String, String)>[
    ('Status', S.statusNames[c.status] ?? c.status),
    if (founded != null) ('Gründung', '${dateFmt.format(founded)} (${_age(founded, d.now)})'),
    if (c.origin != null && c.origin!.isNotEmpty) ('Herkunft', c.origin!),
    if (c.locationPath != null) ('Standort', c.locationPath!),
    if (c.queenCount != null) ('Königinnen', '${c.queenCount}'),
    ('Arbeiterinnen', c.workerMin == null ? 'keine Angabe' : 'ca. ${S.workers(c.workerMin, c.workerMax)}'),
    ('Koloniegründung', S.gyneNames[c.gyneType] ?? c.gyneType),
    if (c.lastTemperature != null || c.lastHumidity != null)
      (
        'Letzte Messung',
        [
          if (c.lastTemperature != null) '${S.decimal(c.lastTemperature!)} °C',
          if (c.lastHumidity != null) '${c.lastHumidity!.round()} %',
        ].join(' · '),
      ),
    (
      'Einträge',
      '${d.events.length} (seit ${d.events.isEmpty ? '–' : dateFmt.format(d.events.last.occurredAt.toLocal())})',
    ),
  ];

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(40, 36, 40, 36),
      footer: (ctx) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('${c.name} · erstellt am ${dateFmt.format(d.now.toLocal())}', style: small),
          pw.Text('Seite ${ctx.pageNumber} / ${ctx.pagesCount}', style: small),
        ],
      ),
      build: (ctx) => [
        // Title
        if (c.species.isNotEmpty) pw.Text(c.species, style: pw.TextStyle(font: f.italic, fontSize: 22)),
        pw.Text(
          '${c.name}${c.number > 0 ? '  ·  Kolonie #${c.number}' : ''}',
          style: pw.TextStyle(font: f.bold, fontSize: c.species.isEmpty ? 22 : 14),
        ),
        pw.SizedBox(height: 10),
        pw.Table(
          columnWidths: const {0: pw.FixedColumnWidth(110), 1: pw.FlexColumnWidth()},
          children: [
            for (final (k, v) in facts)
              pw.TableRow(
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(vertical: 2),
                    child: pw.Text(k, style: pw.TextStyle(color: _muted)),
                  ),
                  pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 2), child: pw.Text(v)),
                ],
              ),
          ],
        ),
        if (c.notes != null && c.notes!.trim().isNotEmpty) ...[
          pw.SizedBox(height: 6),
          pw.Text(c.notes!.trim(), style: const pw.TextStyle(fontSize: 9)),
        ],

        h2('Kolonieentwicklung'),
        if (all.workers.isEmpty)
          pw.Text('Keine Größenangaben erfasst.', style: small)
        else
          _lineChart(
            [
              (all.workers, _green, true),
              (
                [
                  for (final p in all.workers)
                    if (p.max != null) Point(p.at, p.max!),
                ],
                PdfColor(.3, .49, .23, .4),
                true,
              ),
            ],
            from: all.buckets.from,
            to: d.now,
            format: (v) => S.number(v.round()),
            small: small,
          ),

        h2('Fütterungen (12 Monate)'),
        pw.Text(
          '${year.feedings} Fütterungen · Protein ${year.protein} · Kohlenhydrate ${year.carbohydrate}'
          '${year.rated > 0 ? ' · angenommen ${(100 * year.accepted / year.rated).round()} % von ${year.rated} bewerteten' : ''}'
          ' · Wasser ${year.water} · Reinigungen ${year.cleaning}',
        ),
        pw.SizedBox(height: 6),
        _barChart(year, small: small),
        pw.SizedBox(height: 4),
        _legend([('Protein', _protein), ('Kohlenhydrate', _carbs), ('Sonstiges', _muted), ('Wasser', _water)], small),

        if (all.temperature.isNotEmpty || all.humidity.isNotEmpty) ...[
          h2('Temperatur und Luftfeuchtigkeit'),
          if (all.temperature.isNotEmpty)
            _lineChart(
              [(all.temperature, _protein, false)],
              from: all.buckets.from,
              to: d.now,
              format: (v) => '${S.decimal(v)} °C',
              small: small,
            ),
          if (all.humidity.isNotEmpty) ...[
            pw.SizedBox(height: 8),
            _lineChart(
              [(all.humidity, _water, false)],
              from: all.buckets.from,
              to: d.now,
              format: (v) => '${v.round()} %',
              small: small,
            ),
          ],
        ],

        if (all.brood.isNotEmpty) ...[
          h2('Brut (zuletzt erfasst)'),
          pw.Wrap(
            spacing: 14,
            children: [
              for (final st in broodStages)
                if (all.brood[st] != null)
                  pw.Text(
                    '${S.broodStages[st]}: ${_broodText(all.brood[st]!.last.value)} (${dateFmt.format(all.brood[st]!.last.at.toLocal())})',
                  ),
            ],
          ),
        ],

        if (d.due.isNotEmpty) ...[
          h2('Pflegeplan'),
          pw.Table(
            columnWidths: const {0: pw.FixedColumnWidth(110), 1: pw.FixedColumnWidth(90), 2: pw.FlexColumnWidth()},
            children: [
              for (final t in d.due)
                pw.TableRow(
                  children: [
                    pw.Text(
                      t.schedule.taskType == 'custom'
                          ? t.schedule.title ?? 'Aufgabe'
                          : S.taskNames[t.schedule.taskType] ?? t.schedule.taskType,
                    ),
                    pw.Text('alle ${S.decimal(t.schedule.intervalDays)} Tage'.replaceAll(',0 ', ' ')),
                    pw.Text(
                      '${t.lastDone == null ? 'noch nie' : 'zuletzt ${dateFmt.format(t.lastDone!.toLocal())}'} · ${S.dueText(t)}',
                      style: pw.TextStyle(color: t.status == DueStatus.overdue ? PdfColors.red800 : null),
                    ),
                  ],
                ),
            ],
          ),
        ],

        h2('Timeline'),
        if (d.events.isEmpty) pw.Text('Noch keine Einträge.', style: small),
        for (final e in d.events.take(60))
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 2),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.SizedBox(
                  width: 62,
                  child: pw.Text(dateFmt.format(e.occurredAt.toLocal()), style: const pw.TextStyle(fontSize: 9)),
                ),
                pw.SizedBox(
                  width: 70,
                  child: pw.Text(S.eventTypes[e.type] ?? e.type, style: pw.TextStyle(fontSize: 9, color: _muted)),
                ),
                pw.Expanded(
                  child: pw.Text(
                    [S.eventSummary(e), if (e.note != null && e.type == 'feeding') e.note!].join(' – '),
                    style: const pw.TextStyle(fontSize: 9),
                  ),
                ),
              ],
            ),
          ),
        if (d.events.length > 60)
          pw.Text('… und ${d.events.length - 60} ältere Einträge (vollständig im JSON-/CSV-Export).', style: small),

        if (d.photos.isNotEmpty) ...[
          h2('Fotos'),
          pw.Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (p, bytes) in d.photos.take(12))
                pw.SizedBox(
                  width: 120,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.ClipRRect(
                        horizontalRadius: 4,
                        verticalRadius: 4,
                        child: pw.Image(pw.MemoryImage(bytes), width: 120, height: 90, fit: pw.BoxFit.cover),
                      ),
                      pw.Text(
                        '${dateFmt.format(p.takenAt.toLocal())}${p.caption == null ? '' : ' · ${p.caption}'}',
                        style: const pw.TextStyle(fontSize: 7),
                        maxLines: 2,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ],
    ),
  );
  return doc.save();
}

String _age(DateTime founded, DateTime now) {
  final months = (now.year - founded.year) * 12 + now.month - founded.month;
  if (months < 1) return '${now.difference(founded).inDays} Tage';
  if (months < 24) return '$months Monate';
  return '${months ~/ 12} Jahre';
}

String _broodText(double v) => switch (v) {
  0 => 'keine',
  1 => 'wenig',
  2 => 'mittel',
  3 => 'viel',
  _ => S.number(v.round()),
};

pw.Widget _legend(List<(String, PdfColor)> items, pw.TextStyle style) => pw.Wrap(
  spacing: 12,
  children: [
    for (final (label, color) in items)
      pw.Row(
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          pw.Container(width: 7, height: 7, color: color),
          pw.SizedBox(width: 3),
          pw.Text(label, style: style),
        ],
      ),
  ],
);

/// Monthly bars: feedings stacked by kind, water as a thin bar next to them.
pw.Widget _barChart(ColonyStats s, {required pw.TextStyle small}) {
  final maxY = s.care.map((b) => math.max(b.protein + b.carbohydrate + b.otherFeeding, b.water)).fold(0, math.max);
  final top = math.max(3, maxY).toDouble();
  final labels = DateFormat('MMM', 'de');
  return pw.Column(
    children: [
      pw.SizedBox(
        height: 90,
        child: pw.CustomPaint(
          size: const PdfPoint(double.infinity, 90),
          painter: (canvas, size) {
            final n = s.care.length;
            final slot = size.x / n;
            final w = slot * .5;
            canvas
              ..setStrokeColor(_grid)
              ..setLineWidth(.4);
            for (var i = 0; i <= 3; i++) {
              final y = size.y * i / 3;
              canvas
                ..moveTo(0, y)
                ..lineTo(size.x, y)
                ..strokePath();
            }
            for (var i = 0; i < n; i++) {
              final b = s.care[i];
              var y = 0.0;
              final x = i * slot + slot * .15;
              for (final (v, color) in [(b.protein, _protein), (b.carbohydrate, _carbs), (b.otherFeeding, _muted)]) {
                if (v == 0) continue;
                final h = size.y * v / top;
                canvas
                  ..setFillColor(color)
                  ..drawRect(x, y, w, h)
                  ..fillPath();
                y += h;
              }
              if (b.water > 0) {
                canvas
                  ..setFillColor(_water)
                  ..drawRect(x + w + 1, 0, slot * .15, size.y * b.water / top)
                  ..fillPath();
              }
            }
          },
        ),
      ),
      pw.SizedBox(height: 2),
      pw.Row(
        children: [
          for (final start in s.buckets.starts)
            pw.Expanded(
              child: pw.Text(labels.format(start), style: small, textAlign: pw.TextAlign.center),
            ),
        ],
      ),
      pw.Align(
        alignment: pw.Alignment.centerLeft,
        child: pw.Text('max. ${top.round()} pro Monat', style: small),
      ),
    ],
  );
}

/// Lines over time; `step` keeps a value until the next one (colony size).
pw.Widget _lineChart(
  List<(List<Point>, PdfColor, bool)> series, {
  required DateTime from,
  required DateTime to,
  required String Function(double) format,
  required pw.TextStyle small,
}) {
  final values = [for (final s in series) ...s.$1.map((p) => p.value)];
  var lo = values.reduce(math.min), hi = values.reduce(math.max);
  if (lo == hi) {
    lo -= 1;
    hi += 1;
  }
  final span = to.difference(from).inMinutes.toDouble().clamp(1, double.infinity);
  final dateFmt = DateFormat(to.difference(from).inDays > 120 ? 'MMM yyyy' : 'dd.MM.', 'de');
  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.SizedBox(
        width: 48,
        height: 100,
        child: pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text(format(hi), style: small),
            pw.Text(format(lo), style: small),
          ],
        ),
      ),
      pw.SizedBox(width: 6),
      pw.Expanded(
        child: pw.Column(
          children: [
            pw.SizedBox(
              height: 100,
              child: pw.CustomPaint(
                size: const PdfPoint(double.infinity, 100),
                painter: (canvas, size) {
                  double x(DateTime t) => size.x * (t.difference(from).inMinutes / span).clamp(0, 1);
                  double y(double v) => size.y * (v - lo) / (hi - lo);
                  canvas
                    ..setStrokeColor(_grid)
                    ..setLineWidth(.4);
                  for (var i = 0; i <= 4; i++) {
                    canvas
                      ..moveTo(0, size.y * i / 4)
                      ..lineTo(size.x, size.y * i / 4)
                      ..strokePath();
                  }
                  for (final (points, color, step) in series) {
                    if (points.isEmpty) continue;
                    canvas
                      ..setStrokeColor(color)
                      ..setLineWidth(1.4)
                      ..moveTo(x(points.first.at), y(points.first.value));
                    for (var i = 1; i < points.length; i++) {
                      if (step) canvas.lineTo(x(points[i].at), y(points[i - 1].value));
                      canvas.lineTo(x(points[i].at), y(points[i].value));
                    }
                    if (step) canvas.lineTo(size.x, y(points.last.value));
                    canvas.strokePath();
                    if (points.length < 40) {
                      canvas.setFillColor(color);
                      for (final p in points) {
                        canvas
                          ..drawEllipse(x(p.at), y(p.value), 1.6, 1.6)
                          ..fillPath();
                      }
                    }
                  }
                },
              ),
            ),
            pw.SizedBox(height: 2),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(dateFmt.format(from), style: small),
                pw.Text(dateFmt.format(to.toLocal()), style: small),
              ],
            ),
          ],
        ),
      ),
    ],
  );
}
