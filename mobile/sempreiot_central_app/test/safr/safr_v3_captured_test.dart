import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';

import 'safr_v3_vectors_test.dart' show buildSpecVectors;

/// Hardware-in-the-loop regression: frames captured once from the real mock
/// firmware (tools/capture-safr.sh) must reframe, CRC-check and decrypt
/// with the Dart implementation — proving mbedTLS ↔ PointyCastle interop and
/// that the UART path does not corrupt binary (the v1 CRLF bug).
void main() {
  final fixture = File('test/fixtures/safr_v3_captured.hex');

  test(
    'captured firmware stream parses without CRC/auth failures',
    () {
      final hex = fixture.readAsStringSync().replaceAll(RegExp(r'\s'), '');
      final bytes = Uint8List.fromList([
        for (var i = 0; i + 1 < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
      expect(bytes.length, greaterThan(200), reason: 'capture too small');

      // Reframe exactly like SerialNotifier._drainFrames.
      final frames = <Uint8List>[];
      var buf = bytes.toList();
      while (true) {
        final sof = buf.indexOf(safrSof);
        if (sof < 0) break;
        buf = buf.sublist(sof);
        if (buf.length < 4) break;
        if (buf[1] != safrVer3) {
          buf.removeAt(0);
          continue;
        }
        final len = (buf[2] << 8) | buf[3];
        if (len < safrV3MinFrame || len > safrMaxFrame) {
          buf.removeAt(0);
          continue;
        }
        if (buf.length < len) break;
        final frame = Uint8List.fromList(buf.sublist(0, len));
        if (!safrCrcOk(frame)) {
          buf.removeAt(0);
          continue;
        }
        frames.add(frame);
        buf = buf.sublist(len);
      }

      expect(frames.length, greaterThanOrEqualTo(10),
          reason: 'expected a healthy stream of frames in 60 s');

      var authFailures = 0;
      final types = <SafrMsgType>{};
      final macs = <String>{};
      for (final f in frames) {
        final parsed =
            parseSafrWireFrame(f, expectedSystemId: safrDevSystemId);
        if (parsed.error == SafrWireError.authFailed) authFailures++;
        if (parsed.isValid) {
          types.add(parsed.msgType);
          macs.add(parsed.srcMac);
          expect(parsed.systemId, safrDevSystemId);
        }
      }

      expect(authFailures, 0,
          reason: 'PSK/nonce mismatch between firmware and app');
      expect(types, containsAll([SafrMsgType.heartbeat]));
      expect(macs.length, greaterThanOrEqualTo(6),
          reason: 'virtual mesh should show most of its 8 nodes');

      // Boot-time deterministic vectors must match the Dart goldens
      // bit-for-bit when the capture includes a boot (script instructs so).
      final goldens = buildSpecVectors();
      final captured = frames.map(_hex).toSet();
      final found = goldens.where((g) => captured.contains(_hex(g))).length;
      expect(found, greaterThanOrEqualTo(1),
          reason: 'no Appendix-A vector found — capture across a board reset');
    },
    skip: !fixture.existsSync()
        ? 'No capture yet — run tools/capture-safr.sh with the board attached'
        : false,
  );
}

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
