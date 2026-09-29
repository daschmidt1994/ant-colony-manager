import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/session.dart';
import 'router.dart';
import 'strings.dart';
import 'i18n.dart';
import 'providers.dart';
import 'theme.dart';

/// Global messenger for notices from outside a screen (e.g. an NFC tag was read).
final rootMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Set by CI for the test app (`--dart-define=ACM_TEST_BUILD=true`).
const isTestBuild = bool.fromEnvironment('ACM_TEST_BUILD');

/// Theme preference (system / light / dark), stored locally per device.
final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);

class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => switch (ref.read(databaseProvider).getMeta('theme')) {
    'light' => ThemeMode.light,
    'system' => ThemeMode.system,
    _ => ThemeMode.dark, // dark is the default – pleasant in dim ant rooms
  };

  void set(ThemeMode m) {
    ref.read(databaseProvider).setMeta('theme', m.name);
    state = m;
  }
}

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lang = ref.watch(languageProvider);
    setLanguage(lang);
    return MaterialApp.router(
      title: S.appName,
      debugShowCheckedModeBanner: false,
      // A language switch rebuilds everything (texts come from tr(), not from
      // an inherited widget). Test app (CI build from dev): a corner banner.
      builder: (context, child) => KeyedSubtree(
        key: ValueKey(lang),
        child: isTestBuild
            ? Banner(message: 'TEST', location: BannerLocation.topEnd, color: Colors.deepOrange, child: child!)
            : child!,
      ),
      scaffoldMessengerKey: rootMessengerKey,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: ref.watch(routerProvider),
      locale: Locale(lang),
      supportedLocales: [for (final code in languages.keys) Locale(code)],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
