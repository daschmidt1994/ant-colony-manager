import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/session.dart';
import '../../data/sync/background_sync.dart';
import '../../data/sync/realtime.dart';

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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivity?.cancel();
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
  Widget build(BuildContext context) => widget.child;
}
