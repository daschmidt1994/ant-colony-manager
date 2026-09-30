import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

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

bool _tzReady = false;

/// Current UTC offset of an IANA time zone (e.g. Europe/Vienna); null if unknown.
Duration? zoneOffsetNow(String zone) {
  try {
    if (!_tzReady) {
      tzdata.initializeTimeZones();
      _tzReady = true;
    }
    return tz.TZDateTime.now(tz.getLocation(zone)).timeZoneOffset;
  } on Object {
    return null;
  }
}

/// „UTC+2“, „UTC−5:30“.
String offsetText(Duration d) {
  final m = d.inMinutes.abs();
  final sign = d.isNegative ? '−' : '+';
  return 'UTC$sign${m ~/ 60}${m % 60 == 0 ? '' : ':${(m % 60).toString().padLeft(2, '0')}'}';
}

/// Device clock, server clock and the account's time zone side by side – the
/// daily overview is scheduled in the account's time zone.
class ClockCheck extends ConsumerStatefulWidget {
  const ClockCheck({super.key, required this.accountZone, required this.line});
  final String accountZone;
  final Widget Function(bool? ok, String title, String? detail) line;
  @override
  ConsumerState<ClockCheck> createState() => _ClockCheckState();
}

class _ClockCheckState extends ConsumerState<ClockCheck> {
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
    final device = DateTime.now();
    final c = ref.watch(serverClockProvider).value;
    final skew = c == null ? null : clockSkew(c.server, c.fetched);
    final zoneOffset = zoneOffsetNow(widget.accountZone);
    final zoneMismatch = zoneOffset != null && zoneOffset != device.timeZoneOffset;
    String hms(DateTime t) => '${S.time(t)}:${t.second.toString().padLeft(2, '0')}';
    final server = c?.server.add(device.difference(c.fetched)).toLocal();
    return widget.line(
      skew == null && !zoneMismatch,
      tr('Uhrzeit: {0}', [hms(device)]),
      [
        tr('Gerät: {0} ({1})', [hms(device), offsetText(device.timeZoneOffset)]),
        if (server != null) tr('Server: {0}', [hms(server)]),
        tr('Zeitzone im Konto: {0}{1}', [widget.accountZone, zoneOffset == null ? '' : ' (${offsetText(zoneOffset)})']),
        if (skew != null)
          skew.isNegative
              ? tr('⚠ Die Uhr dieses Geräts geht {0} nach – Uhrzeit prüfen', [skewText(skew)])
              : tr('⚠ Die Uhr dieses Geräts geht {0} vor – Uhrzeit prüfen', [skewText(skew)]),
        if (zoneMismatch)
          tr(
            '⚠ Die Zeitzone im Konto passt nicht zum Gerät – Tages-Überblick und Erinnerungen kommen zur falschen Uhrzeit.',
          ),
      ].join('\n'),
    );
  }
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
