import '../../data/repositories/colony_repository.dart';
import '../../domain/due.dart';
import '../../domain/reminders.dart';

/// Hour of the day at which planned care reminders appear – care becomes
/// overdue at midnight, nobody wants to be woken for it.
const plannedReminderHour = 8;

/// Reminders to hand to Android's alarm clock in advance, so that they
/// appear on time also when the app is closed and background work is
/// suppressed (Xiaomi, Samsung …): for every care that becomes overdue within
/// [days] days, the reminder as it will look at [plannedReminderHour] on its
/// first overdue day. [activeSlots] are shown already. At most [limit].
List<({DateTime at, Reminder reminder})> planCareReminders(
  ColonyRepository repo, {
  required Set<String> activeSlots,
  int days = 7,
  int limit = 30,
}) {
  final now = repo.now();
  final moments = <DateTime>{};
  for (final tasks in repo.dueAll(repo.colonies()).values) {
    for (final t in tasks) {
      if (t.nextDue == null || t.status == DueStatus.overdue || t.status == DueStatus.paused) continue;
      final d = t.nextDue!.toLocal();
      final at = DateTime(d.year, d.month, d.day + 1, plannedReminderHour);
      if (at.isAfter(now) && at.difference(now) <= Duration(days: days + 1)) moments.add(at);
    }
  }
  final out = <({DateTime at, Reminder reminder})>[];
  final planned = <String>{};
  for (final at in moments.toList()..sort()) {
    // the reminders as they will be then – due dates are pure date arithmetic
    final then = ColonyRepository(repo.db, userId: repo.userId, onChanged: () {}, clock: () => at);
    for (final r in then.reminders()) {
      if (!r.key.startsWith('due:') || activeSlots.contains(r.slot) || !planned.add(r.slot)) continue;
      out.add((at: at, reminder: r));
      if (out.length >= limit) return out;
    }
  }
  return out;
}
