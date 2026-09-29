import 'models.dart';

/// Worker count known at [t]: the last census on or before it (exact count,
/// else the estimate range). [events] may be in any order.
({int min, int? max, DateTime at})? workersAt(List<ColonyEvent> events, DateTime t) {
  ColonyEvent? best;
  for (final e in events) {
    final c = e.census;
    if (c == null || e.occurredAt.isAfter(t)) continue;
    if (c['exact_count'] == null && c['estimate_min'] == null) continue;
    if (best == null || e.occurredAt.isAfter(best.occurredAt)) best = e;
  }
  if (best == null) return null;
  final c = best.census!;
  final exact = (c['exact_count'] as num?)?.toInt();
  if (exact != null) return (min: exact, max: exact, at: best.occurredAt);
  return (min: (c['estimate_min'] as num).toInt(), max: (c['estimate_max'] as num?)?.toInt(), at: best.occurredAt);
}

/// „1 Jahr 3 Monate“-style distance in whole months and remaining days.
({int years, int months, int days}) timeBetween(DateTime a, DateTime b) {
  var from = a.isBefore(b) ? a : b;
  final to = a.isBefore(b) ? b : a;
  var months = (to.year - from.year) * 12 + to.month - from.month;
  if (DateTime(from.year, from.month + months, from.day).isAfter(to)) months--;
  from = DateTime(from.year, from.month + months, from.day);
  return (years: months ~/ 12, months: months % 12, days: to.difference(from).inDays);
}
