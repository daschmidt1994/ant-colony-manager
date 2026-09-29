import '../../data/local/database.dart';
import '../../data/repositories/colony_repository.dart';

typedef ReminderTap = void Function(String? actionId, String? payload);

Future<void> initReminders(ReminderTap onTap) async {}
Future<({String? actionId, String? payload})?> reminderThatLaunchedApp() async => null;
Future<bool> requestReminderPermission() async => false;
Future<void> syncReminders(ColonyRepository repo) async {}
Future<void> clearReminders() async {}

class ReminderStatus {
  const ReminderStatus({
    required this.allowed,
    required this.batteryUnrestricted,
    required this.manufacturer,
    this.lastRun,
    this.error,
    this.digestAt,
  });
  final bool allowed;
  final bool? batteryUnrestricted;
  final String manufacturer;
  final DateTime? lastRun, digestAt;
  final String? error;
}

Future<ReminderStatus?> reminderStatus(AppDatabase db) async => null;
Future<void> sendTestReminder() async {}
Future<void> openNotificationSettings() async {}
Future<void> openAppSettings() async {}
