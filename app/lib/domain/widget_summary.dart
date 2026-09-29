import '../app/i18n.dart';
import '../app/strings.dart';
import 'due.dart';
import 'models.dart';

/// What the home screen widget shows: counts and the most urgent care.
class WidgetSummary {
  const WidgetSummary({required this.overdue, required this.today, required this.lines});
  final int overdue, today;
  final List<String> lines;

  String get headline => overdue == 0 && today == 0
      ? tr('Alles erledigt')
      : [
          if (overdue > 0) tr('{0} überfällig', [overdue]),
          if (today > 0) tr('{0} heute', [today]),
        ].join(' · ');
}

/// Overdue and due-today care of colonies in care (not view-only), most
/// urgent first; at most [maxLines] lines „Colony · Task · 2 days overdue“.
WidgetSummary widgetSummary({
  required List<Colony> colonies,
  required Map<String, List<DueTask>> due,
  required Set<String> readOnlyColonies,
  int maxLines = 4,
}) {
  var overdue = 0, today = 0;
  final items = <(int, String)>[];
  for (final c in colonies) {
    if (!c.isCareActive || readOnlyColonies.contains(c.id)) continue;
    for (final t in due[c.id] ?? const <DueTask>[]) {
      if (t.status == DueStatus.paused || t.days > 0) continue;
      if (t.days < 0) {
        overdue++;
      } else {
        today++;
      }
      final s = t.schedule;
      final task = s.taskType == 'custom' ? (s.title ?? tr('Aufgabe')) : S.taskNames[s.taskType] ?? s.taskType;
      items.add((t.days, '${c.name} · $task · ${S.dueText(t)}'));
    }
  }
  items.sort((a, b) => a.$1.compareTo(b.$1));
  return WidgetSummary(overdue: overdue, today: today, lines: [for (final i in items.take(maxLines)) i.$2]);
}
