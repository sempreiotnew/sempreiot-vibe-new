import '../domain/ota/firmware_image.dart';
import '../domain/safr/safr_product.dart';
import '../domain/safr/safr_v2_payloads.dart';

/// Where a firmware push is (protocol §13.3).
enum OtaPushPhase {
  /// Nothing running. With a file loaded, the push can start.
  idle,
  readingFile,

  /// Agreeing on the line speed and announcing the image (OTA_BAUD, BEGIN).
  switchingSpeed,
  sending,

  /// Everything was sent; the board checks the image (END → RESULT).
  verifying,

  /// A board image was verified: the board restarts into it and proves
  /// itself. The site is unsupervised until it is back.
  boardRestarting,

  /// The board runs the new image.
  confirmed,

  /// A node or leaf image is on the board, ready for a rollout.
  stored,

  /// The board tried the new image and went back to the one it had.
  rolledBack,
  failed,
}

/// The steps of a push, in the order the operator sees them.
enum OtaStepId {
  readFile('Ler arquivo'),
  linkSpeed('Velocidade do link'),
  begin('Início (placa aceitou)'),
  send('Envio'),
  verify('Verificação'),

  /// Board image only.
  boardRestart('Reinício da placa'),

  /// Board image only.
  confirm('Autoteste / confirmação');

  const OtaStepId(this.label);
  final String label;
}

enum OtaStepStatus { waiting, running, done, failed }

class OtaStep {
  const OtaStep(
    this.id, {
    this.status = OtaStepStatus.waiting,
    this.startedAt,
    this.took,
    this.note,
  });

  final OtaStepId id;
  final OtaStepStatus status;

  /// When it started running; null while it waits.
  final DateTime? startedAt;

  /// How long it took, once done or failed.
  final Duration? took;

  /// What happened in it: "921600 bps", "a partir do bloco 12", or the
  /// reason it failed, in plain words.
  final String? note;
}

/// One line of the push log: something that happened on the wire or in the
/// controller.
class OtaLogLine {
  const OtaLogLine(this.at, this.text);
  final DateTime at;
  final String text;

  /// `14:03:27`.
  String get time {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }

  @override
  String toString() => '$time  $text';
}

/// Timeouts and speeds of a push. One place, so the board firmware and the
/// tablet can be compared line by line; tests shorten them.
class OtaPushTimings {
  const OtaPushTimings({
    this.pushBaud = safrOtaPushBaud,
    this.baudAckTimeout = const Duration(seconds: 2),
    this.baudAttempts = 3,
    this.beginAckTimeout = const Duration(seconds: 3),
    this.beginAttempts = 3,
    this.probeAckTimeout = const Duration(milliseconds: 1500),
    this.probeAttempts = 2,
    this.resultGrace = const Duration(milliseconds: 300),
    this.chunkAckTimeout = const Duration(seconds: 3),
    this.chunkMaxFailures = 5,
    this.reuseMsgIdOnTimeout = true,
    this.endAckTimeout = const Duration(seconds: 2),
    this.endAttempts = 3,
    this.verdictTimeout = const Duration(seconds: 30),
    this.linkLossTimeout = const Duration(seconds: 60),
    this.linkPoll = const Duration(milliseconds: 250),
    this.boardConfirmTimeout = const Duration(seconds: 180),
    this.firstPokeAfter = const Duration(seconds: 3),
    this.pokeInterval = const Duration(seconds: 5),
    this.selfTestWindow = const Duration(seconds: 150),
  });

  /// The speed asked for with OTA_BAUD before BEGIN; 115200 = do not ask.
  final int pushBaud;

  /// OTA_BAUD: the wait for its ACK and the transmissions (§9.1).
  final Duration baudAckTimeout;
  final int baudAttempts;

  /// OTA_PUSH_BEGIN: transmissions and the wait for the ACK of each.
  final Duration beginAckTimeout;
  final int beginAttempts;

  /// OTA_PUSH_BEGIN used to find the board again after the cable came back,
  /// at the speed the push had: a short try before the default speed.
  final Duration probeAckTimeout;
  final int probeAttempts;

  /// How long an OTA_PUSH_RESULT that should already be here is waited for
  /// once its ACK arrived (the board sends the RESULT first).
  final Duration resultGrace;

  /// OTA_PUSH_CHUNK: wait for the ACK, then the same chunk again; the push
  /// fails after this many answers in a row that are not an ACK OK.
  final Duration chunkAckTimeout;
  final int chunkMaxFailures;

  /// A chunk that was never answered goes again under the same MSG_ID
  /// (§9.1). A chunk the board refused (BAD_CRC) always gets a new one.
  final bool reuseMsgIdOnTimeout;

  /// OTA_PUSH_END.
  final Duration endAckTimeout;
  final int endAttempts;

  /// From END to OTA_PUSH_RESULT `ok` / `failed`.
  final Duration verdictTimeout;

  /// The cable is out: how long the push waits for the board to answer
  /// BEGIN again.
  final Duration linkLossTimeout;
  final Duration linkPoll;

  /// A board image, from "verified" to the board proving it runs it (or
  /// went back): 120 s of self-test on the board plus two restarts.
  final Duration boardConfirmTimeout;

  /// While the board restarts the tablet asks for its device table: the
  /// board must hear the tablet to pass its self-test, and answers with the
  /// version it runs.
  final Duration firstPokeAfter;
  final Duration pokeInterval;

  /// The board confirms a new image with a second OTA_PUSH_RESULT `ok`,
  /// sent when its self-test passes. Its NAME_ANNOUNCE alone does not: the
  /// board says what it runs before the self-test is over, and an image
  /// that fails it is thrown away 120 s after it started. So a board that
  /// announces the new version and never sends that RESULT is called
  /// confirmed only when it still announces it this long after it came
  /// back: the 120 s, the restart of a rollback and the 5 s between two
  /// questions of the tablet, with room to spare.
  final Duration selfTestWindow;
}

const _keep = Object();

class OtaPushState {
  const OtaPushState({
    this.phase = OtaPushPhase.idle,
    this.file,
    this.fileError,
    this.chunksDone = 0,
    this.bytesDone = 0,
    this.kbPerSecond = 0,
    this.resumes = 0,
    this.retries = 0,
    this.baud = safrOtaDefaultBaud,
    this.waitingFor,
    this.waitingSince,
    this.reason,
    this.message,
    this.boardVersion,
    this.boardVersionBefore,
    this.boardRestarted = false,
    this.steps = const [],
    this.log = const [],
    this.storedOnBoard = const {},
    this.startedAt,
    this.endedAt,
    this.totals,
  });

  final OtaPushPhase phase;

  /// The file that is loaded; null = none yet.
  final FirmwareFile? file;

  /// Why the last file chosen was refused.
  final String? fileError;

  /// Chunks the board confirmed, and the bytes they hold.
  final int chunksDone;
  final int bytesDone;

  /// Average of this push, over the time spent sending.
  final double kbPerSecond;

  /// Times the push went on from where the board said it was (the cable
  /// came back, the board asked for another chunk).
  final int resumes;

  /// Chunks sent again (no answer, or damaged on the way).
  final int retries;

  /// The line speed now.
  final int baud;

  /// What the push waits for now, in plain words ("placa verificando a
  /// imagem"), since [waitingSince]; null when it is not waiting.
  final String? waitingFor;
  final DateTime? waitingSince;

  /// [OtaPushPhase.failed] / [OtaPushPhase.rolledBack]: the board's reason,
  /// when it gave one.
  final SafrOtaReason? reason;

  /// The result in plain words.
  final String? message;

  /// The version the board reported at the end of a board push.
  final String? boardVersion;

  /// The version the board ran when the push began, as its device row said
  /// then; null when the board never reported one.
  final String? boardVersionBefore;

  /// A board image was handed over and the board restarted with it (or was
  /// told to): from there on only the board knows what it runs. False for
  /// every push that ended before that — nothing changed on the board.
  final bool boardRestarted;

  /// The steps of the push that runs, or of the last one.
  final List<OtaStep> steps;

  /// What happened, oldest first. Kept in memory only.
  final List<OtaLogLine> log;

  /// Node / leaf images this session saw stored on the board: family →
  /// version.
  final Map<SafrProductFamily, String> storedOnBoard;

  /// The push: from "Enviar" to its result.
  final DateTime? startedAt;
  final DateTime? endedAt;

  /// The size of the image when there is no [file]: a push seen through
  /// the central mirror on a user's phone, which never holds the image.
  final ({int chunks, int bytes})? totals;

  int get chunksTotal => file?.chunkCount ?? totals?.chunks ?? 0;
  int get bytesTotal => file?.size ?? totals?.bytes ?? 0;

  /// 0…1.
  double get progress => bytesTotal == 0 ? 0 : bytesDone / bytesTotal;

  /// What is left of the sending at the speed so far; null = not known.
  Duration? get remaining {
    if (phase != OtaPushPhase.sending || kbPerSecond <= 0) return null;
    final kb = (bytesTotal - bytesDone) / 1024;
    return Duration(milliseconds: (kb / kbPerSecond * 1000).round());
  }

  /// From "Enviar" to the result; null while it runs or before it started.
  Duration? get totalTime {
    final a = startedAt, b = endedAt;
    return a == null || b == null ? null : b.difference(a);
  }

  bool get running => switch (phase) {
        OtaPushPhase.readingFile ||
        OtaPushPhase.switchingSpeed ||
        OtaPushPhase.sending ||
        OtaPushPhase.verifying ||
        OtaPushPhase.boardRestarting =>
          true,
        _ => false,
      };

  /// The operator can still give up: nothing was handed to the board for
  /// good. Past END the board decides.
  bool get canCancel =>
      phase == OtaPushPhase.switchingSpeed || phase == OtaPushPhase.sending;

  bool get finished => switch (phase) {
        OtaPushPhase.confirmed ||
        OtaPushPhase.stored ||
        OtaPushPhase.rolledBack ||
        OtaPushPhase.failed =>
          true,
        _ => false,
      };

  bool get isBoardImage => file?.family == SafrProductFamily.board;

  OtaStep? step(OtaStepId id) {
    for (final s in steps) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// The whole log as text, one line per event, for the clipboard.
  String get logText => log.map((l) => l.toString()).join('\n');

  OtaPushState copyWith({
    OtaPushPhase? phase,
    Object? file = _keep,
    Object? fileError = _keep,
    int? chunksDone,
    int? bytesDone,
    double? kbPerSecond,
    int? resumes,
    int? retries,
    int? baud,
    Object? waitingFor = _keep,
    Object? waitingSince = _keep,
    Object? reason = _keep,
    Object? message = _keep,
    Object? boardVersion = _keep,
    Object? boardVersionBefore = _keep,
    bool? boardRestarted,
    List<OtaStep>? steps,
    List<OtaLogLine>? log,
    Map<SafrProductFamily, String>? storedOnBoard,
    Object? startedAt = _keep,
    Object? endedAt = _keep,
  }) =>
      OtaPushState(
        phase: phase ?? this.phase,
        file: identical(file, _keep) ? this.file : file as FirmwareFile?,
        fileError:
            identical(fileError, _keep) ? this.fileError : fileError as String?,
        chunksDone: chunksDone ?? this.chunksDone,
        bytesDone: bytesDone ?? this.bytesDone,
        kbPerSecond: kbPerSecond ?? this.kbPerSecond,
        resumes: resumes ?? this.resumes,
        retries: retries ?? this.retries,
        baud: baud ?? this.baud,
        waitingFor: identical(waitingFor, _keep)
            ? this.waitingFor
            : waitingFor as String?,
        waitingSince: identical(waitingSince, _keep)
            ? this.waitingSince
            : waitingSince as DateTime?,
        reason:
            identical(reason, _keep) ? this.reason : reason as SafrOtaReason?,
        message: identical(message, _keep) ? this.message : message as String?,
        boardVersion: identical(boardVersion, _keep)
            ? this.boardVersion
            : boardVersion as String?,
        boardVersionBefore: identical(boardVersionBefore, _keep)
            ? this.boardVersionBefore
            : boardVersionBefore as String?,
        boardRestarted: boardRestarted ?? this.boardRestarted,
        steps: steps ?? this.steps,
        log: log ?? this.log,
        storedOnBoard: storedOnBoard ?? this.storedOnBoard,
        startedAt: identical(startedAt, _keep)
            ? this.startedAt
            : startedAt as DateTime?,
        endedAt:
            identical(endedAt, _keep) ? this.endedAt : endedAt as DateTime?,
        totals: totals,
      );
}
