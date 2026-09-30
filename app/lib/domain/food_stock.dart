import '../app/i18n.dart';
import '../app/strings.dart';

/// Food stock: feeder insects, sugar water & co. – or a feeder culture
/// (kind „culture“) that needs care itself.
class FoodStock {
  FoodStock(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get name => json['name'] as String? ?? '';
  bool get isCulture => json['kind'] == 'culture';
  String? get foodItemId => json['food_item_id'] as String?;
  double? get quantity => _num(json['quantity']);
  String? get unit => (json['unit'] as String?)?.isNotEmpty == true ? json['unit'] as String : null;
  double? get reorderBelow => _num(json['reorder_below']);
  DateTime? get openedOn => _date(json['opened_on']);
  int? get useWithinDays => (json['use_within_days'] as num?)?.toInt();
  DateTime? get bestBefore => _date(json['best_before']);
  int? get careIntervalDays => (json['care_interval_days'] as num?)?.toInt();
  DateTime? get lastCaredAt => DateTime.tryParse(json['last_cared_at'] as String? ?? '');
  DateTime? get createdAt => DateTime.tryParse(json['created_at'] as String? ?? '');
  String? get notes => (json['notes'] as String?)?.trim().isNotEmpty == true ? json['notes'] as String : null;
  bool get archived => json['archived_at'] != null;

  /// „40 Stück“, „250 g“ – null without a quantity.
  String? get amountText {
    final q = quantity;
    if (q == null) return null;
    final u = unit;
    return u == null ? S.number(q) : '${S.number(q)} ${S.unitNames[u] ?? u}';
  }

  /// Opened for this many days (null if not opened).
  int? openDays(DateTime now) => openedOn == null ? null : _days(openedOn!, now);

  /// The culture's next care (null: no interval).
  DateTime? nextCare() {
    final i = careIntervalDays;
    final base = lastCaredAt ?? createdAt;
    if (i == null || base == null) return null;
    return base.add(Duration(days: i));
  }

  /// What needs attention now, most important first.
  List<StockIssue> issues(DateTime now) {
    if (archived) return const [];
    final today = DateTime(now.year, now.month, now.day);
    final out = <StockIssue>[];
    if (bestBefore != null && bestBefore!.isBefore(today)) out.add(StockIssue.expired);
    if (openedOn != null && useWithinDays != null && openDays(now)! > useWithinDays!) {
      out.add(StockIssue.openedTooLong);
    }
    if (isCulture && nextCare() != null && !nextCare()!.isAfter(now)) out.add(StockIssue.cultureCare);
    if (quantity != null && reorderBelow != null && quantity! <= reorderBelow!) out.add(StockIssue.low);
    return out;
  }

  /// A changing value per issue – a notification comes again when it changes.
  String issueKey(StockIssue i) => switch (i) {
    StockIssue.expired => json['best_before'].toString(),
    StockIssue.openedTooLong => json['opened_on'].toString(),
    StockIssue.cultureCare => (lastCaredAt ?? createdAt)?.toIso8601String() ?? '',
    StockIssue.low => '${json['reorder_below']}',
  };

  String issueText(StockIssue i, DateTime now) => switch (i) {
    StockIssue.expired => tr('Mindesthaltbarkeit abgelaufen ({0})', [S.date(bestBefore!)]),
    StockIssue.openedTooLong => tr('Seit {0} Tagen offen – ersetzen (hält {1} Tage)', [openDays(now), useWithinDays]),
    StockIssue.cultureCare => tr('Zucht versorgen (alle {0} Tage)', [careIntervalDays]),
    StockIssue.low => tr('Nur noch {0} – nachbestellen', [amountText ?? '']),
  };
}

enum StockIssue { expired, openedTooLong, cultureCare, low }

double? _num(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

DateTime? _date(Object? v) {
  final d = DateTime.tryParse(v as String? ?? '');
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

int _days(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays;
