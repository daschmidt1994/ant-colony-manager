import 'dart:convert';

import 'package:ant_colony_manager/core/api_client.dart';
import 'package:ant_colony_manager/data/local/database.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

AppDatabase memoryDb() => AppDatabase(sqlite3.openInMemory());

class MemoryTokens implements TokenStore {
  String? token = 'refresh';
  @override
  Future<String?> readRefresh() async => token;
  @override
  Future<void> writeRefresh(String? t) async => token = t;
}

/// Minimal in-memory imitation of the server's sync API, including its
/// exactly-once semantics, so the app's sync engine can be tested in
/// isolation. The real server contract is covered by the Go tests.
class FakeServer {
  bool online = true;

  /// Apply the next push but lose the response (network drop after commit).
  bool dropNextResponse = false;
  int seq = 0;
  final appliedOps = <String, Map<String, dynamic>>{};
  final rows = <String, Map<String, Map<String, dynamic>>>{}; // entity -> id -> row
  final log = <Map<String, dynamic>>[]; // change log
  final rejectEntities = <String>{};
  int horizon = 0;
  int pushes = 0;

  int count(String entity) => rows[entity]?.values.where((r) => r['deleted_at'] == null).length ?? 0;

  void put(String entity, Map<String, dynamic> row, {bool deleted = false}) {
    seq++;
    final r = {...row, 'version': seq, if (deleted) 'deleted_at': '2026-01-01T00:00:00Z'};
    (rows[entity] ??= {})[row['id'] as String] = r;
    log.add({'seq': seq, 'entity': entity, 'id': row['id'], 'op': deleted ? 'delete' : 'upsert'});
  }

  late final http.Client client = MockClient((req) async {
    if (!online) throw http.ClientException('offline');
    final path = req.url.path;
    if (path == '/api/v1/sync/push') {
      pushes++;
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final results = <Map<String, dynamic>>[];
      for (final op in (body['ops'] as List).cast<Map<String, dynamic>>()) {
        final id = op['op_id'] as String;
        if (appliedOps.containsKey(id)) {
          results.add({...appliedOps[id]!, 'status': 'duplicate'});
          continue;
        }
        Map<String, dynamic> result;
        final entity = op['entity'] as String;
        final eid = op['entity_id'] as String;
        if (rejectEntities.contains(entity)) {
          result = {
            'op_id': id,
            'status': 'rejected',
            'error': {'code': 'validation', 'title': 'nope'},
          };
        } else if (op['op'] == 'create' && rows[entity]?.containsKey(eid) == true) {
          result = {'op_id': id, 'status': 'duplicate', 'version': rows[entity]![eid]!['version']};
        } else if (op['op'] == 'delete') {
          put(entity, rows[entity]![eid]!, deleted: true);
          result = {'op_id': id, 'status': 'applied', 'version': seq};
        } else {
          put(entity, {...?rows[entity]?[eid], ...(op['payload'] as Map<String, dynamic>), 'id': eid});
          result = {'op_id': id, 'status': 'applied', 'version': seq};
        }
        appliedOps[id] = result;
        results.add(result);
      }
      if (dropNextResponse) {
        dropNextResponse = false;
        throw http.ClientException('connection reset after commit');
      }
      return _json({'results': results, 'server_seq': seq});
    }
    if (path == '/api/v1/sync/pull') {
      final since = int.parse(req.url.queryParameters['since']!);
      if (since < horizon) return _json({'code': 'sync.resync_required', 'title': 'resync'}, 410);
      final changes = [
        for (final c in log.where((c) => (c['seq'] as int) > since))
          {...c, if (c['op'] == 'upsert') 'data': rows[c['entity']]![c['id']]},
      ];
      return _json({'changes': changes, 'next': seq, 'has_more': false});
    }
    if (path == '/api/v1/sync/snapshot') {
      return _json({
        'cursor': seq,
        'entities': {
          for (final e in rows.entries) e.key: e.value.values.where((r) => r['deleted_at'] == null).toList(),
        },
      });
    }
    if (path == '/api/v1/auth/refresh') {
      return _json({'access_token': 'a2', 'refresh_token': 'r2'});
    }
    return _json({'code': 'route.not_found', 'title': 'not found'}, 404);
  });

  static http.Response _json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
}
