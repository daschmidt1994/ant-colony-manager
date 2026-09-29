import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/session.dart';
import '../../data/sync/background_sync.dart';
import '../../data/sync/realtime.dart';
import '../../data/sync/sync_engine.dart';
import '../reminders/reminder_actions.dart';
import '../reminders/reminders.dart';
import '../../app/i18n.dart';

/// Starts a sync whenever it is worth it (docs/05 §8): app back in the
/// foreground, network back, realtime signal from the server (Android),
/// every 30 s while a web tab is visible – plus the WorkManager background
/// sync when the app is closed.
class SyncTriggers extends ConsumerStatefulWidget {
  const SyncTriggers({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<SyncTriggers> createState() => _SyncTriggersState();
}

class _SyncTriggersState extends ConsumerState<SyncTriggers> with WidgetsBindingObserver {
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  RealtimeListener? _realtime;
  Timer? _webPoll;
  bool _wasOffline = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    try {
      _connectivity = Connectivity().onConnectivityChanged.listen(_onConnectivity);
    } on Exception {
      // plugin unavailable (tests) – the other triggers still work
    }
    registerBackgroundSync().catchError((Object _) {});
    _foreground();
    _startReminders();
  }

  // ---------------------------------------------------------------------------
  // Reminders (Android): refreshed after every sync and when the app returns.

  Timer? _remindDebounce;

  Future<void> _startReminders() async {
    try {
      await initReminders(_onReminder);
      final db = ref.read(databaseProvider);
      if (db.getMeta('notifications_asked') == null) {
        db.setMeta('notifications_asked', '1');
        await requestReminderPermission();
      }
      final launch = await reminderThatLaunchedApp();
      if (launch != null) _onReminder(launch.actionId, launch.payload);
      _refreshReminders();
    } on Exception {
      // plugin unavailable (tests, web)
    }
  }

  void _refreshReminders() {
    _remindDebounce?.cancel();
    _remindDebounce = Timer(const Duration(seconds: 2), () {
      final repo = ref.read(repositoryProvider);
      if (repo != null) syncReminders(repo).catchError((Object _) {});
    });
  }

  void _onReminder(String? actionId, String? payload) {
    final repo = ref.read(repositoryProvider);
    if (repo == null) return;
    final route = handleReminder(repo, actionId: actionId, payload: payload);
    if (route != null) {
      ref.read(routerProvider).go(route);
    } else {
      rootMessengerKey.currentState?.showSnackBar(SnackBar(content: Text(tr('Erledigt – gespeichert'))));
    }
    _refreshReminders();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivity?.cancel();
    _remindDebounce?.cancel();
    _background();
    super.dispose();
  }

  void _sync() => ref.read(syncEngineProvider)?.sync(resetBackoff: true);

  void _onConnectivity(List<ConnectivityResult> r) {
    final offline = r.isEmpty || r.every((c) => c == ConnectivityResult.none);
    if (_wasOffline && !offline) _sync(); // network is back – send the outbox now
    _wasOffline = offline;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      // The background sync may have written in another isolate.
      ref.read(databaseProvider).notifyExternalChange();
      _sync();
      _foreground();
      _refreshReminders();
    } else if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      _background();
    }
  }

  void _foreground() {
    if (kIsWeb) {
      _webPoll ??= Timer.periodic(const Duration(seconds: 30), (_) => ref.read(syncEngineProvider)?.sync());
      return;
    }
    if (_realtime != null) return;
    final auth = ref.read(authProvider);
    if (auth is! SignedIn) return;
    _realtime = RealtimeListener(
      api: ref.read(authProvider.notifier).api,
      onChange: () => ref.read(syncEngineProvider)?.schedule(const Duration(milliseconds: 300)),
    )..start();
  }

  void _background() {
    _webPoll?.cancel();
    _webPoll = null;
    _realtime?.stop();
    _realtime = null;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(syncStatusProvider, (_, s) {
      if (s.value?.phase != SyncPhase.syncing) _refreshReminders();
    });
    return widget.child;
  }
}
