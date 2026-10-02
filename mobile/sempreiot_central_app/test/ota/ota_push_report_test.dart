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
  });
}
