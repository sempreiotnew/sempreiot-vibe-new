// This used to also integration-test the wizard state machine against
// `mocked-device-autoconnect/server.js`'s old `/reset`-driven mock (old
// deviceId/signature/centralId contract). That contract no longer exists:
// POC-BRIEF.md §5 replaced it with the id/pop/HMAC/HKDF/CCM contract
// implemented in `device_ap_service.dart` and `provisioning_crypto.dart`
// (see `test/provisioning/provisioning_crypto_vectors_test.dart` for that
// crypto verified against an independent implementation).
//
// Restoring a live-mock integration test needs `mocked-device-autoconnect
// /server.js` updated to the §5 contract first (POC-BRIEF.md says to keep
// it in sync — that update is out of scope for this pass, which only
// touched `mobile/sempreiot_central_app/`). Until then this file only keeps
// the static QR-payload parsing check, which needs no server.
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/provisioning/domain/entities/device_qr_payload.dart';

void main() {
  test('DeviceQrPayload parses a valid sticker QR and rejects garbage', () {
    final ok = DeviceQrPayload.tryParse(
      '{"id":"dev-001","mac":"AA:BB:CC:DD:EE:FF","pop":"abc123POP0000"}',
    );
    expect(ok?.id, 'dev-001');
    expect(ok?.mac, 'AA:BB:CC:DD:EE:FF');
    expect(ok?.pop, 'abc123POP0000');

    expect(DeviceQrPayload.tryParse('just-a-subid'), isNull);
    expect(DeviceQrPayload.tryParse('{"id":"x"}'), isNull);
    expect(DeviceQrPayload.tryParse(''), isNull);
  });
}
