/// Due dates and traffic light – the Dart twin of the server's
/// `service.Classify` and the `care_due` SQL view. Both are checked against
/// `test-vectors/due.json`.
library;

enum DueStatus { overdue, soon, ok, paused }

enum DueGroup { overdue, today, tomorrow, thisWeek, later, paused }

/// Calendar date in the user's time zone.
typedef LocalDate = ({int year, int month, int day});

typedef ToLocalDate = LocalDate Function(DateTime utc);

LocalDate deviceLocalDate(DateTime t) {
  final l = t.toLocal();
  return (year: l.year, month: l.month, day: l.day);
}

int calendarDays(LocalDate from, LocalDate to) =>
    DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

class Classification {
  const Classification(this.status, this.group, this.days);
  final DueStatus status;
  final DueGroup group;

  /// Calendar days until due (negative = overdue).
  final int days;
}

Classification classify(DateTime? next, DateTime now, {int soonDays = 1, ToLocalDate toLocal = deviceLocalDate}) {
  if (next == null) return const Classification(DueStatus.paused, DueGroup.paused, 0);
  final days = calendarDays(toLocal(now), toLocal(next));
  final status = days < 0 ? DueStatus.overdue : (days <= soonDays ? DueStatus.soon : DueStatus.ok);
  final group = switch (days) {
    < 0 => DueGroup.overdue,
    0 => DueGroup.today,
    1 => DueGroup.tomorrow,
    <= 6 => DueGroup.thisWeek,
    _ => DueGroup.later,
  };
  return Classification(status, group, days);
}

/// A care schedule of a colony (server entity `care_schedules`).
class Schedule {
  Schedule({
    required this.id,
    required this.colonyId,
    required this.taskType,
    required this.intervalDays,
    required this.startsAt,
    this.title,
    this.active = true,
    this.winterMode,
    this.snoozedUntil,
  });

  factory Schedule.fromJson(Map<String, dynamic> j) => Schedule(
    id: j['id'] as String,
    colonyId: j['colony_id'] as String,
    taskType: j['task_type'] as String,
    intervalDays: (j['interval_days'] as num).toDouble(),
    startsAt: DateTime.parse(j['starts_at'] as String),
    title: j['title'] as String?,
    active: j['active'] as bool? ?? true,
    winterMode: j['winter_mode'] as String?,
    snoozedUntil: DateTime.tryParse(j['snoozed_until'] as String? ?? ''),
  );

  final String id;
  final String colonyId;
  final String taskType; // protein | carbohydrate | feeding | water | cleaning | check | custom
  final double intervalDays;
  final DateTime startsAt;
  final String? title;
  final bool active;
  final String? winterMode; // pause | scale | keep | null (= winter rest setting)

  /// „Morgen“: not due before this instant (even if the interval says so).
  final DateTime? snoozedUntil;
}

/// Open winter rest of a colony.
class WinterRestInfo {
  const WinterRestInfo({required this.mode, required this.factor});
  final String mode; // pause | scale | keep
  final double factor;
}

/// Last time each kind of care happened for a colony (from the local DB).
class LastCare {
  const LastCare({
    this.feeding,
    this.protein,
    this.carbohydrate,
    this.water,
    this.cleaning,
    this.check,
    this.bySchedule = const {},
  });
  final DateTime? feeding, protein, carbohydrate, water, cleaning, check;
  final Map<String, DateTime> bySchedule;

  DateTime? forSchedule(Schedule s) => switch (s.taskType) {
    'feeding' => feeding,
    'protein' => protein,
    'carbohydrate' => carbohydrate,
    'water' => water,
    'cleaning' => cleaning,
    'check' => check,
    _ => bySchedule[s.id],
  };
}

class DueTask {
  DueTask({required this.schedule, required this.lastDone, required this.nextDue, required this.classification});
  final Schedule schedule;
  final DateTime? lastDone;
  final DateTime? nextDue;
  final Classification classification;

  DueStatus get status => classification.status;
  int get days => classification.days;
}

/// Next due date exactly like the server's care_due view.
DateTime? nextDue(Schedule s, DateTime? last, WinterRestInfo? winter) {
  final mode = s.winterMode ?? winter?.mode;
  if (winter != null && mode == 'pause') return null;
  final factor = (winter != null && mode == 'scale') ? winter.factor : 1.0;
  final base = last ?? s.startsAt;
  final next = base.add(Duration(milliseconds: (s.intervalDays * factor * Duration.millisecondsPerDay).round()));
  final snooze = s.snoozedUntil;
  return snooze != null && snooze.isAfter(next) ? snooze : next;
}

/// Start of the next local day – the target of „Morgen“.
DateTime startOfTomorrow(DateTime now) {
  final l = now.toLocal();
  return DateTime(l.year, l.month, l.day + 1);
}

List<DueTask> computeDue({
  required List<Schedule> schedules,
  required LastCare last,
  WinterRestInfo? winter,
  required DateTime now,
  int soonDays = 1,
  ToLocalDate toLocal = deviceLocalDate,
}) {
  final tasks = <DueTask>[];
  for (final s in schedules.where((s) => s.active)) {
    final l = last.forSchedule(s);
    final n = nextDue(s, l, winter);
    tasks.add(
      DueTask(
        schedule: s,
        lastDone: l,
        nextDue: n,
        classification: classify(n, now, soonDays: soonDays, toLocal: toLocal),
      ),
    );
  }
  tasks.sort((a, b) {
    final pa = a.status == DueStatus.paused, pb = b.status == DueStatus.paused;
    if (pa != pb) return pa ? 1 : -1;
    return a.days.compareTo(b.days);
  });
  return tasks;
}

/// Most urgent (non-paused) task, if any.
DueTask? worstOf(List<DueTask> tasks) => tasks.isEmpty || tasks.first.status == DueStatus.paused ? null : tasks.first;
