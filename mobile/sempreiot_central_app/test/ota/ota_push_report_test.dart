import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_report.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_state.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/ota/firmware_image.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

import 'fake_firmware.dart';

/// What a push means, in words: where the firmware is going, who received
/// it, what changed. A node or leaf image is only stored on the board —
/// nothing here may read as "the devices were updated".
void main() {
  FirmwareFile file(String project, {String version = '0.1.1'}) {
    final bytes =
        fakeFirmware(project: project, version: version, size: 100 * 4096);
    return FirmwareFile(
      name: '$project.bin',
      bytes: bytes,
      header: FirmwareImageHeader.parse(bytes),
      sha256: Uint8List(32),
    );
  }

  OtaPushState state(
    OtaPushPhase phase, {
    String project = 'sempreiot-board',
    int chunksDone = 0,
    String? before = '0.1.0-dev',
    String? boardVersion,
    String? message,
    SafrOtaReason? reason,
    bool boardRestarted = false,
    String? waitingFor,
    List<OtaStep> steps = const [],
  }) {
    final f = file(project);
    return OtaPushState(
      phase: phase,
      file: f,
      chunksDone: chunksDone,
      bytesDone: f.bytesBefore(chunksDone),
      boardVersionBefore: before,
      boardVersion: boardVersion,
      message: message,
      reason: reason,
      boardRestarted: boardRestarted,
      waitingFor: waitingFor,
      steps: steps,
      startedAt: DateTime(2026, 9, 29, 14),
    );
  }

  TopologyNode unit(
    String mac, {
    int layer = 2,
    SafrNodeRole role = SafrNodeRole.node,
    int? productCode,
    String? fw,
    String? name,
  }) =>
      TopologyNode(
        mac: mac,
        role: role,
        layer: layer,
        parentMac: null,
        rssi: null,
        batteryPct: null,
        online: true,
        lastSeenAt: DateTime.now().toUtc(),
        alarmLatched: false,
        productCode: productCode,
        fwVersion: fw,
        name: name,
      );

  group('nothing to say', () {
    test('no file, or a file that was not sent', () {
      expect(otaPushReport(const OtaPushState()), isNull);
      expect(otaPushReport(state(OtaPushPhase.idle)), isNull);
      expect(otaBoardActivity(const OtaPushState()), isNull);
    });
  });

  group('while it runs', () {
    test('a board image: what is going where and how far', () {
      final r = otaPushReport(state(OtaPushPhase.sending, chunksDone: 43))!;
      expect(r.running, isTrue);
      expect(r.line, 'Atualização: placa ← firmware da placa 0.1.1');
      expect(r.lineTail, '43 %');
      expect(r.fullLine, 'Atualização: placa ← firmware da placa 0.1.1 · 43 %');
      expect(r.sent, 'Firmware da placa 0.1.1');
      expect(r.changed, startsWith('Nada ainda.'));
    });

    test('a node image: it will be stored, no device receives anything', () {
      final r = otaPushReport(state(OtaPushPhase.sending,
          project: 'sempreiot-node', chunksDone: 43))!;
      expect(
        r.fullLine,
        'Atualização: placa ← firmware de rede elétrica 0.1.1 (será '
        'guardado na placa) · 43 %',
      );
      expect(r.receiver, contains('Nenhum dispositivo recebe nada'));
      expect(r.changed, contains('nenhum dispositivo será atualizado'));
    });

    test('a leaf image', () {
      final r = otaPushReport(state(OtaPushPhase.sending,
          project: 'sempreiot-leaf', chunksDone: 10))!;
      expect(
        r.fullLine,
        'Atualização: placa ← firmware de bateria 0.1.1 (será guardado na '
        'placa) · 10 %',
      );
    });

    test('verifying, restarting, self-test', () {
      expect(otaPushReport(state(OtaPushPhase.verifying))!.fullLine,
          endsWith('· verificando'));
      expect(otaPushReport(state(OtaPushPhase.boardRestarting))!.fullLine,
          endsWith('· reiniciando'));
      final selfTest = otaPushReport(state(
        OtaPushPhase.boardRestarting,
        steps: const [
          OtaStep(OtaStepId.confirm, status: OtaStepStatus.running),
        ],
      ))!;
      expect(selfTest.fullLine, endsWith('· autoteste'));
      expect(selfTest.lineTail, 'autoteste');
      expect(selfTest.title, 'A placa está em autoteste');
      expect(selfTest.changed, startsWith('Ainda não confirmado.'));
    });
  });

  group('when it ended', () {
    test('stored: NO DEVICE WAS UPDATED', () {
      for (final project in ['sempreiot-node', 'sempreiot-leaf']) {
        final r = otaPushReport(state(OtaPushPhase.stored, project: project))!;
        expect(r.kind, OtaReportKind.stored);
        expect(r.tone, OtaReportTone.neutral, reason: 'not a success look');
        expect(r.title, 'Imagem guardada na placa');
        expect(r.receiver, startsWith('Só a placa.'));
        expect(r.changed, startsWith('Nenhum dispositivo foi atualizado.'));
        expect(r.changed, contains('ainda não está disponível'));
        expect(r.line, contains('nenhum dispositivo foi atualizado'));
        expect(r.lineTail, isNull, reason: 'it ended: one sentence');
        expect(r.versionChange, isNull);
      }
      expect(
        otaPushReport(state(OtaPushPhase.stored, project: 'sempreiot-node'))!
            .line,
        'Guardado na placa: firmware de rede elétrica 0.1.1 · nenhum '
        'dispositivo foi atualizado',
      );
    });

    test('the board was updated: old → new', () {
      final r = otaPushReport(state(OtaPushPhase.confirmed,
          boardVersion: '0.1.1', boardRestarted: true))!;
      expect(r.tone, OtaReportTone.good);
      expect(r.title, 'Placa atualizada');
      expect(r.versionChange, '0.1.0-dev → 0.1.1');
      expect(r.line, 'Placa atualizada: 0.1.0-dev → 0.1.1');
      expect(r.changed, contains('Nenhum outro dispositivo foi alterado'));
    });

    test('the board was updated and what it ran before is not known', () {
      final r = otaPushReport(state(OtaPushPhase.confirmed,
          boardVersion: '0.1.1', before: null, boardRestarted: true))!;
      expect(r.versionChange, isNull);
      expect(r.line, 'Placa atualizada: agora na versão 0.1.1');
      expect(r.changed, contains('não era conhecida'));
    });

    test('the board went back', () {
      final r = otaPushReport(state(OtaPushPhase.rolledBack,
          boardVersion: '0.1.0-dev',
          reason: SafrOtaReason.selftestFail,
          boardRestarted: true))!;
      expect(r.tone, OtaReportTone.warning);
      expect(
          r.reason, 'A placa testou a versão 0.1.1 e não passou no autoteste.');
      expect(
          r.changed,
          startsWith('Nada mudou: a placa voltou para a versão '
              '0.1.0-dev.'));
      expect(
        r.line,
        'A placa testou 0.1.1, falhou no autoteste e voltou para a versão '
        '0.1.0-dev',
      );
    });

    test('the board went back and did not say to what', () {
      final r = otaPushReport(
          state(OtaPushPhase.rolledBack, before: null, boardRestarted: true))!;
      expect(r.changed, contains('voltou para a versão que tinha antes'));
    });

    test('failed before the board took it: nothing changed', () {
      final r = otaPushReport(state(OtaPushPhase.failed,
          message: 'A placa parou de responder durante o envio.',
          reason: SafrOtaReason.timedOut))!;
      expect(r.tone, OtaReportTone.bad);
      expect(r.reason, 'A placa parou de responder durante o envio.');
      expect(r.changed,
          'Nada mudou na placa. Ela continua com a versão 0.1.0-dev.');
      expect(
        r.line,
        'Atualização não concluída: a placa parou de responder durante o '
        'envio. Nada mudou na placa.',
      );
    });

    test('refused: the board\'s reason, in plain words', () {
      final r = otaPushReport(state(OtaPushPhase.failed,
          message: SafrOtaReason.sigFail.label,
          reason: SafrOtaReason.sigFail))!;
      expect(r.reason, 'O arquivo não tem a assinatura da SempreIoT.');
      expect(r.changed, startsWith('Nada mudou na placa.'));
    });

    test('a node image that failed', () {
      final r = otaPushReport(state(OtaPushPhase.failed,
          project: 'sempreiot-node', message: SafrOtaReason.noSpace.label))!;
      expect(r.changed,
          'Nada mudou na placa e nenhum dispositivo foi atualizado.');
    });

    test('failed after the board restarted: never "nothing changed"', () {
      final r = otaPushReport(state(OtaPushPhase.failed,
          message: 'A placa não voltou a responder depois de reiniciar.',
          boardRestarted: true))!;
      expect(r.changed, startsWith('Não se sabe.'));
      expect(r.changed, isNot(contains('Nada mudou')));
      expect(r.line, isNot(contains('Nada mudou')));
    });
  });

  group('the board on the map', () {
    test('its activity, phase by phase', () {
      expect(otaBoardActivity(state(OtaPushPhase.switchingSpeed))!.label,
          'Preparando');
      final receiving =
          otaBoardActivity(state(OtaPushPhase.sending, chunksDone: 43))!;
      expect(receiving.label, 'Recebendo 43 %');
      expect(receiving.caption, 'Placa: recebendo 43 %');
      expect(receiving.percent, 43);
      expect(receiving.progress, closeTo(0.43, 1e-9));
      final verifying = otaBoardActivity(state(OtaPushPhase.verifying))!;
      expect(verifying.label, 'Verificando');
      expect(verifying.progress, isNull);
      expect(otaBoardActivity(state(OtaPushPhase.boardRestarting))!.label,
          'Reiniciando');
      expect(
        otaBoardActivity(state(OtaPushPhase.boardRestarting, steps: const [
          OtaStep(OtaStepId.confirm, status: OtaStepStatus.running),
        ]))!
            .label,
        'Autoteste',
      );
      // The cable is out: it waits where it was.
      final waiting = otaBoardActivity(state(OtaPushPhase.sending,
          chunksDone: 43, waitingFor: 'cabo desconectado'))!;
      expect(waiting.label, 'Aguardando');
      expect(waiting.percent, 43);
    });

    test('none once the push ended', () {
      for (final phase in [
        OtaPushPhase.confirmed,
        OtaPushPhase.stored,
        OtaPushPhase.rolledBack,
        OtaPushPhase.failed,
      ]) {
        expect(otaBoardActivity(state(phase)), isNull);
      }
    });

    test('two chunks of the same percent read the same: one rebuild', () {
      // 100 chunks: every chunk is a percent; a 1000-chunk file is not.
      final a = otaMapOverlay(state(OtaPushPhase.sending, chunksDone: 43));
      final b = otaMapOverlay(state(OtaPushPhase.sending, chunksDone: 43));
      expect(a.$1, b.$1);
      expect(
          otaChunksOnTheWay(state(OtaPushPhase.sending, chunksDone: 43)), 43);
      expect(otaChunksOnTheWay(state(OtaPushPhase.verifying, chunksDone: 100)),
          -1);
    });
  });

  group('packets on the map', () {
    final t0 = DateTime(2026, 9, 29, 14);

    test('about ten chunks a second become about one packet a second', () {
      final throttle = OtaPacketThrottle(
          every: 8, minGap: const Duration(milliseconds: 700));
      var packets = 0;
      // 30 s of a push at 10 chunks per second.
      for (var i = 1; i <= 300; i++) {
        final now = t0.add(Duration(milliseconds: 100 * i));
        if (throttle.take(i, now)) packets++;
      }
      expect(packets, inInclusiveRange(30, 40));
    });

    test('never two within the gap, however fast the chunks', () {
      final throttle = OtaPacketThrottle(
          every: 2, minGap: const Duration(milliseconds: 500));
      final taken = <int>[];
      for (var i = 1; i <= 100; i++) {
        final now = t0.add(Duration(milliseconds: 10 * i));
        if (throttle.take(i, now)) taken.add(10 * i);
      }
      for (var i = 1; i < taken.length; i++) {
        expect(taken[i] - taken[i - 1], greaterThanOrEqualTo(500));
      }
      expect(taken, isNotEmpty);
    });

    test('nothing sent, nothing drawn; the first chunk is drawn', () {
      final throttle = OtaPacketThrottle();
      expect(throttle.take(-1, t0), isFalse);
      expect(throttle.take(0, t0), isFalse);
      expect(throttle.take(1, t0), isTrue);
      expect(throttle.take(2, t0.add(const Duration(seconds: 5))), isFalse);
    });

    test('a push that goes on from an earlier chunk is drawn again', () {
      final throttle = OtaPacketThrottle(every: 8);
      expect(throttle.take(40, t0), isTrue);
      // The board asked for chunk 12 again.
      expect(
          throttle.take(13, t0.add(const Duration(milliseconds: 50))), isTrue);
    });
  });

  group('units', () {
    test('family: the product says it; otherwise layer and role', () {
      expect(
          unitFamily(unit('A', productCode: 0x0100)), SafrProductFamily.board);
      expect(
          unitFamily(unit('A', productCode: 0x0201)), SafrProductFamily.node);
      expect(
          unitFamily(unit('A', productCode: 0x0301)), SafrProductFamily.leaf);
      expect(unitFamily(unit('A', layer: 0, role: SafrNodeRole.root)),
          SafrProductFamily.board);
      expect(unitFamily(unit('A', layer: 1, role: SafrNodeRole.root)),
          SafrProductFamily.node);
      expect(unitFamily(unit('A', role: SafrNodeRole.leaf)),
          SafrProductFamily.leaf);
      // Listed by the board, never heard: layer 0 in the registry, not the
      // board.
      expect(unitFamily(unit('A', layer: 0, role: SafrNodeRole.node)),
          SafrProductFamily.node);
    });

    test('pending: stored for the family, another version than it runs', () {
      const stored = {SafrProductFamily.node: '0.1.1'};
      expect(
          pendingFirmwareFor(
              unit('A', productCode: 0x0201, fw: '0.1.0-dev'), stored),
          '0.1.1');
      // Never said what it runs: the image waits for it too.
      expect(pendingFirmwareFor(unit('A'), stored), '0.1.1');
      // It runs that version already.
      expect(
          pendingFirmwareFor(
              unit('A', productCode: 0x0201, fw: '0.1.1'), stored),
          isNull);
      // Another family.
      expect(
          pendingFirmwareFor(
              unit('A', productCode: 0x0301, fw: '0.1.0-dev'), stored),
          isNull);
      expect(
          pendingFirmwareFor(
              unit('A', layer: 0, role: SafrNodeRole.root, fw: '0.1.0-dev'),
              stored),
          isNull);
      expect(otaPendingText('0.1.1'), 'na placa: 0.1.1 (ainda não enviado)');
    });

    test('groups: board, mains by name, battery by name', () {
      final groups = OtaUnitGroups.of([
        unit('5A:03', role: SafrNodeRole.leaf, name: 'Sala'),
        unit('5A:02', name: 'Sirene B'),
        unit('7C:00', layer: 0, role: SafrNodeRole.root),
        unit('5A:01', name: 'acionador A'),
        unit('5A:04', role: SafrNodeRole.leaf, name: 'Cozinha'),
      ]);
      expect(groups.board!.mac, '7C:00');
      expect([for (final n in groups.mains) n.mac], ['5A:01', '5A:02']);
      expect([for (final n in groups.battery) n.mac], ['5A:04', '5A:03']);
      expect(const OtaUnitGroups().isEmpty, isTrue);
    });
  });
}
