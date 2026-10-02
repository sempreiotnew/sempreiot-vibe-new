import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/central_installation_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_controller.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_events_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_report.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_state.dart';
import 'package:sempreiot_central_app/features/central/application/safr_ingest_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/application/serial_link_provider.dart';
import 'package:sempreiot_central_app/features/central/application/serial_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_identity.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

import 'fake_board.dart';
import 'fake_rollout.dart';

/// The rollout controller against a board that plays a rollout byte for
/// byte on the serial port (fake_board.dart + fake_rollout.dart): the real
/// encoder, the real ACK tracking, the real ingest pipeline and reframer in
/// between. Protocol §13.4, §13.6.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final identity = SafrIdentity(
    systemId: 0x4A17,
    key: Uint8List.fromList([for (var i = 0; i < 16; i++) 0x30 + i]),
  );

  // The board's numbers, a hundred times shorter.
  const timings = OtaRolloutTimings(
    answerTimeout: Duration(milliseconds: 150),
    controlAckTimeout: Duration(milliseconds: 100),
    controlAttempts: 2,
    pageAfterControl: Duration(milliseconds: 150),
    pageSetTimeout: Duration(milliseconds: 80),
    rollingSilence: Duration(milliseconds: 200),
    watchdogPeriod: Duration(milliseconds: 50),
  );

  const node = SafrProductFamily.node;
  const root = '5A:46:52:00:00:01';
  const siren = '5A:46:52:00:00:02';
  const button = '5A:46:52:00:00:03';

  late AppDatabase db;
  late FakeRollout mesh;
  late FakeBoard board;
  late ProviderContainer container;

  FakeRollout threeUnits() => FakeRollout(identity: identity)
    ..stored[0x02] = '0.2.0'
    ..rootMac = root
    ..units.addAll([
      FakeUnit(root,
          name: 'Repetidor', zone: 'Térreo', product: 0x0204, layer: 1),
      FakeUnit(siren,
          name: 'Sirene hall', zone: 'Térreo', product: 0x0201, parent: root),
      FakeUnit(button,
          name: 'Botoeira', zone: 'Garagem', product: 0x0202, parent: root),
    ]);

  Future<void> open({bool rollout = true}) async {
    board = FakeBoard(identity: identity, rollout: rollout ? mesh : null);
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      serialProvider.overrideWith((ref) => board),
      safrIdentityProvider.overrideWithValue(identity),
      otaRolloutTimingsProvider.overrideWithValue(timings),
    ]);
    container.read(safrIngestProvider); // serial → ingest → downlink
    container.read(otaRolloutProvider);
    board.plug();
    await _until(
      () => container.read(serialLinkProvider) == SerialLinkStatus.connected,
      what: 'the link to come up',
    );
    // TIME_SYNC, the journal, GET_INSTALLATION, GET_DEVICE_TABLE — and then
    // GET_ROLLOUT.
    await _until(() => board.commands(SafrCommand.getRollout) > 0,
        what: 'GET_ROLLOUT after the link-up sequence');
  }

  Future<void> boot({FakeRollout? with_, bool rollout = true}) async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    mesh = with_ ?? threeUnits();
    await open(rollout: rollout);
    if (rollout) {
      await _until(() => state0(container).boardAnswered == true,
          what: 'the board to answer GET_ROLLOUT');
      mesh.announceUnits();
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  tearDown(() async {
    mesh.close();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    container.dispose();
    await db.close();
  });

  OtaRolloutController ro() => container.read(otaRolloutProvider.notifier);
  OtaRolloutState state() => container.read(otaRolloutProvider);
  OtaFamilyRollout? fam() => state().families[node];
  List<String> log() => [for (final l in state().log) l.text];
  OtaRolloutUnit row(String mac) => fam()!.unit(mac)!;

  Future<void> ended() => _until(() => fam()?.ended == true,
      what: 'the rollout to end', within: const Duration(seconds: 10));

  group('what the board holds', () {
    test('a staged image is learned from the board when the link comes up',
        () async {
      await boot();

      expect(state().boardAnswered, isTrue);
      expect(fam()!.state, SafrOtaRolloutState.staged);
      expect(fam()!.target, '0.2.0');
      expect(fam()!.total, 0);
      expect(fam()!.units, isEmpty);
      expect(fam()!.holdsImage, isTrue);
      // What the board says wins over what the session remembers.
      expect(otaHeldOnBoard(state(), const {node: '0.1.9'}), {node: '0.2.0'});
      expect(
          log(),
          contains('Na placa: firmware de rede elétrica 0.2.0 (nada enviado '
              'aos dispositivos)'));

      // Asked once, after GET_DEVICE_TABLE.
      final cmds = [
        for (final f in board.heard)
          if (f.payload is SafrCommandPayload)
            (f.payload as SafrCommandPayload).cmdRaw
      ];
      expect(cmds.where((c) => c == SafrCommand.getRollout.wire).length, 1);
      expect(
        cmds.indexOf(SafrCommand.getRollout.wire),
        greaterThan(cmds.indexOf(SafrCommand.getDeviceTable.wire)),
      );
      final get = board.heard.firstWhere((f) =>
          f.payload is SafrCommandPayload &&
          (f.payload as SafrCommandPayload).cmdRaw ==
              SafrCommand.getRollout.wire);
      expect((get.payload as SafrCommandPayload).args, [0]);
      expect(get.ackRequired, isFalse);
    });

    test('both families, each with its own header', () async {
      await boot(with_: threeUnits()..stored[0x03] = '0.3.1');
      await _until(() => state().families.length == 2, what: 'two headers');
      expect(state().families[SafrProductFamily.leaf]!.target, '0.3.1');
      expect(state().families[SafrProductFamily.leaf]!.state,
          SafrOtaRolloutState.staged);
      expect(otaHeldOnBoard(state(), const {}), {
        node: '0.2.0',
        SafrProductFamily.leaf: '0.3.1',
      });
    });

    test('nothing stored: the board says so, and that is an answer', () async {
      await boot(with_: threeUnits()..stored.clear());
      expect(state().boardAnswered, isTrue);
      expect(state().families, isEmpty);
      // The session's memory is not shown against the board's word.
      expect(otaHeldOnBoard(state(), const {node: '0.2.0'}), isEmpty);
      expect(await ro().startBlocker(node),
          'A placa não tem imagem guardada para este tipo de dispositivo.');
    });

    test('the screen opens: asked again', () async {
      await boot();
      final before = mesh.gets;
      await ro().refresh();
      await _until(() => mesh.gets == before + 1, what: 'GET_ROLLOUT');
      await _until(() => !state().asking, what: 'the answer');
      expect(fam()!.state, SafrOtaRolloutState.staged);
    });

    test('a board that answers nothing: this session\'s memory is what is left',
        () async {
      await boot(rollout: false);
      await _until(() => state().boardAnswered == false,
          what: 'the wait for an answer to end');
      expect(state().families, isEmpty);
      expect(state().asking, isFalse);
      expect(otaHeldOnBoard(state(), const {node: '0.2.0'}), {node: '0.2.0'});
      expect(log().single, contains('não respondeu'));

      // It is asked to start all the same; it never answers that either.
      final refused = await ro().start(node, const SafrOtaFilter.all());
      expect(refused, contains('A placa não respondeu ao pedido'));
      expect(board.commands(SafrCommand.otaControl), 2,
          reason: 'sent, and once more');
      expect(state().command, isNull);
      expect(state().families, isEmpty);
    });
  });

  group('a rollout', () {
    test('three units, one at a time, the root last', () async {
      await boot();

      expect(
        await ro().start(node, const SafrOtaFilter.all(), expected: 3),
        isNull,
      );
      await ended();
      await ro().settled;

      // What the tablet asked.
      final c = mesh.controls.single;
      expect(c.action, SafrOtaAction.start);
      expect(c.family, 0x02);
      expect(c.filter, const SafrOtaFilter.all());
      final frame = board.heard.lastWhere((f) =>
          f.payload is SafrCommandPayload &&
          (f.payload as SafrCommandPayload).cmdRaw ==
              SafrCommand.otaControl.wire);
      expect(frame.ackRequired, isTrue);
      expect((frame.payload as SafrCommandPayload).args, [1, 2, 0]);

      // The order the board went in.
      expect(mesh.offered, [siren, button, root]);

      final f = fam()!;
      expect(f.state, SafrOtaRolloutState.done);
      expect(f.target, '0.2.0');
      expect(f.total, 3);
      expect(f.doneCount, 3);
      expect(f.failedCount, 0);
      expect(f.units.map((u) => u.mac), [root, siren, button]);
      for (final u in f.units) {
        expect(u.state, SafrOtaUnitState.done);
        expect(u.version, '0.2.0');
        expect(u.versionBefore, '0.1.0');
        expect(u.attempts, 0);
        expect(u.reason, SafrOtaReason.none);
        expect(u.activeSince, isNull);
        expect(u.live, isFalse, reason: 'the board had the last word');
      }
      expect(f.filter, const SafrOtaFilter.all());
      expect(f.startedAt, isNotNull);
      expect(f.startedAtExact, isTrue);
      expect(f.endedAt, isNotNull);
      expect(state().running, isNull);
      expect(otaHeldOnBoard(state(), const {}), {node: '0.2.0'});

      // Every OTA_RESULT was acknowledged by the tablet, to the unit.
      for (final mac in [root, siren, button]) {
        expect(
          board.heard
              .where((x) => x.msgType == SafrMsgType.ack && x.dstMac == mac),
          isNotEmpty,
          reason: 'ACK of the OTA_RESULT of $mac',
        );
      }

      // The units' new version is in the registry (their NAME_ANNOUNCE).
      final rows = await db.select(db.meshDevices).get();
      for (final mac in [root, siren, button]) {
        expect(rows.firstWhere((r) => r.mac == mac).fwVersion, '0.2.0');
      }

      // The log.
      final lines = log();
      expect(
          lines,
          contains('Pedido à placa: enviar firmware de rede elétrica 0.2.0 '
              'aos dispositivos — filtro: todos os dispositivos; 3 '
              'dispositivos pelo registro do tablet'));
      expect(lines, contains('Iniciar: a placa aceitou'));
      expect(
          lines,
          contains('Placa: atualização iniciada — firmware de rede elétrica '
              '0.2.0, 3 dispositivos, um de cada vez'));
      expect(lines, contains('Sirene hall [$siren] → estado: baixando 50 %'));
      expect(lines, contains('Sirene hall [$siren] → estado: reiniciando'));
      expect(lines, contains('Sirene hall [$siren] → estado: autoteste'));
      expect(
          lines,
          contains('Sirene hall [$siren] → resultado: atualizado, agora na '
              'versão 0.2.0'));
      expect(
          lines.where((l) => l.contains('→ resultado: atualizado')).length, 3);
      expect(lines.last,
          startsWith('Atualização concluída: 3 atualizados, de 3, em '));
      // The root's turn comes after the two others are settled.
      final rootOffered = lines.indexWhere(
          (l) => l.startsWith('Repetidor [$root]') && l.contains('oferta'));
      final buttonDone = lines.indexWhere(
          (l) => l.startsWith('Botoeira [$button] → resultado: atualizado'));
      expect(rootOffered, greaterThan(buttonDone));
    });

    test('while a unit is being updated it is in the active set', () async {
      await boot();
      expect(await ro().start(node, const SafrOtaFilter.unit(siren)), isNull);
      await _until(() => fam()?.unit(siren)?.state.active == true,
          what: 'the siren to be offered the image');

      final since = state().activeSince(siren);
      expect(since, isNotNull);
      expect(OtaUpdatingUnits.of(state()).since(siren), since);
      expect(
        OtaUpdatingUnits.of(state())
            .updatingAt(siren, DateTime.now(), otaUpdatingGrace),
        isTrue,
      );
      expect(
        OtaUpdatingUnits.of(state()).updatingAt(
            siren, since!.add(const Duration(seconds: 300)), otaUpdatingGrace),
        isFalse,
        reason: 'after 300 s the normal rule applies again',
      );
      expect(state().activeSince(button), isNull);
      expect(fam()!.total, 1, reason: 'the filter: one unit');
      expect(mesh.controls.single.filter, const SafrOtaFilter.unit(siren));

      await ended();
      await ro().settled;
      // Moving through the states did not restart the clock; the end
      // stopped it.
      expect(state().activeSince(siren), isNull);
      expect(OtaUpdatingUnits.of(state()).isEmpty, isTrue);
      expect(fam()!.state, SafrOtaRolloutState.done);
    });

    test(
        'what reaches the LED mirror: the unit\'s frames up, and the '
        'tablet\'s ACK of its OTA_RESULT down', () async {
      await boot();
      final ticks = <SafrTrafficTick>[];
      final sub = container.read(safrTrafficProvider).stream.listen(ticks.add);
      addTearDown(sub.cancel);

      expect(await ro().start(node, const SafrOtaFilter.unit(siren)), isNull);
      await ended();
      await ro().settled;
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final up = [
        for (final t in ticks)
          if (t.mac == siren && t.direction == SafrTrafficDirection.uplink)
            t.msgType
      ];
      // Its ACK of the board's offer, its statuses, its announce after the
      // restart, its result.
      expect(up.first, SafrMsgType.ack);
      expect(up.where((t) => t == SafrMsgType.otaStatus).length, 6,
          reason: 'downloading 0, 50, 100, verifying, rebooting, self-test');
      expect(up.where((t) => t == SafrMsgType.otaResult).length, 1);
      expect(up, contains(SafrMsgType.nameAnnounce));

      // One ACK goes down to it: for its OTA_RESULT, and for nothing else
      // (an OTA_STATUS is never acknowledged).
      final down = [
        for (final t in ticks)
          if (t.mac == siren && t.direction == SafrTrafficDirection.downlink) t
      ];
      expect(down, hasLength(1));
      expect(down.single.ack, isTrue);
      expect(down.single.msgType, SafrMsgType.ack);
      // The board's pages are the board's own frames.
      expect(
        ticks.where((t) =>
            t.mac == FakeBoard.mac && t.msgType == SafrMsgType.otaRollout),
        isNotEmpty,
      );
      // The unit's ACK of the board's OFFER confirmed nothing of the
      // tablet's: what the tablet asked was answered by the board alone.
      expect(log().where((l) => l.contains('a placa aceitou')).length, 1);
    });

    test('only the sirens', () async {
      await boot();
      expect(
        await ro().start(node, const SafrOtaFilter.product(0x0201)),
        isNull,
      );
      await ended();
      expect(mesh.controls.single.filter, const SafrOtaFilter.product(0x0201));
      expect(mesh.offered, [siren]);
      expect(fam()!.units.single.mac, siren);
      expect(mesh.unit(button).version, '0.1.0');
      expect(
          log(),
          contains(startsWith('Pedido à placa: enviar firmware de rede '
              'elétrica 0.2.0 aos dispositivos — filtro: produto Sirene '
              '(0x0201)')));
    });

    test('one zone', () async {
      await boot();
      expect(
          await ro().start(node, const SafrOtaFilter.zone('Térreo')), isNull);
      await ended();
      expect(mesh.offered, [siren, root]);
      expect(fam()!.doneCount, 2);
    });

    test('a unit that already runs it refuses NOT_NEWER and is skipped',
        () async {
      final m = threeUnits();
      m.unit(button)
        ..version = '0.2.0'
        ..plays.setAll(0, [(FakePlay.refuse, SafrOtaReason.notNewer)]);
      await boot(with_: m);

      expect(await ro().start(node, const SafrOtaFilter.all()), isNull);
      await ended();
      await ro().settled;

      final f = fam()!;
      expect(f.state, SafrOtaRolloutState.done,
          reason: 'skipped is not a failure');
      expect(f.doneCount, 2);
      expect(f.skippedCount, 1);
      expect(f.failedCount, 0);
      final b = row(button);
      expect(b.state, SafrOtaUnitState.skipped);
      expect(b.reason, SafrOtaReason.notNewer);
      expect(b.attempts, 0);
      expect(b.version, '0.2.0');
      expect(mesh.offered.where((x) => x == button).length, 1,
          reason: 'not offered again');
      expect(
          log(),
          contains('Botoeira [$button]: ignorado, motivo 1: já estava nesta '
              'versão ou em uma mais nova, versão 0.2.0'));
      expect(log().last,
          startsWith('Atualização concluída: 2 atualizados, 1 ignorado, de 3'));
    });

    test(
        'a unit that fails twice: offered once more after the others, '
        'then failed, and the rollout ends partial', () async {
      final m = threeUnits();
      m.unit(siren).plays.setAll(0, [(FakePlay.fail, SafrOtaReason.httpErr)]);
      await boot(with_: m);

      expect(await ro().start(node, const SafrOtaFilter.all()), isNull);
      await ended();
      await ro().settled;

      // Fresh units first, the one that failed once, the root last.
      expect(mesh.offered, [siren, button, siren, root]);

      final f = fam()!;
      expect(f.state, SafrOtaRolloutState.partial);
      expect(f.doneCount, 2);
      expect(f.failedCount, 1);
      final s = row(siren);
      expect(s.state, SafrOtaUnitState.failed);
      expect(s.attempts, 2);
      expect(s.reason, SafrOtaReason.httpErr);
      expect(s.version, '0.1.0', reason: 'it runs what it ran');
      expect(f.failures.single.mac, siren);
      expect(mesh.unit(siren).version, '0.1.0');

      final lines = log();
      expect(
          lines
              .where((l) => l.startsWith('Sirene hall [$siren] → resultado: '
                  'não atualizado, motivo 8: o dispositivo não conseguiu '
                  'baixar a imagem da placa; continua na versão 0.1.0'))
              .length,
          2);
      expect(
          lines,
          contains(startsWith('Atualização concluída com falhas: 2 '
              'atualizados, 1 com falha, de 3')));
      expect(
          lines.last,
          'Falhou: Sirene hall [$siren] — motivo 8: o dispositivo não '
          'conseguiu baixar a imagem da placa; continua na versão 0.1.0');
    });

    test('a new image that fails its self-test', () async {
      final m = threeUnits();
      m
          .unit(siren)
          .plays
          .setAll(0, [(FakePlay.failSelfTest, SafrOtaReason.selftestFail)]);
      await boot(with_: m);
      expect(await ro().start(node, const SafrOtaFilter.unit(siren)), isNull);
      await ended();
      await ro().settled;
      expect(fam()!.state, SafrOtaRolloutState.partial);
      expect(row(siren).state, SafrOtaUnitState.failed);
      expect(row(siren).reason, SafrOtaReason.selftestFail);
      expect(row(siren).attempts, 2);
      expect(row(siren).version, '0.1.0');
    });

    test('a unit of before the rollout: takes the offer, does nothing',
        () async {
      final m = threeUnits();
      m.unit(button).plays.setAll(0, [(FakePlay.silent, SafrOtaReason.none)]);
      await boot(with_: m);
      expect(await ro().start(node, const SafrOtaFilter.all()), isNull);
      await ended();
      await ro().settled;
      expect(fam()!.state, SafrOtaRolloutState.partial);
      expect(row(button).state, SafrOtaUnitState.failed);
      expect(row(button).reason, SafrOtaReason.timedOut);
      expect(mesh.offered.where((x) => x == button).length, 1,
          reason: 'not offered the image again in this rollout');
      expect(fam()!.doneCount, 2);
    });
  });

  group('pause, resume, abort', () {
    // Slow enough for the operator to get a word in.
    FakeRollout slow() => FakeRollout(
          identity: identity,
          step: const Duration(milliseconds: 25),
          restartTime: const Duration(milliseconds: 40),
        )
          ..stored[0x02] = '0.2.0'
          ..rootMac = root
          ..units.addAll(threeUnits().units);

    test('an alarm pauses it; resume waits for the alarm to be cleared',
        () async {
      await boot(with_: slow());
      expect(await ro().start(node, const SafrOtaFilter.all()), isNull);
      await _until(() => fam()?.unit(siren)?.state.active == true,
          what: 'the first unit to be busy');

      mesh.alarm(button);
      await _until(() => fam()?.state == SafrOtaRolloutState.paused,
          what: 'the board to pause');
      await ro().settled;
      // The unit that was downloading finishes; nobody else starts.
      await _until(() => row(siren).state == SafrOtaUnitState.done,
          what: 'the unit that was busy to finish');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await _until(() => fam()!.pauseCause == OtaPauseCause.alarm,
          what: 'the pause to be known as the alarm\'s',
          within: const Duration(seconds: 4));
      expect(fam()!.state, SafrOtaRolloutState.paused);
      expect(mesh.offered, [siren]);
      expect(row(button).state, SafrOtaUnitState.waiting);
      expect(row(root).state, SafrOtaUnitState.waiting);
      expect(state().running, isNotNull);

      // Not while the alarm is latched — nothing is even sent.
      final sent = board.commands(SafrCommand.otaControl);
      expect(await ro().resume(node),
          'Há alarme ativo. Rearme a central antes de retomar a atualização.');
      expect(await ro().startBlocker(node), isNotNull);
      expect(board.commands(SafrCommand.otaControl), sent);

      // The operator resets the alarm; the board still remembers it.
      await db.clearAlarmLatch();
      expect(
          await ro().resume(node), contains('alarme nos últimos 10 minutos'));
      expect(fam()!.state, SafrOtaRolloutState.paused);

      mesh.alarmRecent = false;
      expect(await ro().resume(node), isNull);
      await ended();
      await ro().settled;
      expect(fam()!.state, SafrOtaRolloutState.done);
      expect(fam()!.pauseCause, isNull);
      expect(mesh.offered, [siren, button, root]);

      final lines = log();
      expect(
          lines.any((l) => l.startsWith('Placa: atualização pausada')), isTrue);
      expect(
          lines.any((l) =>
              l == 'Placa: atualização pausada — há alarme na instalação' ||
              l == 'A pausa foi por alarme: há alarme ativo na instalação'),
          isTrue);
      expect(
          lines,
          contains('Retomar recusado pela placa: motivo 2: o '
              'dispositivo estava em alarme ou com falha e recusou a atualização'));
      expect(lines, contains('Placa: atualização retomada'));
    });

    test('the operator pauses and resumes', () async {
      await boot(with_: slow());
      expect(await ro().start(node, const SafrOtaFilter.all()), isNull);
      await _until(() => fam()?.unit(siren)?.state.active == true,
          what: 'the first unit to be busy');

      expect(await ro().pause(node), isNull);
      await _until(() => fam()?.state == SafrOtaRolloutState.paused,
          what: 'the board to pause');
      expect(fam()!.pauseCause, OtaPauseCause.operator);
      await _until(() => row(siren).state == SafrOtaUnitState.done,
          what: 'the unit that was busy to finish');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(mesh.offered, [siren]);
      expect(fam()!.state, SafrOtaRolloutState.paused);

      expect(await ro().resume(node), isNull);
      await ended();
      expect(fam()!.state, SafrOtaRolloutState.done);
      expect(mesh.controls.map((c) => c.action), [
        SafrOtaAction.start,
        SafrOtaAction.pause,
        SafrOtaAction.resume,
      ]);
      expect(log(), contains('Pedido à placa: pausar a atualização'));
      expect(
          log(), contains('Placa: atualização pausada — a pedido do operador'));
      expect(log(), contains('Pedido à placa: retomar a atualização'));
    });

    test('abort: the unit that is busy finishes, the ones waiting are skipped',
        () async {
      await boot(with_: slow());
      expect(await ro().start(node, const SafrOtaFilter.all()), isNull);
      await _until(() => fam()?.unit(siren)?.state.active == true,
          what: 'the first unit to be busy');

      expect(await ro().abort(node), isNull);
      await ended();
      await ro().settled;

      final f = fam()!;
      expect(f.state, SafrOtaRolloutState.partial);
      expect(row(siren).state, SafrOtaUnitState.done);
      expect(row(siren).version, '0.2.0');
      for (final mac in [button, root]) {
        expect(row(mac).state, SafrOtaUnitState.skipped);
        expect(row(mac).reason, SafrOtaReason.aborted);
        expect(mesh.unit(mac).version, '0.1.0');
      }
      expect(mesh.offered, [siren]);
      expect(log(), contains('Pedido à placa: cancelar a atualização'));
      expect(
          log(),
          contains(startsWith(
              'Atualização cancelada: 1 atualizado, 2 ignorados, de 3')));
    });

    test('pause with nothing running is refused by the board', () async {
      await boot();
      expect(await ro().pause(node), contains('não há atualização'));
      expect(log().last, startsWith('Pausar recusado pela placa: motivo 12'));
    });
  });

  group('start is refused', () {
    test('while an alarm is latched: nothing is sent', () async {
      await boot();
      mesh.alarm(siren);
      await _until(() async {
        final rows = await db.select(db.meshDevices).get();
        return rows.any((r) => r.alarmLatched == 1);
      }, what: 'the alarm to latch');

      final refused = await ro().start(node, const SafrOtaFilter.all());
      expect(refused,
          'Há alarme ativo. Rearme a central antes de atualizar os dispositivos.');
      expect(board.commands(SafrCommand.otaControl), 0);
      expect(fam()!.state, SafrOtaRolloutState.staged);
      expect(log().last, startsWith('Envio aos dispositivos não iniciado'));
    });

    test('by the board: an alarm in its last 10 minutes', () async {
      await boot();
      mesh.alarmRecent = true;
      final refused = await ro().start(node, const SafrOtaFilter.all());
      expect(refused, contains('houve alarme nos últimos 10 minutos'));
      expect(fam()!.state, SafrOtaRolloutState.staged);
    });

    test('by the board: nobody passes the filter', () async {
      await boot();
      final refused =
          await ro().start(node, const SafrOtaFilter.zone('Cobertura'));
      expect(refused, contains('nenhum dispositivo online passa pelo filtro'));
      expect(mesh.offered, isEmpty);
    });

    test('the battery units: a rollout like any other (§13.5)', () async {
      await boot(
          with_: threeUnits()
            ..stored[0x03] = '0.3.1'
            ..units.add(FakeUnit('5A:46:52:00:00:31',
                name: 'Detector sala',
                zone: 'Térreo',
                product: 0x0301,
                parent: root)));
      final refused =
          await ro().start(SafrProductFamily.leaf, const SafrOtaFilter.all());
      expect(refused, isNull);
      expect(board.commands(SafrCommand.otaControl), 1);
    });

    test('while another one runs', () async {
      await boot();
      expect(await ro().start(node, const SafrOtaFilter.all()), isNull);
      await _until(() => fam()?.running == true, what: 'it to roll');
      expect(await ro().start(node, const SafrOtaFilter.all()),
          'Já há uma atualização em andamento.');
      await ended();
    });

    test('with the cable out', () async {
      await boot();
      board.unplug();
      await _until(
          () =>
              container.read(serialLinkProvider) != SerialLinkStatus.connected,
          what: 'the link to go down');
      expect(await ro().start(node, const SafrOtaFilter.all()),
          'A placa não está respondendo. Verifique o cabo USB.');
    });
  });

  group('the app restarts in the middle of it', () {
    test('a fresh controller learns everything from the board', () async {
      final m = FakeRollout(
        identity: identity,
        step: const Duration(milliseconds: 25),
        restartTime: const Duration(milliseconds: 40),
      )
        ..stored[0x02] = '0.2.0'
        ..rootMac = root
        ..units.addAll(threeUnits().units);
      await boot(with_: m);
      expect(await ro().start(node, const SafrOtaFilter.all()), isNull);
      await _until(() => fam()?.unit(siren)?.state == SafrOtaUnitState.done,
          what: 'the first unit to be updated');

      // The app goes away; the board and the mesh go on.
      container.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // Nothing is remembered: what it shows next it learned again.
      await open();
      await _until(() => fam()?.units.length == 3,
          what: 'the table of the board');
      await ro().settled;

      final f = fam()!;
      expect(f.state.running || f.state.ended, isTrue);
      expect(f.target, '0.2.0');
      expect(f.total, 3);
      expect(row(siren).state, SafrOtaUnitState.done);
      expect(row(siren).version, '0.2.0');
      expect(f.filter, isNull, reason: 'not started in this session');
      expect(f.startedAtExact, isFalse);
      expect(
          log().any((l) => l.startsWith('Placa: atualização em andamento — '
              'firmware de rede elétrica 0.2.0, 3 dispositivos')),
          isTrue);

      await ended();
      await ro().settled;
      expect(fam()!.state, SafrOtaRolloutState.done);
      expect(fam()!.doneCount, 3);
      expect(fam()!.endedAt, isNotNull, reason: 'this session saw it end');
      expect(mesh.offered, [siren, button, root]);
    });

    test('a rollout that was over before the app looked', () async {
      final m = threeUnits();
      await boot(with_: m);
      expect(await ro().start(node, const SafrOtaFilter.all()), isNull);
      await ended();
      container.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      await open();
      await _until(() => fam()?.units.length == 3, what: 'the table');
      await ro().settled;
      expect(fam()!.state, SafrOtaRolloutState.done);
      expect(fam()!.endedAt, isNull,
          reason: 'it ended before: no news for the maps');
      expect(otaRolloutOnTheMap(state(), null), isNull);
      expect(otaHeldOnBoard(state(), const {}), {node: '0.2.0'});
    });

    test('the board restarts: paused until the tablet says resume', () async {
      final m = FakeRollout(
        identity: identity,
        step: const Duration(milliseconds: 25),
      )
        ..stored[0x02] = '0.2.0'
        ..rootMac = root
        ..units.addAll(threeUnits().units);
      await boot(with_: m);
      expect(await ro().start(node, const SafrOtaFilter.all()), isNull);
      await _until(() => fam()?.unit(siren)?.state.active == true,
          what: 'the first unit to be busy');

      mesh.boardRestarted();
      await _until(() => fam()?.state == SafrOtaRolloutState.paused,
          what: 'the paused table');
      await ro().settled;
      expect(fam()!.pauseCause, OtaPauseCause.unknown);
      expect(row(siren).state, SafrOtaUnitState.waiting);
      expect(state().activeSince(siren), isNull);

      expect(await ro().resume(node), isNull);
      await ended();
      expect(fam()!.state, SafrOtaRolloutState.done);
    });
  });

  group('pages', () {
    FakeRollout five({int perPage = 2}) => FakeRollout(identity: identity)
      ..entriesPerPage = perPage
      ..stored[0x02] = '0.2.0'
      ..rootMac = root
      ..units.addAll([
        ...threeUnits().units,
        FakeUnit('5A:46:52:00:00:04', name: 'Módulo', product: 0x0203),
        FakeUnit('5A:46:52:00:00:05', name: 'Sirene 2', product: 0x0201),
      ]);

    test('a table in three pages is whole before it replaces the rows',
        () async {
      await boot(with_: five());
      final sizes = <int>{};
      container.listen<OtaRolloutState>(otaRolloutProvider, (_, s) {
        final f = s.families[node];
        if (f != null && f.state != SafrOtaRolloutState.staged) {
          sizes.add(f.units.length);
        }
      });

      expect(await ro().start(node, const SafrOtaFilter.all()), isNull);
      await ended();
      await ro().settled;

      expect(sizes, {5}, reason: 'never a table of 2 or of 4 rows');
      expect(fam()!.units, hasLength(5));
      expect(fam()!.total, 5);
      expect(fam()!.doneCount, 5);
      expect(mesh.offered.last, root);
    });

    test('a page is lost: the rows stay, the header counts, the tablet asks',
        () async {
      await boot(with_: five());
      expect(await ro().start(node, const SafrOtaFilter.all()), isNull);
      await _until(() => fam()?.units.length == 5, what: 'the first table');

      final gets = mesh.gets;
      mesh.losePage[2] = 1;
      await _until(() => mesh.gets > gets,
          what: 'GET_ROLLOUT after a set that stopped');
      expect(fam()!.units, hasLength(5), reason: 'the rows there were');
      expect(
          log().any((l) => l.startsWith('Tabela da placa incompleta')), isTrue);
      await ended();
      expect(fam()!.doneCount, 5);
    });

    test('the board goes silent while it rolls: the tablet asks', () async {
      final m = FakeRollout(
        identity: identity,
        step: const Duration(milliseconds: 40),
      )
        ..stored[0x02] = '0.2.0'
        ..units.addAll(threeUnits().units);
      await boot(with_: m);
      expect(await ro().start(node, const SafrOtaFilter.all()), isNull);
      await _until(() => fam()?.running == true, what: 'it to roll');

      final gets = mesh.gets;
      mesh.mute = true;
      await _until(() => mesh.gets > gets,
          what: 'GET_ROLLOUT after the silence',
          within: const Duration(seconds: 3));
      expect(
          log().any((l) => l.startsWith('Sem notícias da placa há')), isTrue);
      mesh.mute = false;
      await ended();
      expect(fam()!.state, SafrOtaRolloutState.done);
    });
  });

  group('what the units say, between two pages of the board', () {
    const mac = siren;
    OtaRolloutBus bus() => container.read(otaRolloutBusProvider);

    SafrOtaRolloutPayload page(
      SafrOtaUnitState s, {
      int percent = 0,
      int attempts = 0,
      int reason = 0,
      int? ageS = 0,
      String version = '0.1.0',
      SafrOtaRolloutState state = SafrOtaRolloutState.rolling,
    }) =>
        SafrOtaRolloutPayload(
          page: 1,
          pageCount: 1,
          total: 1,
          state: state,
          family: 0x02,
          target: '0.2.0',
          entries: [
            SafrOtaRolloutEntry(
              mac: mac,
              productCode: 0x0201,
              state: s,
              percent: percent,
              attempts: attempts,
              reasonRaw: reason,
              ageS: ageS,
              version: version,
            ),
          ],
        );

    Future<void> say(OtaRolloutEvent e) async {
      bus().emit(e);
      await ro().settled;
    }

    Future<void> status(SafrOtaUnitState s, int percent) =>
        say(OtaUnitStatusEvent(
          mac: mac,
          status: SafrOtaStatusPayload(state: s, percent: percent),
        ));

    setUp(() async {
      await boot(with_: threeUnits()..stored.clear());
    });

    test('a status moves the row forward, the page has the last word',
        () async {
      await say(OtaRolloutPageEvent(page(SafrOtaUnitState.offered)));
      expect(row(mac).state, SafrOtaUnitState.offered);
      final since = row(mac).activeSince;
      expect(since, isNotNull);

      await status(SafrOtaUnitState.downloading, 40);
      expect(row(mac).state, SafrOtaUnitState.downloading);
      expect(row(mac).percent, 40);
      expect(row(mac).live, isTrue);
      expect(row(mac).activeSince, since, reason: 'the same offer');

      // Older news of the unit never moves it back.
      await status(SafrOtaUnitState.downloading, 20);
      expect(row(mac).percent, 40);
      await status(SafrOtaUnitState.offered, 0);
      expect(row(mac).state, SafrOtaUnitState.downloading);

      // They disagree: the board's table wins.
      await say(OtaRolloutPageEvent(
          page(SafrOtaUnitState.downloading, percent: 30, attempts: 0)));
      expect(row(mac).percent, 30);
      expect(row(mac).live, isFalse);
      expect(row(mac).activeSince, since);
    });

    test('a result settles the row until the board says otherwise', () async {
      await say(
          OtaRolloutPageEvent(page(SafrOtaUnitState.downloading, percent: 50)));
      await say(const OtaUnitResultEvent(
        mac: mac,
        result: SafrOtaResultPayload(ok: false, reasonRaw: 8, version: '0.1.0'),
      ));
      expect(row(mac).state, SafrOtaUnitState.failed);
      expect(row(mac).reason, SafrOtaReason.httpErr);
      expect(row(mac).activeSince, isNull);
      expect(state().activeSince(mac), isNull);

      // The board offers it once more: its row is the board's.
      await say(OtaRolloutPageEvent(
          page(SafrOtaUnitState.waiting, attempts: 1, reason: 8)));
      expect(row(mac).state, SafrOtaUnitState.waiting);
      expect(row(mac).attempts, 1);

      await say(
          OtaRolloutPageEvent(page(SafrOtaUnitState.offered, attempts: 1)));
      final second = row(mac).activeSince;
      expect(second, isNotNull);

      await say(const OtaUnitResultEvent(
        mac: mac,
        result: SafrOtaResultPayload(ok: true, version: '0.2.0'),
      ));
      expect(row(mac).state, SafrOtaUnitState.done);
      expect(row(mac).version, '0.2.0');
      expect(row(mac).versionBefore, '0.1.0');
      expect(row(mac).percent, 100);
    });

    test('a row the board settled is not moved by the unit', () async {
      await say(OtaRolloutPageEvent(page(SafrOtaUnitState.failed,
          attempts: 2, reason: 10, state: SafrOtaRolloutState.partial)));
      await status(SafrOtaUnitState.downloading, 80);
      expect(row(mac).state, SafrOtaUnitState.failed);
      expect(row(mac).reason, SafrOtaReason.timedOut);
    });

    test('OTA_RESULT NOT_NEWER is skipped, not failed', () async {
      await say(OtaRolloutPageEvent(page(SafrOtaUnitState.offered)));
      await say(const OtaUnitResultEvent(
        mac: mac,
        result: SafrOtaResultPayload(ok: false, reasonRaw: 1, version: '0.2.0'),
      ));
      expect(row(mac).state, SafrOtaUnitState.skipped);
    });

    test('a new offer restarts the 300 s, a new state does not', () async {
      await say(OtaRolloutPageEvent(
          page(SafrOtaUnitState.downloading, percent: 10, ageS: 0)));
      final first = row(mac).activeSince!;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await say(OtaRolloutPageEvent(
          page(SafrOtaUnitState.rebooting, percent: 100, ageS: 0)));
      expect(row(mac).activeSince, first);

      // The pages in between were missed: it failed once and is on its
      // second offer.
      await say(OtaRolloutPageEvent(
          page(SafrOtaUnitState.downloading, attempts: 1, ageS: 0)));
      expect(row(mac).activeSince!.isAfter(first), isTrue);
    });

    test('learned in the middle: since when is taken from AGE_S', () async {
      final before = DateTime.now();
      await say(OtaRolloutPageEvent(
          page(SafrOtaUnitState.rebooting, percent: 100, ageS: 120)));
      final since = row(mac).activeSince!;
      final age = before.difference(since).inSeconds;
      expect(age, inInclusiveRange(119, 121));
      expect(row(mac).updatingAt(DateTime.now()), isTrue);
      expect(
          row(mac).updatingAt(DateTime.now().add(const Duration(seconds: 181))),
          isFalse);
      // Not started here: when it began is the oldest change it tells of.
      expect(fam()!.startedAtExact, isFalse);
      expect(before.difference(fam()!.startedAt!).inSeconds,
          inInclusiveRange(119, 121));
    });

    test('a unit nobody knows of talks about an update: the board is asked',
        () async {
      final gets = mesh.gets;
      await status(SafrOtaUnitState.downloading, 10);
      await _until(() => mesh.gets > gets, what: 'GET_ROLLOUT');
      expect(state().families, isEmpty);
      expect(log().last, contains('→ estado: baixando 10 %'));
    });
  });
}

OtaRolloutState state0(ProviderContainer c) => c.read(otaRolloutProvider);

Future<void> _until(
  FutureOr<bool> Function() test, {
  required String what,
  Duration within = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(within);
  while (!await test()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
