/// Typed read-only views over the JSON records the server sends. Unknown
/// fields are kept in [json], so nothing is lost when writing back.
library;

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;
int? _int(Object? v) => (v as num?)?.toInt();
double? _double(Object? v) => (v as num?)?.toDouble();

class Colony {
  Colony(this.json, {this.speciesName, this.locationPath});

  final Map<String, dynamic> json;
  final String? speciesName;
  final String? locationPath;

  String get id => json['id'] as String;
  String get name => json['name'] as String? ?? '';
  int get number => _int(json['number']) ?? 0;
  String? get internalCode => json['internal_code'] as String?;
  String? get speciesId => json['species_id'] as String?;
  String? get speciesText => json['species_text'] as String?;
  String get species => speciesName ?? speciesText ?? '';
  String? get locationId => json['location_id'] as String?;
  String get status => json['status'] as String? ?? 'active';
  String get gyneType => json['gyne_type'] as String? ?? 'unknown';
  String? get notes => json['notes'] as String?;
  bool get archived => json['archived_at'] != null;
  int? get queenCount => _int(json['queen_count']);
  int? get workerMin => _int(json['worker_estimate_min']);
  int? get workerMax => _int(json['worker_estimate_max']);
  String? get origin => json['origin'] as String?;
  int get version => _int(json['version']) ?? 0;

  double? get lastTemperature => _double((json['last_measurement'] as Map?)?['temperature']?['value']);
  double? get lastHumidity => _double((json['last_measurement'] as Map?)?['humidity']?['value']);
  DateTime? get lastMeasurementAt =>
      _date((json['last_measurement'] as Map?)?['temperature']?['at']) ??
      _date((json['last_measurement'] as Map?)?['humidity']?['at']);

  bool get isCareActive => !archived && const {'founding', 'active', 'hibernating'}.contains(status);
}

/// Winter rest of a colony. Without [startedOn] it is only planned: the app
/// reminds on [plannedStartOn] and the switch on the colony starts it.
class WinterRest {
  WinterRest(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get colonyId => json['colony_id'] as String;
  DateTime? get plannedStartOn => _date(json['planned_start_on']);
  DateTime? get startedOn => _date(json['started_on']);
  DateTime? get plannedEndOn => _date(json['planned_end_on']);
  DateTime? get endedOn => _date(json['ended_on']);
  bool get started => startedOn != null;
}

class FeedingItem {
  FeedingItem(this.json);
  final Map<String, dynamic> json;
  String? get foodItemId => json['food_item_id'] as String?;
  String get foodName => json['food_name'] as String? ?? '';
  String get category => json['category'] as String? ?? 'other';
  double? get quantity => _double(json['quantity']);
  String? get unit => json['unit'] as String?;
  String? get size => json['size'] as String?;
}

class ColonyEvent {
  ColonyEvent(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get colonyId => json['colony_id'] as String;
  String get type => json['type'] as String;
  DateTime get occurredAt => _date(json['occurred_at']) ?? DateTime.fromMillisecondsSinceEpoch(0);
  String? get note => json['note'] as String?;
  String? get severity => json['severity'] as String?;
  String? get createdBy => json['created_by'] as String?;

  Map<String, dynamic>? get feeding => json['feeding'] as Map<String, dynamic>?;
  String get acceptance => feeding?['acceptance'] as String? ?? 'unknown';
  List<FeedingItem> get items =>
      ((feeding?['items'] as List?) ?? const []).map((e) => FeedingItem(e as Map<String, dynamic>)).toList();
  List<String> get waterKinds => ((json['water'] as Map?)?['kinds'] as List?)?.cast<String>() ?? const [];
  List<String> get cleaningKinds => ((json['cleaning'] as Map?)?['kinds'] as List?)?.cast<String>() ?? const [];
  List<Map<String, dynamic>> get measurements =>
      ((json['measurements'] as List?) ?? const []).cast<Map<String, dynamic>>();
  Map<String, dynamic>? get census => json['census'] as Map<String, dynamic>?;
}

class FoodItem {
  FoodItem(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get name => json['name'] as String? ?? '';
  String get category => json['category'] as String? ?? 'other';
  String get defaultUnit => json['default_unit'] as String? ?? 'piece';
  int get sortOrder => _int(json['sort_order']) ?? 0;
  bool get archived => json['archived_at'] != null;
}

class Location {
  Location(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get name => json['name'] as String? ?? '';
  String get path => (json['path'] as String?)?.isNotEmpty == true ? json['path'] as String : name;
  String? get parentId => json['parent_id'] as String?;
}

class Species {
  Species(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get scientificName => json['scientific_name'] as String? ?? '';
  String get genus => json['genus'] as String? ?? '';
}

class ScanLink {
  ScanLink(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get colonyId => json['colony_id'] as String;
  String get token => json['token'] as String;
  String get kind => json['kind'] as String? ?? 'qr';
  bool get active => json['active'] as bool? ?? true;
}

class UserSettings {
  UserSettings(this.json);
  final Map<String, dynamic> json;
  int get dueSoonDays => _int(json['due_soon_days']) ?? 1;
  String get theme => json['theme'] as String? ?? 'system';
  String get timezone => json['timezone'] as String? ?? 'Europe/Vienna';

  /// Daily overview time („Tages-Überblick“), hour and minute.
  (int, int) get digestTime {
    final p = (json['digest_time'] as String? ?? '18:00').split(':');
    return (int.tryParse(p[0]) ?? 18, p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0);
  }

  bool get notifyOverdue => json['notify_overdue'] as bool? ?? true;
  bool get emailDigest => json['email_digest'] as bool? ?? false;
}

/// Worker estimate ranges offered in the UI (spec §11).
const workerRanges = <(int, int?)>[
  (1, 10),
  (10, 50),
  (50, 100),
  (100, 500),
  (500, 1000),
  (1000, 5000),
  (5000, 10000),
  (10000, null),
];

/// A care round (Pflege-Rundgang): scanning many colonies one after another.
class CareRound {
  CareRound(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  DateTime get startedAt => _date(json['started_at']) ?? DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? get endedAt => _date(json['ended_at']);
  String? get locationId => json['location_id'] as String?;
  bool get open => endedAt == null;
}

/// One colony of a care round (`care_round_colonies`).
class RoundStop {
  RoundStop(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get roundId => json['care_round_id'] as String;
  String get colonyId => json['colony_id'] as String;
  bool get planned => json['planned'] as bool? ?? true;
  DateTime? get visitedAt => _date(json['visited_at']);
  bool get visited => visitedAt != null;
  bool get skipped => json['skipped'] as bool? ?? false;
}

/// Live state of a round: stops with their colony and what was done there.
class RoundProgress {
  RoundProgress({required this.round, required this.stops, required this.done});
  final CareRound round;

  /// Sorted by location path (walking order), then colony number.
  final List<(RoundStop, Colony)> stops;

  /// Event types documented in this round, per colony.
  final Map<String, Set<String>> done;

  int get total => stops.where((s) => s.$1.planned || s.$1.visited).length;
  int get visited => stops.where((s) => s.$1.visited).length;
  List<(RoundStop, Colony)> get open => stops.where((s) => !s.$1.visited && !s.$1.skipped).toList();
  RoundStop? stopOf(String colonyId) => stops.where((s) => s.$2.id == colonyId).firstOrNull?.$1;
}

class RoundSummary {
  RoundSummary({
    required this.round,
    required this.total,
    required this.visited,
    required this.colonies,
    required this.missing,
    required this.skipped,
  });
  final CareRound round;
  final int total, visited;

  /// Event type → number of colonies it was documented for.
  final Map<String, int> colonies;
  final List<Colony> missing, skipped;

  Duration get duration => (round.endedAt ?? DateTime.now()).difference(round.startedAt);
}

/// What happened when a colony was scanned during a round.
enum VisitResult { first, again, added }

/// Photo metadata (`photos`); the binary is uploaded separately.
class Photo {
  Photo(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get colonyId => json['colony_id'] as String;
  String? get eventId => json['event_id'] as String?;
  String? get caption => json['caption'] as String?;
  DateTime get takenAt =>
      _date(json['taken_at']) ?? _date(json['created_at']) ?? DateTime.fromMillisecondsSinceEpoch(0);
  bool get stored => json['upload_state'] == 'stored';
}
