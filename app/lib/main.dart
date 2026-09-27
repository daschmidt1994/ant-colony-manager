import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app/app.dart';
import 'app/theme.dart';
import 'core/tab_guard.dart';
import 'core/session.dart';
import 'data/local/database.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy(); // real paths like /c/<code> instead of /#/c/<code>
  await initializeDateFormatting('de');
  if (await otherTabActive()) {
    runApp(const OtherTabApp());
    return;
  }
  final db = await AppDatabase.open();
  runApp(ProviderScope(overrides: [databaseProvider.overrideWithValue(db)], child: const App()));
}

/// Shown in a second browser tab: the first tab owns the local database.
class OtherTabApp extends StatelessWidget {
  const OtherTabApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.dark),
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.tab, size: 56),
              const SizedBox(height: 16),
              const Text('Die App ist bereits in einem anderen Tab geöffnet.', textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text(
                'Bitte dort weiterarbeiten – oder den anderen Tab schließen und hier neu laden.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              const FilledButton(onPressed: reloadPage, child: Text('Neu laden')),
            ],
          ),
        ),
      ),
    ),
  );
}
