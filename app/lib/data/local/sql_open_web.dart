import 'package:sqlite3/wasm.dart';

IndexedDbFileSystem? _fs;

Future<CommonDatabase> openPlatformDatabase(String name) async {
  // sqlite3.wasm is served next to index.html (see web/ and tool/fetch_web_assets.sh).
  final sqlite = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
  final fs = await IndexedDbFileSystem.open(dbName: name);
  sqlite.registerVirtualFileSystem(fs, makeDefault: true);
  _fs = fs;
  return sqlite.open('/$name.db');
}

/// Persists pending IndexedDB writes (also happens automatically).
Future<void> flushPlatformDatabase() async => _fs?.flush();
