import '../domain/safr/safr_product.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'ota_push_state.dart' show OtaLogLine;

/// For how long a unit whose rollout row is offered / downloading /
/// verifying / rebooting / in self-test is UPDATING instead of missing
/// (protocol §13.4 `DEADLINE_S`, design value 300). The tablet never sees
/// the offer, so it uses the design value.
const otaUpdatingGrace = Duration(seconds: 300);

/// Timeouts of the rollout, in one place so the board firmware and the
/// tablet can be compared line by line; tests shorten them.
class OtaRolloutTimings {
  const OtaRolloutTimings({
    this.answerTimeout = const Duration(seconds: 3),
    this.controlAckTimeout = const Duration(seconds: 2),
    this.controlAttempts = 3,
    this.pageAfterControl = const Duration(seconds: 3),
    this.pageSetTimeout = const Duration(seconds: 2),
    this.rollingSilence = const Duration(seconds: 15),
    this.watchdogPeriod = const Duration(seconds: 5),
    this.updatingGrace = otaUpdatingGrace,
  });

  /// GET_ROLLOUT: no OTA_ROLLOUT page within this = the board did not
  /// answer (a firmware before the rollout, or nothing to say).
  final Duration answerTimeout;

  /// OTA_CONTROL: the wait for its ACK and the transmissions (§9.1).
  final Duration controlAckTimeout;
  final int controlAttempts;

  /// After the ACK of an OTA_CONTROL the board sends its table (it
  /// changed). None within this: the tablet asks with GET_ROLLOUT.
  final Duration pageAfterControl;

  /// A set of pages that stops before its last page is dropped after this
  /// and the tablet asks again.
  final Duration pageSetTimeout;

  /// While a rollout is `rolling` the board sends its table every 5 s.
  /// Nothing for this long: the tablet asks with GET_ROLLOUT.
  final Duration rollingSilence;
  final Duration watchdogPeriod;

  /// See [otaUpdatingGrace].
  final Duration updatingGrace;
}

/// Why a rollout is paused, as far as the tablet can tell: the header of
/// OTA_ROLLOUT says `paused` and nothing else.
enum OtaPauseCause {
  /// The operator asked for it on this tablet, in this session.
  operator,

  /// An alarm is latched on the site (or was when the pause came).
  alarm,

  /// Neither: the board restarted and waits for `resume`, or the pause is
  /// from before this app started.
  unknown,
}

/// One unit of a rollout, as the board's table says and as the unit's own
/// OTA_STATUS / OTA_RESULT refined it since.
class OtaRolloutUnit {
  const OtaRolloutUnit({
    required this.mac,
    required this.productCode,
    required this.state,
    required this.changedAt,
    this.percent = 0,
    this.attempts = 0,
    this.reasonRaw = 0,
    this.version = '',
    this.versionBefore,
    this.activeSince,
    this.live = false,
  });

  final String mac;
  final int productCode;
  final SafrOtaUnitState state;

  /// 0…100, while downloading.
  final int percent;

  /// Offers the board made to this unit in this rollout.
  final int attempts;
  final int reasonRaw;

  /// What the unit runs now, as the board (or the unit's result) said;
  /// empty = not known.
  final String version;

  /// What the unit ran when this tablet first saw it in this rollout; null
  /// = the first thing seen was already the outcome.
  final String? versionBefore;

  /// When this row last changed, on the tablet's clock (`AGE_S` of the
  /// board taken from the time the page arrived).
  final DateTime changedAt;

  /// When the row entered offered / downloading / verifying / rebooting /
  /// self-test, on the tablet's clock; null while it is in none of them.
  /// Moving between those states does not restart it; a new offer does.
  final DateTime? activeSince;

  /// The last word came from the unit itself (OTA_STATUS / OTA_RESULT) and
  /// no page of the board confirmed it yet.
  final bool live;

  SafrOtaReason get reason => SafrOtaReason.fromWire(reasonRaw);
  SafrProduct? get product => SafrProduct.fromCode(productCode);

  /// Still UPDATING at [now]: in one of the active states, for less than
  /// [grace] since it entered them.
  bool updatingAt(DateTime now, [Duration grace = otaUpdatingGrace]) {
    final since = activeSince;
    return state.active && since != null && now.difference(since) < grace;
  }

  OtaRolloutUnit copyWith({
    SafrOtaUnitState? state,
    int? percent,
    int? attempts,
    int? reasonRaw,
    String? version,
    DateTime? changedAt,
    Object? activeSince = _keep,
    bool? live,
  }) =>
      OtaRolloutUnit(
        mac: mac,
        productCode: productCode,
        state: state ?? this.state,
        percent: percent ?? this.percent,
        attempts: attempts ?? this.attempts,
        reasonRaw: reasonRaw ?? this.reasonRaw,
        version: version ?? this.version,
        versionBefore: versionBefore,
        changedAt: changedAt ?? this.changedAt,
        activeSince: identical(activeSince, _keep)
            ? this.activeSince
            : activeSince as DateTime?,
        live: live ?? this.live,
      );
}

const _keep = Object();

/// The rollout of one family: what the board holds and, when a rollout was
/// started, where every unit is.
class OtaFamilyRollout {
  const OtaFamilyRollout({
    required this.family,
    required this.state,
    required this.target,
    required this.updatedAt,
    this.total = 0,
    this.units = const [],
    this.startedAt,
    this.startedAtExact = false,
    this.endedAt,
    this.pauseCause,
    this.filter,
  });

  final SafrProductFamily family;
  final SafrOtaRolloutState state;

  /// The version the board holds for this family (and rolls out).
  final String target;

  /// Units in the rollout, as the header says.
  final int total;

  /// One row per unit, in the order of the board's table.
  final List<OtaRolloutUnit> units;

  /// When the last page of the board about this family arrived.
  final DateTime updatedAt;

  /// When the rollout started. Exact when this session started it or saw
  /// it start; otherwise the oldest change the board's table tells of — it
  /// started no later than that.
  final DateTime? startedAt;
  final bool startedAtExact;

  /// When this session saw it end (rolling / paused → done / partial);
  /// null for a rollout that was over before the tablet looked.
  final DateTime? endedAt;

  /// Only while [state] is paused.
  final OtaPauseCause? pauseCause;

  /// The filter this session started it with; null = not started here.
  final SafrOtaFilter? filter;

  bool get running => state.running;
  bool get ended => state.ended;

  /// The board holds an image of this family.
  bool get holdsImage =>
      state != SafrOtaRolloutState.idle && target.isNotEmpty;

  int count(SafrOtaUnitState s) => units.where((u) => u.state == s).length;

  int get doneCount => count(SafrOtaUnitState.done);
  int get failedCount => count(SafrOtaUnitState.failed);
  int get skippedCount => count(SafrOtaUnitState.skipped);
  int get settledCount => units.where((u) => u.state.settled).length;

  /// Units of the rollout: the header's TOTAL, or the rows when they are
  /// more (a header that came ahead of its rows).
  int get unitCount => total > units.length ? total : units.length;

  /// The unit the board is busy with now, if any.
  OtaRolloutUnit? get current {
    for (final u in units) {
      if (u.state.active) return u;
    }
    return null;
  }

  OtaRolloutUnit? unit(String mac) {
    for (final u in units) {
      if (u.mac == mac) return u;
    }
    return null;
  }

  List<OtaRolloutUnit> get failures =>
      [for (final u in units) if (u.state == SafrOtaUnitState.failed) u];

  OtaFamilyRollout copyWith({
    SafrOtaRolloutState? state,
    String? target,
    int? total,
    List<OtaRolloutUnit>? units,
    DateTime? updatedAt,
    Object? startedAt = _keep,
    bool? startedAtExact,
    Object? endedAt = _keep,
    Object? pauseCause = _keep,
    Object? filter = _keep,
  }) =>
      OtaFamilyRollout(
        family: family,
        state: state ?? this.state,
        target: target ?? this.target,
        total: total ?? this.total,
        units: units ?? this.units,
        updatedAt: updatedAt ?? this.updatedAt,
        startedAt: identical(startedAt, _keep)
            ? this.startedAt
            : startedAt as DateTime?,
        startedAtExact: startedAtExact ?? this.startedAtExact,
        endedAt:
            identical(endedAt, _keep) ? this.endedAt : endedAt as DateTime?,
        pauseCause: identical(pauseCause, _keep)
            ? this.pauseCause
            : pauseCause as OtaPauseCause?,
        filter:
            identical(filter, _keep) ? this.filter : filter as SafrOtaFilter?,
      );
}

/// Everything the tablet knows of the rollouts: one entry per family the
/// board said something about.
class OtaRolloutState {
  const OtaRolloutState({
    this.families = const {},
    this.boardAnswered,
    this.asking = false,
    this.command,
    this.log = const [],
  });

  final Map<SafrProductFamily, OtaFamilyRollout> families;

  /// The board answered GET_ROLLOUT (or sent its table by itself): true.
  /// It was asked and said nothing: false — what this session saw stored on
  /// the board is then all the tablet has. Null = not asked yet.
  final bool? boardAnswered;

  /// A GET_ROLLOUT is waiting for its answer.
  final bool asking;

  /// The OTA_CONTROL that waits for its ACK; null = none.
  final SafrOtaAction? command;

  /// What happened, oldest first. Kept in memory only.
  final List<OtaLogLine> log;

  OtaFamilyRollout? family(SafrProductFamily f) => families[f];

  /// The rollout that runs (rolling or paused), if any; the board runs one
  /// at a time.
  OtaFamilyRollout? get running {
    for (final f in families.values) {
      if (f.running) return f;
    }
    return null;
  }

  /// The unit with [mac] in the rollout that runs, else in one that ended
  /// in this session.
  OtaRolloutUnit? unit(String mac) {
    OtaRolloutUnit? found;
    for (final f in families.values) {
      final u = f.unit(mac);
      if (u == null) continue;
      if (f.running) return u;
      found ??= u;
    }
    return found;
  }

  /// Since when the unit with [mac] is being updated; null = it is not.
  DateTime? activeSince(String mac) {
    for (final f in families.values) {
      final u = f.unit(mac);
      if (u != null && u.state.active) return u.activeSince;
    }
    return null;
  }

  String get logText => log.map((l) => l.toString()).join('\n');

  OtaRolloutState copyWith({
    Map<SafrProductFamily, OtaFamilyRollout>? families,
    Object? boardAnswered = _keep,
    bool? asking,
    Object? command = _keep,
    List<OtaLogLine>? log,
  }) =>
      OtaRolloutState(
        families: families ?? this.families,
        boardAnswered: identical(boardAnswered, _keep)
            ? this.boardAnswered
            : boardAnswered as bool?,
        asking: asking ?? this.asking,
        command:
            identical(command, _keep) ? this.command : command as SafrOtaAction?,
        log: log ?? this.log,
      );
}
