import 'dart:convert';
import 'dart:math';

import 'package:uuid/uuid.dart';

import '../../domain/due.dart';
import '../../domain/models.dart';
import '../local/database.dart';

const _uuid = Uuid();
String newId() => _uuid.v7();

const _base62 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
final _rand = Random.secure();

/// 16 random base62 characters (~95 bit) – same format as the server.
String newScanToken() {
  final b = StringBuffer();
  while (b.length < 16) {
    final v = _rand.nextInt(256);
    if (v < 248) b.write(_base62[v % 62]); // rejection sampling, no modulo bias
  }
  return b.toString();
}

/// Everything the dashboard needs, computed from the local database.
class DashboardData {
  DashboardData({required this.colonies, required this.due, required this.recent, required this.hibernating});
  final List<Colony> colonies;
  final Map<String, List<DueTask>> due;
  final List<(ColonyEvent, Colony?)> recent;
  final List<(Colony, DateTime?)> hibernating;

  int count(String status) => colonies.where((c) => c.status == status).length;
  int get needsAttention => due.values.where((t) => (worstOf(t)?.days ?? 1) <= 0).length;
}

/// Result of resolving a scanned QR/NFC code.
sealed class ScanResolution {}

class ScanFound extends ScanResolution {
  ScanFound(this.colonyId);
  final String colonyId;
}

class ScanRevoked extends ScanResolution {}

class ScanUnknown extends ScanResolution {}

/// Reads and writes colony data. Reads come only from the local database;
/// every write is a local transaction (record + outbox op) followed by a
/// background sync – the UI never waits for the network.
class ColonyRepository {
  ColonyRepository(this.db, {required this.userId, required this.onChanged, DateTime Function()? clock})
    : now = clock ?? DateTime.now;

  final AppDatabase db;
  final String userId;
  final void Function() onChanged;
  final DateTime Function() now;

  // ---------------------------------------------------------------------------
  // Reads (synchronous, for use inside db.watch)

  Map<String, Species> _species() => {for (final r in db.records('species', orderBy: 'id')) r.id: Species(r.json)};
  Map<String, Location> _locations() => {
    for (final r in db.records('locations', orderBy: 'id')) r.id: Location(r.json),
  };

  List<Colony> colonies({bool includeArchived = false}) {
    final sp = _species(), loc = _locations();
    final list =
        db
            .records('colonies', orderBy: 'id')
            .map((r) {
              final j = r.json;
              return Colony(
                j,
                speciesName: sp[j['species_id']]?.scientificName,
                locationPath: loc[j['location_id']]?.path,
              );
            })
            .where((c) => includeArchived || !c.archived)
            .toList()
          ..sort((a, b) => a.number.compareTo(b.number));
    return list;
  }

  Colony? colony(String id) {
    final r = db.record('colonies', id);
    if (r == null) return null;
    final j = r.json;
    return Colony(
      j,
      speciesName: _species()[j['species_id']]?.scientificName,
      locationPath: _locations()[j['location_id']]?.path,
    );
  }

  List<ColonyEvent> events(String colonyId, {Set<String>? types, int? limit}) {
    final rows = db.select(
      '''SELECT data FROM records WHERE entity = 'colony_events' AND colony_id = ?
         ${types == null || types.isEmpty ? '' : 'AND json_extract(data, \'\$.type\') IN (${types.map((_) => '?').join(',')})'}
         ORDER BY ts DESC, id DESC ${limit != null ? 'LIMIT $limit' : ''}''',
      [colonyId, ...?types],
    );
    return rows.map((r) => ColonyEvent(_decode(r['data'] as String))).toList();
  }

  ColonyEvent? lastFeeding(String colonyId) {
    final e = events(colonyId, types: {'feeding'}, limit: 1);
    return e.isEmpty ? null : e.first;
  }

  List<Schedule> schedules({String? colonyId}) =>
      db.records('care_schedules', colonyId: colonyId, orderBy: 'id').map((r) => Schedule.fromJson(r.json)).toList();

  List<FoodItem> foodItems() =>
      db.records('food_items', orderBy: 'id').map((r) => FoodItem(r.json)).where((f) => !f.archived).toList()
        ..sort((a, b) => a.sortOrder != b.sortOrder ? a.sortOrder.compareTo(b.sortOrder) : a.name.compareTo(b.name));

  List<Location> locations() => _locations().values.toList()..sort((a, b) => a.path.compareTo(b.path));

  List<ScanLink> scanLinks(String colonyId) =>
      db.records('scan_links', colonyId: colonyId, orderBy: 'id').map((r) => ScanLink(r.json)).toList();

  UserSettings settings() {
    final r = db.record('user_settings', userId);
    return UserSettings(r?.json ?? const {});
  }

  /// My role on a colony (owner / editor / viewer), from colony_members.
  String roleOn(String colonyId) {
    final r = db.select(
      '''SELECT json_extract(data, '\$.role') AS role FROM records WHERE entity = 'colony_members'
         AND colony_id = ? AND json_extract(data, '\$.user_id') = ?''',
      [colonyId, userId],
    );
    return r.isEmpty ? 'owner' : r.first['role'] as String;
  }

  /// Last care per colony, computed in SQLite (JSON1) – fast for many colonies.
  Map<String, LastCare> lastCare() {
    DateTime? t(Object? v) => v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);
    const hasCategory =
        "EXISTS (SELECT 1 FROM json_each(data, '\$.feeding.items') WHERE json_extract(value, '\$.category') = ?)";
    final rows = db.select(
      '''
      SELECT colony_id,
        max(CASE WHEN type = 'feeding' THEN ts END) AS feeding,
        max(CASE WHEN type = 'feeding' AND $hasCategory THEN ts END) AS protein,
        max(CASE WHEN type = 'feeding' AND $hasCategory THEN ts END) AS carbohydrate,
        max(CASE WHEN type = 'water' THEN ts END) AS water,
        max(CASE WHEN type = 'cleaning' THEN ts END) AS cleaning,
        max(CASE WHEN type IN ('check', 'feeding', 'water', 'cleaning', 'census', 'brood') THEN ts END) AS chk
      FROM (SELECT colony_id, ts, data, json_extract(data, '\$.type') AS type FROM records WHERE entity = 'colony_events')
      GROUP BY colony_id''',
      ['protein', 'carbohydrate'],
    );
    final bySchedule = <String, Map<String, DateTime>>{};
    for (final r in db.select('''
      SELECT colony_id, json_extract(data, '\$.schedule_id') AS sid, max(ts) AS last FROM records
      WHERE entity = 'colony_events' AND json_extract(data, '\$.schedule_id') IS NOT NULL GROUP BY colony_id, sid''')) {
      (bySchedule[r['colony_id'] as String] ??= {})[r['sid'] as String] = t(r['last'])!;
    }
    return {
      for (final r in rows)
        r['colony_id'] as String: LastCare(
          feeding: t(r['feeding']),
          protein: t(r['protein']),
          carbohydrate: t(r['carbohydrate']),
          water: t(r['water']),
          cleaning: t(r['cleaning']),
          check: t(r['chk']),
          bySchedule: bySchedule[r['colony_id']] ?? const {},
        ),
    };
  }

  /// Open winter rests (started, not ended) per colony.
  Map<String, WinterRestInfo> openWinterRests() {
    final today = _dateString(now());
    final out = <String, WinterRestInfo>{};
    for (final r in db.records('winter_rests', orderBy: 'id')) {
      final j = r.json;
      if (j['ended_on'] == null && (j['started_on'] as String? ?? '9999').compareTo(today) <= 0) {
        out[j['colony_id'] as String] = WinterRestInfo(
          mode: j['reminder_mode'] as String? ?? 'scale',
          factor: (j['reminder_factor'] as num?)?.toDouble() ?? 4,
        );
      }
    }
    return out;
  }

  static String _dateString(DateTime t) {
    final l = t.toLocal();
    return '${l.year.toString().padLeft(4, '0')}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
  }

  Map<String, List<DueTask>> dueAll([List<Colony>? cols]) {
    cols ??= colonies();
    final last = lastCare();
    final winter = openWinterRests();
    final soon = settings().dueSoonDays;
    final bySchedule = <String, List<Schedule>>{};
    for (final s in schedules()) {
      (bySchedule[s.colonyId] ??= []).add(s);
    }
    final t = now();
    return {
      for (final c in cols.where((c) => c.isCareActive))
        c.id: computeDue(
          schedules: bySchedule[c.id] ?? const [],
          last: last[c.id] ?? const LastCare(),
          winter: winter[c.id],
          now: t,
          soonDays: soon,
        ),
    };
  }

  List<DueTask> due(String colonyId) {
    final c = colony(colonyId);
    if (c == null) return const [];
    return dueAll([c])[colonyId] ?? const [];
  }

  DashboardData dashboard() {
    final cols = colonies();
    final byId = {for (final c in cols) c.id: c};
    final recent = db
        .select("SELECT data FROM records WHERE entity = 'colony_events' ORDER BY ts DESC LIMIT 12")
        .map((r) => ColonyEvent(_decode(r['data'] as String)))
        .map((e) => (e, byId[e.colonyId]))
        .where((p) => p.$2 != null)
        .toList();
    final winterStart = {
      for (final r in db.records('winter_rests', orderBy: 'id'))
        if (r.json['ended_on'] == null)
          r.json['colony_id'] as String: DateTime.tryParse(r.json['started_on'] as String? ?? ''),
    };
    return DashboardData(
      colonies: cols,
      due: dueAll(cols),
      recent: recent,
      hibernating: [for (final c in cols.where((c) => c.status == 'hibernating')) (c, winterStart[c.id])],
    );
  }

  /// QR/NFC token → colony, entirely offline (scan_links are synced).
  ScanResolution resolveToken(String token) {
    final r = db.select("SELECT data FROM records WHERE entity = 'scan_links' AND json_extract(data, '\$.token') = ?", [
      token,
    ]);
    if (r.isEmpty) return ScanUnknown();
    final link = ScanLink(_decode(r.first['data'] as String));
    if (!link.active) return ScanRevoked();
    if (db.record('colonies', link.colonyId) == null) return ScanUnknown();
    return ScanFound(link.colonyId);
  }

  // ---------------------------------------------------------------------------
  // Writes

  T _write<T>(T Function() fn) {
    final r = db.transaction(fn);
    onChanged();
    return r;
  }

  Map<String, dynamic> _create(String entity, Map<String, dynamic> payload, {String? id}) {
    final rid = id ?? newId();
    final data = {...payload, 'id': rid, 'version': 0};
    db.putRecord(entity, data, pending: true);
    db.queueCreate(newId(), entity, rid, payload);
    return data;
  }

  void _update(String entity, String id, Map<String, dynamic> patch) {
    final rec = db.record(entity, id);
    if (rec == null) throw StateError('$entity $id not found');
    db.putRecord(entity, {...rec.json, ...patch}, version: rec.version, pending: true);
    db.queueUpdate(newId(), entity, id, patch, rec.version);
  }

  void _delete(String entity, String id) {
    db.queueDelete(newId(), entity, id);
    db.removeRecord(entity, id);
  }

  /// Creates a colony with its care schedules and a QR code – works offline.
  String createColony(Map<String, dynamic> fields, {Map<String, double> intervals = const {}}) => _write(() {
    final used = colonies(includeArchived: true).map((c) => c.number).fold<int>(0, max);
    final c = _create('colonies', {'number': used + 1, 'status': 'active', ...fields});
    final id = c['id'] as String;
    final start = now().toUtc().toIso8601String();
    intervals.forEach((type, days) {
      _create('care_schedules', {'colony_id': id, 'task_type': type, 'interval_days': days, 'starts_at': start});
    });
    _create('scan_links', {'colony_id': id, 'token': newScanToken(), 'kind': 'qr', 'active': true});
    // The owner membership is created by the server and arrives with the next pull.
    return id;
  });

  void updateColony(String id, Map<String, dynamic> patch) => _write(() => _update('colonies', id, patch));

  /// Sets interval days per task type; 0 removes the schedule.
  void setIntervals(String colonyId, Map<String, double> intervals) => _write(() {
    final existing = {for (final s in schedules(colonyId: colonyId)) s.taskType: s};
    intervals.forEach((type, days) {
      final s = existing[type];
      if (days <= 0) {
        if (s != null) _delete('care_schedules', s.id);
      } else if (s == null) {
        _create('care_schedules', {
          'colony_id': colonyId,
          'task_type': type,
          'interval_days': days,
          'starts_at': now().toUtc().toIso8601String(),
        });
      } else if (s.intervalDays != days) {
        _update('care_schedules', s.id, {'interval_days': days});
      }
    });
  });

  void archiveColony(String id, bool archive) =>
      updateColony(id, {'archived_at': archive ? now().toUtc().toIso8601String() : null});

  void deleteColony(String id) => _write(() {
    _delete('colonies', id);
    db.purgeColony(id);
  });

  /// Records an event. [details] are the type-specific parts (feeding, water …).
  ColonyEvent logEvent(
    String colonyId,
    String type, {
    Map<String, dynamic> details = const {},
    String? note,
    DateTime? at,
  }) => _write(() {
    final payload = {
      'colony_id': colonyId,
      'type': type,
      'occurred_at': (at ?? now()).toUtc().toIso8601String(),
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      ...details,
    };
    final data = _create('colony_events', payload);
    db.putRecord('colony_events', {...data, 'created_by': userId}, pending: true);
    return ColonyEvent({...data, 'created_by': userId});
  });

  /// „Letzte Fütterung wiederholen“ – one tap. Returns null if there is none.
  ColonyEvent? repeatLastFeeding(String colonyId, {DateTime? at}) {
    final last = lastFeeding(colonyId);
    if (last == null) return null;
    final items = [
      for (final i in last.items)
        {
          for (final k in const ['food_item_id', 'food_name', 'category', 'quantity', 'unit', 'size'])
            if (i.json[k] != null) k: i.json[k],
        },
    ];
    return logEvent(
      colonyId,
      'feeding',
      details: {
        'feeding': {'acceptance': 'unknown', 'items': items},
      },
      at: at,
    );
  }

  /// Duplicate guard: an identical feeding within the last 2 minutes.
  bool fedJustNow(String colonyId) {
    final last = lastFeeding(colonyId);
    return last != null && now().difference(last.occurredAt).inSeconds.abs() < 120;
  }

  /// Sets acceptance later (often only known hours after feeding).
  void setAcceptance(String eventId, String acceptance) => _write(() {
    final rec = db.record('colony_events', eventId);
    if (rec == null) return;
    final feeding = Map<String, dynamic>.from(rec.json['feeding'] as Map? ?? {});
    feeding['acceptance'] = acceptance;
    // The server replaces details as a whole – always send them completely.
    feeding['items'] = [
      for (final i in (feeding['items'] as List? ?? const []).cast<Map<String, dynamic>>())
        {
          for (final e in i.entries)
            if (e.key != 'feeding_id') e.key: e.value,
        },
    ];
    _update('colony_events', eventId, {'feeding': feeding});
  });

  void updateEvent(String eventId, Map<String, dynamic> patch) =>
      _write(() => _update('colony_events', eventId, patch));

  void deleteEvent(String eventId) => _write(() => _delete('colony_events', eventId));

  String createLocation(String name, {String? parentId}) => _write(() {
    final parent = parentId == null ? null : _locations()[parentId];
    final data = _create('locations', {'name': name.trim(), 'parent_id': ?parentId});
    // path is computed by the server; show it right away locally
    db.putRecord('locations', {
      ...data,
      'path': parent == null ? name.trim() : '${parent.path}/${name.trim()}',
    }, pending: true);
    return data['id'] as String;
  });

  static Map<String, dynamic> _decode(String s) => jsonDecode(s) as Map<String, dynamic>;
}
