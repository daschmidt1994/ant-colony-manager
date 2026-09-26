import 'package:sqlite3/wasm.dart';
import 'package:web/web.dart' as web;

IndexedDbFileSystem? _fs;

Future<CommonDatabase> openPlatformDatabase(String name) async {
  // Resolve against the document base (<base href>), not the current route:
  // on /colonies/<id> a bare 'sqlite3.wasm' would be fetched from /colonies/.
  final wasm = Uri.parse(web.document.baseURI).resolve('sqlite3.wasm');
  final sqlite = await WasmSqlite3.loadFromUrl(wasm);
  final fs = await IndexedDbFileSystem.open(dbName: name);
  sqlite.registerVirtualFileSystem(fs, makeDefault: true);
  _fs = fs;
  return sqlite.open('/$name.db');
}

/// Persists pending IndexedDB writes (also happens automatically).
Future<void> flushPlatformDatabase() async => _fs?.flush();
