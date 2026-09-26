import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app/app.dart';
import 'core/session.dart';
import 'data/local/database.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy(); // real paths like /c/<code> instead of /#/c/<code>
  await initializeDateFormatting('de');
  final db = await AppDatabase.open();
  runApp(ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const App(),
  ));
}
