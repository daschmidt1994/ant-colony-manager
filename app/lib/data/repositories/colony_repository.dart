import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:uuid/uuid.dart';

import '../../domain/due.dart';
import '../../domain/food_stock.dart';
import '../../domain/models.dart';
import '../../domain/reminders.dart';
import '../../domain/stats.dart';
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

/// Which colonies a care round covers.
enum RoundScope { withTasks, allActive, location }

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

  /// Catalog and own species, sorted by name.
  List<Species> species() => _species().values.toList()..sort((a, b) => a.scientificName.compareTo(b.scientificName));

  Species? speciesById(String id) => _species()[id];

  /// Own species; the catalog is read-only (the server rejects changes).
  String createSpecies(Map<String, dynamic> fields) => _write(() {
    final data = _create('species', fields);
    // owner_id is set by the server; mark it as own right away (not catalog)
    db.putRecord('species', {...data, 'owner_id': userId}, pending: true);
    return data['id'] as String;
  });

  void updateSpecies(String id, Map<String, dynamic> patch) => _write(() => _update('species', id, patch));

  void deleteSpecies(String id) => _write(() => _delete('species', id));

  /// Links a colony to a species care sheet; the species name follows the
  /// catalog spelling. Returns the previous fields (for „Rückgängig“).
  Map<String, dynamic> linkSpecies(String colonyId, Species s) =>
      _setSpecies(colonyId, {'species_id': s.id, 'species_text': s.scientificName});

  /// Removes the link; the name stays as text.
  Map<String, dynamic> unlinkSpecies(String colonyId) {
    final c = colony(colonyId);
    return _setSpecies(colonyId, {'species_id': null, 'species_text': c?.species ?? ''});
  }

  Map<String, dynamic> _setSpecies(String colonyId, Map<String, dynamic> patch) => _write(() {
    final rec = db.record('colonies', colonyId);
    if (rec == null) return const <String, dynamic>{};
    final previous = {'species_id': rec.json['species_id'], 'species_text': rec.json['species_text']};
    _update('colonies', colonyId, patch);
    return previous;
  });

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

  /// Last care per colony. Each value is the newest matching event, read
  /// backwards along the (entity, colony_id, ts) index and stopped at the
  /// first hit – no scan of the whole history, so it stays fast however
  /// long the timeline gets. [colonyIds]: only these colonies.
  Map<String, LastCare> lastCare({Iterable<String>? colonyIds, Iterable<Schedule>? schedules}) {
    final ids = colonyIds?.toSet() ?? {for (final c in colonies(includeArchived: true)) c.id};
    final custom = <String, List<String>>{};
    for (final s in schedules ?? this.schedules()) {
      if (s.taskType == 'custom' && ids.contains(s.colonyId)) (custom[s.colonyId] ??= []).add(s.id);
    }
    DateTime? newest(String colonyId, String where, [List<Object?> args = const []]) {
      final r = db.select(
        """SELECT ts FROM records WHERE entity = 'colony_events' AND colony_id = ? AND ts IS NOT NULL AND $where
           ORDER BY ts DESC LIMIT 1""",
        [colonyId, ...args],
      );
      return r.isEmpty ? null : DateTime.fromMillisecondsSinceEpoch(r.first['ts'] as int);
    }

    const type = "json_extract(data, '\$.type')";
    const category =
        "$type = 'feeding' AND EXISTS (SELECT 1 FROM json_each(data, '\$.feeding.items') WHERE json_extract(value, '\$.category') = ?)";
    return {
      for (final id in ids)
        id: LastCare(
          feeding: newest(id, "$type = 'feeding'"),
          protein: newest(id, category, ['protein']),
          carbohydrate: newest(id, category, ['carbohydrate']),
          water: newest(id, "$type = 'water'"),
          cleaning: newest(id, "$type = 'cleaning'"),
          check: newest(id, "$type IN ('check', 'feeding', 'water', 'cleaning', 'census', 'brood')"),
          bySchedule: {
            for (final sid in custom[id] ?? const <String>[])
              sid: ?newest(id, "json_extract(data, '\$.schedule_id') = ?", [sid]),
          },
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

  /// The colony's current winter rest: running or planned (at most one).
  WinterRest? winterRest(String colonyId) => db
      .records('winter_rests', colonyId: colonyId, orderBy: 'id')
      .map((r) => WinterRest(r.json))
      .where((w) => w.endedOn == null)
      .lastOrNull;

  /// Plans a winter rest (reminders on [start] and [end]); on a running one
  /// only the planned end can change.
  void planWinter(String colonyId, {required DateTime start, DateTime? end}) => _write(() {
    final w = winterRest(colonyId);
    final endOn = end == null ? null : _dateString(end);
    if (w == null) {
      _create('winter_rests', {'colony_id': colonyId, 'planned_start_on': _dateString(start), 'planned_end_on': endOn});
    } else {
      _update('winter_rests', w.id, {if (!w.started) 'planned_start_on': _dateString(start), 'planned_end_on': endOn});
    }
  });

  void cancelWinterPlan(String colonyId) => _write(() {
    final w = winterRest(colonyId);
    if (w != null && !w.started) _delete('winter_rests', w.id);
  });

  /// The switch: starts the planned winter rest today (or a new one without plan).
  void startWinter(String colonyId) => _write(() {
    final today = _dateString(now());
    final w = winterRest(colonyId);
    if (w != null && w.started) return;
    final String id;
    if (w == null) {
      id = _create('winter_rests', {'colony_id': colonyId, 'started_on': today})['id'] as String;
    } else {
      id = w.id;
      _update('winter_rests', id, {'started_on': today});
    }
    _setLocalStatus(colonyId, from: const {'active', 'founding', 'paused'}, to: 'hibernating');
    logEvent(colonyId, 'winter_start', details: {'winter_rest_id': id});
  });

  void endWinter(String colonyId) => _write(() {
    final w = winterRest(colonyId);
    if (w == null || !w.started) return;
    _update('winter_rests', w.id, {'ended_on': _dateString(now())});
    _setLocalStatus(colonyId, from: const {'hibernating'}, to: 'active');
    logEvent(colonyId, 'winter_end', details: {'winter_rest_id': w.id});
  });

  /// The server derives the status from the winter rest (same rule); this only
  /// shows it right away – offline too – until the synced colony arrives.
  void _setLocalStatus(String colonyId, {required Set<String> from, required String to}) {
    final rec = db.record('colonies', colonyId);
    if (rec == null || !from.contains(rec.json['status'] ?? 'active')) return;
    db.putRecord('colonies', {...rec.json, 'status': to}, version: rec.version, pending: rec.pending);
  }

  static String _dateString(DateTime t) {
    final l = t.toLocal();
    return '${l.year.toString().padLeft(4, '0')}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
  }

  Map<String, List<DueTask>> dueAll([List<Colony>? cols]) {
    cols ??= colonies();
    final active = cols.where((c) => c.isCareActive).toList();
    final all = active.length == 1 ? schedules(colonyId: active.single.id) : schedules();
    final last = lastCare(colonyIds: active.map((c) => c.id), schedules: all);
    final winter = openWinterRests();
    final soon = settings().dueSoonDays;
    final bySchedule = <String, List<Schedule>>{};
    for (final s in all) {
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

  /// Normalised hex of a stored uid hash (pulled rows carry PostgreSQL's "\\x" prefix).
  static const _uidExpr = "lower(replace(json_extract(data, '\$.uid_hash'), '\\x', ''))";

  List<Map<String, dynamic>> nfcTags(String colonyId) =>
      db.records('nfc_tags', colonyId: colonyId, orderBy: 'id').map((r) => r.json).toList();

  String? colonyByUidHash(String hash) {
    final r = db.select("SELECT colony_id FROM records WHERE entity = 'nfc_tags' AND $_uidExpr = ?", [
      hash.toLowerCase(),
    ]);
    return r.isEmpty ? null : r.first['colony_id'] as String?;
  }

  ScanLink? linkByToken(String token) {
    final r = db.select("SELECT data FROM records WHERE entity = 'scan_links' AND json_extract(data, '\$.token') = ?", [
      token,
    ]);
    return r.isEmpty ? null : ScanLink(_decode(r.first['data'] as String));
  }

  /// Resolves an NFC tag: first by the URI on the tag, then by its serial number.
  ScanResolution resolveTag(List<String> uris, String? uidHashValue, String? Function(String) tokenOf) {
    var revoked = false;
    for (final u in uris) {
      final token = tokenOf(u);
      if (token == null) continue;
      switch (resolveToken(token)) {
        case ScanFound f:
          return f;
        case ScanRevoked():
          revoked = true;
        case ScanUnknown():
      }
    }
    if (uidHashValue != null) {
      final c = colonyByUidHash(uidHashValue);
      if (c != null && db.record('colonies', c) != null) return ScanFound(c);
    }
    return revoked ? ScanRevoked() : ScanUnknown();
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

  /// Own activities of a colony (e.g. „Nest befeuchten“): custom schedules.
  List<Schedule> customTasks(String colonyId) =>
      schedules(colonyId: colonyId).where((s) => s.taskType == 'custom' && s.active).toList();

  /// Sets the own activities of a colony: entries with an id are changed,
  /// without one created, and own activities missing from [tasks] removed.
  void setCustomTasks(String colonyId, List<({String? id, String title, double days})> tasks) => _write(() {
    final existing = {for (final s in customTasks(colonyId)) s.id: s};
    final keep = <String>{};
    for (final t in tasks) {
      final title = t.title.trim();
      if (title.isEmpty || t.days <= 0) continue;
      final s = t.id == null ? null : existing[t.id];
      if (s == null) {
        _create('care_schedules', {
          'colony_id': colonyId,
          'task_type': 'custom',
          'title': title,
          'interval_days': t.days,
          'starts_at': now().toUtc().toIso8601String(),
        });
      } else {
        keep.add(s.id);
        if (s.title != title || s.intervalDays != t.days) {
          _update('care_schedules', s.id, {'title': title, 'interval_days': t.days});
        }
      }
    }
    for (final id in existing.keys) {
      if (!keep.contains(id)) _delete('care_schedules', id);
    }
  });

  /// An own activity done – the name travels with the event.
  ColonyEvent logCustomTask(String colonyId, Schedule task, {String? note, DateTime? at}) => logEvent(
    colonyId,
    'custom_task',
    details: {
      'schedule_id': task.id,
      'payload': {'title': task.title ?? ''},
    },
    note: note,
    at: at,
  );

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
    // During a care round every documented action belongs to it.
    final round = activeRound();
    if (round != null) _visit(round.id, colonyId);
    final payload = {
      'colony_id': colonyId,
      'type': type,
      'occurred_at': (at ?? now()).toUtc().toIso8601String(),
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      'care_round_id': ?round?.id,
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
    return _repeatFeeding(last, at: at);
  }

  ColonyEvent _repeatFeeding(ColonyEvent last, {DateTime? at}) {
    final colonyId = last.colonyId;
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

  /// „Erledigt“ from a reminder (docs/13 F8): protein/carbohydrates repeat
  /// the last matching feeding, water and cleaning use the kinds from last
  /// time. Null if there is nothing to repeat (the app opens instead).
  ColonyEvent? completeDue(String colonyId, String taskType, {String? scheduleId}) => _write(() {
    List<String> lastKinds(String type, String key, List<String> fallback) {
      final e = events(colonyId, types: {type}, limit: 1);
      final k = e.isEmpty ? const <String>[] : ((e.first.json[key] as Map?)?['kinds'] as List?)?.cast<String>();
      return k == null || k.isEmpty ? fallback : k;
    }

    switch (taskType) {
      case 'water':
        return logEvent(
          colonyId,
          'water',
          details: {
            'water': {
              'kinds': lastKinds('water', 'water', const ['drinker_refilled']),
            },
          },
        );
      case 'cleaning':
        return logEvent(
          colonyId,
          'cleaning',
          details: {
            'cleaning': {
              'kinds': lastKinds('cleaning', 'cleaning', const ['other']),
            },
          },
        );
      case 'check':
        return logEvent(colonyId, 'check');
      case 'feeding' || 'protein' || 'carbohydrate':
        final last = events(
          colonyId,
          types: {'feeding'},
        ).where((e) => taskType == 'feeding' || e.items.any((i) => i.category == taskType)).firstOrNull;
        return last == null ? null : _repeatFeeding(last);
      default:
        final task = scheduleId == null
            ? null
            : schedules(colonyId: colonyId).where((s) => s.id == scheduleId).firstOrNull;
        if (task != null) return logCustomTask(colonyId, task);
        return logEvent(colonyId, 'custom_task', details: {'schedule_id': ?scheduleId});
    }
  });

  // ---------------------------------------------------------------------------
  // Statistics (computed locally)

  ColonyStats colonyStatsFor(String colonyId, StatsRange range) => colonyStats(events(colonyId), range, now());

  GlobalStats collectionStats() {
    final cols = colonies();
    return globalStats(
      colonies: cols,
      genusOfSpecies: {for (final s in _species().values) s.id: s.genus},
      due: dueAll(cols),
      feedingTimes: [
        for (final r in db.select(
          "SELECT ts FROM records WHERE entity = 'colony_events' AND json_extract(data, '\$.type') = 'feeding'",
        ))
          if (r['ts'] != null) DateTime.fromMillisecondsSinceEpoch(r['ts'] as int),
      ],
      now: now(),
    );
  }

  List<Map<String, dynamic>> sensors() => db.records('sensors', orderBy: 'id').map((r) => r.json).toList();

  /// Stores a record the server created directly (REST, e.g. a sensor with its key).
  void adoptServerRecord(String entity, Map<String, dynamic> data) => _write(() {
    db.putRecord(entity, data, version: (data['version'] as num?)?.toInt());
  });

  void updateSensor(String id, Map<String, dynamic> patch) => _write(() => _update('sensors', id, patch));

  void deleteSensor(String id) => _write(() => _delete('sensors', id));

  /// Sensors assigned to a colony (readings come from the server).
  List<Map<String, dynamic>> sensorsOf(String colonyId) =>
      db.records('sensors', colonyId: colonyId, orderBy: 'id').map((r) => r.json).toList();

  /// Changes my settings (synced to all my devices).
  void updateSettings(Map<String, dynamic> patch) => _write(() {
    if (db.record('user_settings', userId) != null) _update('user_settings', userId, patch);
  });

  List<Map<String, dynamic>> openTasks() =>
      db.records('tasks', orderBy: 'id').map((r) => r.json).where((t) => t['done_at'] == null).toList();

  void completeTask(String taskId) => _write(() {
    if (db.record('tasks', taskId) == null) return;
    _update('tasks', taskId, {'done_at': now().toUtc().toIso8601String()});
  });

  // ---------------------------------------------------------------------------
  // „Morgen“ – no time today: postpone by one day (offline, synced).

  /// Care task: not due before tomorrow (the interval continues from the last care).
  /// Returns the previous value (for „Rückgängig“).
  String? snoozeSchedule(String scheduleId) =>
      setScheduleSnooze(scheduleId, startOfTomorrow(now()).toUtc().toIso8601String());

  String? setScheduleSnooze(String scheduleId, String? until) => _write(() {
    final rec = db.record('care_schedules', scheduleId);
    if (rec == null) return null;
    final previous = rec.json['snoozed_until'] as String?;
    _update('care_schedules', scheduleId, {'snoozed_until': until});
    return previous;
  });

  /// Deferral with a reason („Noch ausreichend Wasser“): documented as an
  /// event, the care is not due before the start of the day in [days] days.
  /// Returns the event and the previous snooze (for „Rückgängig“).
  (ColonyEvent, String?)? deferSchedule(String scheduleId, {required String reason, required int days, String? note}) =>
      _write(() {
        final rec = db.record('care_schedules', scheduleId);
        if (rec == null) return null;
        final until = startOfTomorrow(now()).add(Duration(days: days - 1)).toUtc();
        final e = logEvent(
          rec.json['colony_id'] as String,
          'care_deferred',
          note: note,
          details: {
            'schedule_id': scheduleId,
            'payload': {
              'reason': reason,
              'days': days,
              'task_type': rec.json['task_type'],
              'title': ?rec.json['title'],
              'until': until.toIso8601String(),
            },
          },
        );
        final previous = setScheduleSnooze(scheduleId, until.toIso8601String());
        return (e, previous);
      });

  /// One-off task: due tomorrow at the start of the day.
  void snoozeTask(String taskId) => _write(() {
    if (db.record('tasks', taskId) == null) return;
    _update('tasks', taskId, {'due_at': startOfTomorrow(now()).toUtc().toIso8601String()});
  });

  /// Winter rest plan: the pending step (start or end) moves by one day;
  /// a planned end stays after the start.
  void snoozeWinter(String colonyId) => _write(() {
    final w = winterRest(colonyId);
    if (w == null) return;
    DateTime day(DateTime t) => DateTime(t.year, t.month, t.day);
    final today = day(now().toLocal());
    DateTime later(DateTime? a) => a == null || day(a).isBefore(today) ? today : day(a);
    if (w.started) {
      _update('winter_rests', w.id, {
        'planned_end_on': _dateString(later(w.plannedEndOn).add(const Duration(days: 1))),
      });
      return;
    }
    final start = later(w.plannedStartOn).add(const Duration(days: 1));
    final end = w.plannedEndOn;
    _update('winter_rests', w.id, {
      'planned_start_on': _dateString(start),
      if (end != null && !end.isAfter(start)) 'planned_end_on': _dateString(start.add(const Duration(days: 1))),
    });
  });

  /// Colonies I may only look at (no reminders, no „Erledigt“).
  Set<String> readOnlyColonies() => {
    for (final r in db.select(
      '''SELECT colony_id FROM records WHERE entity = 'colony_members'
         AND json_extract(data, '\$.user_id') = ? AND json_extract(data, '\$.role') = 'viewer' ''',
      [userId],
    ))
      r['colony_id'] as String,
  };

  List<Reminder> reminders() {
    final cols = colonies();
    return overdueReminders(
      colonies: cols,
      due: dueAll(cols),
      readOnlyColonies: readOnlyColonies(),
      winterRests: db.records('winter_rests', orderBy: 'id').map((r) => r.json).toList(),
      tasks: openTasks(),
      now: now(),
      notifyOverdue: settings().notifyOverdue,
      notifyWinter: settings().notifyWinterApp,
      notifySensor: settings().notifySensorApp,
      sensorProblems: [
        for (final r in db.select(
          '''SELECT data FROM records WHERE entity = 'colony_events' AND ts > ?
             AND json_extract(data, '\$.type') = 'problem' AND json_extract(data, '\$.payload.source') = 'sensor' ''',
          [now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch],
        ))
          _decode(r['data'] as String),
      ],
      sensors: sensors(),
      foodStocks: foodStocks(),
      flightWatch: [for (final id in settings().flightWatch) ?speciesById(id)],
    );
  }

  /// Watch / unwatch a species' nuptial flight season (synced setting).
  void setFlightWatch(String speciesId, bool on) {
    final ids = {...settings().flightWatch};
    on ? ids.add(speciesId) : ids.remove(speciesId);
    updateSettings({'flight_watch': ids.toList()});
  }

  // ---------------------------------------------------------------------------
  // Food stock

  List<FoodStock> foodStocks({bool includeArchived = false}) =>
      [
        for (final r in db.records('food_stocks', orderBy: 'id'))
          if (includeArchived || r.json['archived_at'] == null) FoodStock(r.json),
      ]..sort((a, b) {
        if (a.isCulture != b.isCulture) return a.isCulture ? 1 : -1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

  /// Stock entries with something to do now (dashboard, reminders).
  List<(FoodStock, List<StockIssue>)> foodStockIssues() => [
    for (final s in foodStocks())
      if (s.issues(now()) case final i when i.isNotEmpty) (s, i),
  ];

  String createFoodStock(Map<String, dynamic> fields) =>
      _write(() => _create('food_stocks', {'kind': 'stock', ...fields})['id'] as String);

  void updateFoodStock(String id, Map<String, dynamic> patch) => _write(() => _update('food_stocks', id, patch));

  void deleteFoodStock(String id) => _write(() => _delete('food_stocks', id));

  /// Culture looked after (fed, cleaned) – next care counts from now.
  void careFoodStock(String id) {
    if (db.record('food_stocks', id) != null) updateFoodStock(id, {'last_cared_at': now().toUtc().toIso8601String()});
  }

  /// Freshly opened / newly made (e.g. honey water) – the shelf life starts today.
  void openFoodStock(String id) {
    if (db.record('food_stocks', id) != null) updateFoodStock(id, {'opened_on': _dateString(now())});
  }

  /// +/- on the quantity (never below 0).
  void adjustFoodStock(String id, double delta) {
    final s = db.record('food_stocks', id);
    if (s == null) return;
    final q = FoodStock(s.json).quantity ?? 0;
    updateFoodStock(id, {'quantity': max(0, q + delta)});
  }

  /// Winter rests whose planned end has passed (for the digest).
  int winterEndsDue() => reminders().where((r) => r.payload['kind'] == 'winter').length;

  /// Planned winter rests whose start has come (for the digest).
  int winterStartsDue() => reminders().where((r) => r.payload['kind'] == 'winter_start').length;

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

  void deactivateScanLink(String id) => _write(() => _update('scan_links', id, {'active': false}));

  /// New QR code; the old printed label stops working. Offline-capable.
  String regenerateQr(String colonyId) => _write(() {
    for (final l in scanLinks(colonyId).where((l) => l.kind == 'qr' && l.active)) {
      _update('scan_links', l.id, {'active': false});
    }
    final token = newScanToken();
    _create('scan_links', {'colony_id': colonyId, 'token': token, 'kind': 'qr', 'active': true});
    return token;
  });

  /// Registers a written (or serial-number-only) NFC tag for a colony.
  /// A tag that was registered before (same serial) is moved over.
  void assignNfc(
    String colonyId, {
    String? uidHashValue,
    String? token,
    String? tagType,
    bool locked = false,
    String? label,
  }) => _write(() {
    if (uidHashValue != null) {
      final old = db.select("SELECT data FROM records WHERE entity = 'nfc_tags' AND $_uidExpr = ?", [
        uidHashValue.toLowerCase(),
      ]);
      for (final r in old) {
        final t = _decode(r['data'] as String);
        _delete('nfc_tags', t['id'] as String);
        final link = t['scan_link_id'] as String?;
        if (link != null && db.record('scan_links', link) != null) _update('scan_links', link, {'active': false});
      }
    }
    String? linkId;
    if (token != null) {
      linkId =
          _create('scan_links', {'colony_id': colonyId, 'token': token, 'kind': 'nfc', 'active': true})['id'] as String;
    }
    if (uidHashValue != null) {
      _create('nfc_tags', {
        'colony_id': colonyId,
        'scan_link_id': ?linkId,
        'uid_hash': uidHashValue.toLowerCase(),
        'tag_type': ?tagType,
        'locked': locked,
        'written_at': token == null ? null : now().toUtc().toIso8601String(),
        'label': ?label,
      });
    }
  });

  void removeNfcTag(String tagId) => _write(() {
    final t = db.record('nfc_tags', tagId)?.json;
    if (t == null) return;
    _delete('nfc_tags', tagId);
    final link = t['scan_link_id'] as String?;
    if (link != null && db.record('scan_links', link) != null) _update('scan_links', link, {'active': false});
  });

  void updateEvent(String eventId, Map<String, dynamic> patch) =>
      _write(() => _update('colony_events', eventId, patch));

  void deleteEvent(String eventId) => _write(() {
    // A photo entry takes its photos with it.
    if (db.record('colony_events', eventId)?.json['type'] == 'photo') {
      for (final p in photosOfEvent(eventId)) {
        _delete('photos', p.id);
        db.removePhotoData(p.id);
      }
    }
    _delete('colony_events', eventId);
  });

  // ---------------------------------------------------------------------------
  // Photos (docs/05 §7): metadata through the outbox, the image in
  // photo_uploads until the sync engine has uploaded it.

  List<Photo> photos(String colonyId) =>
      db.records('photos', colonyId: colonyId, orderBy: 'id').map((r) => Photo(r.json)).toList()
        ..sort((a, b) => b.takenAt.compareTo(a.takenAt));

  List<Photo> photosOfEvent(String eventId) => db
      .select("SELECT data FROM records WHERE entity = 'photos' AND json_extract(data, '\$.event_id') = ?", [eventId])
      .map((r) => Photo(_decode(r['data'] as String)))
      .toList();

  /// Photo count per event of a colony (timeline badges).
  Map<String, List<String>> photoIdsByEvent(String colonyId) {
    final out = <String, List<String>>{};
    for (final p in photos(colonyId)) {
      if (p.eventId != null) (out[p.eventId!] ??= []).add(p.id);
    }
    return out;
  }

  /// Saves a photo – offline. Without [eventId] it becomes its own timeline
  /// entry („Foto“); otherwise it is attached to that event.
  Photo addPhoto(
    String colonyId,
    Uint8List jpeg, {
    required Uint8List thumb,
    String? eventId,
    String? caption,
    DateTime? takenAt,
  }) => _write(() {
    final at = (takenAt ?? now()).toUtc().toIso8601String();
    eventId ??= logEvent(colonyId, 'photo', note: caption, at: takenAt).id;
    final data = _create('photos', {
      'colony_id': colonyId,
      'event_id': eventId,
      'taken_at': at,
      if (caption != null && caption.trim().isNotEmpty) 'caption': caption.trim(),
    });
    final local = {...data, 'upload_state': 'pending', 'created_by': userId};
    db.putRecord('photos', local, pending: true);
    db.putPhotoUpload(data['id'] as String, jpeg, sha256.convert(jpeg).toString());
    db.putThumb(data['id'] as String, thumb);
    return Photo(local);
  });

  void setCaption(String photoId, String caption) => _write(() {
    final p = db.record('photos', photoId);
    if (p == null) return;
    final c = caption.trim();
    _update('photos', photoId, {'caption': c.isEmpty ? null : c});
    final ev = db.record('colony_events', p.json['event_id'] as String? ?? '');
    if (ev != null && ev.json['type'] == 'photo') _update('colony_events', ev.id, {'note': c.isEmpty ? null : c});
  });

  void deletePhoto(String photoId) => _write(() {
    final p = db.record('photos', photoId)?.json;
    if (p == null) return;
    _delete('photos', photoId);
    db.removePhotoData(photoId);
    // The „Foto“ timeline entry goes when its last photo goes.
    final ev = p['event_id'] as String?;
    if (ev != null && db.record('colony_events', ev)?.json['type'] == 'photo' && photosOfEvent(ev).isEmpty) {
      _delete('colony_events', ev);
    }
  });

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

  // ---------------------------------------------------------------------------
  // Care round (docs/02 §8, docs/13 F6). Everything is local: rounds, stops
  // and events sync like any other record, the summary is a local query.

  /// A round without activity for this long counts as finished.
  static const roundTimeout = Duration(hours: 12);

  List<CareRound> _openRounds() =>
      db.records('care_rounds', orderBy: 'id DESC').map((r) => CareRound(r.json)).where((r) => r.open).toList();

  List<RoundStop> _stops(String roundId) => db
      .select(
        "SELECT data FROM records WHERE entity = 'care_round_colonies' AND json_extract(data, '\$.care_round_id') = ?",
        [roundId],
      )
      .map((r) => RoundStop(_decode(r['data'] as String)))
      .toList();

  RoundStop? _stop(String roundId, String colonyId) => _stops(roundId).where((s) => s.colonyId == colonyId).firstOrNull;

  DateTime _lastActivity(CareRound r) {
    var last = r.startedAt;
    for (final s in _stops(r.id)) {
      if (s.visitedAt != null && s.visitedAt!.isAfter(last)) last = s.visitedAt!;
    }
    final e = db.select(
      "SELECT max(ts) AS t FROM records WHERE entity = 'colony_events' AND json_extract(data, '\$.care_round_id') = ?",
      [r.id],
    );
    final t = e.first['t'] as int?;
    if (t != null && t > last.millisecondsSinceEpoch) last = DateTime.fromMillisecondsSinceEpoch(t, isUtc: true);
    return last;
  }

  /// The round in progress (newest open one that is not timed out).
  CareRound? activeRound() {
    for (final r in _openRounds()) {
      if (now().difference(_lastActivity(r)) <= roundTimeout) return r;
    }
    return null;
  }

  /// Ends rounds left open for more than [roundTimeout]; their summary stays.
  void closeStaleRounds() {
    final stale = _openRounds().where((r) => now().difference(_lastActivity(r)) > roundTimeout).toList();
    if (stale.isEmpty) return;
    _write(() {
      for (final r in stale) {
        _update('care_rounds', r.id, {'ended_at': _lastActivity(r).toUtc().toIso8601String()});
      }
    });
  }

  /// Finished rounds, newest first (for „Letzte Rundgänge“).
  List<CareRound> recentRounds({int limit = 5}) {
    final active = activeRound()?.id;
    return db
        .records('care_rounds', orderBy: 'id DESC')
        .map((r) => CareRound(r.json))
        .where((r) => r.id != active)
        .take(limit)
        .toList();
  }

  /// Colonies offered when starting a round.
  List<Colony> roundCandidates(RoundScope scope, {String? locationId}) {
    final cols = colonies().where((c) => c.isCareActive).toList();
    switch (scope) {
      case RoundScope.withTasks:
        final due = dueAll(cols);
        return cols.where((c) => (worstOf(due[c.id] ?? const [])?.days ?? 1) <= 0).toList();
      case RoundScope.allActive:
        return cols;
      case RoundScope.location:
        final loc = locationId == null ? null : _locations()[locationId];
        if (loc == null) return const [];
        return cols
            .where((c) => c.locationPath == loc.path || (c.locationPath?.startsWith('${loc.path}/') ?? false))
            .toList();
    }
  }

  /// Starts a round over [colonyIds]; a round still open is ended first.
  String startRound(List<String> colonyIds, {String? locationId}) => _write(() {
    final t = now().toUtc().toIso8601String();
    for (final r in _openRounds()) {
      _update('care_rounds', r.id, {'ended_at': t});
    }
    final id = _create('care_rounds', {'started_at': t, 'location_id': ?locationId})['id'] as String;
    for (final c in colonyIds.toSet()) {
      _create('care_round_colonies', {'care_round_id': id, 'colony_id': c, 'planned': true});
    }
    return id;
  });

  VisitResult _visit(String roundId, String colonyId) {
    final s = _stop(roundId, colonyId);
    final t = now().toUtc().toIso8601String();
    if (s == null) {
      _create('care_round_colonies', {
        'care_round_id': roundId,
        'colony_id': colonyId,
        'planned': false,
        'visited_at': t,
      });
      return VisitResult.added;
    }
    if (s.visited) return VisitResult.again;
    _update('care_round_colonies', s.id, {'visited_at': t, if (s.skipped) 'skipped': false});
    return VisitResult.first;
  }

  /// A colony was scanned during the round – counts as checked (no event).
  VisitResult visit(String roundId, String colonyId) => _write(() => _visit(roundId, colonyId));

  /// Event types documented for [colonyId] in this round.
  Set<String> doneInRound(String roundId, String colonyId) => {
    for (final r in db.select(
      '''SELECT json_extract(data, '\$.type') AS type FROM records WHERE entity = 'colony_events'
         AND colony_id = ? AND json_extract(data, '\$.care_round_id') = ?''',
      [colonyId, roundId],
    ))
      r['type'] as String,
  };

  RoundProgress? roundProgress(String roundId) {
    final r = db.record('care_rounds', roundId);
    if (r == null) return null;
    final byId = {for (final c in colonies(includeArchived: true)) c.id: c};
    final stops =
        [
          for (final s in _stops(roundId))
            if (byId[s.colonyId] != null) (s, byId[s.colonyId]!),
        ]..sort((a, b) {
          final la = a.$2.locationPath ?? '￿', lb = b.$2.locationPath ?? '￿';
          return la != lb ? la.compareTo(lb) : a.$2.number.compareTo(b.$2.number);
        });
    final done = <String, Set<String>>{};
    for (final e in db.select(
      '''SELECT colony_id, json_extract(data, '\$.type') AS type FROM records WHERE entity = 'colony_events'
         AND json_extract(data, '\$.care_round_id') = ?''',
      [roundId],
    )) {
      (done[e['colony_id'] as String] ??= {}).add(e['type'] as String);
    }
    return RoundProgress(round: CareRound(r.json), stops: stops, done: done);
  }

  void endRound(String roundId) =>
      _write(() => _update('care_rounds', roundId, {'ended_at': now().toUtc().toIso8601String()}));

  /// „Als übersprungen markieren“ for the colonies not scanned.
  void skipUnvisited(String roundId) => _write(() {
    for (final s in _stops(roundId).where((s) => s.planned && !s.visited && !s.skipped)) {
      _update('care_round_colonies', s.id, {'skipped': true});
    }
  });

  RoundSummary? roundSummary(String roundId) {
    final p = roundProgress(roundId);
    if (p == null) return null;
    final counts = <String, int>{};
    for (final types in p.done.values) {
      for (final t in types) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    return RoundSummary(
      round: p.round,
      total: p.total,
      visited: p.visited,
      colonies: counts,
      missing: [
        for (final (s, c) in p.stops)
          if (s.planned && !s.visited && !s.skipped) c,
      ],
      skipped: [
        for (final (s, c) in p.stops)
          if (s.skipped && !s.visited) c,
      ],
    );
  }

  static Map<String, dynamic> _decode(String s) => jsonDecode(s) as Map<String, dynamic>;
}
