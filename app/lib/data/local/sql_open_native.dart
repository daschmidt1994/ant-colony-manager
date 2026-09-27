import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart';

Future<CommonDatabase> openPlatformDatabase(String name) async {
  final dir = await getApplicationDocumentsDirectory();
  final db = sqlite3.open('${dir.path}/$name.db');
  // Background isolates (WorkManager sync, „Erledigt“ from a notification)
  // open the same file: WAL lets them read while the app writes, and a short
  // wait instead of an immediate SQLITE_BUSY.
  db.execute('PRAGMA journal_mode = WAL');
  db.execute('PRAGMA busy_timeout = 5000');
  return db;
}

/// Native SQLite writes synchronously; nothing to flush.
Future<void> flushPlatformDatabase() async {}
