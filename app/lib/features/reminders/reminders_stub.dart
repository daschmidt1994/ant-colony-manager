import '../../data/repositories/colony_repository.dart';

typedef ReminderTap = void Function(String? actionId, String? payload);

Future<void> initReminders(ReminderTap onTap) async {}
Future<({String? actionId, String? payload})?> reminderThatLaunchedApp() async => null;
Future<bool> requestReminderPermission() async => false;
Future<void> syncReminders(ColonyRepository repo) async {}
Future<void> clearReminders() async {}
