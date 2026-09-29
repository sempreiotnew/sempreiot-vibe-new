import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/central_installation_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_board_events_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_controller.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_state.dart';
import 'package:sempreiot_central_app/features/central/application/safr_ingest_provider.dart';
import 'package:sempreiot_central_app/features/central/application/serial_link_provider.dart';
import 'package:sempreiot_central_app/features/central/application/serial_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_identity.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

import 'fake_board.dart';
import 'fake_firmware.dart';

/// The push controller against a board played byte for byte on the serial
/// port (fake_board.dart): the real encoder, the real ACK tracking, the
/// real ingest pipeline and reframer in between. Protocol §13.3.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final identity = SafrIdentity(
    systemId: 0x4A17,
    key: Uint8List.fromList([for (var i = 0; i < 16; i++) 0x30 + i]),
  );

  // The board's numbers, a hundred times shorter.
  const timings = OtaPushTimings(
    baudAckTimeout: Duration(milliseconds: 80),
    baudAttempts: 2,
    beginAckTimeout: Duration(milliseconds: 100),
    beginAttempts: 2,
    probeAckTimeout: Duration(milliseconds: 80),
    probeAttempts: 1,
    resultGrace: Duration(milliseconds: 40),
    chunkAckTimeout: Duration(milliseconds: 120),
    chunkMaxFailures: 5,
    endAckTimeout: Duration(milliseconds: 80),
    endAttempts: 2,
    verdictTimeout: Duration(milliseconds: 600),
    linkLossTimeout: Duration(milliseconds: 900),
    linkPoll: Duration(milliseconds: 15),
    boardConfirmTimeout: Duration(milliseconds: 1500),
    firstPokeAfter: Duration(milliseconds: 80),
    pokeInterval: Duration(milliseconds: 60),
    selfTestWindow: Duration(milliseconds: 600),
  );

  late AppDatabase db;
  late FakeBoard board;
  late ProviderContainer container;

  Future<void> boot({
    String boardRuns = '0.1.0',
    OtaPushTimings t = timings,
  }) async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    board = FakeBoard(identity: identity, runningVersion: boardRuns);
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      serialProvider.overrideWith((ref) => board),
      safrIdentityProvider.overrideWithValue(identity),
      otaPushTimingsProvider.overrideWithValue(t),
    ]);
    container.read(safrIngestProvider); // serial → ingest → downlink
    container.read(otaPushProvider);
    board.plug();
    await _until(
      () => container.read(serialLinkProvider) == SerialLinkStatus.connected,
      what: 'the link to come up',
    );
    // What the tablet sends when the link comes up (TIME_SYNC, the journal,
    // GET_INSTALLATION, GET_DEVICE_TABLE): answered and out of the way.
    await _until(() => board.commands(SafrCommand.getDeviceTable) > 0,
        what: 'the link-up sequence');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  tearDown(() async {
    // A link-up sequence started by a cable that came back ends first.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    container.dispose();
    await db.close();
  });

  OtaPushController push() => container.read(otaPushProvider.notifier);
  OtaPushState state() => container.read(otaPushProvider);
  List<String> log() => [for (final l in state().log) l.text];

  Future<Uint8List> load({
    String project = 'sempreiot-node',
    String version = '0.2.0',
    int size = 4096 * 6 + 1000,
  }) async {
    final image = fakeFirmware(project: project, version: version, size: size);
    await push().loadFile('$project.bin', image);
    expect(state().fileError, isNull);
    expect(state().file, isNotNull);
    return image;
  }

  Future<OtaPushState> run({bool force = false}) async {
    expect(await push().start(force: force), isNull);
    await _until(() => state().finished,
        what: 'the push to end', within: const Duration(seconds: 20));
    return state();
  }

  OtaStepStatus? step(OtaStepId id) => state().step(id)?.status;

  /// Every write that starts with an OTA_PUSH_CHUNK frame carries exactly
  /// that frame and its raw bytes: nothing else in it, nothing in between.
  void expectChunksWrittenWhole(int chunkFrames) {
    var seen = 0;
    for (final w in board.writes) {
      if (w.length < 5 || w[0] != safrSof || w[4] != 0x10) continue;
      seen++;
      final frameLen = (w[2] << 8) | w[3];
      final frame = parseSafrWireFrame(
        Uint8List.sublistView(w, 0, frameLen),
        key: identity.key,
        expectedSystemId: identity.systemId,
      );
      expect(frame.error, isNull);
      expect(frame.ackRequired, isTrue);
      final header = frame.payload as SafrOtaPushChunkPayload;
      expect(w.length, frameLen + header.len,
          reason: 'frame and raw bytes of chunk ${header.seq} in one write');
    }
    expect(seen, chunkFrames);
  }

  group('a node image', () {
    test('is sent, verified and stored', () async {
      await boot();
      final image = await load();
      board.eventEveryChunks = 2; // other traffic in the middle of it

      final end = await run();

      expect(end.phase, OtaPushPhase.stored);
      expect(
          end.message, 'Guardado na placa: unidades de rede elétrica 0.2.0.');
      // Stored is all that happened: the board runs what it ran.
      expect(end.boardRestarted, isFalse);
      expect(end.boardVersionBefore, '0.1.0');
      expect(end.storedOnBoard, {SafrProductFamily.node: '0.2.0'});
      expect(board.runningVersion, '0.1.0');
      expect(board.images[0x02], image);
      expect(board.imageVersions[0x02], '0.2.0');
      expect(end.chunksDone, 7);
      expect(end.chunksTotal, 7);
      expect(end.bytesDone, image.length);
      expect(end.progress, 1.0);
      expect(end.retries, 0);
      expect(end.resumes, 0);
      expect(end.kbPerSecond, greaterThan(0));
      expect(end.totalTime, isNotNull);
      expect(end.storedOnBoard, {
        for (final e in end.storedOnBoard.entries) e.key: '0.2.0',
      });
      expect(end.storedOnBoard.keys.single.wire, 0x02);

      // Seven chunks, in order, once each, each in one write.
      expect(board.chunksSeen, [0, 1, 2, 3, 4, 5, 6]);
      expectChunksWrittenWhole(7);

      // What BEGIN said.
      final begin = board.heard
          .firstWhere((f) => f.msgType == SafrMsgType.otaPushBegin)
          .payload as SafrOtaPushBeginPayload;
      expect(begin.family, 0x02);
      expect(begin.size, image.length);
      expect(begin.chunk, 4096);
      expect(begin.flags, 0);
      expect(begin.version, '0.2.0');
      expect(begin.sha256, crypto.sha256.convert(image).bytes);

      // Up to 921600 and back, both ends.
      expect(board.baudCommands, 2);
      expect(board.boardBaud, 115200);
      expect(board.tabletBaud, 115200);
      expect(end.baud, 115200);

      // The unit's events were ACKed while the push ran.
      final acks = board.heard.where((f) => f.msgType == SafrMsgType.ack);
      expect(acks.length, greaterThanOrEqualTo(3));
      expect(acks.every((f) => f.dstMac == FakeBoard.unitMac), isTrue);
    });

    test('shows its steps and writes its log', () async {
      await boot();
      await load(size: 4096 * 20);
      final phases = <OtaPushPhase>{};
      final sub = container.listen(
          otaPushProvider, (_, s) => phases.add(s.phase),
          fireImmediately: true);
      final end = await run();
      sub.close();

      expect(
          phases,
          containsAll([
            OtaPushPhase.switchingSpeed,
            OtaPushPhase.sending,
            OtaPushPhase.verifying,
            OtaPushPhase.stored,
          ]));
      expect(end.steps.map((s) => s.id), [
        OtaStepId.readFile,
        OtaStepId.linkSpeed,
        OtaStepId.begin,
        OtaStepId.send,
        OtaStepId.verify,
      ]);
      for (final s in end.steps) {
        expect(s.status, OtaStepStatus.done, reason: s.id.name);
        expect(s.took, isNotNull, reason: s.id.name);
      }
      expect(end.step(OtaStepId.linkSpeed)!.note, '921600 bps');
      expect(end.step(OtaStepId.begin)!.note, 'desde o início');
      expect(end.step(OtaStepId.send)!.note, startsWith('20 de 20 blocos'));
      expect(end.waitingFor, isNull);

      final lines = log();
      expect(lines.first, startsWith('Arquivo escolhido: sempreiot-node.bin'));
      expect(lines.first, contains('versão 0.2.0'));
      expect(lines.first, contains('80 KB'));
      expect(lines.first, contains('SHA-256 '));
      expect(lines, contains('Velocidade: 921600 bps (a placa confirmou)'));
      expect(lines, contains(startsWith('BEGIN enviado a 921600 bps')));
      expect(lines, contains('BEGIN aceito: a placa quer o bloco 0'));
      expect(lines, contains('END enviado'));
      expect(
          lines,
          contains('Placa → OTA_PUSH_RESULT: recebendo, próximo bloco 0, '
              'versão 0.2.0'));
      expect(lines, contains('Placa → OTA_PUSH_RESULT: ok, versão 0.2.0'));
      expect(lines,
          contains('Velocidade: de volta a 115200 bps (a placa confirmou)'));
      expect(lines, contains(startsWith('Resultado: guardado — ')));
      expect(lines.last, startsWith('Resumo: '));
      expect(lines.last, contains('0 bloco(s) reenviado(s), 0 retomada(s)'));

      // Progress every 10 %, never a line per chunk.
      final progress = lines.where((l) => l.startsWith('Envio: ')).toList();
      expect(progress.length, 10);
      expect(progress.first, startsWith('Envio: 10 % — 2 de 20 blocos'));
      expect(progress.last, startsWith('Envio: 100 % — 20 de 20 blocos'));
      expect(lines.where((l) => l.startsWith('Bloco ')), isEmpty);

      // Times with seconds, oldest first, and the whole of it as text.
      expect(state().log.first.time, matches(RegExp(r'^\d\d:\d\d:\d\d$')));
      expect(state().logText.split('\n').length, lines.length);
    });

    test('a leaf image is stored as one', () async {
      await boot();
      final image = await load(project: 'sempreiot-leaf', version: '1.0.0');
      final end = await run();
      expect(end.phase, OtaPushPhase.stored);
      expect(end.message, 'Guardado na placa: unidades a bateria 1.0.0.');
      expect(board.images[0x03], image);
    });

    test('what was stored stays on the screen for the session', () async {
      await boot();
      await load();
      await run();
      await load(project: 'sempreiot-leaf', version: '1.0.0');
      expect(state().storedOnBoard.values, ['0.2.0']);
      await run();
      expect({
        for (final e in state().storedOnBoard.entries) e.key.wire: e.value,
      }, {
        0x02: '0.2.0',
        0x03: '1.0.0'
      });
      push().clear();
      expect(state().storedOnBoard.length, 2);
      expect(state().log, isEmpty);
    });
  });

  group('a chunk that goes wrong', () {
    test('BAD_CRC: the same chunk again', () async {
      await boot();
      final image = await load();
      board.corruptOnce.add(2);

      final end = await run();

      expect(end.phase, OtaPushPhase.stored);
      expect(board.images[0x02], image);
      expect(board.chunksSeen, [0, 1, 2, 2, 3, 4, 5, 6]);
      expect(end.retries, 1);
      expect(end.resumes, 0);
      expectChunksWrittenWhole(8);
      expect(log(), contains('Bloco 2: erro de CRC, reenviado (1 de 5)'));
      expect(log().last, contains('1 bloco(s) reenviado(s)'));

      // Refused: the chunk went again as a new transmission.
      final ids = [
        for (final f in board.heard)
          if (f.payload case SafrOtaPushChunkPayload p when p.seq == 2) f.msgId,
      ];
      expect(ids.length, 2);
      expect(ids[0], isNot(ids[1]));
    });

    test('a lost ACK: sent again under the same MSG_ID, written once',
        () async {
      await boot();
      final image = await load();
      board.dropAckOnce.add(1);

      final end = await run();

      expect(end.phase, OtaPushPhase.stored);
      expect(board.images[0x02], image);
      expect(board.chunksSeen, [0, 1, 1, 2, 3, 4, 5, 6]);
      expect(end.retries, 1);
      expect(log(),
          contains('Bloco 1: sem resposta em 0.1 s, reenviado (1 de 5)'));

      final sent = [
        for (final f in board.heard)
          if (f.payload case SafrOtaPushChunkPayload p when p.seq == 1) f,
      ];
      expect(sent.length, 2);
      expect(sent[0].msgId, sent[1].msgId); // §9.1
      expect(sent[0].msgCtr, isNot(sent[1].msgCtr)); // a nonce is never reused
    });

    test('a chunk that never arrives: sent again', () async {
      await boot();
      final image = await load();
      board.loseChunk[3] = 2;

      final end = await run();

      expect(end.phase, OtaPushPhase.stored);
      expect(board.images[0x02], image);
      expect(end.retries, 2);
      expect(
          log().where((l) => l.startsWith('Bloco 3: sem resposta')).length, 2);
    });

    test('five times without an answer: the push fails', () async {
      await boot();
      await load();
      board.loseChunk[2] = 99;

      final end = await run();

      expect(end.phase, OtaPushPhase.failed);
      expect(end.reason, SafrOtaReason.timedOut);
      expect(end.message, 'A placa parou de responder durante o envio.');
      expect(end.boardRestarted, isFalse);
      expect(end.storedOnBoard, isEmpty);
      expect(end.chunksDone, 2);
      expect(board.images, isEmpty);
      expect(end.retries, 4);
      expect(step(OtaStepId.send), OtaStepStatus.failed);
      expect(end.step(OtaStepId.send)!.note, end.message);
      expect(step(OtaStepId.verify), OtaStepStatus.waiting);
      expect(log(), contains('Bloco 2: sem resposta pela 5ª vez, desistindo'));
      // Back at the default speed, both ends.
      expect(board.boardBaud, 115200);
      expect(board.tabletBaud, 115200);
    });

    test('OUT_OF_ORDER: on from the chunk the board wants', () async {
      await boot();
      final image = await load();
      board.rewindAt[4] = 2; // at chunk 4 the board is back at chunk 2

      final end = await run();

      expect(end.phase, OtaPushPhase.stored);
      expect(board.images[0x02], image);
      expect(board.chunksSeen, [0, 1, 2, 3, 4, 2, 3, 4, 5, 6]);
      expect(end.resumes, 1);
      expect(end.retries, 0);
      expect(board.count(SafrMsgType.otaPushBegin), 1);
      expect(log(), contains('Bloco 4: fora de ordem; a placa quer o bloco 2'));
      expect(log().last, contains('1 retomada(s)'));
    });

    test('the board holds no transfer any more: BEGIN again', () async {
      await boot();
      final image = await load();
      board.forgetAt.add(3);

      final end = await run();

      expect(end.phase, OtaPushPhase.stored);
      expect(board.images[0x02], image);
      expect(board.chunksSeen, [0, 1, 2, 3, 0, 1, 2, 3, 4, 5, 6]);
      expect(board.count(SafrMsgType.otaPushBegin), 2);
      expect(end.resumes, 1);
      expect(
          log(),
          contains('Bloco 3: a placa não tem mais este envio; começando '
              'de novo'));
      expect(
          log(),
          contains('Placa → OTA_PUSH_RESULT: falhou, motivo 15: a placa '
              'recebeu os dados fora de ordem'));
    });
  });

  group('resume', () {
    test('the board holds part of this image: starts where it stopped',
        () async {
      await boot();
      final image = await load();
      final file = state().file!;
      board.holdPartOf(
        image,
        SafrOtaPushBeginPayload(
          family: 0x02,
          size: image.length,
          sha256: file.sha256,
          version: '0.2.0',
        ),
        3,
      );

      final end = await run();

      expect(end.phase, OtaPushPhase.stored);
      expect(board.images[0x02], image);
      expect(board.chunksSeen, [3, 4, 5, 6]);
      expect(end.resumes, 1);
      expect(end.step(OtaStepId.begin)!.note, 'a partir do bloco 3');
      expect(log(), contains('BEGIN aceito: a placa quer o bloco 3'));
    });

    test('the cable is pulled and put back: BEGIN again, and on', () async {
      await boot();
      final image = await load(size: 4096 * 10);
      var pulled = false;
      board.onChunkWritten = (seq) {
        if (seq != 3 || pulled) return;
        pulled = true;
        board.unplug();
        Timer(const Duration(milliseconds: 150), board.plug);
      };
      final waits = <String>{};
      final sub = container.listen(otaPushProvider, (_, s) {
        if (s.waitingFor != null) waits.add(s.waitingFor!);
      });

      final end = await run();
      sub.close();

      expect(end.phase, OtaPushPhase.stored);
      expect(board.images[0x02], image);
      expect(end.resumes, 1);
      expect(board.count(SafrMsgType.otaPushBegin), 2);
      // Chunk 3 was written, its ACK died with the cable: the board asks
      // for 4.
      expect(board.chunksSeen, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
      expectChunksWrittenWhole(10);
      expect(waits,
          contains('cabo desconectado: aguardando a ligação com a placa'));

      final lines = log();
      final lost = lines.indexOf('Ligação perdida no bloco 3');
      final back = lines.indexOf('Ligação de volta');
      final wants = lines.indexOf('BEGIN aceito: a placa quer o bloco 4');
      expect(lost, greaterThan(0));
      expect(back, greaterThan(lost));
      expect(wants, greaterThan(back));
      // The port opened at 115200 with the board still at 921600: found
      // there, no second OTA_BAUD needed to go up.
      expect(lines,
          contains('Velocidade: tentando 921600 bps, onde a placa estava'));
      expect(board.baudCommands, 2); // up once, down once
      expect(board.boardBaud, 115200);
      expect(end.baud, 115200);
    });

    test('the board lost power while the cable was out: from the start',
        () async {
      await boot();
      final image = await load(size: 4096 * 8);
      var pulled = false;
      board.onChunkWritten = (seq) {
        if (seq != 4 || pulled) return;
        pulled = true;
        board.unplug();
        board.powerCycle();
        Timer(const Duration(milliseconds: 100), board.plug);
      };

      final end = await run();

      expect(end.phase, OtaPushPhase.stored);
      expect(board.images[0x02], image);
      expect(end.resumes, 1);
      expect(board.chunksSeen, [0, 1, 2, 3, 4, 0, 1, 2, 3, 4, 5, 6, 7]);
      expect(log(), contains('BEGIN aceito: a placa quer o bloco 0'));
      expect(board.baudCommands, 3); // up, up again after the restart, down
    });

    test('the cable never comes back: gives up', () async {
      await boot();
      await load(size: 4096 * 10);
      board.onChunkWritten = (seq) {
        if (seq == 2) board.unplug();
      };

      final end = await run();

      expect(end.phase, OtaPushPhase.failed);
      expect(end.reason, SafrOtaReason.timedOut);
      expect(end.message, contains('interrompida por mais de'));
      expect(board.images, isEmpty);
      expect(step(OtaStepId.send), OtaStepStatus.failed);
      expect(log(), contains('Ligação perdida no bloco 2'));
      expect(log(), isNot(contains('Ligação de volta')));
    });
  });

  group('a board that says no', () {
    test('BEGIN refused: nothing is sent, the reason is shown', () async {
      await boot();
      await load();
      board.refuseBegin = SafrOtaReason.notNewer;

      final end = await run();

      expect(end.phase, OtaPushPhase.failed);
      expect(end.reason, SafrOtaReason.notNewer);
      expect(
          end.message, 'A versão do arquivo não é mais nova que a instalada.');
      expect(board.chunksSeen, isEmpty);
      expect(board.count(SafrMsgType.otaPushChunk), 0);
      expect(board.count(SafrMsgType.otaPushEnd), 0);
      expect(step(OtaStepId.linkSpeed), OtaStepStatus.done);
      expect(step(OtaStepId.begin), OtaStepStatus.failed);
      expect(end.step(OtaStepId.begin)!.note, end.message);
      expect(step(OtaStepId.send), OtaStepStatus.waiting);
      expect(
          log(),
          contains('BEGIN recusado: motivo 1: a versão do arquivo não é '
              'mais nova que a instalada'));
      // After a failure too: back with OTA_BAUD.
      expect(board.baudCommands, 2);
      expect(board.boardBaud, 115200);
      expect(board.tabletBaud, 115200);
    });

    test('every refusal of BEGIN has its words', () async {
      await boot();
      await load();
      for (final reason in [
        SafrOtaReason.busyAlarm,
        SafrOtaReason.noSpace,
        SafrOtaReason.badArgs,
        SafrOtaReason.busy,
        SafrOtaReason.badVersion,
        SafrOtaReason.forceRefused,
      ]) {
        board.refuseBegin = reason;
        final end = await run();
        expect(end.phase, OtaPushPhase.failed, reason: reason.name);
        expect(end.reason, reason);
        expect(end.message, reason.label);
      }
    });

    test('the image fails the verification', () async {
      await boot();
      await load();
      board.verdict = SafrOtaReason.sigFail;

      final end = await run();

      expect(end.phase, OtaPushPhase.failed);
      expect(end.reason, SafrOtaReason.sigFail);
      expect(end.message, 'O arquivo não tem a assinatura da SempreIoT.');
      expect(end.chunksDone, 7);
      expect(step(OtaStepId.send), OtaStepStatus.done);
      expect(step(OtaStepId.verify), OtaStepStatus.failed);
      expect(end.storedOnBoard, isEmpty);
      expect(
          log(),
          contains('Placa → OTA_PUSH_RESULT: falhou, motivo 4: o arquivo '
              'não tem a assinatura da SempreIoT, versão 0.2.0'));
      expect(board.boardBaud, 115200);
    });

    test('FORCE goes in the FLAGS of BEGIN', () async {
      await boot();
      await load();
      await run(force: true);
      final begin = board.heard
          .firstWhere((f) => f.msgType == SafrMsgType.otaPushBegin)
          .payload as SafrOtaPushBeginPayload;
      expect(begin.force, isTrue);
      expect(log(), contains(contains('(instalação forçada)')));
    });
  });

  group('the line speed', () {
    test('a board that never answers OTA_BAUD: the push goes at 115200',
        () async {
      await boot();
      final image = await load();
      board.ignoreBaud = true;

      final end = await run();

      expect(end.phase, OtaPushPhase.stored);
      expect(board.images[0x02], image);
      expect(board.boardBaud, 115200);
      expect(board.tabletBaud, 115200);
      expect(end.step(OtaStepId.linkSpeed)!.note,
          '115200 bps (a placa não confirmou 921600)');
      expect(
          log(),
          contains('Velocidade: a placa não confirmou; o envio segue a '
              '115200 bps'));
      expect(log(), contains(startsWith('BEGIN enviado a 115200 bps')));
    });

    test('a board that knows nothing of the push: fails, says so', () async {
      await boot();
      await load();
      board.ignoreBaud = true;
      board.ignorePush = true;

      final end = await run();

      expect(end.phase, OtaPushPhase.failed);
      expect(end.reason, SafrOtaReason.timedOut);
      expect(end.message, contains('não respondeu ao pedido de atualização'));
      expect(step(OtaStepId.begin), OtaStepStatus.failed);
      expect(log(), contains('BEGIN sem resposta'));
    });

    test('pushBaud 115200: OTA_BAUD is never sent', () async {
      await boot(
        t: const OtaPushTimings(
          pushBaud: 115200,
          beginAckTimeout: Duration(milliseconds: 100),
          resultGrace: Duration(milliseconds: 40),
          chunkAckTimeout: Duration(milliseconds: 120),
          endAckTimeout: Duration(milliseconds: 80),
          verdictTimeout: Duration(milliseconds: 600),
        ),
      );
      await load();
      final end = await run();
      expect(end.phase, OtaPushPhase.stored);
      expect(board.baudCommands, 0);
    });
  });

  group('cancel', () {
    test('stops sending; the board is asked back to the default speed',
        () async {
      await boot();
      await load(size: 4096 * 30);
      board.onChunkWritten = (seq) {
        if (seq == 5) push().cancel();
      };

      final end = await run();

      expect(end.phase, OtaPushPhase.failed);
      expect(end.reason, SafrOtaReason.aborted);
      expect(end.message, 'A atualização foi cancelada pelo operador.');
      expect(board.chunksSeen.length, lessThan(9));
      expect(board.count(SafrMsgType.otaPushEnd), 0);
      expect(board.images, isEmpty);
      expect(board.boardBaud, 115200);
      expect(board.tabletBaud, 115200);
      expect(log(), contains('Cancelamento pedido pelo operador'));

      // And the same file can be sent again: the board resumes it.
      board.onChunkWritten = null;
      final again = await run();
      expect(again.phase, OtaPushPhase.stored);
      expect(again.resumes, 1);
    });
  });

  group('a board image', () {
    Future<void> boardRow({int latched = 0}) =>
        db.into(db.meshDevices).insertOnConflictUpdate(MeshDevicesCompanion(
              mac: const Value(FakeBoard.unitMac),
              firstSeenAt: Value(DateTime.now().toUtc()),
              lastSeenAt: Value(DateTime.now().toUtc()),
              alarmLatched: Value(latched),
            ));

    test('is confirmed when the board says it passed its self-test', () async {
      await boot();
      final image = await load(project: 'sempreiot-board');
      final waits = <String>[];
      final sub = container.listen(otaPushProvider, (_, s) {
        final w = s.waitingFor;
        if (w != null && (waits.isEmpty || waits.last != w)) waits.add(w);
      });

      final end = await run();
      sub.close();

      expect(end.phase, OtaPushPhase.confirmed);
      expect(end.message, 'A placa reiniciou e está com a versão 0.2.0.');
      expect(end.boardVersion, '0.2.0');
      // What it ran when the push began, for "0.1.0 → 0.2.0".
      expect(end.boardVersionBefore, '0.1.0');
      expect(end.boardRestarted, isTrue);
      expect(board.images[0x01], image);
      expect(board.runningVersion, '0.2.0');

      // The board restarts: no OTA_BAUD back, the port goes to 115200 alone.
      expect(board.baudCommands, 1);
      expect(board.tabletBaud, 115200);
      expect(end.baud, 115200);

      expect(end.steps.map((s) => s.id), OtaStepId.values);
      for (final s in end.steps) {
        expect(s.status, OtaStepStatus.done, reason: s.id.name);
      }
      expect(waits.take(3), [
        'placa verificando a imagem',
        'aguardando a placa reiniciar',
        'placa respondeu, aguardando confirmação',
      ]);
      expect(end.waitingFor, isNull);
      expect(end.storedOnBoard, isEmpty);

      final lines = log();
      expect(lines, contains('A placa respondeu depois de reiniciar'));
      expect(lines, contains('Placa → NAME_ANNOUNCE: versão 0.2.0'));
      expect(
          lines
              .where((l) => l == 'Placa → OTA_PUSH_RESULT: ok, versão 0.2.0')
              .length,
          2); // verified, then running and confirmed
      expect(lines, contains('Velocidade: de volta a 115200 bps'));

      // The board's row says what it runs.
      final row = pickBoardDevice(await db.select(db.meshDevices).get());
      expect(row!.mac, FakeBoard.mac);
      expect(row.fwVersion, '0.2.0');
    });

    test('is not started while an alarm is latched', () async {
      await boot();
      await load(project: 'sempreiot-board');
      await boardRow(latched: 1);

      final blocker = await push().start();

      expect(blocker,
          'Há alarme ativo. Rearme a central antes de atualizar a placa.');
      expect(state().phase, OtaPushPhase.idle);
      expect(state().running, isFalse);
      expect(board.count(SafrMsgType.otaPushBegin), 0);
      expect(board.baudCommands, 0);
      expect(log().last, startsWith('Não iniciado: Há alarme ativo'));

      // A node image only goes to the board's store: allowed.
      await load();
      expect(await push().startBlocker(), isNull);
    });

    test('an alarm during the push stops it before END', () async {
      await boot();
      await load(project: 'sempreiot-board', size: 4096 * 12);
      board.onChunkWritten = (seq) {
        if (seq == 3) boardRow(latched: 1);
      };

      final end = await run();

      expect(end.phase, OtaPushPhase.failed);
      expect(end.reason, SafrOtaReason.busyAlarm);
      expect(board.count(SafrMsgType.otaPushEnd), 0);
      expect(board.images, isEmpty);
      expect(board.runningVersion, '0.1.0');
    });

    test('that fails its self-test: the board went back, and it shows',
        () async {
      await boot();
      await load(project: 'sempreiot-board');
      board.failSelfTest = true;

      final end = await run();

      expect(end.phase, OtaPushPhase.rolledBack);
      expect(end.reason, SafrOtaReason.selftestFail);
      expect(end.boardVersion, '0.1.0');
      expect(end.boardVersionBefore, '0.1.0');
      expect(end.boardRestarted, isTrue);
      expect(
          end.message,
          'A placa testou a versão 0.2.0, não passou no autoteste e voltou '
          'para a versão anterior. Ela continua com a versão 0.1.0.');
      expect(board.runningVersion, '0.1.0');
      expect(step(OtaStepId.boardRestart), OtaStepStatus.done);
      expect(step(OtaStepId.confirm), OtaStepStatus.failed);
      expect(end.step(OtaStepId.confirm)!.note, end.message);

      final lines = log();
      // The new image said what it was before it failed: not a confirmation.
      expect(lines, contains('Placa → NAME_ANNOUNCE: versão 0.2.0'));
      expect(lines, contains('Placa → NAME_ANNOUNCE: versão 0.1.0'));
      expect(
          lines,
          contains(startsWith(
              'Placa → OTA_PUSH_RESULT: falhou, motivo 9: o novo firmware '
              'falhou no autoteste')));
      expect(
          lines, contains(startsWith('Resultado: voltou à versão anterior')));
      final row = pickBoardDevice(await db.select(db.meshDevices).get());
      expect(row!.fwVersion, '0.1.0');
    });

    test('whose confirmation is lost: confirmed by what it keeps announcing',
        () async {
      await boot();
      await load(project: 'sempreiot-board');
      board.loseSelfTestResult = true;

      final end = await run();

      expect(end.phase, OtaPushPhase.confirmed);
      expect(end.boardVersion, '0.2.0');
      expect(
          log(),
          contains('A placa segue na versão 0.2.0 depois do prazo do '
              'autoteste'));
      // Only after the self-test window: never on the first announce.
      final took = end.step(OtaStepId.confirm)!.took!;
      expect(took, greaterThanOrEqualTo(timings.selfTestWindow));
    });

    test('that never comes back: fails, and says what to check', () async {
      await boot();
      await load(project: 'sempreiot-board');
      board.onRestart = board.unplug; // the cable goes out as it restarts

      final end = await run();

      expect(end.phase, OtaPushPhase.failed);
      expect(end.reason, SafrOtaReason.timedOut);
      expect(
          end.message,
          'A placa não voltou a responder depois de reiniciar. Verifique o '
          'cabo USB.');
      // It took the image and restarted: "nothing changed" cannot be said.
      expect(end.boardRestarted, isTrue);
      expect(step(OtaStepId.verify), OtaStepStatus.done);
      expect(step(OtaStepId.boardRestart), OtaStepStatus.failed);
      expect(step(OtaStepId.confirm), OtaStepStatus.waiting);
      expect(log(), isNot(contains('A placa respondeu depois de reiniciar')));
    });
  });

  group('the file', () {
    test('that is not a firmware is refused before anything is sent', () async {
      await boot();
      final before = board.writes.length;

      await push().loadFile('foto.jpg', Uint8List(5000));

      expect(state().file, isNull);
      expect(state().fileError, 'Este arquivo não é um firmware SempreIoT.');
      expect(state().step(OtaStepId.readFile)!.status, OtaStepStatus.failed);
      expect(
          log().single,
          'Arquivo recusado: foto.jpg — Este arquivo não é um firmware '
          'SempreIoT.');
      expect(await push().start(), 'Escolha o arquivo do firmware.');
      expect(board.writes.length, before);
    });

    test('of another project is refused', () async {
      await boot();
      await push().loadFile(
          'x.bin', fakeFirmware(project: 'hello_world', version: '1.0.0'));
      expect(state().fileError, 'Firmware de outro produto ("hello_world").');
    });

    test('says what it is', () async {
      await boot();
      final image = await load(project: 'sempreiot-board', version: '0.3.1');
      final f = state().file!;
      expect(f.family.wire, 0x01);
      expect(f.version, '0.3.1');
      expect(f.size, image.length);
      expect(f.sha256, crypto.sha256.convert(image).bytes);
      expect(state().isBoardImage, isTrue);
      expect(state().phase, OtaPushPhase.idle);
      expect(state().step(OtaStepId.readFile)!.status, OtaStepStatus.done);
      expect(state().steps.length, 7);
    });

    test('cannot be sent without the board on the link', () async {
      await boot();
      await load();
      board.unplug();
      await _until(
          () =>
              container.read(serialLinkProvider) != SerialLinkStatus.connected,
          what: 'the link to drop');
      expect(await push().start(),
          'A placa não está respondendo. Verifique o cabo USB.');
      expect(state().running, isFalse);
    });
  });
}

Future<void> _until(
  bool Function() test, {
  required String what,
  Duration within = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(within);
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
