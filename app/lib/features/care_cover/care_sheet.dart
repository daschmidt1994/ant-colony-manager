import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../app/i18n.dart';
import '../../app/strings.dart';
import '../../domain/due.dart';
import '../../domain/models.dart';
import '../labels/labels.dart' show LabelFonts;

/// Pflegezettel: a printable sheet for whoever looks after the colonies
/// during a holiday – no account and no app needed. Per colony what to do
/// on which day (from the care schedules), with boxes to tick and room for
/// notes. Built from the local database, so it also works offline.

/// One colony on the sheet.
class CareSheetColony {
  CareSheetColony({required this.colony, required this.due, this.instructions = ''});
  final Colony colony;
  final List<DueTask> due;
  final String instructions;
}

/// A task with the days in the period it is due on.
typedef CareSheetTask = ({DueTask task, String name, List<DateTime> days});

DateTime _day(DateTime t) {
  final l = t.toLocal();
  return DateTime(l.year, l.month, l.day);
}

/// Which task is due on which day between [from] and [to] (both inclusive,
/// local days): from the next due date on, every interval – anything
/// overdue before the period is due on its first day. Paused tasks (winter
/// rest) are left out.
List<CareSheetTask> careSheetPlan(List<DueTask> due, DateTime from, DateTime to) {
  final first = _day(from), last = _day(to);
  final out = <CareSheetTask>[];
  for (final t in due) {
    final next = t.nextDue;
    if (next == null || !t.schedule.active) continue;
    final step = t.schedule.intervalDays.round().clamp(1, 3650);
    var d = _day(next);
    if (d.isBefore(first)) d = first;
    final days = <DateTime>[];
    while (!d.isAfter(last)) {
      days.add(d);
      d = DateTime(d.year, d.month, d.day + step);
    }
    out.add((
      task: t,
      name: t.schedule.taskType == 'custom'
          ? t.schedule.title ?? tr('Aufgabe')
          : S.taskNames[t.schedule.taskType] ?? t.schedule.taskType,
      days: days,
    ));
  }
  return out;
}

String _every(double days) {
  final n = days.round();
  return n <= 1 ? tr('täglich') : tr('alle {0} Tage', [n]);
}

const _green = PdfColor.fromInt(0xFF4E7D3A);
const _muted = PdfColor.fromInt(0xFF6B6F6A);
const _grid = PdfColor.fromInt(0xFFB9BCB6);
const _shade = PdfColor.fromInt(0xFFF1F3EE);

Future<Uint8List> buildCareSheet({
  required List<CareSheetColony> colonies,
  required DateTime from,
  required DateTime to,
  String instructions = '',
  String contact = '',
  String? author,
  required DateTime now,
  LabelFonts? fonts,
}) async {
  final f = fonts ?? await LabelFonts.load();
  final doc = pw.Document(
    title: tr('Pflegezettel'),
    author: author,
    creator: tr('Ant Colony Manager'),
    theme: pw.ThemeData.withFont(base: f.regular, bold: f.bold, italic: f.italic),
  );
  final lang = currentLanguage;
  final dayFmt = DateFormat(lang == 'de' ? 'EE dd.MM.' : 'EEE d MMM', lang);
  final small = pw.TextStyle(fontSize: 8, color: _muted);
  final period = '${S.date(from)} – ${S.date(to)}';

  pw.Widget box(bool due) => pw.Center(
    child: due
        ? pw.Container(width: 9, height: 9, decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.8)))
        : pw.Text('–', style: small),
  );

  pw.Widget colonySection(CareSheetColony c) {
    final plan = careSheetPlan(c.due, from, to);
    final days = {for (final t in plan) ...t.days}.toList()..sort();
    final col = c.colony;
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(height: 14),
        pw.Text(
          '${col.name}  (#${col.number})',
          style: pw.TextStyle(font: f.bold, fontSize: 13, color: _green),
        ),
        pw.Text(
          [if (col.species.isNotEmpty) col.species, if (col.locationPath != null) col.locationPath!].join(' · '),
          style: small,
        ),
        if (c.instructions.trim().isNotEmpty)
          pw.Padding(padding: const pw.EdgeInsets.only(top: 4), child: pw.Text(c.instructions.trim())),
        pw.SizedBox(height: 6),
        if (plan.isEmpty)
          pw.Text(tr('Keine regelmäßigen Aufgaben – nur nachsehen, ob alles in Ordnung ist.'), style: small)
        else ...[
          pw.Wrap(
            spacing: 12,
            children: [
              for (final t in plan) pw.Text('${t.name}: ${_every(t.task.schedule.intervalDays)}', style: small),
            ],
          ),
          pw.SizedBox(height: 4),
          if (days.isEmpty)
            pw.Text(tr('In diesem Zeitraum ist nichts fällig.'), style: small)
          else
            pw.Table(
              border: pw.TableBorder.all(color: _grid, width: 0.5),
              columnWidths: {
                0: const pw.FixedColumnWidth(62),
                for (var i = 0; i < plan.length; i++) i + 1: const pw.FixedColumnWidth(66),
                plan.length + 1: const pw.FlexColumnWidth(),
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: _shade),
                  children: [
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(3),
                      child: pw.Text(tr('Datum'), style: small),
                    ),
                    for (final t in plan)
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(3),
                        child: pw.Text(t.name, style: small, textAlign: pw.TextAlign.center),
                      ),
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(3),
                      child: pw.Text(tr('Notiz'), style: small),
                    ),
                  ],
                ),
                for (final d in days)
                  pw.TableRow(
                    verticalAlignment: pw.TableCellVerticalAlignment.middle,
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                        child: pw.Text(dayFmt.format(d), style: const pw.TextStyle(fontSize: 9)),
                      ),
                      for (final t in plan) box(t.days.contains(d)),
                      pw.SizedBox(height: 16),
                    ],
                  ),
              ],
            ),
        ],
      ],
    );
  }

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 36, 36, 36),
      footer: (ctx) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(tr('Erstellt am {0} mit Ant Colony Manager', [S.date(now)]), style: small),
          pw.Text('${ctx.pageNumber}/${ctx.pagesCount}', style: small),
        ],
      ),
      build: (ctx) => [
        pw.Text(tr('Pflegezettel'), style: pw.TextStyle(font: f.bold, fontSize: 20)),
        pw.Text(
          [
            period,
            if (author != null && author.isNotEmpty) tr('von {0}', [author]),
          ].join(' · '),
          style: const pw.TextStyle(fontSize: 11),
        ),
        if (contact.trim().isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 6),
            child: pw.Text(
              tr('Bei Fragen oder Problemen: {0}', [contact.trim()]),
              style: pw.TextStyle(font: f.bold, fontSize: 10),
            ),
          ),
        if (instructions.trim().isNotEmpty)
          pw.Container(
            margin: const pw.EdgeInsets.only(top: 10),
            padding: const pw.EdgeInsets.all(8),
            decoration: const pw.BoxDecoration(color: _shade),
            child: pw.Text(instructions.trim()),
          ),
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 8),
          child: pw.Text(
            tr(
              'Kästchen = an diesem Tag zu tun, nach dem Erledigen abhaken. Auffälligkeiten bitte bei „Notiz“ eintragen.',
            ),
            style: small,
          ),
        ),
        for (final c in colonies) colonySection(c),
      ],
    ),
  );
  return doc.save();
}
