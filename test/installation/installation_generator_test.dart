import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/installation/domain/services/installation_generator.dart';

void main() {
  group('InstallationGenerator', () {
    test('NET_SSID is derived from SYSTEM_ID (blueprint §0, lifecycle §8)', () {
      for (var i = 0; i < 20; i++) {
        final inst = InstallationGenerator.generate(displayName: 'Site $i');
        expect(inst.systemId, inRange(1, 0xFFFF));
        final hex = inst.systemId.toRadixString(16).padLeft(4, '0').toUpperCase();
        expect(inst.netSsid, 'SIOT-$hex');
        expect(inst.netPsk.length, 16);
        expect(inst.safrPskHex.length, 32);
        expect([1, 6, 11], contains(inst.channel));
        expect(inst.meshId, inRange(1, 255));
      }
    });

    test('netSsidFor pads and upper-cases', () {
      expect(InstallationGenerator.netSsidFor(0x00AB), 'SIOT-00AB');
      expect(InstallationGenerator.netSsidFor(0xBEEF), 'SIOT-BEEF');
    });
  });
}

Matcher inRange(int lo, int hi) =>
    allOf(greaterThanOrEqualTo(lo), lessThanOrEqualTo(hi));
