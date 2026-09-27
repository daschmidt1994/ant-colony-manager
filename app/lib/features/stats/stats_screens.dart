import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../domain/stats.dart';
import '../../shared/widgets.dart';

final colonyStatsProvider = StreamProvider.family<ColonyStats, (String, StatsRange)>(
  (ref, k) => watchRepo(ref, (r) => r.colonyStatsFor(k.$1, k.$2)),
);

final collectionStatsProvider = StreamProvider<GlobalStats>((ref) => watchRepo(ref, (r) => r.collectionStats()));

/// Sensor data of the colony's sensors for the chart range (online only).
final sensorSeriesProvider = FutureProvider.autoDispose.family<Map<String, List<Point>>, (String, StatsRange)>((
  ref,
  k,
) async {
  final repo = ref.read(repositoryProvider);
  if (repo == null) return const {};
  final sensors = repo.sensorsOf(k.$1);
  if (sensors.isEmpty) return const {};
  final from = Buckets.of(k.$2, DateTime.now()).from;
  final bucket = switch (k.$2) {
    StatsRange.week => '1h',
    StatsRange.month => '6h',
    StatsRange.quarter => '24h',
    _ => '168h',
  };
  final out = <String, List<Point>>{};
  final api = ref.read(authProvider.notifier).api;
  for (final s in sensors) {
    try {
      final res =
          await api.get(
                '/api/v1/sensors/${s['id']}/measurements',
                query: {
                  'from': from.toUtc().toIso8601String(),
                  'to': DateTime.now().toUtc().toIso8601String(),
                  'bucket': bucket,
                },
              )
              as Map<String, dynamic>;
      for (final b in (res['buckets'] as List).cast<Map<String, dynamic>>()) {
        (out[b['metric'] as String] ??= []).add(Point(DateTime.parse(b['at'] as String), (b['avg'] as num).toDouble()));
      }
    } on Exception {
      // offline or no access – manual measurements are still shown
    }
  }
  return out;
});

class ColonyStatsScreen extends ConsumerStatefulWidget {
  const ColonyStatsScreen({super.key, required this.colonyId});
  final String colonyId;
  @override
  ConsumerState<ColonyStatsScreen> createState() => _ColonyStatsScreenState();
}

class _ColonyStatsScreenState extends ConsumerState<ColonyStatsScreen> {
  StatsRange _range = StatsRange.month;

  @override
  Widget build(BuildContext context) {
    final colony = ref.watch(colonyProvider(widget.colonyId)).value;
    final stats = ref.watch(colonyStatsProvider((widget.colonyId, _range)));
    final sensors = ref.watch(sensorSeriesProvider((widget.colonyId, _range))).value ?? const {};
    return Scaffold(
      appBar: AppBar(title: Text(colony == null ? 'Statistik' : 'Statistik · ${colony.name}')),
      body: ContentWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Center(
              child: SegmentedButton<StatsRange>(
                showSelectedIcon: false,
                segments: [for (final r in StatsRange.values) ButtonSegment(value: r, label: Text(r.label))],
                selected: {_range},
                onSelectionChanged: (v) => setState(() => _range = v.first),
              ),
            ),
            ...stats.when(
              loading: () => [
                const Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
              error: (e, _) => [EmptyState(icon: Icons.error_outline, title: 'Fehler', text: '$e')],
              data: (s) => _content(context, s, sensors),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context, ColonyStats s, Map<String, List<Point>> sensors) {
    final c = context.colors;
    final temp = [...s.temperature, ...?sensors['temperature']]..sort((a, b) => a.at.compareTo(b.at));
    final hum = [...s.humidity, ...?sensors['humidity']]..sort((a, b) => a.at.compareTo(b.at));
    return [
      const SizedBox(height: 16),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _Kpi('${s.feedings}', 'Fütterungen', sub: 'Protein ${s.protein} · KH ${s.carbohydrate}'),
          _Kpi('${s.water}', 'Wasser'),
          _Kpi('${s.cleaning}', 'Reinigungen'),
          _Kpi(
            s.rated == 0 ? '–' : '${(100 * s.accepted / s.rated).round()} %',
            'angenommen',
            sub: '${s.rated} bewertet',
          ),
        ],
      ),
      _ChartCard(
        title: 'Fütterungen',
        legend: [('Protein', c.protein), ('Kohlenhydrate', c.carbs), ('Sonstiges', c.muted)],
        empty: s.feedings == 0,
        child: _Bars(
          buckets: s.buckets,
          stacks: [
            for (final b in s.care)
              [
                (b.protein.toDouble(), c.protein),
                (b.carbohydrate.toDouble(), c.carbs),
                (b.otherFeeding.toDouble(), c.muted),
              ],
          ],
        ),
      ),
      _ChartCard(
        title: 'Wasser & Reinigung',
        legend: [('Wasser', c.winter), ('Reinigung', c.ok)],
        empty: s.water + s.cleaning == 0,
        child: _Bars(
          buckets: s.buckets,
          groups: [
            for (final b in s.care) [(b.water.toDouble(), c.winter), (b.cleaning.toDouble(), c.ok)],
          ],
        ),
      ),
      _ChartCard(
        title: 'Koloniewachstum',
        subtitle: 'Arbeiterinnen (Schätzung oder Zählung)',
        empty: s.workers.isEmpty,
        emptyText: 'Noch keine Koloniegröße erfasst – Kolonie-Seite → Menü ⋮ → „Größe & Brut erfassen“.',
        child: _Lines(
          from: s.buckets.from,
          series: [
            (s.workers, Theme.of(context).colorScheme.primary, true),
            (
              [
                for (final p in s.workers)
                  if (p.max != null) Point(p.at, p.max!),
              ],
              Theme.of(context).colorScheme.primary.withValues(alpha: .4),
              true,
            ),
          ],
          format: (v) => S.number(v.round()),
        ),
      ),
      _ChartCard(
        title: 'Temperatur',
        subtitle: sensors.isEmpty ? 'Messungen' : 'Messungen und Sensor',
        empty: temp.isEmpty,
        child: _Lines(from: s.buckets.from, series: [(temp, c.protein, false)], format: (v) => '${S.decimal(v)} °'),
      ),
      _ChartCard(
        title: 'Luftfeuchtigkeit',
        empty: hum.isEmpty,
        child: _Lines(from: s.buckets.from, series: [(hum, c.winter, false)], format: (v) => '${v.round()} %'),
      ),
      _ChartCard(
        title: 'Brutentwicklung',
        subtitle: '0 keine · 1 wenig · 2 mittel · 3 viel',
        legend: [
          for (final (i, st) in broodStages.indexed)
            if (s.brood.containsKey(st)) (_broodNames[st]!, _broodColors[i]),
        ],
        empty: s.brood.isEmpty,
        emptyText: 'Noch keine Brut erfasst – Kolonie-Seite → Menü ⋮ → „Größe & Brut erfassen“.',
        child: _Lines(
          from: s.buckets.from,
          series: [
            for (final (i, st) in broodStages.indexed)
              if (s.brood.containsKey(st)) (s.brood[st]!, _broodColors[i], false),
          ],
          format: (v) => v.toStringAsFixed(0),
        ),
      ),
    ];
  }
}

const _broodNames = {
  'eggs': 'Eier',
  'larvae': 'Larven',
  'pupae': 'Puppen (Kokon)',
  'naked_pupae': 'Puppen (nackt)',
  'alates': 'Geschlechtstiere',
};
const _broodColors = [Color(0xFFE0C068), Color(0xFFD08A5A), Color(0xFF8EAE6A), Color(0xFF6AA0B8), Color(0xFFB07AC0)];

class _Kpi extends StatelessWidget {
  const _Kpi(this.value, this.label, {this.sub});
  final String value, label;
  final String? sub;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 160,
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
            Text(label, style: TextStyle(color: context.colors.muted)),
            if (sub != null) Text(sub!, style: TextStyle(color: context.colors.muted, fontSize: 12)),
          ],
        ),
      ),
    ),
  );
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.child,
    this.subtitle,
    this.legend = const [],
    this.empty = false,
    this.emptyText,
  });
  final String title;
  final String? subtitle, emptyText;
  final List<(String, Color)> legend;
  final bool empty;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            if (subtitle != null) Text(subtitle!, style: TextStyle(color: context.colors.muted, fontSize: 12)),
            const SizedBox(height: 12),
            if (empty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  emptyText ?? 'Keine Daten in diesem Zeitraum',
                  style: TextStyle(color: context.colors.muted),
                ),
              )
            else ...[
              SizedBox(height: 180, child: child),
              if (legend.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 14,
                  runSpacing: 4,
                  children: [
                    for (final (label, color) in legend)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
                          ),
                          const SizedBox(width: 5),
                          Text(label, style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    ),
  );
}

String _bucketLabel(Buckets b, int i) {
  final d = b.starts[i];
  return switch (b.unit) {
    BucketUnit.day => DateFormat('d.M.', 'de').format(d),
    BucketUnit.week => 'KW ${_isoWeek(d)}',
    BucketUnit.month => DateFormat(d.month == 1 || i == 0 ? 'MMM yy' : 'MMM', 'de').format(d),
  };
}

int _isoWeek(DateTime d) {
  final thursday = d.add(Duration(days: 4 - d.weekday));
  final jan1 = DateTime(thursday.year);
  return 1 + thursday.difference(jan1).inDays ~/ 7;
}

/// Bar chart per bucket: [stacks] (one stacked rod) or [groups] (rods side by side).
class _Bars extends StatelessWidget {
  const _Bars({required this.buckets, this.stacks, this.groups});
  final Buckets buckets;
  final List<List<(double, Color)>>? stacks, groups;

  @override
  Widget build(BuildContext context) {
    final n = buckets.starts.length;
    final values = stacks ?? groups!;
    final maxY = values
        .map((g) => stacks != null ? g.fold(0.0, (s, x) => s + x.$1) : g.fold(0.0, (s, x) => math.max(s, x.$1)))
        .fold(0.0, math.max);
    final every = (n / 6).ceil();
    final width = (260 / n).clamp(3.0, 18.0);
    return BarChart(
      BarChartData(
        maxY: maxY < 3 ? 3 : maxY * 1.1,
        gridData: FlGridData(
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(color: context.colors.border, strokeWidth: .6),
        ),
        borderData: FlBorderData(show: false),
        barTouchData: BarTouchData(enabled: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              getTitlesWidget: (v, m) => v % 1 != 0
                  ? const SizedBox.shrink()
                  : SideTitleWidget(
                      meta: m,
                      child: Text(v.toInt().toString(), style: const TextStyle(fontSize: 11)),
                    ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (v, m) {
                final i = v.toInt();
                if (i % every != 0 && i != n - 1) return const SizedBox.shrink();
                return SideTitleWidget(
                  meta: m,
                  child: Text(_bucketLabel(buckets, i), style: const TextStyle(fontSize: 10)),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < n; i++)
            BarChartGroupData(
              x: i,
              barsSpace: 1,
              barRods: stacks != null
                  ? [
                      BarChartRodData(
                        toY: stacks![i].fold(0.0, (s, x) => s + x.$1),
                        width: width,
                        borderRadius: BorderRadius.circular(2),
                        rodStackItems: () {
                          var y = 0.0;
                          return [
                            for (final (v, color) in stacks![i])
                              if (v > 0) BarChartRodStackItem(y, y += v, color),
                          ];
                        }(),
                        color: Colors.transparent,
                      ),
                    ]
                  : [
                      for (final (v, color) in groups![i])
                        BarChartRodData(toY: v, width: width / 2, color: color, borderRadius: BorderRadius.circular(2)),
                    ],
            ),
        ],
      ),
    );
  }
}

/// Lines over time. x = days since [from]; `step` draws a step line (sizes stay until the next count).
class _Lines extends StatelessWidget {
  const _Lines({required this.from, required this.series, required this.format});
  final DateTime from;
  final List<(List<Point>, Color, bool)> series;
  final String Function(double) format;

  double _x(DateTime t) => t.difference(from).inMinutes / 1440;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final maxX = math.max(1.0, _x(now));
    final all = [for (final s in series) ...s.$1];
    var minY = all.map((p) => p.value).fold(double.infinity, math.min);
    var maxY = all.map((p) => p.value).fold(-double.infinity, math.max);
    if (minY == maxY) {
      minY -= 1;
      maxY += 1;
    }
    final pad = (maxY - minY) * .1;
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: maxX,
        minY: minY - pad,
        maxY: maxY + pad,
        gridData: FlGridData(
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(color: context.colors.border, strokeWidth: .6),
        ),
        borderData: FlBorderData(show: false),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => [
              for (final s in spots)
                LineTooltipItem(
                  '${S.date(from.add(Duration(minutes: (s.x * 1440).round())))}\n${format(s.y)}',
                  TextStyle(color: s.bar.color, fontSize: 12, fontWeight: FontWeight.w600),
                ),
            ],
          ),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              getTitlesWidget: (v, m) => v == m.max || v == m.min
                  ? const SizedBox.shrink()
                  : SideTitleWidget(
                      meta: m,
                      child: Text(format(v), style: const TextStyle(fontSize: 10)),
                    ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: math.max(1, (maxX / 4).roundToDouble()),
              getTitlesWidget: (v, m) => SideTitleWidget(
                meta: m,
                child: Text(
                  DateFormat(maxX > 120 ? 'MMM yy' : 'd.M.', 'de').format(from.add(Duration(days: v.round()))),
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            ),
          ),
        ),
        lineBarsData: [
          for (final (points, color, step) in series)
            if (points.isNotEmpty)
              LineChartBarData(
                spots: [
                  for (final p in points) FlSpot(_x(p.at).clamp(0, maxX), p.value),
                  // a size stays valid until today
                  if (step) FlSpot(maxX, points.last.value),
                ],
                color: color,
                barWidth: 2.5,
                isStepLineChart: step,
                dotData: FlDotData(show: points.length < 40),
              ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Whole collection (§33)

class CollectionStatsScreen extends ConsumerWidget {
  const CollectionStatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(collectionStatsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Statistiken')),
      body: s.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(icon: Icons.error_outline, title: 'Fehler', text: '$e'),
        data: (s) => ContentWidth(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _Kpi('${s.colonies}', 'Kolonien'),
                  _Kpi('${s.species}', 'Arten'),
                  _Kpi('${s.genera}', 'Gattungen'),
                  _Kpi(
                    s.workersMax == null
                        ? '${S.number(s.workersMin)}+'
                        : s.workersMin == s.workersMax
                        ? S.number(s.workersMin)
                        : '${S.number(s.workersMin)}–${S.number(s.workersMax!)}',
                    'Arbeiterinnen (geschätzt)',
                    sub: s.workersUnknown > 0 ? '${s.workersUnknown} ohne Angabe' : null,
                  ),
                  _Kpi('${s.feedingsWeek}', 'Fütterungen', sub: 'diese Woche'),
                  _Kpi('${s.feedingsMonth}', 'Fütterungen', sub: 'dieser Monat'),
                  _Kpi('${s.overdueTasks}', 'überfällige Aufgaben'),
                  _Kpi('${s.hibernating}', 'in Winterruhe'),
                ],
              ),
              _Distribution(title: 'Nach Art', entries: s.bySpecies, italic: true),
              _Distribution(title: 'Nach Gattung', entries: s.byGenus, italic: true),
              _Distribution(title: 'Nach Standort', entries: s.byLocation),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal bars, largest first (top 12, rest summed up).
class _Distribution extends StatelessWidget {
  const _Distribution({required this.title, required this.entries, this.italic = false});
  final String title;
  final List<MapEntry<String, int>> entries;
  final bool italic;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final shown = entries.take(12).toList();
    final rest = entries.skip(12).fold(0, (s, e) => s + e.value);
    final max = entries.first.value;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 10),
              for (final e in [...shown, if (rest > 0) MapEntry('weitere', rest)])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 150,
                        child: Text(
                          e.key,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontStyle: italic && e.key != 'weitere' ? FontStyle.italic : null),
                        ),
                      ),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (c, box) => Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              height: 14,
                              width: math.max(4, box.maxWidth * e.value / math.max(max, rest)),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary.withValues(alpha: .8),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: 36, child: Text('${e.value}', textAlign: TextAlign.right)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
