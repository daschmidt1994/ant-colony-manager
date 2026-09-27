import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api_client.dart';
import '../local/database.dart';

enum SyncPhase { idle, syncing, offline, error, loginRequired, deviceRevoked }

@immutable
class SyncStatus {
  const SyncStatus({this.phase = SyncPhase.idle, this.pending = 0, this.failed = 0, this.lastSync, this.message});
  final SyncPhase phase;
  final int pending;
  final int failed;
  final DateTime? lastSync;
  final String? message;

  SyncStatus copyWith({SyncPhase? phase, int? pending, int? failed, DateTime? lastSync, String? message}) => SyncStatus(
    phase: phase ?? this.phase,
    pending: pending ?? this.pending,
    failed: failed ?? this.failed,
    lastSync: lastSync ?? this.lastSync,
    message: message,
  );
}

class DeviceIdentity {
  const DeviceIdentity({required this.id, required this.name, required this.platform, required this.appVersion});
  final String id, name, platform, appVersion;
}

/// Offline-first synchronisation (see docs/05-sync.md):
///   1. push the outbox (idempotent – op_id)
///   2. pull changes after the cursor
///   3. full snapshot on first sync or when the cursor is too old (410)
class SyncEngine {
  SyncEngine({required this.db, required this.api, required this.device, required this.userId});

  final AppDatabase db;
  final ApiClient api;
  final DeviceIdentity device;
  final String userId;

  final _status = StreamController<SyncStatus>.broadcast();
  SyncStatus _current = const SyncStatus();
  bool _running = false;
  bool _again = false;
  Timer? _debounce;
  Timer? _periodic;

  static const _cursorKey = 'sync_cursor';
  static const _lastSyncKey = 'sync_last';

  Stream<SyncStatus> get status => _status.stream;
  SyncStatus get current => _current;

  void start({Duration every = const Duration(minutes: 2)}) {
    final last = db.getMeta(_lastSyncKey);
    _set(_current.copyWith(lastSync: last == null ? null : DateTime.tryParse(last)));
    _periodic ??= Timer.periodic(every, (_) => sync());
    sync();
  }

  void dispose() {
    _debounce?.cancel();
    _periodic?.cancel();
    _status.close();
  }

  /// Called after every local write – bundles quick successive actions.
  void schedule([Duration delay = const Duration(milliseconds: 1500)]) {
    _debounce?.cancel();
    _debounce = Timer(delay, sync);
  }

  void _set(SyncStatus s) {
    _current = s.copyWith(pending: db.pendingOpCount(), failed: db.failedOps().length);
    if (!_status.isClosed) _status.add(_current);
  }

  /// Runs one full cycle. Concurrent calls are coalesced.
  Future<void> sync({bool resetBackoff = false}) async {
    if (resetBackoff) db.resetBackoff();
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        _set(_current.copyWith(phase: SyncPhase.syncing));
        try {
          final needSnapshot = await _push();
          if (needSnapshot || db.getMeta(_cursorKey) == null) {
            await snapshot();
          } else {
            await _pull();
          }
          final now = DateTime.now();
          db.setMeta(_lastSyncKey, now.toIso8601String());
          _set(_current.copyWith(phase: SyncPhase.idle, lastSync: now));
        } on NetworkException {
          _set(_current.copyWith(phase: SyncPhase.offline, message: 'Keine Verbindung zum Server'));
          return;
        } on DeviceRevokedException {
          _set(_current.copyWith(phase: SyncPhase.deviceRevoked, message: 'Dieses Gerät wurde abgemeldet'));
          return;
        } on SessionExpiredException {
          _set(_current.copyWith(phase: SyncPhase.loginRequired, message: 'Bitte erneut anmelden'));
          return;
        } on ApiException catch (e) {
          _set(_current.copyWith(phase: SyncPhase.error, message: e.title));
          return;
        }
      } while (_again);
    } finally {
      _running = false;
    }
  }

  // ---------------------------------------------------------------------------

  /// Sends the outbox. Returns true if a snapshot is needed afterwards
  /// (a rejection left local data that may differ from the server).
  Future<bool> _push() async {
    var needSnapshot = false;
    while (true) {
      final ops = db.takeOps(100);
      if (ops.isEmpty) return needSnapshot;
      final Map<String, dynamic> res;
      try {
        res =
            await api.post('/api/v1/sync/push', {
                  'device_id': device.id,
                  'device_name': device.name,
                  'platform': device.platform,
                  'app_version': device.appVersion,
                  'ops': ops.map((o) => o.toWire()).toList(),
                })
                as Map<String, dynamic>;
      } on NetworkException catch (e) {
        db.retryLater(ops.map((o) => o.seq).toList(), e.toString());
        rethrow;
      } catch (e) {
        db.retryLater(ops.map((o) => o.seq).toList(), e.toString());
        rethrow;
      }
      final results = {for (final r in (res['results'] as List).cast<Map<String, dynamic>>()) r['op_id'] as String: r};
      db.transaction(() {
        for (final op in ops) {
          final r = results[op.opId];
          if (r == null) {
            db.retryLater([op.seq], 'no result');
            continue;
          }
          switch (r['status']) {
            case 'applied' || 'duplicate' || 'merged':
              db.completeOp(op.seq);
              // merged fields arrive with the following pull (the record is no longer pending)
              _confirm(op, (r['version'] as num?)?.toInt() ?? 0);
            default:
              final err = (r['error'] as Map?)?['title'] as String? ?? 'abgelehnt';
              db.failOp(op.seq, err);
              if (op.op == 'create') db.removeRecord(op.entity, op.entityId);
              needSnapshot = true; // local state may differ from the server now
          }
        }
      });
    }
  }

  void _confirm(OutboxOp op, int version) {
    if (op.op == 'delete') return;
    final rec = db.record(op.entity, op.entityId);
    if (rec == null) return;
    db.putRecord(op.entity, rec.json, version: version, pending: db.hasPendingOps(op.entity, op.entityId));
  }

  Future<void> _pull() async {
    var cursor = int.parse(db.getMeta(_cursorKey) ?? '0');
    final newlyShared = <String>{};
    while (true) {
      final Map<String, dynamic> res;
      try {
        res = await api.get('/api/v1/sync/pull', query: {'since': '$cursor', 'limit': '500'}) as Map<String, dynamic>;
      } on ApiException catch (e) {
        if (e.status == 410) return snapshot(); // cursor older than the tombstone horizon
        rethrow;
      }
      final changes = (res['changes'] as List).cast<Map<String, dynamic>>();
      db.transaction(() {
        for (final c in changes) {
          _apply(c, newlyShared);
        }
        cursor = (res['next'] as num).toInt();
        db.setMeta(_cursorKey, '$cursor');
      });
      if (res['has_more'] != true) break;
    }
    if (newlyShared.isNotEmpty) await snapshot(onlyColonies: newlyShared);
  }

  void _apply(Map<String, dynamic> c, Set<String> newlyShared) {
    final entity = c['entity'] as String;
    final id = c['id'] as String;
    if (db.hasPendingOps(entity, id)) return; // local changes win until pushed
    if (c['op'] == 'delete') {
      if (entity == 'colony_members') {
        final m = db.record(entity, id)?.json;
        if (m != null && m['user_id'] == userId) db.purgeColony(m['colony_id'] as String);
      }
      // A deleted colony takes its events, schedules, links … with it.
      if (entity == 'colonies') db.purgeColony(id);
      db.removeRecord(entity, id);
      return;
    }
    final data = (c['data'] as Map).cast<String, dynamic>();
    if (entity == 'colony_members' &&
        data['user_id'] == userId &&
        data['role'] != 'owner' &&
        db.record('colonies', data['colony_id'] as String) == null) {
      newlyShared.add(data['colony_id'] as String);
    }
    db.putRecord(entity, data, version: (data['version'] as num?)?.toInt());
  }

  /// Replaces local state with the server state (keeping unsent changes).
  Future<void> snapshot({Set<String>? onlyColonies}) async {
    final res =
        await api.get(
              '/api/v1/sync/snapshot',
              query: onlyColonies == null ? null : {'colony_ids': onlyColonies.join(',')},
            )
            as Map<String, dynamic>;
    final entities = (res['entities'] as Map).cast<String, dynamic>();
    db.transaction(() {
      if (onlyColonies == null) {
        db.execute('DELETE FROM records WHERE pending = 0', const [], {'records'});
      }
      entities.forEach((entity, rows) {
        for (final row in (rows as List).cast<Map<String, dynamic>>()) {
          if (!db.hasPendingOps(entity, row['id'] as String)) {
            db.putRecord(entity, row, version: (row['version'] as num?)?.toInt());
          }
        }
      });
      if (onlyColonies == null) db.setMeta(_cursorKey, '${res['cursor']}');
    });
  }
}
