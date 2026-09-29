import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/serial_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

/// The port as the push needs it (protocol §13.3): a frame with its raw
/// bytes in one write, one queue for everything, the speed of the open port.
class _Port extends SerialNotifier {
  _Port({
    Duration baudSilence = SerialNotifier.defaultBaudSilence,
    Duration baudSettle = const Duration(milliseconds: 30),
  }) : super.detached(baudSilence: baudSilence, baudSettle: baudSettle);

  /// What reached the port, in order: bytes, or a speed.
  final log = <Object>[];
  Duration writeTakes = Duration.zero;

  @override
  Future<bool> portWrite(Uint8List bytes) async {
    if (writeTakes > Duration.zero) await Future<void>.delayed(writeTakes);
    log.add(Uint8List.fromList(bytes));
    return true;
  }

  @override
  Future<bool> portSetBaud(int baud) async {
    log.add(baud);
    return true;
  }
}

void main() {
  final frameA = Uint8List.fromList(List.filled(40, 0xA1));
  final frameB = Uint8List.fromList(List.filled(40, 0xB2));
  final raw = Uint8List.fromList([for (var i = 0; i < 4096; i++) i & 0xFF]);

  test('a frame and its raw bytes leave in one write, back to back', () async {
    final port = _Port()..debugSetConnected(true);
    addTearDown(port.dispose);

    expect(await port.writeFrameWithData(frameA, raw), isTrue);

    expect(port.log.length, 1);
    final out = port.log.single as Uint8List;
    expect(out.length, frameA.length + raw.length);
    expect(out.sublist(0, 40), frameA);
    expect(out.sublist(40), raw);
  });

  test('nothing is written between a chunk and the end of its bytes', () async {
    final port = _Port()
      ..debugSetConnected(true)
      ..writeTakes = const Duration(milliseconds: 20);
    addTearDown(port.dispose);

    // Asked for at the same moment, by whoever: they leave whole, in the
    // order they were asked.
    final all = Future.wait([
      port.write(frameB),
      port.writeFrameWithData(frameA, raw),
      port.write(frameB),
      port.writeFrameWithData(frameA, raw),
    ]);
    expect(await all, everyElement(isTrue));

    expect(port.log.map((w) => (w as Uint8List).length),
        [40, 40 + 4096, 40, 40 + 4096]);
  });

  test(
      'a speed change waits for what was asked before it, and what is asked '
      'during it waits for it to settle', () async {
    final port = _Port(baudSettle: const Duration(milliseconds: 60))
      ..debugSetConnected(true)
      ..writeTakes = const Duration(milliseconds: 10);
    addTearDown(port.dispose);
    expect(port.baudRate, 115200);

    final first = port.write(frameA);
    final change = port.setBaudRate(921600);
    final watch = Stopwatch()..start();
    final second = port.write(frameB);

    expect(await first, isTrue);
    expect(await change, isTrue);
    expect(await second, isTrue);

    expect(port.baudRate, 921600);
    expect(port.log.length, 3);
    expect(port.log[0], frameA);
    expect(port.log[1], 921600);
    expect(port.log[2], frameB);
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(60));
  });

  test('the same speed again touches nothing', () async {
    final port = _Port()..debugSetConnected(true);
    addTearDown(port.dispose);
    expect(await port.setBaudRate(115200), isTrue);
    expect(port.log, isEmpty);
  });

  test('a port that opens again is at the default speed', () async {
    final port = _Port()..debugSetConnected(true);
    addTearDown(port.dispose);
    await port.setBaudRate(921600);
    expect(port.baudRate, 921600);

    port.debugSetConnected(false);
    expect(port.baudRate, 115200);
    expect(port.state, SerialStatus.disconnected);
    port.debugSetConnected(true);
    expect(port.baudRate, 115200);
    expect(port.state, SerialStatus.connected);
  });

  group('silence at another speed', () {
    Uint8List heartbeat(SafrEncoder enc) => enc.encode(
          msgType: SafrMsgType.heartbeat,
          payload: Uint8List(SafrTimeSyncPayload.wireLength),
        );

    test('puts the port back at the default one', () async {
      final port = _Port(
        baudSilence: const Duration(milliseconds: 200),
        baudSettle: const Duration(milliseconds: 5),
      )..debugSetConnected(true);
      addTearDown(port.dispose);

      await port.setBaudRate(921600);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(port.baudRate, 921600);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(port.baudRate, 115200);
      expect(port.log, [921600, 115200]);
    });

    test('a board that keeps talking keeps the speed', () async {
      final port = _Port(
        baudSilence: const Duration(milliseconds: 200),
        baudSettle: const Duration(milliseconds: 5),
      )..debugSetConnected(true);
      addTearDown(port.dispose);
      final enc = SafrEncoder(bootCtr: 1);
      final frames = <Uint8List>[];
      final sub = port.dataStream.listen(frames.add);
      addTearDown(sub.cancel);

      await port.setBaudRate(921600);
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        port.debugReceive(heartbeat(enc));
      }

      await Future<void>.delayed(Duration.zero); // the last one is delivered
      expect(frames.length, 8);
      expect(port.baudRate, 921600);
    });

    test('noise is not the board talking', () async {
      final port = _Port(
        baudSilence: const Duration(milliseconds: 200),
        baudSettle: const Duration(milliseconds: 5),
      )..debugSetConnected(true);
      addTearDown(port.dispose);

      await port.setBaudRate(921600);
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        port.debugReceive(Uint8List.fromList([0x00, 0xFF, 0xA5, 0x13, 0x37]));
      }

      expect(port.baudRate, 115200);
    });
  });
}
