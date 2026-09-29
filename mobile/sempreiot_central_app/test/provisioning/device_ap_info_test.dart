import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/installation/domain/entities/installation.dart';
import 'package:sempreiot_central_app/features/provisioning/domain/entities/device_ap_info.dart';

void main() {
  group('/info product identity', () {
    test('firmware that reports the PRODUCT code', () {
      final info = DeviceApInfo.fromMap({
        'id': '80456B72E330',
        'mac': '80:45:6B:72:E3:30',
        'model': 'SIOT-SIREN-01',
        'fw': '0.1.0-dev',
        'product': 0x0201,
        'family': 'node',
        'hw_rev': 0,
        'state': 'idle',
        'nonce': '00',
      });
      expect(info.productCode, 0x0201);
      expect(info.hwRev, isNull); // 0 = not stated
      expect(info.product?.family, SafrProductFamily.node);
      expect(info.productDisplay, 'Sirene · SIOT-SIREN-01');
    });

    test('older firmware: the model string names the product', () {
      final info = DeviceApInfo.fromMap({
        'id': 'x',
        'model': 'SIOT-SMOKE-01',
        'fw': '0.1.0-dev',
        'nonce': '00',
      });
      expect(info.productCode, isNull);
      expect(info.product?.code, 0x0301);
      expect(info.productDisplay, 'Detector de fumaça (bateria) · SIOT-SMOKE-01');
    });

    test('a code this app does not know is kept and shown', () {
      final info = DeviceApInfo.fromMap(
          {'id': 'x', 'model': 'SIOT-NEW-01', 'product': 0x0206, 'nonce': '00'});
      expect(info.product?.isKnown, isFalse);
      expect(info.productDisplay, 'Produto desconhecido 0x0206 · rede elétrica');
    });

    test('product 0 and a model outside the catalogue: the bare model', () {
      final info = DeviceApInfo.fromMap(
          {'id': 'x', 'model': 'SIOT-XYZ-01', 'product': 0, 'nonce': '00'});
      expect(info.product, isNull);
      expect(info.productDisplay, 'SIOT-XYZ-01');
      expect(DeviceApInfo.fromMap({'id': 'x'}).productDisplay, '—');
    });

    test('fromModel ignores case and spaces, rejects the unknown', () {
      expect(SafrProduct.fromModel(' siot-pbs-01 ')?.code, 0x0202);
      expect(SafrProduct.fromModel('SIOT-PBS-02'), isNull);
      expect(SafrProduct.fromModel(''), isNull);
      expect(SafrProduct.fromModel(null), isNull);
    });
  });

  group('ProvisionedDevice keeps what the unit said it is', () {
    test('round trip', () {
      const d = ProvisionedDevice(
        mac: 'AA:BB:CC:DD:EE:FF',
        id: 'dev-1',
        name: 'Sirene hall',
        zone: 'Térreo',
        model: 'SIOT-SIREN-01',
        productCode: 0x0201,
        fw: '0.1.0-dev',
      );
      final back = ProvisionedDevice.fromJson(d.toJson());
      expect(back.model, 'SIOT-SIREN-01');
      expect(back.productCode, 0x0201);
      expect(back.fw, '0.1.0-dev');
    });

    test('an entry written before the fields existed still loads', () {
      final back = ProvisionedDevice.fromJson(
          {'mac': 'AA:BB:CC:DD:EE:FF', 'id': 'dev-1', 'name': 'n', 'zone': 'z'});
      expect(back.model, isNull);
      expect(back.productCode, isNull);
      expect(back.fw, isNull);
      expect(back.toJson().containsKey('productCode'), isFalse);
    });
  });
}
