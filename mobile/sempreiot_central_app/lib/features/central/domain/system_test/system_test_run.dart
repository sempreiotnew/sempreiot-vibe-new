/// One "Teste do sistema" (TESTAR to every unit at once): who was in it,
/// how each one answered, how it ended. The tablet keeps every run
/// (`SystemTests`, reference §3.6.1) and publishes the running one and the
/// last few, retained, so a phone — opened, reloaded or arriving late —
/// starts with the whole picture (`docs/cloud/central-mirror.md` §4.7).
library;

/// How the test ended; [running] while it goes on.
enum SystemTestVerdict {
  running('Em andamento'),
  passed('Concluído'),
  failed('Com falhas'),
  cancelled('Cancelado');

  const SystemTestVerdict(this.label);
  final String label;

  static SystemTestVerdict fromName(String? name) => values.firstWhere(
        (v) => v.name == name,
        orElse: () => SystemTestVerdict.running,
      );
}

/// A unit's answer in the test (the same outcomes the Central's grid
/// shows: device_command_widgets `commandOutcomeLabel`).
enum SystemTestOutcome {
  pending('Pendente'),
  pendingWake('Próximo despertar'),
  confirmed('Confirmado'),
  noAnswer('Sem resposta'),
  missing('Sem comunicação'),
  cancelled('Cancelado');

  const SystemTestOutcome(this.label);
  final String label;

  bool get isPending => this == pending || this == pendingWake;
  bool get isFailure =>
      this == noAnswer || this == missing || this == cancelled;

  static SystemTestOutcome fromName(String? name) => values.firstWhere(
        (v) => v.name == name,
        orElse: () => SystemTestOutcome.pending,
      );
}

class SystemTestUnit {
  const SystemTestUnit({
    required this.mac,
    required this.outcome,
    this.name,
    this.at,
  });

  final String mac;

  /// The unit's name when the test ran (a renamed unit keeps its old name
  /// in an old report).
  final String? name;
  final SystemTestOutcome outcome;

  /// When it confirmed, or when it was given up on; null while pending.
  final DateTime? at;

  String get displayName => name?.isNotEmpty == true ? name! : mac;

  Map<String, dynamic> toJson() => {
        'mac': mac,
        if (name != null) 'name': name,
        'outcome': outcome.name,
        if (at != null) 'at': at!.toUtc().toIso8601String(),
      };

  static SystemTestUnit? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final mac = raw['mac'];
    if (mac is! String) return null;
    return SystemTestUnit(
      mac: mac,
      name: raw['name'] as String?,
      outcome: SystemTestOutcome.fromName(raw['outcome'] as String?),
      at: _time(raw['at']),
    );
  }
}

class SystemTestRun {
  const SystemTestRun({
    required this.id,
    required this.startedAt,
    required this.verdict,
    required this.units,
    this.endedAt,
    this.by,
    this.boardAcked = false,
  });

  /// Unique on the tablet and in the cloud (the start time in
  /// microseconds, hex).
  final String id;
  final DateTime startedAt;
  final DateTime? endedAt;

  /// Who started it from a phone; null = the tablet itself.
  final String? by;
  final SystemTestVerdict verdict;
  final List<SystemTestUnit> units;

  /// Running: the board took the command (one ✓ on the Central).
  final bool boardAcked;

  bool get running => verdict == SystemTestVerdict.running;

  int get total => units.length;
  int get confirmed =>
      units.where((u) => u.outcome == SystemTestOutcome.confirmed).length;
  int get pending => units.where((u) => u.outcome.isPending).length;
  int get sleepers =>
      units.where((u) => u.outcome == SystemTestOutcome.pendingWake).length;
  int get missing =>
      units.where((u) => u.outcome == SystemTestOutcome.missing).length;
  int get noAnswer =>
      units.where((u) => u.outcome == SystemTestOutcome.noAnswer).length;
  int get cancelled =>
      units.where((u) => u.outcome == SystemTestOutcome.cancelled).length;

  /// How long it took (or has been running, against [now]).
  Duration elapsed([DateTime? now]) =>
      (endedAt ?? now ?? DateTime.now()).difference(startedAt);

  /// "2 confirmaram · 1 pendente (1 no próximo despertar) · 1 sem
  /// comunicação" — the Central's tally, the report's summary.
  String get summary => [
        '$confirmed ${confirmed == 1 ? 'confirmou' : 'confirmaram'}',
        if (pending > 0)
          '$pending ${pending == 1 ? 'pendente' : 'pendentes'}'
              '${sleepers > 0 ? ' ($sleepers no próximo despertar)' : ''}',
        if (missing > 0) '$missing sem comunicação',
        if (noAnswer > 0) '$noAnswer sem resposta',
        if (cancelled > 0)
          '$cancelled ${cancelled == 1 ? 'cancelado' : 'cancelados'}',
      ].join(' · ');

  SystemTestRun copyWith({
    DateTime? endedAt,
    SystemTestVerdict? verdict,
    List<SystemTestUnit>? units,
    bool? boardAcked,
  }) =>
      SystemTestRun(
        id: id,
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        by: by,
        verdict: verdict ?? this.verdict,
        units: units ?? this.units,
        boardAcked: boardAcked ?? this.boardAcked,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'started': startedAt.toUtc().toIso8601String(),
        if (endedAt != null) 'ended': endedAt!.toUtc().toIso8601String(),
        if (by != null) 'by': by,
        'verdict': verdict.name,
        if (boardAcked) 'boardAcked': true,
        'units': [for (final u in units) u.toJson()],
      };

  static SystemTestRun? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final started = _time(raw['started']);
    if (id is! String || started == null) return null;
    final units = raw['units'];
    return SystemTestRun(
      id: id,
      startedAt: started,
      endedAt: _time(raw['ended']),
      by: raw['by'] as String?,
      verdict: SystemTestVerdict.fromName(raw['verdict'] as String?),
      boardAcked: raw['boardAcked'] == true,
      units: [
        if (units is List)
          for (final u in units)
            if (SystemTestUnit.fromJson(u) case final unit?) unit,
      ],
    );
  }

  /// An id from the start time: unique on the tablet (one test at a time)
  /// and readable in a log.
  static String idFor(DateTime startedAt) =>
      startedAt.toUtc().microsecondsSinceEpoch.toRadixString(16);
}

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v) : null;
