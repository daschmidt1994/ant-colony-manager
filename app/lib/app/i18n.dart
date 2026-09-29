/// Translations: German is the source text, every other language is a table
/// „German text → translation“ in lib/l10n/<code>.dart. A missing entry shows
/// the German text. Placeholders are {0}, {1}, … (positional).
///
///   Text(tr('Speichern'))
///   tr('seit {0} Tagen überfällig', [days])
///
/// A new language: copy lib/l10n/en.dart, translate the values, register it
/// in [languages]. test/i18n_test.dart checks that no text is missing.
library;

import 'dart:ui' show PlatformDispatcher;

import '../l10n/en.dart' as en;

/// Supported languages: code → (native name, table; null = German source).
final languages = <String, (String, Map<String, String>?)>{'de': ('Deutsch', null), 'en': ('English', en.table)};

String _lang = 'de';
Map<String, String>? _table;

/// Current language code ('de', 'en', …) – for dates and numbers too.
String get currentLanguage => _lang;

/// [setting] from user_settings.locale: a language code or 'system'.
String resolveLanguage(String? setting) {
  if (setting != null && languages.containsKey(setting)) return setting;
  final device = PlatformDispatcher.instance.locale.languageCode;
  return languages.containsKey(device) ? device : (setting == 'system' ? 'en' : 'de');
}

/// Switches the language; returns true if it changed.
bool setLanguage(String code) {
  if (!languages.containsKey(code) || code == _lang) return false;
  _lang = code;
  _table = languages[code]!.$2;
  return true;
}

String tr(String de, [List<Object?> args = const []]) {
  var s = _table?[de] ?? de;
  for (var i = 0; i < args.length; i++) {
    s = s.replaceAll('{$i}', '${args[i]}');
  }
  return s;
}
