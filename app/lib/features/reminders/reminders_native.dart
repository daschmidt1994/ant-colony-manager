import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../core/session.dart';
import '../../data/local/database.dart';
import '../../data/repositories/colony_repository.dart';
import '../../data/sync/background_sync_native.dart';
import '../../domain/reminders.dart';
import '../widget/home_widget.dart';
import 'plan.dart';
import 'reminder_actions.dart';
import '../../app/i18n.dart';

typedef ReminderTap = void Function(String? actionId, String? payload);

final _plugin = FlutterLocalNotificationsPlugin();
const _system = MethodChannel('acm/system');
bool _ready = false;
ReminderTap? _onTap;
const _shownKey = 'reminders_shown';
const _lastRunKey = 'reminders_last_run';
const _errorKey = 'reminders_error';
const _digestAtKey = 'reminders_digest_at';
const _plannedKey = 'reminders_planned'; // slot → "<at ISO>|<key>" handed to the alarm clock
const _groupKey = 'at.antcolony.manager.due';
final _digestId = notificationId('digest');
final _summaryId = notificationId('summary');
const _green = Color(0xFF7DB36F); // app primary – tints the icon

NotificationDetails get _dueDetails => NotificationDetails(
  android: AndroidNotificationDetails(
    'due',
    tr('Überfällige Pflege'),
    channelDescription: tr('Eine Benachrichtigung pro überfälliger Aufgabe – mit „Erledigt“'),
    category: AndroidNotificationCategory.reminder,
    color: _green,
    groupKey: _groupKey,
    actions: [
      AndroidNotificationAction('done', tr('Erledigt')),
      AndroidNotificationAction('snooze', tr('Morgen')),
      AndroidNotificationAction('open', tr('Öffnen'), showsUserInterface: true),
    ],
  ),
);

/// Food culture: „Erledigt“ without „Morgen“.
NotificationDetails get _doneDetails => NotificationDetails(
  android: AndroidNotificationDetails(
    'due',
    tr('Überfällige Pflege'),
    channelDescription: tr('Eine Benachrichtigung pro überfälliger Aufgabe – mit „Erledigt“'),
    category: AndroidNotificationCategory.reminder,
    color: _green,
    groupKey: _groupKey,
    actions: [
      AndroidNotificationAction('done', tr('Erledigt')),
      AndroidNotificationAction('open', tr('Öffnen'), showsUserInterface: true),
    ],
  ),
);

/// Winter rest plan: no „Erledigt“ (the switch is in the app), but „Morgen“.
NotificationDetails get _snoozeDetails => NotificationDetails(
  android: AndroidNotificationDetails(
    'due',
    tr('Überfällige Pflege'),
    channelDescription: tr('Eine Benachrichtigung pro überfälliger Aufgabe – mit „Erledigt“'),
    category: AndroidNotificationCategory.reminder,
    color: _green,
    groupKey: _groupKey,
    actions: [
      AndroidNotificationAction('snooze', tr('Morgen')),
      AndroidNotificationAction('open', tr('Öffnen'), showsUserInterface: true),
    ],
  ),
);

NotificationDetails get _infoDetails => NotificationDetails(
  android: AndroidNotificationDetails(
    'due',
    tr('Überfällige Pflege'),
    channelDescription: tr('Eine Benachrichtigung pro überfälliger Aufgabe – mit „Erledigt“'),
    category: AndroidNotificationCategory.reminder,
    color: _green,
    groupKey: _groupKey,
  ),
);

NotificationDetails get _summaryDetails => NotificationDetails(
  android: AndroidNotificationDetails(
    'due',
    tr('Überfällige Pflege'),
    groupKey: _groupKey,
    setAsGroupSummary: true,
    color: _green,
  ),
);

NotificationDetails get _digestDetails => NotificationDetails(
  android: AndroidNotificationDetails(
    'digest',
    tr('Tages-Überblick'),
    channelDescription: tr('Einmal täglich: was heute ansteht'),
    category: AndroidNotificationCategory.reminder,
    color: _green,
  ),
);

bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Future<void> _init({ReminderTap? onTap}) async {
  if (onTap != null) _onTap = onTap; // the shell is rebuilt on a language switch
  if (_ready || !_android) return;
  tzdata.initializeTimeZones();
  await _plugin.initialize(
    settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_ant')),
    onDidReceiveNotificationResponse: (r) => _onTap?.call(r.actionId, r.payload),
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
/// Time and error of the last run are kept for the diagnostics screen.
Future<void> syncReminders(ColonyRepository repo) async {
  if (!_android) return;
  try {
    await _syncReminders(repo);
    await updateHomeWidget(repo);
    repo.db.setMeta(_errorKey, null);
  } catch (e) {
    repo.db.setMeta(_errorKey, '$e');
    rethrow;
  } finally {
    repo.db.setMeta(_lastRunKey, DateTime.now().toUtc().toIso8601String());
  }
}

Future<void> _syncReminders(ColonyRepository repo) async {
  await _init();
  setLanguage(resolveLanguage(repo.settings().locale)); // also in the background isolate
  final db = repo.db;
  final shown = ((jsonDecode(db.getMeta(_shownKey) ?? '{}') as Map).cast<String, String>());
  final list = repo.reminders();
  final active = {for (final r in list) r.slot: r};

  // Reminders planned last time: those whose time has come were shown by
  // Android (also with the app closed) – count them as shown, so they do not
  // pop up a second time. The others are planned anew below.
  final planned = ((jsonDecode(db.getMeta(_plannedKey) ?? '{}') as Map).cast<String, String>());
  final now = repo.now();
  for (final MapEntry(key: slot, value: v) in planned.entries) {
    final (at, key) = (DateTime.tryParse(v.split('|').first), v.split('|').last);
    if (at != null && !at.isAfter(now)) {
      shown[slot] = key;
    } else {
      await _plugin.cancel(id: notificationId(slot));
    }
  }

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
      notificationDetails: r.canComplete && !r.canSnooze
          ? _doneDetails
          : r.canComplete
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
      title: tr('Pflege überfällig'),
      body: '${shown.length} Aufgaben',
      notificationDetails: _summaryDetails,
    );
  } else {
    await _plugin.cancel(id: _summaryId);
  }
  db.setMeta(_shownKey, jsonEncode(shown));
  await _planAhead(repo, active.keys.toSet());
  await _scheduleDigest(repo);
}

/// Hands the care reminders of the next days to Android's alarm clock – they
/// appear on time also when the app is closed and background work does not
/// run (Xiaomi, Samsung …). Replaced on every run.
Future<void> _planAhead(ColonyRepository repo, Set<String> activeSlots) async {
  final plan = <String, String>{};
  for (final (:at, :reminder) in planCareReminders(repo, activeSlots: activeSlots)) {
    await _plugin.zonedSchedule(
      id: notificationId(reminder.slot), // the same id as when shown live: never twice
      scheduledDate: tz.TZDateTime.from(at, tz.UTC),
      notificationDetails: _dueDetails,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      title: reminder.title,
      body: reminder.body,
      payload: reminder.payloadJson,
    );
    plan[reminder.slot] = '${at.toUtc().toIso8601String()}|${reminder.key}';
  }
  repo.db.setMeta(_plannedKey, jsonEncode(plan));
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
  repo.db.setMeta(_digestAtKey, null);
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
  repo.db.setMeta(_digestAtKey, at.toUtc().toIso8601String());
}

/// What the diagnostics screen shows about notifications on this phone.
class ReminderStatus {
  const ReminderStatus({
    required this.allowed,
    required this.batteryUnrestricted,
    required this.manufacturer,
    this.lastRun,
    this.error,
    this.digestAt,
    this.planned = 0,
    this.nextPlanned,
  });
  final bool allowed;
  final bool? batteryUnrestricted;
  final String manufacturer;
  final DateTime? lastRun, digestAt, nextPlanned;

  /// Care reminders handed to the alarm clock (appear also with the app closed).
  final int planned;
  final String? error;
}

Future<ReminderStatus?> reminderStatus(AppDatabase db) async {
  if (!_android) return null;
  await _init();
  final impl = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  Future<T?> sys<T>(String m) async {
    try {
      return await _system.invokeMethod<T>(m);
    } on Exception {
      return null;
    }
  }

  DateTime? at(String key) => DateTime.tryParse(db.getMeta(key) ?? '')?.toLocal();
  final now = DateTime.now();
  final plannedAt = [
    for (final v in ((jsonDecode(db.getMeta(_plannedKey) ?? '{}') as Map).values))
      ?DateTime.tryParse((v as String).split('|').first)?.toLocal(),
  ].where((t) => t.isAfter(now)).toList()..sort();
  return ReminderStatus(
    allowed: await impl?.areNotificationsEnabled() ?? false,
    batteryUnrestricted: await sys<bool>('batteryUnrestricted'),
    manufacturer: await sys<String>('manufacturer') ?? '',
    lastRun: at(_lastRunKey),
    error: db.getMeta(_errorKey),
    digestAt: at(_digestAtKey),
    planned: plannedAt.length,
    nextPlanned: plannedAt.firstOrNull,
  );
}

/// Shows a notification right away – proves permission, channel and icon.
Future<void> sendTestReminder() async {
  if (!_android) return;
  await _init();
  await _plugin.show(
    id: notificationId('test'),
    title: tr('Test-Benachrichtigung'),
    body: tr('App-Benachrichtigungen funktionieren auf diesem Gerät.'),
    notificationDetails: _digestDetails,
  );
}

Future<void> openNotificationSettings() => _system.invokeMethod<void>('openNotificationSettings');
Future<void> openAppSettings() => _system.invokeMethod<void>('openAppSettings');

/// Logout: nothing about the previous account stays on screen.
Future<void> clearReminders() async {
  if (!_android) return;
  await _init();
  await _plugin.cancelAll();
  await clearHomeWidget();
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
