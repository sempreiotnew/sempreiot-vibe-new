import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/installation/domain/entities/installation.dart';
import 'package:sempreiot_central_app/features/installation/domain/services/installation_backup_codec.dart';

Installation _sample() => Installation(
      localId: 'abc',
      displayName: 'Galpão 2',
      systemId: 0x1234,
      netSsid: 'SIOT-1234',
      netPsk: 'QR2heszWr0mJjaDd',
      safrPskHex: '00112233445566778899aabbccddeeff',
      channel: 6,
      meshId: 0x34,
      zones: const ['Térreo', '1º andar'],
      createdAt: DateTime.utc(2026, 9, 24, 10),
      devices: const [
        ProvisionedDevice(
            mac: '7C:4F:AD:AE:85:90', id: 'dev-b', name: 'Sirene 1', zone: 'Térreo'),
      ],
    );

void main() {
  group('InstallationBackupCodec', () {
    test('round trip keeps the code and zones, drops the work log', () {
      final env = InstallationBackupCodec.encode(_sample(), 'senha-forte-1',
          iterations: 2000);
      expect(InstallationBackupCodec.detectFormat(env), BackupFormat.encryptedV2);
      final back = InstallationBackupCodec.decode(env, 'senha-forte-1');
      expect(back.systemId, 0x1234);
      expect(back.safrPskHex, '00112233445566778899aabbccddeeff');
      expect(back.netPsk, 'QR2heszWr0mJjaDd');
      expect(back.zones, ['Térreo', '1º andar']);
      expect(back.devices, isEmpty);
      expect(back.formatVersion, 2);
    });

    test('the envelope never contains the secrets in clear', () {
      final env = InstallationBackupCodec.encode(_sample(), 'senha-forte-1',
          iterations: 2000);
      expect(env, isNot(contains('QR2heszWr0mJjaDd')));
      expect(env, isNot(contains('00112233445566778899aabbccddeeff')));
      expect(env, isNot(contains('Galpão')));
    });

    test('wrong passphrase is reported as such', () {
      final env = InstallationBackupCodec.encode(_sample(), 'senha-forte-1',
          iterations: 2000);
      expect(
        () => InstallationBackupCodec.decode(env, 'senha-errada'),
        throwsA(isA<BackupDecodeException>()
            .having((e) => e.wrongPassphrase, 'wrongPassphrase', isTrue)),
      );
    });

    test('tampered ciphertext is rejected', () {
      final env = InstallationBackupCodec.encode(_sample(), 'senha-forte-1',
          iterations: 2000);
      final map = jsonDecode(env) as Map<String, dynamic>;
      final ct = base64.decode(map['ct'] as String);
      ct[0] ^= 0x01;
      map['ct'] = base64.encode(ct);
      expect(
        () => InstallationBackupCodec.decode(jsonEncode(map), 'senha-forte-1'),
        throwsA(isA<BackupDecodeException>()),
      );
    });

    test('short passphrases are refused', () {
      expect(() => InstallationBackupCodec.encode(_sample(), '1234567'),
          throwsA(isA<ArgumentError>()));
    });

    test('deterministic with fixed salt and nonce', () {
      final salt = Uint8List.fromList(List.generate(16, (i) => i));
      final nonce = Uint8List.fromList(List.generate(12, (i) => 0xA0 + i));
      final a = InstallationBackupCodec.encode(_sample(), 'senha-forte-1',
          iterations: 2000, saltOverride: salt, nonceOverride: nonce);
      final b = InstallationBackupCodec.encode(_sample(), 'senha-forte-1',
          iterations: 2000, saltOverride: salt, nonceOverride: nonce);
      expect(a, b);
    });

    test('detectFormat tells v2, legacy and garbage apart', () {
      expect(InstallationBackupCodec.detectFormat(jsonEncode(_sample().toJson())),
          BackupFormat.legacyPlaintext);
      expect(InstallationBackupCodec.detectFormat('{"id":"dev","mac":"x","pop":"y"}'),
          BackupFormat.unknown);
      expect(InstallationBackupCodec.detectFormat('nope'), BackupFormat.unknown);
    });
  });
}
