import 'package:intl/intl.dart';

import '../domain/due.dart';
import '../domain/models.dart';
import 'i18n.dart';

/// UI texts and formatting in one place. Texts go through tr() (German is the
/// source, see i18n.dart); dates and numbers follow the current language.
abstract final class S {
  static const appName = 'Ant Colony Manager';

  static Map<String, String> get taskNames => {
    'protein': tr('Protein'),
    'carbohydrate': tr('Kohlenhydrate'),
    'feeding': tr('Fütterung'),
    'water': tr('Wasser'),
    'cleaning': tr('Reinigung'),
    'check': tr('Kontrolle'),
    'custom': tr('Aufgabe'),
  };

  static Map<String, String> get statusNames => {
    'founding': tr('Gründung'),
    'active': tr('aktiv'),
    'hibernating': tr('Winterruhe'),
    'paused': tr('pausiert'),
    'given_away': tr('abgegeben'),
    'sold': tr('verkauft'),
    'deceased': tr('verstorben'),
  };

  static Map<String, String> get gyneNames => {
    'monogyne': tr('monogyn'),
    'polygyne': tr('polygyn'),
    'unknown': tr('unbekannt'),
  };

  static Map<String, String> get waterKinds => {
    'drinker_refilled': tr('Tränke aufgefüllt'),
    'nest_moistened': tr('Nest befeuchtet'),
    'tank_refilled': tr('Wassertank aufgefüllt'),
    'water_changed': tr('Wasser gewechselt'),
  };

  static Map<String, String> get cleaningKinds => {
    'food_remains': tr('Futterreste'),
    'midden': tr('Müllplatz'),
    'arena': tr('Arena'),
    'glass': tr('Scheiben'),
    'drinker': tr('Tränke'),
    'nest': tr('Nest'),
    'other': tr('Sonstiges'),
  };

  static Map<String, String> get acceptance => {
    'accepted': tr('angenommen'),
    'partial': tr('teilweise'),
    'ignored': tr('ignoriert'),
    'unknown': tr('unbekannt'),
  };

  static Map<String, String> get broodStages => {
    'eggs': tr('Eier'),
    'larvae': tr('Larven'),
    'pupae': tr('Puppen'),
    'naked_pupae': tr('nackte Puppen'),
    'alates': tr('Geschlechtstiere'),
  };
  static Map<String, String> get broodLevels => {
    'none': tr('keine'),
    'few': tr('wenig'),
    'medium': tr('mittel'),
    'many': tr('viel'),
  };

  static Map<String, String> get eventTypes => {
    'feeding': tr('Fütterung'),
    'water': tr('Wasser'),
    'cleaning': tr('Reinigung'),
    'check': tr('Kontrolle'),
    'note': tr('Notiz'),
    'problem': tr('Problem'),
    'photo': tr('Foto'),
    'measurement': tr('Messung'),
    'census': tr('Koloniegröße'),
    'brood': tr('Brut'),
    'habitat_move': tr('Nestwechsel'),
    'queen': tr('Königin'),
    'winter_start': tr('Winterruhe begonnen'),
    'winter_end': tr('Winterruhe beendet'),
    'status_change': tr('Status geändert'),
    'custom_task': tr('Aufgabe erledigt'),
  };

  static String number(num n) => NumberFormat.decimalPattern(currentLanguage).format(n);
  static String decimal(num n) => NumberFormat('0.0', currentLanguage).format(n);

  static String workers(int? min, int? max) {
    if (min == null && max == null) return '–';
    if (max == null) return '${number(min!)}+';
    if (min == max) return number(min!);
    return '${number(min ?? 0)}–${number(max)}';
  }

  static String dueText(DueTask t) {
    final d = t.days;
    return switch (t.status) {
      DueStatus.paused => tr('pausiert'),
      DueStatus.overdue => d == -1 ? tr('1 Tag überfällig') : tr('{0} Tage überfällig', [-d]),
      _ => switch (d) {
        0 => tr('heute'),
        1 => tr('morgen'),
        _ => tr('in {0} Tagen', [d]),
      },
    };
  }

  /// Date patterns per language: German numeric, otherwise unambiguous („29 Sep 2026“).
  static bool get _de => currentLanguage == 'de';
  static DateFormat _f(String de, String other) => DateFormat(_de ? de : other, currentLanguage);

  static String relativeDay(DateTime t, DateTime now) {
    final days = calendarDays(deviceLocalDate(t), deviceLocalDate(now));
    return switch (days) {
      0 => tr('Heute'),
      1 => tr('Gestern'),
      < 7 => tr('Vor {0} Tagen', [days]),
      _ => _f('d. MMMM y', 'd MMMM y').format(t.toLocal()),
    };
  }

  /// relativeDay inside a sentence: „heute“, „vor 3 Tagen“, a date stays as is.
  static String relativeDayInline(DateTime t, DateTime now) {
    final r = relativeDay(t, now);
    final days = calendarDays(deviceLocalDate(t), deviceLocalDate(now));
    return days < 7 && r.isNotEmpty ? r[0].toLowerCase() + r.substring(1) : r;
  }

  static String time(DateTime t) => DateFormat('HH:mm', currentLanguage).format(t.toLocal());
  static String date(DateTime t) => _f('dd.MM.y', 'd MMM y').format(t.toLocal());
  static String dateTime(DateTime t) => _f('dd.MM.y, HH:mm', 'd MMM y, HH:mm').format(t.toLocal());

  /// Short day for charts and lists: „14.8.“ / „14 Aug“.
  static String dayMonth(DateTime t) => _f('d.M.', 'd MMM').format(t);

  /// Any pattern in the current language (month names …).
  static String format(String pattern, DateTime t) => DateFormat(pattern, currentLanguage).format(t);

  /// Food names of the shipped catalogue are translated; own names stay.
  static String foodName(String name) => tr(name);

  static String quantity(FeedingItem i) {
    final q = i.quantity;
    final food = foodName(i.foodName);
    if (q == null) return food;
    final n = q == q.roundToDouble() ? q.toInt().toString() : decimal(q);
    final size = switch (i.size) {
      'tiny' => tr(' (winzig)'),
      'small' => tr(' (klein)'),
      'large' => tr(' (groß)'),
      _ => '',
    };
    return switch (i.unit) {
      'drop' => tr('{0} Tropfen {1}', [n, food]),
      'ml' => '$n ml $food',
      'g' => '$n g $food',
      'portion' => '$n× $food',
      _ => '$n× $food$size',
    };
  }

  /// One-line summary of an event for timeline and snackbars.
  static String eventSummary(ColonyEvent e) {
    switch (e.type) {
      case 'feeding':
        final items = e.items.map(quantity).join(' + ');
        return items.isEmpty ? tr('Gefüttert') : items;
      case 'water':
        return e.waterKinds.map((k) => waterKinds[k] ?? k).join(', ');
      case 'cleaning':
        return tr('Gereinigt: {0}', [e.cleaningKinds.map((k) => cleaningKinds[k] ?? k).join(', ')]);
      case 'measurement':
        return e.measurements.map(measurementText).join(' · ');
      case 'census':
        final c = e.census ?? const {};
        final exact = c['exact_count'] as num?;
        final size = exact != null
            ? number(exact)
            : workers((c['estimate_min'] as num?)?.toInt(), (c['estimate_max'] as num?)?.toInt());
        return tr('Koloniegröße: {0}', [size]);
      case 'brood':
        final stages = ((e.json['brood'] as List?) ?? const []).cast<Map<String, dynamic>>();
        final parts = stages.map(
          (b) => '${broodStages[b['stage']] ?? b['stage']} ${broodLevels[b['level']] ?? b['exact_count'] ?? ''}'.trim(),
        );
        return tr('Brut: {0}', [parts.join(', ')]);
      case 'check':
        return e.note?.isNotEmpty == true ? tr('Kontrolle: {0}', [e.note]) : tr('Kontrolle – alles in Ordnung');
      case 'note':
      case 'problem':
        return e.note ?? eventTypes[e.type]!;
      default:
        return eventTypes[e.type] ?? e.type;
    }
  }

  static String measurementText(Map<String, dynamic> m) {
    final v = (m['value'] as num).toDouble();
    return m['metric'] == 'temperature' ? '${decimal(v)} °C' : '${v.round()} %';
  }
}
