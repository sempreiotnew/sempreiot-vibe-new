import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/provisioning/domain/entities/provisioning_limits.dart';

/// The wizard counts bytes of UTF-8, as the unit's slots do (protocol §7.11).
void main() {
  test('name: 32 bytes, an accent costs two', () {
    expect(ProvisioningLimits.nameMaxBytes, 32);
    expect(ProvisioningLimits.fits('Detector de fumaça corredor 2', 32),
        isTrue); // 30 bytes
    expect(ProvisioningLimits.fits('Sensor escritório administração', 32),
        isFalse); // 34 bytes
    expect(ProvisioningLimits.fits('a' * 32, 32), isTrue);
    expect(ProvisioningLimits.fits('a' * 33, 32), isFalse);
  });

  test('endereçamento: 16 bytes', () {
    expect(ProvisioningLimits.addressMaxBytes, 16);
    expect(ProvisioningLimits.fits('1º andar', 16), isTrue); // 9 bytes
    expect(ProvisioningLimits.fits('Administração', 16), isTrue); // 15 bytes
    expect(ProvisioningLimits.fits('Administração 2', 16), isFalse); // 17 bytes
  });
}
