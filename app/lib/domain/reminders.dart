/// Which reminders to show – pure logic, the Android side only displays the
/// result (docs/02 „Erinnerungen ohne Push-Dienst“, docs/13 F8).
library;

import 'dart:convert';

import 'due.dart';
import 'models.dart';

/// One notification. [key] identifies the reason (e.g. this schedule being
/// overdue since this date) – shown once, not every time the check runs.
class Reminder {
  const Reminder({
    required this.key,
    required this.slot,
    required this.title,
    required this.body,
    required this.payload,
    this.canComplete = false,
  });
  final String key;

  /// Stable per subject (schedule, task …): a newer reminder replaces the old one.
  final String slot;
  final String title, body;
  final Map<String, dynamic> payload;

  /// Offer „Erledigt“ (one tap documents the care without opening the app).
  final bool canComplete;

  String get payloadJson => jsonEncode(payload);
}

class Digest {
  const Digest({required this.title, required this.body});
  final String title, body;
}

/// Singles for everything overdue (if enabled), planned winter rests to start,
/// winter rests past their planned end and open one-off tasks.
List<Reminder> overdueReminders({
  required List<Colony> colonies,
  required Map<String, List<DueTask>> due,
  required Set<String> readOnlyColonies,
  required List<Map<String, dynamic>> winterRests,
  required List<Map<String, dynamic>> tasks,
  required DateTime now,
  required bool notifyOverdue,
  List<Map<String, dynamic>> sensorProblems = const [],
  List<Map<String, dynamic>> sensors = const [],
}) {
  final byId = {for (final c in colonies) c.id: c};
  final out = <Reminder>[];
  String titleOf(Colony c) => c.species.isNotEmpty && c.species != c.name ? '${c.species} – ${c.name}' : c.name;

  if (notifyOverdue) {
    for (final c in colonies) {
      if (!c.isCareActive || readOnlyColonies.contains(c.id)) continue;
      for (final t in due[c.id] ?? const <DueTask>[]) {
        if (t.status != DueStatus.overdue) continue;
        final s = t.schedule;
        final name = s.taskType == 'custom' ? (s.title ?? 'Aufgabe') : _taskLong[s.taskType] ?? s.taskType;
        final since = -t.days;
        out.add(
          Reminder(
            key: 'due:${s.id}:${t.nextDue!.toUtc().toIso8601String().substring(0, 10)}',
            slot: 'due:${s.id}',
            title: titleOf(c),
            body: '$name seit ${since == 1 ? '1 Tag' : '$since Tagen'} überfällig.',
            payload: {'kind': 'due', 'colony': c.id, 'schedule': s.id, 'task_type': s.taskType},
            canComplete: true,
          ),
        );
      }
    }
  }

  final today = _date(now);
  for (final w in winterRests) {
    final c = byId[w['colony_id']];
    if (w['ended_on'] != null || c == null) continue;
    if (w['started_on'] == null) {
      final start = w['planned_start_on'] as String?;
      if (start == null || start.compareTo(today) > 0) continue;
      out.add(
        Reminder(
          key: 'winter_start:${w['id']}:$start',
          slot: 'winter:${w['id']}',
          title: titleOf(c),
          body: 'Winterruhe beginnen? Der geplante Start ist erreicht.',
          payload: {'kind': 'winter_start', 'colony': c.id},
        ),
      );
      continue;
    }
    final end = w['planned_end_on'] as String?;
    if (end == null || end.compareTo(today) > 0) continue;
    out.add(
      Reminder(
        key: 'winter:${w['id']}:$end',
        slot: 'winter:${w['id']}',
        title: titleOf(c),
        body: 'Winterruhe beenden? Das geplante Ende ist erreicht.',
        payload: {'kind': 'winter', 'colony': c.id},
      ),
    );
  }

  for (final t in tasks) {
    final at = DateTime.tryParse(t['due_at'] as String? ?? '');
    if (at == null || t['done_at'] != null || at.isAfter(now)) continue;
    final c = byId[t['colony_id']];
    out.add(
      Reminder(
        key: 'task:${t['id']}:${t['due_at']}',
        slot: 'task:${t['id']}',
        title: c == null ? 'Aufgabe' : titleOf(c),
        body: '${t['title'] ?? 'Aufgabe'} ist fällig.',
        payload: {'kind': 'task', 'colony': ?c?.id, 'task': t['id']},
        canComplete: true,
      ),
    );
  }

  // Automations: limits exceeded (the server wrote a „problem“ entry) …
  for (final e in sensorProblems) {
    final at = DateTime.tryParse(e['occurred_at'] as String? ?? '');
    final c = byId[e['colony_id']];
    if (at == null || c == null || now.difference(at) > const Duration(hours: 24)) continue;
    out.add(
      Reminder(
        key: 'alert:${e['id']}',
        slot: 'alert:${e['id']}',
        title: '⚠ ${titleOf(c)}',
        body: e['note'] as String? ?? 'Sensor-Grenzwert überschritten',
        payload: {'kind': 'problem', 'colony': c.id},
      ),
    );
  }
  // … and sensors that went silent.
  for (final s in sensors) {
    final seen = DateTime.tryParse(s['last_seen_at'] as String? ?? '');
    if (seen == null || s['active'] == false) continue;
    final silent = now.difference(seen);
    if (silent < sensorSilentAfter) continue;
    out.add(
      Reminder(
        key: 'silent:${s['id']}:${s['last_seen_at']}',
        slot: 'silent:${s['id']}',
        title: 'Sensor „${s['name'] ?? 'Sensor'}“',
        body:
            'Sendet seit ${silent.inHours < 48 ? '${silent.inHours} Stunden' : '${silent.inDays} Tagen'} keine Daten – Stromversorgung oder WLAN prüfen.',
        payload: {'kind': 'sensor', 'sensor': s['id']},
      ),
    );
  }
  return out;
}

/// A sensor that sent nothing for this long is reported.
const sensorSilentAfter = Duration(hours: 6);

/// „7 Kolonien brauchen heute Aufmerksamkeit (3 überfällig)“ – null if nothing is due.
Digest? digestFor(Map<String, List<DueTask>> due, {int winterEnds = 0, int winterStarts = 0}) {
  var attention = 0, overdue = 0;
  for (final tasks in due.values) {
    final w = worstOf(tasks);
    if (w == null || w.days > 0) continue;
    attention++;
    if (w.days < 0) overdue++;
  }
  if (attention == 0 && winterEnds == 0 && winterStarts == 0) return null;
  final parts = <String>[
    if (attention > 0)
      '${attention == 1 ? '1 Kolonie braucht' : '$attention Kolonien brauchen'} heute Aufmerksamkeit'
          '${overdue > 0 ? ' ($overdue überfällig)' : ''}',
    if (winterStarts > 0) '$winterStarts× Winterruhe beginnen?',
    if (winterEnds > 0) '$winterEnds× Winterruhe beenden?',
  ];
  return Digest(title: 'Pflege heute', body: parts.join(' · '));
}

/// Stable 31-bit notification id for a slot (Android ids are ints).
int notificationId(String slot) {
  var h = 0x811c9dc5;
  for (final c in slot.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0x7fffffff;
  }
  return h == 0 ? 1 : h;
}

const _taskLong = {
  'protein': 'Proteinfütterung',
  'carbohydrate': 'Kohlenhydratfütterung',
  'feeding': 'Fütterung',
  'water': 'Wasser',
  'cleaning': 'Reinigung',
  'check': 'Kontrolle',
};

String _date(DateTime t) {
  final l = t.toLocal();
  return '${l.year.toString().padLeft(4, '0')}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
}
