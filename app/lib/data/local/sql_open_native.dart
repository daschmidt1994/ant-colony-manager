import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart';

Future<CommonDatabase> openPlatformDatabase(String name) async {
  final dir = await getApplicationDocumentsDirectory();
  return sqlite3.open('${dir.path}/$name.db');
}

/// Native SQLite writes synchronously; nothing to flush.
Future<void> flushPlatformDatabase() async {}
