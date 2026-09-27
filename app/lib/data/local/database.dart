import 'dart:async';
import 'dart:convert';

import 'package:sqlite3/common.dart';

import 'sql_open.dart';

/// A synchronised server row: its JSON representation plus indexed columns.
/// Mirrors the server's generic sync engine – new server fields need no app
/// migration.
class LocalRecord {
  LocalRecord({
    required this.entity,
    required this.id,
    required this.colonyId,
    required this.ts,
    required this.version,
    required this.pending,
    required this.data,
  });

  factory LocalRecord.fromRow(Row r) => LocalRecord(
    entity: r['entity'] as String,
    id: r['id'] as String,
    colonyId: r['colony_id'] as String?,
    ts: r['ts'] as int?,
    version: r['version'] as int,
    pending: (r['pending'] as int) == 1,
    data: r['data'] as String,
  );

  final String entity, id;
  final String? colonyId;
  final int? ts;
  final int version;
  final bool pending;
  final String data;

  Map<String, dynamic> get json => jsonDecode(data) as Map<String, dynamic>;
}

/// An operation waiting for the server (exactly-once via [opId]).
class OutboxOp {
  OutboxOp({
    required this.seq,
    required this.opId,
    required this.entity,
    required this.entityId,
    required this.op,
    required this.payload,
    required this.baseVersion,
    required this.createdAt,
    required this.attempts,
    required this.lastError,
    required this.failed,
  });

  factory OutboxOp.fromRow(Row r) => OutboxOp(
    seq: r['seq'] as int,
    opId: r['op_id'] as String,
    entity: r['entity'] as String,
    entityId: r['entity_id'] as String,
    op: r['op'] as String,
    payload: r['payload'] == null ? null : jsonDecode(r['payload'] as String) as Map<String, dynamic>,
    baseVersion: r['base_version'] as int?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
    attempts: r['attempts'] as int,
    lastError: r['last_error'] as String?,
    failed: (r['failed'] as int) == 1,
  );

  final int seq;
  final String opId, entity, entityId, op;
  final Map<String, dynamic>? payload;
  final int? baseVersion;
  final DateTime createdAt;
  final int attempts;
  final String? lastError;
  final bool failed;

  /// Wire format of `POST /api/v1/sync/push`.
  Map<String, dynamic> toWire() => {
    'op_id': opId,
    'entity': entity,
    'entity_id': entityId,
    'op': op,
    if (payload != null) 'payload': payload,
    if (baseVersion != null && baseVersion! > 0) 'base_version': baseVersion,
    'created_at': createdAt.toUtc().toIso8601String(),
  };
}

/// Result of queuing a delete: whether the record ever reached the server.
enum DeleteOutcome { queued, droppedLocally }

/// Thin, synchronous layer over SQLite with change notifications for
/// reactive UI queries. All writes of one user action happen in one
/// transaction (record + outbox), so a crash never loses half an action.
class AppDatabase {
  AppDatabase(this._db) {
    _migrate();
  }

  static Future<AppDatabase> open() async => AppDatabase(await openPlatformDatabase('ant_colony_manager'));

  final CommonDatabase _db;
  final _changes = StreamController<Set<String>>.broadcast();
  final Set<String> _dirty = {};
  int _txDepth = 0;
  Timer? _flushTimer;

  static const tables = {'records', 'outbox', 'meta'};

  void _migrate() {
    final version = _db.select('PRAGMA user_version').first.values.first as int;
    if (version < 1) {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS records (
          entity TEXT NOT NULL, id TEXT NOT NULL, colony_id TEXT, ts INTEGER,
          version INTEGER NOT NULL DEFAULT 0, pending INTEGER NOT NULL DEFAULT 0,
          data TEXT NOT NULL, PRIMARY KEY (entity, id));
        CREATE INDEX IF NOT EXISTS records_colony_ts ON records (entity, colony_id, ts);
        CREATE TABLE IF NOT EXISTS outbox (
          seq INTEGER PRIMARY KEY AUTOINCREMENT, op_id TEXT NOT NULL UNIQUE,
          entity TEXT NOT NULL, entity_id TEXT NOT NULL, op TEXT NOT NULL, payload TEXT,
          base_version INTEGER, created_at INTEGER NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0, next_try_at INTEGER NOT NULL DEFAULT 0,
          last_error TEXT, failed INTEGER NOT NULL DEFAULT 0, inflight INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS outbox_entity ON outbox (entity, entity_id);
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        PRAGMA user_version = 1;
      ''');
    }
    // Ops that were being sent when the app died are simply sent again –
    // the server deduplicates by op_id.
    _db.execute('UPDATE outbox SET inflight = 0 WHERE inflight = 1');
  }

  void dispose() {
    _flushTimer?.cancel();
    _changes.close();
    _db.close();
  }

  // ---------------------------------------------------------------------------
  // Core

  List<Row> select(String sql, [List<Object?> args = const []]) => _db.select(sql, args).toList();

  void execute(String sql, List<Object?> args, Set<String> touches) {
    _db.execute(sql, args);
    _markDirty(touches);
  }

  void _markDirty(Set<String> t) {
    _dirty.addAll(t);
    if (_txDepth == 0) _emit();
  }

  void _emit() {
    if (_dirty.isEmpty) return;
    final changed = Set<String>.of(_dirty);
    _dirty.clear();
    _changes.add(changed);
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 200), flushPlatformDatabase);
  }

  /// Runs [fn] atomically. Nested calls join the outer transaction.
  T transaction<T>(T Function() fn) {
    if (_txDepth > 0) {
      _txDepth++;
      try {
        return fn();
      } finally {
        _txDepth--;
      }
    }
    _db.execute('BEGIN IMMEDIATE');
    _txDepth = 1;
    try {
      final r = fn();
      _db.execute('COMMIT');
      _txDepth = 0;
      _emit();
      return r;
    } catch (_) {
      _db.execute('ROLLBACK');
      _txDepth = 0;
      _dirty.clear();
      rethrow;
    }
  }

  /// Another process (the background sync) wrote to the database file:
  /// re-run all reactive queries.
  void notifyExternalChange() => _markDirty(tables);

  /// Emits [query] now and again whenever one of [on] changes.
  Stream<T> watch<T>(T Function() query, {Set<String> on = const {'records'}}) {
    late StreamController<T> c;
    StreamSubscription<Set<String>>? sub;
    var scheduled = false;
    void run() {
      scheduled = false;
      if (!c.isClosed) {
        try {
          c.add(query());
        } catch (e, st) {
          c.addError(e, st);
        }
      }
    }

    c = StreamController<T>(
      onListen: () {
        run();
        sub = _changes.stream.listen((t) {
          if (!scheduled && t.any(on.contains)) {
            scheduled = true;
            scheduleMicrotask(run);
          }
        });
      },
      onCancel: () => sub?.cancel(),
    );
    return c.stream;
  }

  // ---------------------------------------------------------------------------
  // Meta

  String? getMeta(String key) {
    final r = select('SELECT value FROM meta WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  void setMeta(String key, String? value) {
    if (value == null) {
      execute('DELETE FROM meta WHERE key = ?', [key], {'meta'});
    } else {
      execute(
        'INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value',
        [key, value],
        {'meta'},
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Records

  static String? colonyIdOf(String entity, Map<String, dynamic> data) =>
      entity == 'colonies' ? data['id'] as String? : data['colony_id'] as String?;

  static int? tsOf(Map<String, dynamic> data) {
    final v = data['occurred_at'];
    return v is String ? DateTime.tryParse(v)?.millisecondsSinceEpoch : null;
  }

  LocalRecord? record(String entity, String id) {
    final r = select('SELECT * FROM records WHERE entity = ? AND id = ?', [entity, id]);
    return r.isEmpty ? null : LocalRecord.fromRow(r.first);
  }

  List<LocalRecord> records(String entity, {String? colonyId, String orderBy = 'ts DESC'}) => select(
    'SELECT * FROM records WHERE entity = ?${colonyId != null ? ' AND colony_id = ?' : ''} ORDER BY $orderBy',
    [entity, ?colonyId],
  ).map(LocalRecord.fromRow).toList();

  void putRecord(String entity, Map<String, dynamic> data, {int? version, bool pending = false}) {
    execute(
      '''INSERT INTO records (entity, id, colony_id, ts, version, pending, data) VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (entity, id) DO UPDATE SET colony_id = excluded.colony_id, ts = excluded.ts,
           version = excluded.version, pending = excluded.pending, data = excluded.data''',
      [
        entity,
        data['id'] as String,
        colonyIdOf(entity, data),
        tsOf(data),
        version ?? (data['version'] as num?)?.toInt() ?? 0,
        pending ? 1 : 0,
        jsonEncode(data),
      ],
      {'records'},
    );
  }

  void removeRecord(String entity, String id) =>
      execute('DELETE FROM records WHERE entity = ? AND id = ?', [entity, id], {'records'});

  /// Removes a colony and everything that belongs to it (access lost).
  void purgeColony(String colonyId) =>
      execute('DELETE FROM records WHERE colony_id = ? AND pending = 0', [colonyId], {'records'});

  bool hasPendingOps(String entity, String id) =>
      select('SELECT 1 FROM outbox WHERE entity = ? AND entity_id = ? AND failed = 0 LIMIT 1', [entity, id]).isNotEmpty;

  /// Deletes all local data (logout or another account).
  void wipe() => transaction(() {
    execute('DELETE FROM records', const [], {'records'});
    execute('DELETE FROM outbox', const [], {'outbox'});
    execute('DELETE FROM meta', const [], {'meta'});
  });

  // ---------------------------------------------------------------------------
  // Outbox

  /// Queues a create. The payload is the full record.
  void queueCreate(String opId, String entity, String id, Map<String, dynamic> payload) {
    _insertOp(opId, entity, id, 'create', payload, null);
  }

  /// Queues changed fields. Unsent changes of the same record are merged into
  /// one operation – but never into one that was already sent: the server may
  /// have applied it with the response lost, and a retry is answered as a
  /// duplicate without looking at the payload again (found by the chaos test).
  void queueUpdate(String opId, String entity, String id, Map<String, dynamic> patch, int baseVersion) {
    transaction(() {
      final last = select(
        'SELECT * FROM outbox WHERE entity = ? AND entity_id = ? AND failed = 0 ORDER BY seq DESC LIMIT 1',
        [entity, id],
      );
      if (last.isNotEmpty) {
        final op = OutboxOp.fromRow(last.first);
        final neverSent = op.attempts == 0 && last.first['inflight'] == 0;
        if (neverSent && (op.op == 'create' || op.op == 'update')) {
          final merged = {...?op.payload, ...patch};
          execute('UPDATE outbox SET payload = ? WHERE seq = ?', [jsonEncode(merged), op.seq], {'outbox'});
          return;
        }
        if (op.op == 'delete') return;
      }
      _insertOp(opId, entity, id, 'update', patch, baseVersion);
    });
  }

  /// Queues a delete. A record that never reached the server is dropped
  /// together with its unsent create.
  DeleteOutcome queueDelete(String opId, String entity, String id) => transaction(() {
    final ops = select('SELECT * FROM outbox WHERE entity = ? AND entity_id = ? AND failed = 0 ORDER BY seq', [
      entity,
      id,
    ]).map(OutboxOp.fromRow).toList();
    // Only a create that was never sent can be dropped – once sent, the server
    // may already have the record, so the delete has to go out too.
    final unsentCreate =
        ops.any((o) => o.op == 'create') &&
        select('SELECT 1 FROM outbox WHERE entity = ? AND entity_id = ? AND (inflight = 1 OR attempts > 0)', [
          entity,
          id,
        ]).isEmpty;
    if (unsentCreate) {
      execute('DELETE FROM outbox WHERE entity = ? AND entity_id = ? AND failed = 0', [entity, id], {'outbox'});
      return DeleteOutcome.droppedLocally;
    }
    execute(
      'DELETE FROM outbox WHERE entity = ? AND entity_id = ? AND failed = 0 AND inflight = 0 AND op = ?',
      [entity, id, 'update'],
      {'outbox'},
    );
    _insertOp(opId, entity, id, 'delete', null, null);
    return DeleteOutcome.queued;
  });

  void _insertOp(String opId, String entity, String id, String op, Map<String, dynamic>? payload, int? base) {
    execute(
      '''INSERT INTO outbox (op_id, entity, entity_id, op, payload, base_version, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)''',
      [opId, entity, id, op, payload == null ? null : jsonEncode(payload), base, DateTime.now().millisecondsSinceEpoch],
      {'outbox'},
    );
  }

  /// Takes up to [limit] sendable ops and marks them in flight.
  List<OutboxOp> takeOps(int limit) => transaction(() {
    final rows = select(
      'SELECT * FROM outbox WHERE failed = 0 AND inflight = 0 AND next_try_at <= ? ORDER BY seq LIMIT ?',
      [DateTime.now().millisecondsSinceEpoch, limit],
    ).map(OutboxOp.fromRow).toList();
    if (rows.isNotEmpty) {
      // Counted as an attempt as soon as it leaves – even if the app dies mid-request.
      execute(
        'UPDATE outbox SET inflight = 1, attempts = attempts + 1 WHERE seq IN (${rows.map((o) => o.seq).join(',')})',
        const [],
        {'outbox'},
      );
    }
    return rows;
  });

  void completeOp(int seq) => execute('DELETE FROM outbox WHERE seq = ?', [seq], {'outbox'});

  void failOp(int seq, String error) =>
      execute('UPDATE outbox SET failed = 1, inflight = 0, last_error = ? WHERE seq = ?', [error, seq], {'outbox'});

  /// Network trouble: release ops and retry later with exponential backoff.
  void retryLater(List<int> seqs, String error) {
    if (seqs.isEmpty) return;
    transaction(() {
      for (final seq in seqs) {
        final a = (select('SELECT attempts FROM outbox WHERE seq = ?', [seq]).firstOrNull?['attempts'] as int?) ?? 0;
        final delay = Duration(seconds: [1 << a.clamp(1, 10), 900].reduce((x, y) => x < y ? x : y));
        execute(
          'UPDATE outbox SET inflight = 0, last_error = ?, next_try_at = ? WHERE seq = ?',
          [error, DateTime.now().add(delay).millisecondsSinceEpoch, seq],
          {'outbox'},
        );
      }
    });
  }

  /// Makes all queued ops immediately eligible again (connectivity regained).
  void resetBackoff() => execute('UPDATE outbox SET next_try_at = 0 WHERE failed = 0', const [], {'outbox'});

  int pendingOpCount() => select('SELECT count(*) AS n FROM outbox WHERE failed = 0').first['n'] as int;

  List<OutboxOp> failedOps() =>
      select('SELECT * FROM outbox WHERE failed = 1 ORDER BY seq DESC').map(OutboxOp.fromRow).toList();

  void dismissFailed() => execute('DELETE FROM outbox WHERE failed = 1', const [], {'outbox'});
}
