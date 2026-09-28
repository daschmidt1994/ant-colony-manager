import 'dart:convert';

import '../../data/repositories/colony_repository.dart';

/// What a tap on a reminder does. Returns the route to open, or null when
/// nothing needs to be shown (the care was documented in the background).
String? handleReminder(ColonyRepository repo, {String? actionId, String? payload}) {
  final p = payload == null ? const <String, dynamic>{} : (jsonDecode(payload) as Map).cast<String, dynamic>();
  final colony = p['colony'] as String?;
  final open = colony == null || repo.colony(colony) == null ? '/' : '/colonies/$colony';
  if (actionId == 'snooze') {
    switch (p['kind']) {
      case 'due' when p['schedule'] is String:
        repo.snoozeSchedule(p['schedule'] as String);
        return null;
      case 'task' when p['task'] is String:
        repo.snoozeTask(p['task'] as String);
        return null;
      case 'winter' || 'winter_start' when colony != null:
        repo.snoozeWinter(colony);
        return null;
    }
  }
  if (actionId == 'done') {
    switch (p['kind']) {
      case 'due' when colony != null && repo.colony(colony) != null:
        final e = repo.completeDue(colony, p['task_type'] as String, scheduleId: p['schedule'] as String?);
        return e == null ? open : null; // nothing to repeat yet → open the colony
      case 'task':
        repo.completeTask(p['task'] as String);
        return null;
    }
  }
  return switch (p['kind']) {
    'digest' => '/',
    'sensor' => '/settings/sensors',
    _ => open,
  };
}
