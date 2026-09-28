import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../core/session.dart';
import '../../data/local/database.dart';
import '../../data/repositories/colony_repository.dart';
import '../../data/sync/background_sync_native.dart';
import '../../domain/reminders.dart';
import 'reminder_actions.dart';

typedef ReminderTap = void Function(String? actionId, String? payload);

final _plugin = FlutterLocalNotificationsPlugin();
bool _ready = false;
const _shownKey = 'reminders_shown';
const _groupKey = 'at.antcolony.manager.due';
final _digestId = notificationId('digest');
final _summaryId = notificationId('summary');

const _dueDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'due',
    'Überfällige Pflege',
    channelDescription: 'Eine Benachrichtigung pro überfälliger Aufgabe – mit „Erledigt“',
    category: AndroidNotificationCategory.reminder,
    groupKey: _groupKey,
    actions: [
      AndroidNotificationAction('done', 'Erledigt'),
      AndroidNotificationAction('snooze', 'Morgen'),
      AndroidNotificationAction('open', 'Öffnen', showsUserInterface: true),
    ],
  ),
);

/// Winter rest plan: no „Erledigt“ (the switch is in the app), but „Morgen“.
const _snoozeDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'due',
    'Überfällige Pflege',
    channelDescription: 'Eine Benachrichtigung pro überfälliger Aufgabe – mit „Erledigt“',
    category: AndroidNotificationCategory.reminder,
    groupKey: _groupKey,
    actions: [
      AndroidNotificationAction('snooze', 'Morgen'),
      AndroidNotificationAction('open', 'Öffnen', showsUserInterface: true),
    ],
  ),
);

const _infoDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'due',
    'Überfällige Pflege',
    channelDescription: 'Eine Benachrichtigung pro überfälliger Aufgabe – mit „Erledigt“',
    category: AndroidNotificationCategory.reminder,
    groupKey: _groupKey,
  ),
);

const _summaryDetails = NotificationDetails(
  android: AndroidNotificationDetails('due', 'Überfällige Pflege', groupKey: _groupKey, setAsGroupSummary: true),
);

const _digestDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'digest',
    'Tages-Überblick',
    channelDescription: 'Einmal täglich: was heute ansteht',
    category: AndroidNotificationCategory.reminder,
  ),
);

bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Future<void> _init({ReminderTap? onTap}) async {
  if (_ready || !_android) return;
  tzdata.initializeTimeZones();
  await _plugin.initialize(
    settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    onDidReceiveNotificationResponse: onTap == null ? null : (r) => onTap(r.actionId, r.payload),
    onDidReceiveBackgroundNotificationResponse: reminderActionInBackground,
  );
  _ready = true;
}

/// Called once by the running app; [onTap] handles taps and „Kolonie öffnen“.
Future<void> initReminders(ReminderTap onTap) => _init(onTap: onTap);

Future<({String? actionId, String? payload})?> reminderThatLaunchedApp() async {
  if (!_android) return null;
  await _init();
  final d = await _plugin.getNotificationAppLaunchDetails();
  final r = d?.notificationResponse;
  return d?.didNotificationLaunchApp == true && r != null ? (actionId: r.actionId, payload: r.payload) : null;
}

/// Android 13+: asks for the notification permission.
Future<bool> requestReminderPermission() async {
  if (!_android) return false;
  await _init();
  final impl = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  return await impl?.requestNotificationsPermission() ?? false;
}

/// Brings the notifications in line with the local data: new overdue care
/// is shown once, done care disappears, and the daily overview is scheduled
/// for the next digest time with what will be due then. Runs after every
/// sync, when the app comes back, and hourly in the background – offline too.
Future<void> syncReminders(ColonyRepository repo) async {
  if (!_android) return;
  await _init();
  final db = repo.db;
  final shown = ((jsonDecode(db.getMeta(_shownKey) ?? '{}') as Map).cast<String, String>());
  final list = repo.reminders();
  final active = {for (final r in list) r.slot: r};

  for (final slot in shown.keys.where((s) => !active.containsKey(s)).toList()) {
    await _plugin.cancel(id: notificationId(slot));
    shown.remove(slot);
  }
  var posted = 0;
  for (final r in list) {
    if (shown[r.slot] == r.key || posted >= 10) continue; // once per reason; no flood
    await _plugin.show(
      id: notificationId(r.slot),
      title: r.title,
      body: r.body,
      notificationDetails: r.canComplete
          ? _dueDetails
          : r.canSnooze
          ? _snoozeDetails
          : _infoDetails,
      payload: r.payloadJson,
    );
    shown[r.slot] = r.key;
    posted++;
  }
  if (shown.length > 1) {
    await _plugin.show(
      id: _summaryId,
      title: 'Pflege überfällig',
      body: '${shown.length} Aufgaben',
      notificationDetails: _summaryDetails,
    );
  } else {
    await _plugin.cancel(id: _summaryId);
  }
  db.setMeta(_shownKey, jsonEncode(shown));
  await _scheduleDigest(repo);
}

Future<void> _scheduleDigest(ColonyRepository repo) async {
  final settings = repo.settings();
  tz.Location loc;
  try {
    loc = tz.getLocation(settings.timezone);
  } on Exception {
    loc = tz.UTC;
  }
  final now = tz.TZDateTime.now(loc);
  if (!settings.notifyDigestApp) {
    await _plugin.cancel(id: _digestId);
    return;
  }
  final (h, m) = settings.digestTime;
  var at = tz.TZDateTime(loc, now.year, now.month, now.day, h, m);
  if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
  // What will be due at that moment – due dates are pure date arithmetic.
  final then = ColonyRepository(repo.db, userId: repo.userId, onChanged: () {}, clock: () => at);
  final d = digestFor(then.dueAll(), winterEnds: then.winterEndsDue(), winterStarts: then.winterStartsDue());
  await _plugin.cancel(id: _digestId);
  if (d == null) return;
  await _plugin.zonedSchedule(
    id: _digestId,
    scheduledDate: at,
    notificationDetails: _digestDetails,
    androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    title: d.title,
    body: d.body,
    payload: jsonEncode({'kind': 'digest'}),
  );
}

/// Logout: nothing about the previous account stays on screen.
Future<void> clearReminders() async {
  if (!_android) return;
  await _init();
  await _plugin.cancelAll();
}

/// „Erledigt“ while the app is closed or in the background: Android starts
/// this in a separate isolate. It documents the care directly in the local
/// database (outbox) and tries to send it right away.
@pragma('vm:entry-point')
Future<void> reminderActionInBackground(NotificationResponse r) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final userJson = await SessionStore().read('user');
  if (userJson == null) return;
  final db = await AppDatabase.open();
  try {
    final repo = ColonyRepository(db, userId: User(jsonDecode(userJson) as Map<String, dynamic>).id, onChanged: () {});
    handleReminder(repo, actionId: r.actionId, payload: r.payload);
    await syncReminders(repo);
  } finally {
    db.dispose();
  }
  try {
    await runBackgroundSync();
  } catch (_) {
    // offline – WorkManager sends it later
  }
}
