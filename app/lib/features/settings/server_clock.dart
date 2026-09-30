import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/i18n.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';

/// Server clock: fetched once, then counted on locally. Due dates and
/// reminders follow the server's time – a wrong device clock is worth a hint.
final serverClockProvider = FutureProvider.autoDispose<({DateTime server, DateTime fetched, String zone})?>((
  ref,
) async {
  try {
    final r = await ref.read(authProvider.notifier).api.public('GET', '/api/v1/instance') as Map<String, dynamic>;
    final at = DateTime.tryParse(r['server_time'] as String? ?? '');
    if (at == null) return null; // older server
    return (server: at, fetched: DateTime.now(), zone: r['time_zone'] as String? ?? '');
  } on Exception {
    return null;
  }
});

/// How far the device clock is off (positive = device is ahead); null when
/// within [tolerance] (network delay).
Duration? clockSkew(DateTime server, DateTime fetched, {Duration tolerance = const Duration(minutes: 2)}) {
  final d = fetched.difference(server);
  return d.abs() <= tolerance ? null : d;
}

/// „3 Min.“, „2 Std. 5 Min.“ – a readable difference.
String skewText(Duration d) {
  final m = d.inMinutes.abs();
  if (m < 60) return tr('{0} Min.', [m]);
  return m % 60 == 0 ? tr('{0} Std.', [m ~/ 60]) : tr('{0} Std. {1} Min.', [m ~/ 60, m % 60]);
}

class ServerClockTile extends ConsumerStatefulWidget {
  const ServerClockTile({super.key});
  @override
  ConsumerState<ServerClockTile> createState() => _ServerClockTileState();
}

class _ServerClockTileState extends ConsumerState<ServerClockTile> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(serverClockProvider).value;
    if (c == null) return const SizedBox.shrink();
    // server time now = server time then + time passed on this device
    final now = c.server.add(DateTime.now().difference(c.fetched)).toLocal();
    final skew = clockSkew(c.server, c.fetched);
    return ListTile(
      leading: const Icon(Icons.schedule),
      title: Text(tr('Serverzeit: {0}', ['${S.date(now)} ${S.time(now)}:${now.second.toString().padLeft(2, '0')}'])),
      subtitle: Text(
        [
          if (c.zone.isNotEmpty) tr('Zeitzone des Servers: {0}', [c.zone]),
          if (skew != null)
            skew.isNegative
                ? tr('⚠ Die Uhr dieses Geräts geht {0} nach – Uhrzeit prüfen', [skewText(skew)])
                : tr('⚠ Die Uhr dieses Geräts geht {0} vor – Uhrzeit prüfen', [skewText(skew)]),
        ].join('\n'),
        style: skew == null ? null : TextStyle(color: context.colors.overdue),
      ),
      onTap: () => ref.invalidate(serverClockProvider),
    );
  }
}
