import 'dart:io';

import 'package:ant_colony_manager/app/i18n.dart';
import 'package:ant_colony_manager/app/strings.dart';
import 'package:ant_colony_manager/l10n/en.dart' as en;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Source files with UI texts (the translation tables themselves excluded).
List<File> sources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart') && !f.path.contains('/l10n/') && !f.path.endsWith('app/i18n.dart'))
    .toList();

/// Walks Dart source: calls back for every string literal with its text and
/// whether it sits inside a tr( … ) call. Comments are skipped.
void scanLiterals(String src, void Function(String text, bool inTr, int offset) onLiteral) {
  final parens = <bool>[]; // true = this '(' opened a tr call
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (src.startsWith('//', i)) {
      i = src.indexOf('\n', i);
      if (i < 0) return;
      continue;
    }
    if (src.startsWith('/*', i)) {
      i = src.indexOf('*/', i) + 2;
      continue;
    }
    if (c == "'" || c == '"') {
      final raw = i > 0 && src[i - 1] == 'r';
      final triple = src.startsWith(c * 3, i);
      final q = triple ? c * 3 : c;
      final start = i;
      i += q.length;
      final buf = StringBuffer();
      while (i < src.length && !src.startsWith(q, i)) {
        if (!raw && src[i] == r'\') {
          buf.write(src.substring(i, i + 2));
          i += 2;
          continue;
        }
        if (!raw && src.startsWith(r'${', i)) {
          var depth = 1;
          i += 2;
          while (i < src.length && depth > 0) {
            if (src[i] == '{') depth++;
            if (src[i] == '}') depth--;
            i++;
          }
          buf.write(r'${…}');
          continue;
        }
        buf.write(src[i]);
        i++;
      }
      i += q.length;
      onLiteral(buf.toString(), parens.contains(true), start);
      continue;
    }
    if (c == '(') {
      parens.add(i >= 2 && src.substring(i - 2, i) == 'tr' && (i < 3 || !RegExp(r'[\w.]').hasMatch(src[i - 3])));
    } else if (c == ')' && parens.isNotEmpty) {
      parens.removeLast();
    }
    i++;
  }
}

/// All tr('literal' 'adjacent') keys, unescaped like Dart does.
Set<String> trKeys(String src) {
  final out = <String>{};
  final lit = RegExp(r"""\s*('(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*")""");
  for (final m in RegExp(r'(?<![\w.])tr\(').allMatches(src)) {
    var pos = m.end;
    final parts = <String>[];
    while (true) {
      final l = lit.matchAsPrefix(src, pos);
      if (l == null) break;
      final body = l.group(1)!;
      parts.add(
        body
            .substring(1, body.length - 1)
            .replaceAllMapped(RegExp(r'\\(.)'), (e) => e[1] == 'n' ? '\n' : (e[1] == 't' ? '\t' : e[1]!)),
      );
      pos = l.end;
    }
    if (parts.isNotEmpty) out.add(parts.join());
  }
  return out;
}

final _placeholders = RegExp(r'\{\d\}');

void main() {
  setUpAll(() => initializeDateFormatting());
  tearDown(() => setLanguage('de'));

  test('every tr() text has an English translation with the same placeholders', () {
    final missing = <String>[];
    final wrongArgs = <String>[];
    for (final f in sources()) {
      for (final k in trKeys(f.readAsStringSync())) {
        final t = en.table[k];
        if (t == null) {
          missing.add('${f.path}: $k');
        } else if ((_placeholders.allMatches(k).map((m) => m[0]).toList()..sort()).join() !=
            (_placeholders.allMatches(t).map((m) => m[0]).toList()..sort()).join()) {
          wrongArgs.add('$k → $t');
        }
      }
    }
    expect(missing, isEmpty, reason: 'add these to lib/l10n/en.dart');
    expect(wrongArgs, isEmpty);
  });

  test('no German text outside tr()', () {
    final german = RegExp(r'[äöüÄÖÜß]');
    final found = <String>[];
    for (final f in sources()) {
      final src = f.readAsStringSync();
      scanLiterals(src, (text, inTr, offset) {
        if (inTr || !german.hasMatch(text)) return;
        final line = '\n'.allMatches(src.substring(0, offset)).length + 1;
        found.add('${f.path}:$line: $text');
      });
    }
    expect(found, isEmpty, reason: 'wrap user-facing texts in tr()');
  });

  test('switching the language changes texts and date formats', () {
    final d = DateTime(2026, 9, 29, 14, 5);
    expect(tr('Speichern'), 'Speichern');
    expect(S.date(d), '29.09.2026');
    expect(setLanguage('en'), isTrue);
    expect(tr('Speichern'), 'Save');
    expect(tr('{0} Tage überfällig', [3]), '3 days overdue');
    expect(tr('gibt es nicht'), 'gibt es nicht'); // missing → German
    expect(S.date(d), '29 Sep 2026');
    expect(S.statusNames['hibernating'], 'Hibernation');
    expect(setLanguage('xx'), isFalse);
    expect(resolveLanguage('en'), 'en');
    expect(resolveLanguage('de'), 'de');
  });
}
