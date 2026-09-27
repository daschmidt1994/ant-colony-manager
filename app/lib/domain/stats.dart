/// Statistics per colony (spec §32) and for the whole collection (§33).
/// Computed from the local database – available offline, no server query.
library;

import 'due.dart';
import 'models.dart';

enum StatsRange {
  week('7 T', 7),
  month('30 T', 30),
  quarter('3 M', 91),
  year('1 J', 365),
  all('Gesamt', null);

  const StatsRange(this.label, this.days);
  final String label;
  final int? days;
}

/// Time buckets of a chart: days for short ranges, weeks for 3 months,
/// months for a year and the whole time.
class Buckets {
  Buckets._(this.starts, this.unit);
  final List<DateTime> starts; // local midnight / Monday / 1st of month
  final BucketUnit unit;

  DateTime get from => starts.first;

  /// Index of the bucket containing [t], or null if outside.
  int? indexOf(DateTime t) {
    final l = t.toLocal();
    if (l.isBefore(starts.first)) return null;
    for (var i = starts.length - 1; i >= 0; i--) {
      if (!l.isBefore(starts[i])) return i;
    }
    return null;
  }

  factory Buckets.of(StatsRange range, DateTime now, {DateTime? firstEvent}) {
    final today = DateTime(now.toLocal().year, now.toLocal().month, now.toLocal().day);
    switch (range) {
      case StatsRange.week || StatsRange.month:
        final n = range.days!;
        return Buckets._([
          for (var i = n - 1; i >= 0; i--) DateTime(today.year, today.month, today.day - i),
        ], BucketUnit.day);
      case StatsRange.quarter:
        final monday = DateTime(today.year, today.month, today.day - (today.weekday - 1));
        return Buckets._([
          for (var i = 12; i >= 0; i--) DateTime(monday.year, monday.month, monday.day - 7 * i),
        ], BucketUnit.week);
      case StatsRange.year:
        return Buckets._([for (var i = 11; i >= 0; i--) DateTime(today.year, today.month - i)], BucketUnit.month);
      case StatsRange.all:
        final f = (firstEvent ?? now).toLocal();
        var months = (today.year - f.year) * 12 + today.month - f.month + 1;
        months = months.clamp(1, 240);
        return Buckets._([
          for (var i = months - 1; i >= 0; i--) DateTime(today.year, today.month - i),
        ], BucketUnit.month);
    }
  }
}

enum BucketUnit { day, week, month }

class CareBucket {
  int protein = 0, carbohydrate = 0, otherFeeding = 0, water = 0, cleaning = 0;
  int get feedings => protein + carbohydrate + otherFeeding;
}

class Point {
  const Point(this.at, this.value, [this.max]);
  final DateTime at;
  final double value;

  /// Upper end of a range (worker estimate „500–1.000“); null = exact or open.
  final double? max;
}

/// Brood level as a number for charts (exact counts are shown as they are).
const broodLevels = {'none': 0.0, 'few': 1.0, 'medium': 2.0, 'many': 3.0};
const broodStages = ['eggs', 'larvae', 'pupae', 'naked_pupae', 'alates'];

class ColonyStats {
  ColonyStats({
    required this.buckets,
    required this.care,
    required this.workers,
    required this.temperature,
    required this.humidity,
    required this.brood,
    required this.accepted,
    required this.rated,
  });
  final Buckets buckets;
  final List<CareBucket> care;
  final List<Point> workers, temperature, humidity;
  final Map<String, List<Point>> brood; // stage → levels over time

  /// Feedings with a known acceptance, and how many of them were accepted (fully or partly).
  final int accepted, rated;

  int get feedings => care.fold(0, (s, b) => s + b.feedings);
  int get protein => care.fold(0, (s, b) => s + b.protein);
  int get carbohydrate => care.fold(0, (s, b) => s + b.carbohydrate);
  int get water => care.fold(0, (s, b) => s + b.water);
  int get cleaning => care.fold(0, (s, b) => s + b.cleaning);
}

ColonyStats colonyStats(List<ColonyEvent> events, StatsRange range, DateTime now) {
  final first = events.isEmpty ? null : events.map((e) => e.occurredAt).reduce((a, b) => a.isBefore(b) ? a : b);
  final buckets = Buckets.of(range, now, firstEvent: first);
  final care = [for (final _ in buckets.starts) CareBucket()];
  final workers = <Point>[], temperature = <Point>[], humidity = <Point>[];
  final brood = <String, List<Point>>{};
  var accepted = 0, rated = 0;
  final from = buckets.from;

  // Growth: the last known size before the range is the starting point of the line.
  Point? before;
  for (final e in events.reversed) {
    // events are newest first → reversed = chronological
    final c = e.census;
    if (c == null) continue;
    final exact = (c['exact_count'] as num?)?.toDouble();
    final min = (c['estimate_min'] as num?)?.toDouble();
    final max = (c['estimate_max'] as num?)?.toDouble();
    final p = exact != null ? Point(e.occurredAt, exact) : (min != null ? Point(e.occurredAt, min, max) : null);
    if (p == null) continue;
    if (e.occurredAt.toLocal().isBefore(from)) {
      before = p;
    } else {
      workers.add(p);
    }
  }
  if (before != null) workers.insert(0, Point(from, before.value, before.max));

  for (final e in events) {
    final at = e.occurredAt;
    if (at.toLocal().isBefore(from)) continue;
    final i = buckets.indexOf(at);
    if (i != null) {
      final b = care[i];
      switch (e.type) {
        case 'feeding':
          final cats = e.items.map((x) => x.category).toSet();
          if (cats.contains('protein')) b.protein++;
          if (cats.contains('carbohydrate')) b.carbohydrate++;
          if (!cats.contains('protein') && !cats.contains('carbohydrate')) b.otherFeeding++;
          if (e.acceptance != 'unknown') {
            rated++;
            if (e.acceptance == 'accepted' || e.acceptance == 'partial') accepted++;
          }
        case 'water':
          b.water++;
        case 'cleaning':
          b.cleaning++;
      }
    }
    for (final m in e.measurements) {
      final v = (m['value'] as num?)?.toDouble();
      if (v == null) continue;
      (m['metric'] == 'temperature' ? temperature : humidity).add(Point(at, v));
    }
    for (final s in ((e.json['brood'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      final v = (s['exact_count'] as num?)?.toDouble() ?? broodLevels[s['level']];
      if (v != null) (brood[s['stage'] as String] ??= []).add(Point(at, v));
    }
  }
  int byTime(Point a, Point b) => a.at.compareTo(b.at);
  temperature.sort(byTime);
  humidity.sort(byTime);
  for (final l in brood.values) {
    l.sort(byTime);
  }
  return ColonyStats(
    buckets: buckets,
    care: care,
    workers: workers,
    temperature: temperature,
    humidity: humidity,
    brood: brood,
    accepted: accepted,
    rated: rated,
  );
}

// -----------------------------------------------------------------------------
// Whole collection

class GlobalStats {
  GlobalStats({
    required this.colonies,
    required this.species,
    required this.genera,
    required this.workersMin,
    required this.workersMax,
    required this.workersUnknown,
    required this.feedingsWeek,
    required this.feedingsMonth,
    required this.overdueTasks,
    required this.hibernating,
    required this.bySpecies,
    required this.byGenus,
    required this.byLocation,
  });
  final int colonies, species, genera;

  /// Sum of the worker estimates; [workersMax] is null if one range is open („10.000+“).
  final int workersMin;
  final int? workersMax;

  /// Colonies without any size information.
  final int workersUnknown;
  final int feedingsWeek, feedingsMonth, overdueTasks, hibernating;

  /// Sorted, largest first.
  final List<MapEntry<String, int>> bySpecies, byGenus, byLocation;
}

/// [feedingTimes]: time of every feeding (any colony).
GlobalStats globalStats({
  required List<Colony> colonies,
  required Map<String, String> genusOfSpecies,
  required Map<String, List<DueTask>> due,
  required List<DateTime> feedingTimes,
  required DateTime now,
}) {
  // The living collection: not archived, not given away, sold or deceased.
  final active = colonies
      .where((c) => !c.archived && const {'founding', 'active', 'hibernating', 'paused'}.contains(c.status))
      .toList();
  List<MapEntry<String, int>> count(Iterable<String> keys) {
    final m = <String, int>{};
    for (final k in keys) {
      m[k] = (m[k] ?? 0) + 1;
    }
    return m.entries.toList()..sort((a, b) => b.value != a.value ? b.value.compareTo(a.value) : a.key.compareTo(b.key));
  }

  String genus(Colony c) {
    final g = c.speciesId == null ? null : genusOfSpecies[c.speciesId];
    if (g != null && g.isNotEmpty) return g;
    final s = c.species.trim();
    return s.isEmpty ? 'unbekannt' : s.split(RegExp(r'\s+')).first;
  }

  var min = 0, unknown = 0;
  int? max = 0;
  for (final c in active) {
    if (c.workerMin == null) {
      unknown++;
      continue;
    }
    min += c.workerMin!;
    max = (max == null || c.workerMax == null) ? null : max + c.workerMax!;
  }
  final l = now.toLocal();
  final weekStart = DateTime(l.year, l.month, l.day - (l.weekday - 1));
  final monthStart = DateTime(l.year, l.month);
  final species = count(active.map((c) => c.species.isEmpty ? 'unbekannt' : c.species));
  final genera = count(active.map(genus));
  return GlobalStats(
    colonies: active.length,
    species: species.where((e) => e.key != 'unbekannt').length,
    genera: genera.where((e) => e.key != 'unbekannt').length,
    workersMin: min,
    workersMax: max,
    workersUnknown: unknown,
    feedingsWeek: feedingTimes.where((t) => !t.toLocal().isBefore(weekStart)).length,
    feedingsMonth: feedingTimes.where((t) => !t.toLocal().isBefore(monthStart)).length,
    overdueTasks: due.values.expand((t) => t).where((t) => t.status == DueStatus.overdue).length,
    hibernating: active.where((c) => c.status == 'hibernating').length,
    bySpecies: species,
    byGenus: genera,
    byLocation: count(active.map((c) => c.locationPath ?? 'ohne Standort')),
  );
}
