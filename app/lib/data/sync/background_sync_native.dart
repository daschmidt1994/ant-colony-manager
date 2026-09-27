import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../../core/api_client.dart';
import '../../core/session.dart';
import '../local/database.dart';
import 'sync_engine.dart';
import 'upload_policy.dart';

const _task = 'acm-sync';

/// Runs in a separate isolate started by Android's WorkManager – also when the
/// app is closed – so offline entries reach the server as soon as there is a
/// network (docs/05 §8).
@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    try {
      return await runBackgroundSync();
    } catch (e) {
      debugPrint('background sync failed: $e');
      return false; // WorkManager retries later
    }
  });
}

Future<bool> runBackgroundSync() async {
  final store = SessionStore();
  final url = await store.read('server_url');
  final userJson = await store.read('user');
  if (url == null || userJson == null) return true; // not signed in
  final db = await AppDatabase.open();
  final api = ApiClient(baseUrl: url, tokens: store, isWeb: false);
  try {
    if (!await api.refresh()) return true; // signed out – the app handles it on next start
    final user = User(jsonDecode(userJson) as Map<String, dynamic>);
    final engine = SyncEngine(
      db: db,
      api: api,
      userId: user.id,
      uploadAllowed: uploadPolicy(db),
      device: DeviceIdentity(id: deviceIdOf(db), name: 'Android', platform: 'android', appVersion: appVersion),
    );
    await engine.sync(resetBackoff: true);
    engine.dispose();
    return engine.current.phase != SyncPhase.error;
  } on NetworkException {
    return false;
  } on SessionExpiredException {
    return true;
  } finally {
    api.close();
    db.dispose();
  }
}

Future<void> registerBackgroundSync() async {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  await Workmanager().initialize(backgroundSyncDispatcher);
  await Workmanager().registerPeriodicTask(
    _task,
    _task,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}

Future<void> cancelBackgroundSync() async {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  await Workmanager().cancelByUniqueName(_task);
}
