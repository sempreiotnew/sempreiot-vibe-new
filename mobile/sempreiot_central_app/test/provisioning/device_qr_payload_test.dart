import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/provisioning/application/provisioning_wizard_provider.dart';
import 'package:sempreiot_central_app/features/provisioning/domain/entities/device_ap_info.dart';
import 'package:sempreiot_central_app/features/provisioning/domain/entities/device_qr_payload.dart';
import 'package:sempreiot_central_app/features/provisioning/presentation/widgets/scan_step.dart';

/// The sticker QR (tools/make_sticker.py): {id, mac, pop} since the POC,
/// plus the product and its type since 2026-10-29 — so the wizard knows
/// what it is setting up before the phone joins the unit's network.
void main() {
  group('sticker QR', () {
    test('a sticker with the product and its type', () {
      final p = DeviceQrPayload.tryParse(
          '{"id":"80456B52005C","mac":"80:45:6B:52:00:5C","pop":"abcdefghijklmnop",'
          '"model":"SIOT-SIREN-01","family":"node"}')!;
      expect(p.model, 'SIOT-SIREN-01');
      expect(p.family, 'node');
      expect(p.product?.code, 0x0201);
      expect(p.productFamily, SafrProductFamily.node);
    });

    test('an older sticker, {id, mac, pop} only, still parses', () {
      final p = DeviceQrPayload.tryParse(
          '{"id":"dev-001","mac":"AA:BB:CC:DD:EE:FF","pop":"abcdefghijklmnop"}')!;
      expect(p.model, isNull);
      expect(p.family, isNull);
      expect(p.product, isNull);
      expect(p.productFamily, SafrProductFamily.unknown);
    });

    test('a model this app does not know keeps the printed type', () {
      final p = DeviceQrPayload.tryParse(
          '{"id":"x","mac":"m","pop":"abcdefghijklmnop","model":"SIOT-NEW-01","family":"LEAF"}')!;
      expect(p.product, isNull);
      expect(p.productFamily, SafrProductFamily.leaf);
    });

    test('a model alone gives the type; a bad type gives unknown', () {
      final a = DeviceQrPayload.tryParse(
          '{"id":"x","mac":"m","pop":"abcdefghijklmnop","model":"siot-board-01"}')!;
      expect(a.product?.code, 0x0100);
      expect(a.productFamily, SafrProductFamily.board);
      final b = DeviceQrPayload.tryParse(
          '{"id":"x","mac":"m","pop":"abcdefghijklmnop","family":"tablet"}')!;
      expect(b.productFamily, SafrProductFamily.unknown);
    });

    test('the mandatory fields are still mandatory', () {
      expect(DeviceQrPayload.tryParse('{"id":"x","mac":"m"}'), isNull);
      expect(DeviceQrPayload.tryParse('not json'), isNull);
    });
  });

  group('the scan step hands the wizard what the QR said', () {
    const scanned = DeviceQrPayload(
        id: '80456B520038',
        mac: '80:45:6B:52:00:38',
        pop: 'abcdefghijklmnop',
        model: 'SIOT-SMOKE-01',
        family: 'leaf');

    test('scanned and untouched: product and type come along (bug 2026-10-29)',
        () {
      final p = stickerFromFields(
          scanned: scanned,
          id: ' 80456B520038 ',
          mac: '80:45:6B:52:00:38',
          pop: 'abcdefghijklmnop');
      expect(p.model, 'SIOT-SMOKE-01');
      expect(p.productFamily, SafrProductFamily.leaf);
      expect(p.product?.code, 0x0301);
    });

    test('a field edited after the scan: the typed credentials, no product',
        () {
      final p = stickerFromFields(
          scanned: scanned,
          id: '80456B520038',
          mac: '80:45:6B:52:00:38',
          pop: 'another-units-pop');
      expect(p.pop, 'another-units-pop');
      expect(p.model, isNull);
      expect(p.productFamily, SafrProductFamily.unknown);
    });

    test('typed by hand, never scanned: the bare fields', () {
      final p = stickerFromFields(
          scanned: null, id: 'x', mac: 'm', pop: 'abcdefghijklmnop');
      expect(p.model, isNull);
    });
  });

  group('the type as the installer reads it', () {
    test('names', () {
      expect(SafrProductFamily.board.title, 'Central');
      expect(SafrProductFamily.node.title, 'Dispositivo AC');
      expect(SafrProductFamily.leaf.title, 'Dispositivo Bateria');
      expect(SafrProductFamily.fromName('node'), SafrProductFamily.node);
      expect(SafrProductFamily.fromName(' Board '), SafrProductFamily.board);
      expect(SafrProductFamily.fromName('unknown'), SafrProductFamily.unknown);
      expect(SafrProductFamily.fromName(null), SafrProductFamily.unknown);
      expect(SafrProductFamily.leaf.wireName, 'leaf');
      expect(SafrProductFamily.unknown.wireName, '');
    });
  });

  group('the unit against its sticker (GET /info is authoritative)', () {
    DeviceApInfo info({String model = '', int? product, String? family}) =>
        DeviceApInfo.fromMap({
          'id': 'x',
          'model': model,
          if (product != null) 'product': product,
          if (family != null) 'family': family,
          'nonce': '00',
        });
    const siren = DeviceQrPayload(
        id: 'x', mac: 'm', pop: 'p', model: 'SIOT-SIREN-01', family: 'node');

    test('agree: nothing to say', () {
      expect(
          ProvisioningWizardNotifier.stickerMismatch(
              siren, info(model: 'SIOT-SIREN-01', product: 0x0201)),
          isNull);
      expect(
          ProvisioningWizardNotifier.stickerMismatch(
              siren, info(model: 'SIOT-SIREN-01')),
          isNull,
          reason: 'older firmware names the product by its model string');
    });

    test('a sticker that names nothing can contradict nothing', () {
      const bare = DeviceQrPayload(id: 'x', mac: 'm', pop: 'p');
      expect(
          ProvisioningWizardNotifier.stickerMismatch(
              bare, info(model: 'SIOT-SMOKE-01', product: 0x0301)),
          isNull);
      expect(ProvisioningWizardNotifier.stickerMismatch(null, info()), isNull);
    });

    test('the unit says nothing: the sticker stands', () {
      expect(ProvisioningWizardNotifier.stickerMismatch(siren, info()), isNull);
    });

    test('another product: a wrong label', () {
      final why = ProvisioningWizardNotifier.stickerMismatch(
          siren, info(model: 'SIOT-SMOKE-01', product: 0x0301));
      expect(why, contains('Sirene (SIOT-SIREN-01)'));
      expect(why, contains('Detector de fumaça (bateria) · SIOT-SMOKE-01'));
    });

    test('a product run as the other type (2026-10-29): the unit\'s word', () {
      // A push-button station flashed as a battery unit: the sticker and
      // /info both say leaf although the product's native family is node.
      const batteryPbs = DeviceQrPayload(
          id: 'x', mac: 'm', pop: 'p', model: 'SIOT-PBS-01', family: 'leaf');
      final unit = info(model: 'SIOT-PBS-01', product: 0x0202, family: 'leaf');
      expect(unit.productFamily, SafrProductFamily.leaf);
      expect(unit.product?.code, 0x0202);
      expect(
          ProvisioningWizardNotifier.stickerMismatch(batteryPbs, unit), isNull);
      // The same unit under a sticker printed for the mains version.
      const mainsPbs = DeviceQrPayload(
          id: 'x', mac: 'm', pop: 'p', model: 'SIOT-PBS-01', family: 'node');
      expect(ProvisioningWizardNotifier.stickerMismatch(mainsPbs, unit),
          contains('Dispositivo Bateria'));
      // Older firmware says no family: the product's native one stands.
      expect(info(model: 'SIOT-PBS-01', product: 0x0202).productFamily,
          SafrProductFamily.node);
    });

    test('type alone against the unit\'s family', () {
      const typed = DeviceQrPayload(
          id: 'x', mac: 'm', pop: 'p', model: 'SIOT-NEW-01', family: 'leaf');
      final why = ProvisioningWizardNotifier.stickerMismatch(
          typed, info(model: 'SIOT-SIREN-01', product: 0x0201));
      expect(why, contains('Dispositivo Bateria'));
      expect(why, contains('Dispositivo AC'));
      expect(
          ProvisioningWizardNotifier.stickerMismatch(
              typed, info(model: 'SIOT-SMOKE-01', product: 0x0301)),
          isNull);
    });
  });
}
