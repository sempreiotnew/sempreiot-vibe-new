import 'dart:async';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../data/services/firmware_file_picker.dart';
import '../domain/ota/crc32.dart';
import '../domain/ota/firmware_image.dart';
import '../domain/safr/safr_product.dart';
import '../domain/safr/safr_v2_frame.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'alarm_latch_provider.dart';
import 'ota_board_events_provider.dart';
import 'ota_push_state.dart';
import 'safr_downlink_provider.dart';
import 'serial_link_provider.dart';
import 'serial_provider.dart';

/// Pushes a firmware image from the tablet to the board over the serial
/// link (docs/safr/protocol-safr-v3.md §13.3):
///
///   file → OTA_BAUD → BEGIN → chunks, one at a time → END → the board's
///   verdict → (board image) the board restarts and proves itself.
///
/// The frames travel through [SafrDownlink] like every other downlink frame;
/// the rest of the traffic (heartbeats, LINK_CHECK, events) keeps flowing.
/// The push survives the screen that started it: it lives as long as the
/// app, and so do its steps and its log — on the bench the tablet is the
/// only window on what the board does.
class OtaPushController extends StateNotifier<OtaPushState> {
  OtaPushController(this._ref, {OtaPushTimings? timings})
      : _t = timings ?? const OtaPushTimings(),
        super(const OtaPushState()) {
    _events = _ref.read(otaBoardBusProvider).stream.listen(_onBoardEvent);
    _ref.listen<bool>(
      activeAlarmProvider,
      (_, latched) => _alarmLatched = latched,
      fireImmediately: true,
    );
    // A cable that goes out and comes back within the wait for an ACK
    // leaves an open port behind — at the default speed, with a board that
    // may be at another. The port closing is what counts.
    _ref.listen<SerialStatus>(serialProvider, (prev, next) {
      if (prev == SerialStatus.connected && next != SerialStatus.connected) {
        _linkLost = true;
      }
    });
  }

  /// Lines the log keeps; the oldest leave first.
  static const logCapacity = 600;

  final Ref _ref;
  final OtaPushTimings _t;
  late final StreamSubscription<OtaBoardEvent> _events;

  final _mail = _Mailbox<OtaBoardEvent>();
  bool _alarmLatched = false;
  bool _cancelRequested = false;

  /// The port closed since the push last agreed with the board where it is.
  bool _linkLost = false;

  /// The last NAME_ANNOUNCE written to the log: one that says the same
  /// again is not written again.
  String? _loggedAnnounce;

  /// The board agreed to the push speed and, as far as the tablet knows, is
  /// still there — also after the port closed and opened again.
  bool _boardAtPushBaud = false;

  /// BOOT_CTR of the board that is taking the image.
  int? _boardBootCtr;

  /// Time spent sending (the waits for the cable are not counted).
  final _clock = Stopwatch();
  int _bytesThisRun = 0;
  int _loggedTenth = 0;
  Duration _readTook = Duration.zero;

  SafrDownlink get _downlink => _ref.read(safrDownlinkProvider);
  SerialNotifier get _serial => _ref.read(serialProvider.notifier);
  bool get _portOpen => _ref.read(serialProvider) == SerialStatus.connected;

  /// The push must agree with the board again before it goes on.
  bool get _linkBroken => _linkLost || !_portOpen;

  // ── The file ─────────────────────────────────────────────────────────────

  /// Opens the file chooser and loads what the operator picks.
  Future<void> pickFile() async {
    if (state.running) return;
    final PickedFirmware? picked;
    try {
      picked = await _ref.read(firmwareFilePickerProvider).pick();
    } on FirmwarePickException catch (e) {
      state = state.copyWith(fileError: e.message);
      _log('Arquivo: ${e.message}');
      return;
    }
    if (picked == null) return;
    await loadFile(picked.name, picked.bytes);
  }

  /// Reads family and version from the image itself and computes its
  /// SHA-256. A file that is not one of the three images is refused here,
  /// before anything is sent. A new file starts a new log.
  Future<void> loadFile(String name, Uint8List bytes) async {
    if (state.running) return;
    final kept = state.storedOnBoard;
    final began = DateTime.now();
    state = OtaPushState(
      phase: OtaPushPhase.readingFile,
      storedOnBoard: kept,
      steps: [
        OtaStep(OtaStepId.readFile,
            status: OtaStepStatus.running, startedAt: began),
      ],
    );
    try {
      final header = FirmwareImageHeader.parse(bytes);
      final digest = await compute(_sha256, bytes);
      if (!mounted) return;
      _readTook = DateTime.now().difference(began);
      final file = FirmwareFile(
        name: name,
        bytes: bytes,
        header: header,
        sha256: digest,
        chunkSize: safrOtaChunkMax,
      );
      state = OtaPushState(
        file: file,
        storedOnBoard: kept,
        steps: _freshSteps(file),
      );
      _log('Arquivo escolhido: $name — ${firmwareFamilyLabel(file.family)}, '
          'versão ${file.version}, ${_kb(file.size)}, '
          'SHA-256 ${file.sha256Short}');
    } on FirmwareImageException catch (e) {
      state = OtaPushState(
        fileError: e.message,
        storedOnBoard: kept,
        steps: [
          OtaStep(
            OtaStepId.readFile,
            status: OtaStepStatus.failed,
            startedAt: began,
            took: DateTime.now().difference(began),
            note: e.message,
          ),
        ],
      );
      _log('Arquivo recusado: $name — ${e.message}');
    }
  }

  /// Forgets the file, the steps and the log. What this session saw stored
  /// on the board stays.
  void clear() {
    if (state.running) return;
    state = OtaPushState(storedOnBoard: state.storedOnBoard);
  }

  List<OtaStep> _freshSteps(FirmwareFile file) => [
        OtaStep(
          OtaStepId.readFile,
          status: OtaStepStatus.done,
          took: _readTook,
          note: '${firmwareFamilyLabel(file.family)} ${file.version}, '
              '${_kb(file.size)}',
        ),
        const OtaStep(OtaStepId.linkSpeed),
        const OtaStep(OtaStepId.begin),
        const OtaStep(OtaStepId.send),
        const OtaStep(OtaStepId.verify),
        if (file.family == SafrProductFamily.board) ...const [
          OtaStep(OtaStepId.boardRestart),
          OtaStep(OtaStepId.confirm),
        ],
      ];

  // ── Start / cancel ───────────────────────────────────────────────────────

  /// Why the push cannot start now, or null when it can. A board image is
  /// never started while an alarm is latched: the board restarts, and the
  /// site is unsupervised while it does.
  Future<String?> startBlocker() async {
    final file = state.file;
    if (file == null) return 'Escolha o arquivo do firmware.';
    if (state.running) return 'Já há uma atualização em andamento.';
    if (_ref.read(serialLinkProvider) != SerialLinkStatus.connected) {
      return 'A placa não está respondendo. Verifique o cabo USB.';
    }
    if (file.family == SafrProductFamily.board && await _anyAlarmLatched()) {
      return 'Há alarme ativo. Rearme a central antes de atualizar a placa.';
    }
    return null;
  }

  /// Starts the push of the loaded file. Returns why not, or null when it
  /// started; the push then reports through [state]. [force]: FLAGS bit 0,
  /// for the bench (the same version again, a downgrade).
  Future<String?> start({bool force = false}) async {
    final blocker = await startBlocker();
    if (blocker != null) {
      _log('Não iniciado: $blocker');
      return blocker;
    }
    final file = state.file!;
    final boardRuns = await _boardRuns();
    if (!mounted) return 'A atualização foi encerrada.';
    if (state.running) return 'Já há uma atualização em andamento.';
    _cancelRequested = false;
    state = OtaPushState(
      phase: OtaPushPhase.switchingSpeed,
      file: file,
      baud: _serial.baudRate,
      boardVersionBefore: boardRuns,
      steps: _freshSteps(file),
      log: state.log,
      storedOnBoard: state.storedOnBoard,
      startedAt: DateTime.now(),
    );
    _log('Atualização iniciada: ${firmwareFamilyLabel(file.family)} '
        '${file.version}${force ? ' (instalação forçada)' : ''}'
        '${boardRuns == null ? '' : '; a placa está com a versão $boardRuns'}');
    unawaited(_run(file, force));
    return null;
  }

  /// Stops sending. Nothing is told to the board: it drops a push nobody
  /// continues by itself.
  void cancel() {
    if (!state.canCancel || _cancelRequested) return;
    _cancelRequested = true;
    _log('Cancelamento pedido pelo operador');
  }

  // ── The push ─────────────────────────────────────────────────────────────

  Future<void> _run(FirmwareFile file, bool force) async {
    _mail.clear();
    _boardAtPushBaud = false;
    _boardBootCtr = null;
    _bytesThisRun = 0;
    _loggedTenth = 0;
    _linkLost = false;
    _loggedAnnounce = null;
    _clock
      ..reset()
      ..stop();

    _End end;
    try {
      end = await _transfer(file, force);
    } on _End catch (e) {
      end = e;
    } catch (e, st) {
      debugPrint('[OTA] push failed: $e\n$st');
      end = _End.failed(message: 'A atualização parou por um erro interno.');
    }
    _clock.stop();
    if (!mounted) return;

    final ok =
        end.phase == OtaPushPhase.confirmed || end.phase == OtaPushPhase.stored;
    _closeSteps(failedWith: ok ? null : end.message);

    // A board that restarts took its own line back to the default speed;
    // in every other case the board is asked to go back.
    await _restoreSpeed(askBoard: !end.boardRestarted);
    if (!mounted) return;

    final stored = end.phase == OtaPushPhase.stored
        ? {...state.storedOnBoard, file.family: file.version}
        : state.storedOnBoard;
    state = state.copyWith(
      phase: end.phase,
      message: end.message,
      reason: end.reason,
      boardVersion: end.boardVersion,
      // Also when the push broke while the board was restarting.
      boardRestarted: end.boardRestarted ||
          state.phase == OtaPushPhase.boardRestarting,
      baud: _serial.baudRate,
      waitingFor: null,
      waitingSince: null,
      storedOnBoard: stored,
      endedAt: DateTime.now(),
    );
    _log('Resultado: ${_phaseWord(end.phase)} — ${end.message}');
    final took = state.totalTime;
    _log('Resumo: ${took == null ? '' : '${_seconds(took)} no total, '}'
        '${state.kbPerSecond.toStringAsFixed(0)} KB/s em média, '
        '${state.retries} bloco(s) reenviado(s), '
        '${state.resumes} retomada(s)');
  }

  Future<_End> _transfer(FirmwareFile file, bool force) async {
    final total = file.chunkCount;
    final isBoard = file.family == SafrProductFamily.board;

    var seq = await _openSession(file, force, first: true) ??
        (throw _End.failed(
          reason: SafrOtaReason.timedOut,
          message: 'A placa não respondeu ao pedido de atualização. '
              'O firmware dela pode não aceitar atualização pelo tablet.',
        ));
    _showSending(file, seq, resumed: seq > 0);

    var failures = 0;
    int? retryId;

    while (true) {
      var boardAlreadyVerifying = false;

      while (seq < total) {
        _throwIfCancelled();
        if (isBoard && _alarmLatched) {
          throw _End.failed(
            reason: SafrOtaReason.busyAlarm,
            message: 'Um alarme chegou durante o envio.',
          );
        }
        if (_linkBroken) {
          seq = await _resumeAfterLinkLoss(file, force, seq);
          failures = 0;
          retryId = null;
          _showSending(file, seq, resumed: true);
          continue;
        }

        final data = file.chunk(seq);
        final header = SafrOtaPushChunkPayload(
          seq: seq,
          len: data.length,
          crc32: otaCrc32(data),
        ).build();
        _mail.clear();
        _clock.start();
        final tx = await _downlink.sendOta(
          msgType: SafrMsgType.otaPushChunk,
          payload: header,
          raw: data,
          ackTimeout: _t.chunkAckTimeout,
          description: 'firmware: bloco $seq',
          msgId: retryId,
        );
        retryId = null;
        final ack = tx.ack;

        if (ack == null) {
          if (_linkBroken) continue; // the cable: handled above
          failures++;
          if (failures >= _t.chunkMaxFailures) {
            _log('Bloco $seq: sem resposta pela $failuresª vez, desistindo');
            throw _End.failed(
              reason: SafrOtaReason.timedOut,
              message: 'A placa parou de responder durante o envio.',
            );
          }
          if (_t.reuseMsgIdOnTimeout) retryId = tx.msgId;
          state = state.copyWith(retries: state.retries + 1);
          _log('Bloco $seq: sem resposta em '
              '${_seconds(_t.chunkAckTimeout)}, reenviado '
              '($failures de ${_t.chunkMaxFailures})');
          continue;
        }

        if (ack.status == SafrAckStatus.ok) {
          failures = 0;
          _bytesThisRun += data.length;
          seq++;
          _showProgress(file, seq);
          continue;
        }

        final reason = ack.otaReason;
        if (reason == SafrOtaReason.busy) {
          // END was heard (its ACK was lost): nothing more to send.
          _log('Bloco $seq: a placa já está verificando a imagem');
          boardAlreadyVerifying = true;
          break;
        }
        if (reason != SafrOtaReason.badCrc &&
            reason != SafrOtaReason.outOfOrder) {
          _log('Bloco $seq recusado: ${_reasonText(ack.detailRaw)}');
          throw _End.failed(reason: reason, message: reason.label);
        }
        failures++;
        if (failures >= _t.chunkMaxFailures) {
          _log('Bloco $seq: ${_reasonText(ack.detailRaw)} pela '
              '$failuresª vez, desistindo');
          throw _End.failed(
            reason: reason,
            message: reason == SafrOtaReason.badCrc
                ? 'Os dados chegam corrompidos à placa. Verifique o cabo USB.'
                : 'A placa e o tablet não se entendem sobre o ponto do envio.',
          );
        }
        if (reason == SafrOtaReason.badCrc) {
          state = state.copyWith(retries: state.retries + 1);
          _log('Bloco $seq: erro de CRC, reenviado '
              '($failures de ${_t.chunkMaxFailures})');
          continue; // the same chunk again, as a new transmission
        }
        final sent = seq;
        seq = await _whereToContinue(file, force, 'Bloco $sent');
        _showSending(file, seq, resumed: true);
      }

      // Everything is on the board: END, then its verdict.
      _throwIfCancelled();
      if (isBoard && await _anyAlarmLatched()) {
        throw _End.failed(
          reason: SafrOtaReason.busyAlarm,
          message: 'Um alarme chegou durante o envio.',
        );
      }
      _clock.stop();
      _step(OtaStepId.send, OtaStepStatus.done,
          note: '$total de $total blocos, '
              '${state.kbPerSecond.toStringAsFixed(0)} KB/s');
      _step(OtaStepId.verify, OtaStepStatus.running);
      state = state.copyWith(
        phase: OtaPushPhase.verifying,
        waitingFor: 'placa verificando a imagem',
        waitingSince: DateTime.now(),
      );

      if (!boardAlreadyVerifying) {
        _mail.clear();
        _log('END enviado');
        final tx = await _downlink.sendOta(
          msgType: SafrMsgType.otaPushEnd,
          payload: SafrOtaPushEndPayload.build(),
          ackTimeout: _t.endAckTimeout,
          attempts: _t.endAttempts,
          description: 'firmware: fim do envio',
        );
        final ack = tx.ack;
        if (ack == null && _linkBroken) {
          _backToSending();
          seq = await _resumeAfterLinkLoss(file, force, seq);
          _showSending(file, seq, resumed: true);
          continue;
        }
        if (ack == null) {
          _log('END sem confirmação; aguardando o resultado mesmo assim');
        } else if (ack.status == SafrAckStatus.ok) {
          _log('END confirmado; a placa verifica a imagem');
        } else {
          final reason = ack.otaReason;
          _log('END recusado: ${_reasonText(ack.detailRaw)}');
          if (reason == SafrOtaReason.outOfOrder) {
            // The board lacks something: it says what.
            if (++failures >= _t.chunkMaxFailures) {
              throw _End.failed(reason: reason, message: reason.label);
            }
            _backToSending();
            seq = await _whereToContinue(file, force, 'END');
            _showSending(file, seq, resumed: true);
            continue;
          }
          if (reason != SafrOtaReason.busy) {
            throw _End.failed(reason: reason, message: reason.label);
          }
        }
      }

      final verdict = await _mail.take(
        (e) =>
            e is OtaPushResultEvent &&
            e.result.phase != SafrOtaPushPhase.receiving,
        _t.verdictTimeout,
      ) as OtaPushResultEvent?;

      if (verdict == null) {
        _log('A placa não informou o resultado em '
            '${_seconds(_t.verdictTimeout)}');
        if (!isBoard) {
          throw _End.failed(
            reason: SafrOtaReason.timedOut,
            message: 'A placa não informou o resultado da verificação.',
          );
        }
        // The verdict of a board image may be lost to its restart: what
        // the board runs next tells.
        _step(OtaStepId.verify, OtaStepStatus.done, note: 'sem resposta');
        return _awaitBoard(file);
      }
      _boardBootCtr = verdict.bootCtr;
      final result = verdict.result;
      if (result.phase == SafrOtaPushPhase.failed) {
        throw _End.failed(reason: result.reason, message: result.reason.label);
      }
      _step(OtaStepId.verify, OtaStepStatus.done, note: 'imagem aprovada');
      if (!isBoard) {
        return _End(
          OtaPushPhase.stored,
          message: 'Guardado na placa: ${firmwareFamilyLabel(file.family)} '
              '${file.version}.',
        );
      }
      return _awaitBoard(file);
    }
  }

  /// A board image was verified: the board restarts into it (1.5 s after
  /// its verdict, at the default speed), runs its self-test — for which it
  /// must hear the tablet — and reports:
  ///
  /// - a second OTA_PUSH_RESULT `ok`: the self-test passed, confirmed;
  /// - OTA_PUSH_RESULT `failed` (SELFTEST_FAIL), or a NAME_ANNOUNCE with
  ///   another version: the board went back to the image it had;
  /// - a NAME_ANNOUNCE with the new version and nothing else: the board
  ///   runs it, the self-test is not known to be over — confirmed only if
  ///   it still says so after [OtaPushTimings.selfTestWindow].
  ///
  /// Frames of the board from before the restart (same BOOT_CTR) are not
  /// an answer.
  Future<_End> _awaitBoard(FirmwareFile file) async {
    // The board set its own line to the default speed: no OTA_BAUD.
    await _restoreSpeed(askBoard: false);
    _step(OtaStepId.boardRestart, OtaStepStatus.running);
    state = state.copyWith(
      phase: OtaPushPhase.boardRestarting,
      baud: _serial.baudRate,
      waitingFor: 'aguardando a placa reiniciar',
      waitingSince: DateTime.now(),
    );
    _log('A placa reinicia com a nova imagem; instalação sem supervisão '
        'até ela voltar');

    final before = _boardBootCtr;
    bool restarted(OtaBoardEvent e) => before == null || e.bootCtr != before;
    final started = DateTime.now();
    var deadline = started.add(_t.boardConfirmTimeout);
    var nextPoke = started.add(_t.firstPokeAfter);
    DateTime? heardAt;
    var saidNewVersion = false;

    void boardIsBack() {
      if (heardAt != null) return;
      final now = heardAt = DateTime.now();
      // From here the board has its whole self-test window to answer.
      final end = now.add(_t.selfTestWindow + _t.pokeInterval * 3);
      if (end.isAfter(deadline)) deadline = end;
      _step(OtaStepId.boardRestart, OtaStepStatus.done);
      _step(OtaStepId.confirm, OtaStepStatus.running);
      state = state.copyWith(
        waitingFor: 'placa respondeu, aguardando confirmação',
        waitingSince: now,
      );
      _log('A placa respondeu depois de reiniciar');
    }

    while (true) {
      final now = DateTime.now();
      if (!now.isBefore(deadline)) {
        return _End(
          OtaPushPhase.failed,
          boardRestarted: true,
          reason: SafrOtaReason.timedOut,
          message: heardAt != null
              ? 'A placa reiniciou, mas não confirmou a nova versão. '
                  'Confira a versão dela nesta tela.'
              : 'A placa não voltou a responder depois de reiniciar. '
                  'Verifique o cabo USB.',
        );
      }
      if (!now.isBefore(nextPoke)) {
        nextPoke = now.add(_t.pokeInterval);
        // Any frame of the tablet lets the board pass its self-test; this
        // one also makes it say what it runs.
        if (_portOpen) unawaited(_downlink.sendGetDeviceTable());
      }
      var wait = nextPoke.difference(now);
      final left = deadline.difference(now);
      if (left < wait) wait = left;

      final event = await _mail.take(restarted, wait);
      if (event == null) continue;
      boardIsBack();

      switch (event) {
        case OtaPushResultEvent(:final result):
          if (result.phase == SafrOtaPushPhase.ok) {
            return _confirmed(file, result.version);
          }
          if (result.phase == SafrOtaPushPhase.failed) {
            // What it runs now came, or comes, with its NAME_ANNOUNCE.
            final said = await _mail.take(
              (e) => restarted(e) && e is BoardAnnounceEvent,
              _t.resultGrace,
            ) as BoardAnnounceEvent?;
            return _rolledBack(
              file,
              reason: result.reason,
              runs: said?.fwVersion,
            );
          }
        case BoardAnnounceEvent(:final fwVersion):
          if (fwVersion != file.version) {
            // Its report of the rollback comes right behind.
            final report = await _mail.take(
              (e) =>
                  restarted(e) &&
                  e is OtaPushResultEvent &&
                  e.result.phase == SafrOtaPushPhase.failed,
              _t.resultGrace,
            ) as OtaPushResultEvent?;
            return _rolledBack(
              file,
              runs: fwVersion,
              reason: report?.result.reason,
            );
          }
          final since = DateTime.now().difference(heardAt!);
          if (since >= _t.selfTestWindow) {
            _log('A placa segue na versão $fwVersion depois do prazo do '
                'autoteste');
            return _confirmed(file, fwVersion);
          }
          if (!saidNewVersion) {
            saidNewVersion = true;
            state = state.copyWith(
              waitingFor: 'placa com a versão $fwVersion, aguardando o '
                  'autoteste',
            );
          }
        case BoardHeartbeatEvent():
          break;
      }
    }
  }

  _End _confirmed(FirmwareFile file, String version) {
    final runs = version.isEmpty ? file.version : version;
    return _End(
      OtaPushPhase.confirmed,
      boardRestarted: true,
      boardVersion: runs,
      message: 'A placa reiniciou e está com a versão $runs.',
    );
  }

  _End _rolledBack(FirmwareFile file, {String? runs, SafrOtaReason? reason}) {
    final kept = runs == null ? '' : ' Ela continua com a versão $runs.';
    return _End(
      OtaPushPhase.rolledBack,
      boardRestarted: true,
      reason: reason ?? SafrOtaReason.selftestFail,
      boardVersion: runs,
      message: reason != null && reason != SafrOtaReason.selftestFail
          ? 'A placa não ficou com a versão ${file.version}: '
              '${reason.label}$kept'
          : 'A placa testou a versão ${file.version}, não passou no '
              'autoteste e voltou para a versão anterior.$kept',
    );
  }

  // ── Speed, BEGIN, resume ─────────────────────────────────────────────────

  /// Agrees on the speed and announces the image. Returns the chunk the
  /// board wants first, or null when the board never answered. Throws when
  /// the board refused. [first]: the session that opens the push moves the
  /// steps; one that resumes it only writes to the log.
  Future<int?> _openSession(
    FirmwareFile file,
    bool force, {
    bool first = false,
  }) async {
    if (first) _step(OtaStepId.linkSpeed, OtaStepStatus.running);

    // After the cable came back the board may still be at the push speed
    // (it only leaves it after 20 s of silence) while the port opened at
    // the default one: try there first, briefly.
    if (_boardAtPushBaud && _serial.baudRate != _t.pushBaud) {
      _log('Velocidade: tentando ${_t.pushBaud} bps, onde a placa estava');
      await _setLocalBaud(_t.pushBaud);
      final next = await _begin(
        file,
        force,
        ackTimeout: _t.probeAckTimeout,
        attempts: _t.probeAttempts,
      );
      if (next != null) return next;
      await _setLocalBaud(safrOtaDefaultBaud);
      _boardAtPushBaud = false;
    }

    var speedNote = '${_serial.baudRate} bps';
    if (!_boardAtPushBaud && _t.pushBaud != safrOtaDefaultBaud) {
      _throwIfCancelled();
      _log('Velocidade: pedindo ${_t.pushBaud} bps à placa');
      final ack = await _sendBaud(_t.pushBaud);
      if (ack != null && ack.status == SafrAckStatus.ok) {
        await _setLocalBaud(_t.pushBaud);
        _boardAtPushBaud = true;
        speedNote = '${_t.pushBaud} bps';
        _log('Velocidade: ${_t.pushBaud} bps (a placa confirmou)');
      } else {
        // Never confirmed (older firmware) or refused: the push goes on at
        // the speed the link has.
        final why = ack == null
            ? 'a placa não confirmou'
            : 'a placa recusou: ${_reasonText(ack.detailRaw)}';
        speedNote = '${_serial.baudRate} bps ($why ${_t.pushBaud})';
        _log('Velocidade: $why; o envio segue a ${_serial.baudRate} bps');
      }
    }
    if (first) {
      _step(OtaStepId.linkSpeed, OtaStepStatus.done, note: speedNote);
      _step(OtaStepId.begin, OtaStepStatus.running);
    }

    _throwIfCancelled();
    var next = await _begin(file, force);
    if (next == null && _boardAtPushBaud && _portOpen) {
      // It confirmed the speed and is not there: back to the default one.
      _log('Velocidade: sem resposta a ${_t.pushBaud} bps, de volta a '
          '$safrOtaDefaultBaud bps');
      await _setLocalBaud(safrOtaDefaultBaud);
      _boardAtPushBaud = false;
      if (first) {
        _step(OtaStepId.linkSpeed, OtaStepStatus.done,
            note: '$safrOtaDefaultBaud bps (sem resposta a ${_t.pushBaud})');
      }
      _throwIfCancelled();
      next = await _begin(file, force);
    }
    if (next != null && first) {
      _step(OtaStepId.begin, OtaStepStatus.done,
          note: next == 0 ? 'desde o início' : 'a partir do bloco $next');
    }
    return next;
  }

  /// OTA_PUSH_BEGIN. The board answers OTA_PUSH_RESULT {receiving,
  /// NEXT_SEQ} and then the ACK: NEXT_SEQ is 0 for a new transfer, the
  /// first chunk it lacks when it holds part of this same image. Null = no
  /// ACK. Throws when the board refused (ACK ERROR, DETAIL = the reason).
  Future<int?> _begin(
    FirmwareFile file,
    bool force, {
    Duration? ackTimeout,
    int? attempts,
  }) async {
    _mail.clear();
    _log('BEGIN enviado a ${_serial.baudRate} bps: '
        '${firmwareFamilyLabel(file.family)} ${file.version}, '
        '${_kb(file.size)}, ${file.chunkCount} blocos');
    final tx = await _downlink.sendOta(
      msgType: SafrMsgType.otaPushBegin,
      payload: SafrOtaPushBeginPayload(
        family: file.family.wire,
        size: file.size,
        sha256: file.sha256,
        chunk: file.chunkSize,
        flags: force ? safrOtaFlagForce : 0,
        version: file.version,
      ).build(),
      ackTimeout: ackTimeout ?? _t.beginAckTimeout,
      attempts: attempts ?? _t.beginAttempts,
      description: 'firmware: início do envio',
    );
    final ack = tx.ack;
    if (ack == null) {
      _log(_portOpen ? 'BEGIN sem resposta' : 'BEGIN não enviado: sem cabo');
      return null;
    }
    if (ack.status != SafrAckStatus.ok) {
      final reason = ack.otaReason;
      _log('BEGIN recusado: ${_reasonText(ack.detailRaw)}');
      throw _End.failed(
        reason: reason,
        // SHA_FAIL cannot be the answer to BEGIN: nothing was sent yet. The
        // value is "refused" in the DETAIL list of the other commands
        // (§7.5), which is what a board without firmware update answers.
        message: reason == SafrOtaReason.shaFail || reason == SafrOtaReason.none
            ? 'A placa recusou a atualização.'
            : reason.label,
      );
    }
    final hint = await _mail.take(
      (e) =>
          e is OtaPushResultEvent &&
          e.result.phase == SafrOtaPushPhase.receiving,
      _t.resultGrace,
    ) as OtaPushResultEvent?;
    if (hint != null) _boardBootCtr = hint.bootCtr;
    final next = _checkedSeq(file, hint?.result.nextSeq ?? 0);
    _log('BEGIN aceito: a placa quer o bloco $next'
        '${hint == null ? ' (ela não disse; do início)' : ''}');
    return next;
  }

  /// The board refused a chunk (or END) as out of order. It said where it
  /// is with an OTA_PUSH_RESULT sent just before that ACK: `receiving` =
  /// go on from NEXT_SEQ; `failed` with OUT_OF_ORDER = it holds no transfer
  /// any more (it restarted, or dropped a push nobody continued): BEGIN
  /// again. Without a RESULT, BEGIN asks.
  Future<int> _whereToContinue(
    FirmwareFile file,
    bool force,
    String what,
  ) async {
    final event = await _mail.take(
      (e) => e is OtaPushResultEvent,
      _t.resultGrace,
    ) as OtaPushResultEvent?;
    if (event != null) {
      final r = event.result;
      if (r.phase == SafrOtaPushPhase.receiving) {
        _boardBootCtr = event.bootCtr;
        final next = _checkedSeq(file, r.nextSeq);
        _log('$what: fora de ordem; a placa quer o bloco $next');
        return next;
      }
      if (r.phase == SafrOtaPushPhase.failed &&
          r.reason != SafrOtaReason.outOfOrder) {
        throw _End.failed(reason: r.reason, message: r.reason.label);
      }
    }
    _log('$what: a placa não tem mais este envio; começando de novo');
    _throwIfCancelled();
    final next = await _begin(file, force);
    if (next == null) {
      if (_linkBroken) return _resumeAfterLinkLoss(file, force, 0);
      throw _End.failed(
        reason: SafrOtaReason.timedOut,
        message: 'A placa parou de responder durante o envio.',
      );
    }
    return next;
  }

  int _checkedSeq(FirmwareFile file, int next) {
    if (next > file.chunkCount) {
      throw _End.failed(
        reason: SafrOtaReason.outOfOrder,
        message: 'A placa pediu um bloco que o arquivo não tem.',
      );
    }
    return next;
  }

  /// The cable is out. When the port is back: speed and BEGIN again, and on
  /// from the chunk the board gives. Gives up
  /// [OtaPushTimings.linkLossTimeout] after the link was lost.
  Future<int> _resumeAfterLinkLoss(
    FirmwareFile file,
    bool force,
    int at,
  ) async {
    _clock.stop();
    final deadline = DateTime.now().add(_t.linkLossTimeout);
    state = state.copyWith(
      waitingFor: 'cabo desconectado: aguardando a ligação com a placa',
      waitingSince: DateTime.now(),
    );
    _log('Ligação perdida no bloco $at');
    var wasOpen = false;
    while (true) {
      _throwIfCancelled();
      if (!DateTime.now().isBefore(deadline)) {
        throw _End.failed(
          reason: SafrOtaReason.timedOut,
          message: 'A ligação com a placa ficou interrompida por mais de '
              '${_seconds(_t.linkLossTimeout)}.',
        );
      }
      if (!_portOpen) {
        wasOpen = false;
        await Future<void>.delayed(_t.linkPoll);
        continue;
      }
      _linkLost = false;
      if (!wasOpen) {
        wasOpen = true;
        _log('Ligação de volta');
        state = state.copyWith(
          waitingFor: 'cabo de volta: aguardando a placa responder',
        );
      }
      final next = await _openSession(file, force);
      if (next != null && !_linkLost) return next;
      // The port is open and the board silent (or the cable went out
      // again): once more, until the deadline.
      await Future<void>.delayed(_t.linkPoll);
    }
  }

  Future<SafrAckPayload?> _sendBaud(int baud) => _downlink.sendOtaBaud(
        baud,
        ackTimeout: _t.baudAckTimeout,
        attempts: _t.baudAttempts,
      );

  Future<void> _setLocalBaud(int baud) async {
    await _serial.setBaudRate(baud);
    if (mounted) state = state.copyWith(baud: _serial.baudRate);
  }

  /// Back to the default speed. [askBoard]: tell the board with OTA_BAUD
  /// first; whether it confirms or not, this end goes back.
  Future<void> _restoreSpeed({required bool askBoard}) async {
    if (_portOpen && _serial.baudRate != safrOtaDefaultBaud) {
      if (askBoard) {
        final ack = await _sendBaud(safrOtaDefaultBaud);
        if (!mounted) return;
        _log(ack != null && ack.status == SafrAckStatus.ok
            ? 'Velocidade: de volta a $safrOtaDefaultBaud bps '
                '(a placa confirmou)'
            : 'Velocidade: de volta a $safrOtaDefaultBaud bps (a placa não '
                'confirmou; ela volta sozinha depois de 20 s de silêncio)');
      } else {
        _log('Velocidade: de volta a $safrOtaDefaultBaud bps');
      }
      await _serial.setBaudRate(safrOtaDefaultBaud);
      if (mounted) state = state.copyWith(baud: _serial.baudRate);
    }
    _boardAtPushBaud = false;
  }

  // ── Steps, log, progress ─────────────────────────────────────────────────

  void _onBoardEvent(OtaBoardEvent event) {
    if (!state.running) return;
    _mail.add(event);
    switch (event) {
      case OtaPushResultEvent(:final result):
        final version =
            result.version.isEmpty ? '' : ', versão ${result.version}';
        _log(switch (result.phase) {
          SafrOtaPushPhase.receiving =>
            'Placa → OTA_PUSH_RESULT: recebendo, próximo bloco '
                '${result.nextSeq}$version',
          SafrOtaPushPhase.ok => 'Placa → OTA_PUSH_RESULT: ok$version',
          SafrOtaPushPhase.failed => 'Placa → OTA_PUSH_RESULT: falhou, '
              '${_reasonText(result.reasonRaw)}$version',
        });
      case BoardAnnounceEvent(:final fwVersion, :final bootCtr):
        final said = '$bootCtr/$fwVersion';
        if (said != _loggedAnnounce) {
          _loggedAnnounce = said;
          _log('Placa → NAME_ANNOUNCE: versão $fwVersion');
        }
      case BoardHeartbeatEvent():
        break;
    }
  }

  void _log(String text) {
    if (!mounted) return;
    debugPrint('[OTA] $text');
    final log = state.log.length >= logCapacity
        ? state.log.sublist(state.log.length - logCapacity + 1)
        : state.log;
    state = state.copyWith(log: [...log, OtaLogLine(DateTime.now(), text)]);
  }

  void _step(OtaStepId id, OtaStepStatus status, {String? note}) {
    if (!mounted) return;
    final now = DateTime.now();
    state = state.copyWith(steps: [
      for (final s in state.steps)
        if (s.id != id)
          s
        else
          switch (status) {
            OtaStepStatus.waiting => OtaStep(id),
            OtaStepStatus.running => OtaStep(
                id,
                status: status,
                startedAt: s.startedAt ?? now,
                note: note ?? s.note,
              ),
            OtaStepStatus.done || OtaStepStatus.failed => OtaStep(
                id,
                status: status,
                startedAt: s.startedAt,
                took: s.startedAt == null
                    ? Duration.zero
                    : now.difference(s.startedAt!),
                note: note ?? s.note,
              ),
          },
    ]);
  }

  /// The end: what was running failed with [failedWith], or is done.
  void _closeSteps({String? failedWith}) {
    for (final s in state.steps) {
      if (s.status != OtaStepStatus.running) continue;
      _step(
        s.id,
        failedWith == null ? OtaStepStatus.done : OtaStepStatus.failed,
        note: failedWith,
      );
    }
  }

  /// END was refused or never left: the push is sending again.
  void _backToSending() {
    _step(OtaStepId.verify, OtaStepStatus.waiting);
    _step(OtaStepId.send, OtaStepStatus.running);
  }

  void _showSending(FirmwareFile file, int seq, {bool resumed = false}) {
    _step(OtaStepId.send, OtaStepStatus.running);
    _loggedTenth = (file.bytesBefore(seq) * 10) ~/ file.size;
    state = state.copyWith(
      phase: OtaPushPhase.sending,
      chunksDone: seq,
      bytesDone: file.bytesBefore(seq),
      baud: _serial.baudRate,
      waitingFor: null,
      waitingSince: null,
      resumes: state.resumes + (resumed ? 1 : 0),
    );
  }

  void _showProgress(FirmwareFile file, int seq) {
    final ms = _clock.elapsedMilliseconds;
    state = state.copyWith(
      chunksDone: seq,
      bytesDone: file.bytesBefore(seq),
      kbPerSecond: ms <= 0 ? 0 : (_bytesThisRun / 1024) / (ms / 1000),
    );
    final tenth = (state.bytesDone * 10) ~/ file.size;
    if (tenth > _loggedTenth) {
      _loggedTenth = tenth;
      _log('Envio: ${tenth * 10} % — $seq de ${file.chunkCount} blocos, '
          '${state.kbPerSecond.toStringAsFixed(0)} KB/s');
    }
  }

  void _throwIfCancelled() {
    if (_cancelRequested) {
      throw _End.failed(
        reason: SafrOtaReason.aborted,
        message: 'A atualização foi cancelada pelo operador.',
      );
    }
  }

  /// The firmware the board runs, as its device row says now; null when the
  /// board never reported one.
  Future<String?> _boardRuns() async {
    final db = _ref.read(appDatabaseProvider);
    final rows = await (db.select(db.meshDevices)
          ..orderBy([(t) => OrderingTerm.desc(t.lastSeenAt)]))
        .get();
    final fw = pickBoardDevice(rows)?.fwVersion;
    return fw == null || fw.isEmpty ? null : fw;
  }

  Future<bool> _anyAlarmLatched() async {
    final db = _ref.read(appDatabaseProvider);
    final row = await (db.select(db.meshDevices)
          ..where((t) => t.alarmLatched.equals(1))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  /// "motivo 14: os dados chegaram corrompidos pelo cabo".
  static String _reasonText(int raw) {
    final label = SafrOtaReason.fromWire(raw).label;
    final text =
        label.endsWith('.') ? label.substring(0, label.length - 1) : label;
    return 'motivo $raw: ${text[0].toLowerCase()}${text.substring(1)}';
  }

  static String _kb(int bytes) =>
      '${(bytes / 1024).toStringAsFixed(bytes < 10240 ? 1 : 0)} KB';

  static String _seconds(Duration d) => d.inMilliseconds % 1000 == 0
      ? '${d.inSeconds} s'
      : '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';

  static String _phaseWord(OtaPushPhase phase) => switch (phase) {
        OtaPushPhase.confirmed => 'confirmado',
        OtaPushPhase.stored => 'guardado',
        OtaPushPhase.rolledBack => 'voltou à versão anterior',
        OtaPushPhase.failed => 'falhou',
        _ => phase.name,
      };

  @override
  void dispose() {
    _cancelRequested = true;
    _events.cancel();
    super.dispose();
  }
}

Uint8List _sha256(Uint8List bytes) =>
    Uint8List.fromList(crypto.sha256.convert(bytes).bytes);

/// How a push ended.
class _End implements Exception {
  _End(
    this.phase, {
    required this.message,
    this.reason,
    this.boardVersion,
    this.boardRestarted = false,
  });

  _End.failed({required this.message, this.reason})
      : phase = OtaPushPhase.failed,
        boardVersion = null,
        boardRestarted = false;

  final OtaPushPhase phase;
  final String message;
  final SafrOtaReason? reason;
  final String? boardVersion;

  /// The board restarted: its line is at the default speed by itself.
  final bool boardRestarted;
}

/// What the board said while the push was busy with something else, in the
/// order it arrived.
class _Mailbox<T> {
  final _items = <T>[];
  Completer<void>? _signal;

  void add(T item) {
    _items.add(item);
    final s = _signal;
    _signal = null;
    if (s != null && !s.isCompleted) s.complete();
  }

  void clear() => _items.clear();

  /// The first item [test] accepts, within [timeout]; it and everything
  /// before it leave the box. Null = none came.
  Future<T?> take(bool Function(T item) test, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final i = _items.indexWhere(test);
      if (i >= 0) {
        final item = _items[i];
        _items.removeRange(0, i + 1);
        return item;
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      final signal = _signal ??= Completer<void>();
      await signal.future.timeout(left, onTimeout: () {});
    }
  }
}

/// Timeouts of the push; tests override it with short ones.
final otaPushTimingsProvider =
    Provider<OtaPushTimings>((ref) => const OtaPushTimings());

final otaPushProvider =
    StateNotifierProvider<OtaPushController, OtaPushState>((ref) {
  return OtaPushController(ref, timings: ref.watch(otaPushTimingsProvider));
});
