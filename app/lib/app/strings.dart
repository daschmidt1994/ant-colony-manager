import 'package:intl/intl.dart';

import '../domain/due.dart';
import '../domain/models.dart';

/// German UI texts and formatting in one place (prepared for translation).
abstract final class S {
  static const appName = 'Ant Colony Manager';

  static const taskNames = {
    'protein': 'Protein',
    'carbohydrate': 'Kohlenhydrate',
    'feeding': 'Fütterung',
    'water': 'Wasser',
    'cleaning': 'Reinigung',
    'check': 'Kontrolle',
    'custom': 'Aufgabe',
  };

  static const statusNames = {
    'founding': 'Gründung',
    'active': 'aktiv',
    'hibernating': 'Winterruhe',
    'paused': 'pausiert',
    'given_away': 'abgegeben',
    'sold': 'verkauft',
    'deceased': 'verstorben',
  };

  static const gyneNames = {'monogyne': 'monogyn', 'polygyne': 'polygyn', 'unknown': 'unbekannt'};

  static const waterKinds = {
    'drinker_refilled': 'Tränke aufgefüllt',
    'nest_moistened': 'Nest befeuchtet',
    'tank_refilled': 'Wassertank aufgefüllt',
    'water_changed': 'Wasser gewechselt',
  };

  static const cleaningKinds = {
    'food_remains': 'Futterreste',
    'midden': 'Müllplatz',
    'arena': 'Arena',
    'glass': 'Scheiben',
    'drinker': 'Tränke',
    'nest': 'Nest',
    'other': 'Sonstiges',
  };

  static const acceptance = {
    'accepted': 'angenommen',
    'partial': 'teilweise',
    'ignored': 'ignoriert',
    'unknown': 'unbekannt',
  };

  static const broodStages = {
    'eggs': 'Eier',
    'larvae': 'Larven',
    'pupae': 'Puppen',
    'naked_pupae': 'nackte Puppen',
    'alates': 'Geschlechtstiere',
  };
  static const broodLevels = {'none': 'keine', 'few': 'wenig', 'medium': 'mittel', 'many': 'viel'};

  static const eventTypes = {
    'feeding': 'Fütterung',
    'water': 'Wasser',
    'cleaning': 'Reinigung',
    'check': 'Kontrolle',
    'note': 'Notiz',
    'problem': 'Problem',
    'photo': 'Foto',
    'measurement': 'Messung',
    'census': 'Koloniegröße',
    'brood': 'Brut',
    'habitat_move': 'Nestwechsel',
    'queen': 'Königin',
    'winter_start': 'Winterruhe begonnen',
    'winter_end': 'Winterruhe beendet',
    'status_change': 'Status geändert',
    'custom_task': 'Aufgabe erledigt',
  };

  static final _num = NumberFormat.decimalPattern('de');
  static final _dec1 = NumberFormat('0.0', 'de');

  static String number(num n) => _num.format(n);
  static String decimal(num n) => _dec1.format(n);

  static String workers(int? min, int? max) {
    if (min == null && max == null) return '–';
    if (max == null) return '${number(min!)}+';
    if (min == max) return number(min!);
    return '${number(min ?? 0)}–${number(max)}';
  }

  static String dueText(DueTask t) {
    final d = t.days;
    return switch (t.status) {
      DueStatus.paused => 'pausiert',
      DueStatus.overdue => d == -1 ? '1 Tag überfällig' : '${-d} Tage überfällig',
      _ => switch (d) {
        0 => 'heute',
        1 => 'morgen',
        _ => 'in $d Tagen',
      },
    };
  }

  static String relativeDay(DateTime t, DateTime now) {
    final days = calendarDays(deviceLocalDate(t), deviceLocalDate(now));
    return switch (days) {
      0 => 'Heute',
      1 => 'Gestern',
      < 7 => 'Vor $days Tagen',
      _ => DateFormat('d. MMMM y', 'de').format(t.toLocal()),
    };
  }

  static String time(DateTime t) => DateFormat('HH:mm', 'de').format(t.toLocal());
  static String date(DateTime t) => DateFormat('dd.MM.y', 'de').format(t.toLocal());
  static String dateTime(DateTime t) => DateFormat('dd.MM.y, HH:mm', 'de').format(t.toLocal());

  static String quantity(FeedingItem i) {
    final q = i.quantity;
    if (q == null) return i.foodName;
    final n = q == q.roundToDouble() ? q.toInt().toString() : decimal(q);
    final size = switch (i.size) {
      'tiny' => ' (winzig)',
      'small' => ' (klein)',
      'large' => ' (groß)',
      _ => '',
    };
    return switch (i.unit) {
      'drop' => '$n Tropfen ${i.foodName}',
      'ml' => '$n ml ${i.foodName}',
      'g' => '$n g ${i.foodName}',
      'portion' => '$n× ${i.foodName}',
      _ => '$n× ${i.foodName}$size',
    };
  }

  /// One-line summary of an event for timeline and snackbars.
  static String eventSummary(ColonyEvent e) {
    switch (e.type) {
      case 'feeding':
        final items = e.items.map(quantity).join(' + ');
        return items.isEmpty ? 'Gefüttert' : items;
      case 'water':
        return e.waterKinds.map((k) => waterKinds[k] ?? k).join(', ');
      case 'cleaning':
        return 'Gereinigt: ${e.cleaningKinds.map((k) => cleaningKinds[k] ?? k).join(', ')}';
      case 'measurement':
        return e.measurements.map(measurementText).join(' · ');
      case 'census':
        final c = e.census ?? const {};
        final exact = c['exact_count'] as num?;
        return 'Koloniegröße: ${exact != null ? number(exact) : workers((c['estimate_min'] as num?)?.toInt(), (c['estimate_max'] as num?)?.toInt())}';
      case 'brood':
        final stages = ((e.json['brood'] as List?) ?? const []).cast<Map<String, dynamic>>();
        return 'Brut: ${stages.map((b) => '${broodStages[b['stage']] ?? b['stage']} ${broodLevels[b['level']] ?? b['exact_count'] ?? ''}'.trim()).join(', ')}';
      case 'check':
        return e.note?.isNotEmpty == true ? 'Kontrolle: ${e.note}' : 'Kontrolle – alles in Ordnung';
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
