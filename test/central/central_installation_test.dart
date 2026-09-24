import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/central_installation_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_ingest_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_identity.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/installation/domain/entities/installation.dart';
import 'package:sempreiot_central_app/features/installation/domain/services/installation_backup_codec.dart';

/// The JSON the installer phone shows as "Backup da instalação".
Map<String, dynamic> _backupJson({
  int systemId = 1220,
  String pskHex = '00112233445566778899aabbccddeeff',
}) =>
    {
      'localId': 'local-1',
      'displayName': 'Galpão 2',
      'systemId': systemId,
      'netSsid': 'SIOT-CC2C',
      'netPsk': 'QR2heszWr0mJjaDd',
      'safrPskHex': pskHex,
      'channel': 1,
      'meshId': 196,
      'zones': ['Térreo'],
      'createdAt': '2026-09-16T10:00:00.000Z',
      'devices': [
        {'mac': '7C:4F:AD:AE:85:90', 'id': 'dev-b', 'name': 'Sirene 1', 'zone': 'Térreo'},
      ],
    };

Uint8List _heartbeatPayload({int layer = 1}) => Uint8List.fromList([
      0x68, 0x6E, 0x2F, 0x01, 0x00, 0x00, 0x0E, 0x10,
      0x01, 0x64, 0x00, 0xFA, 0xBE,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x01, layer,
    ]);

void main() {
  group('parseInstallationBackup', () {
    test('accepts the legacy plaintext JSON, flagged as legacy', () {
      final parsed = parseInstallationBackup(jsonEncode(_backupJson()));
      expect(parsed.legacyPlaintext, isTrue);
      final inst = parsed.installation;
      expect(inst.systemId, 1220);
      expect(inst.devices.single.name, 'Sirene 1');
      expect(SafrIdentity.keyFromHex(inst.safrPskHex), isNotNull);
    });

    test('accepts the v2 encrypted share with its passphrase', () {
      final original = Installation.fromJson(_backupJson());
      final envelope =
          InstallationBackupCodec.encode(original, 'senha-forte-1');
      expect(() => parseInstallationBackup(envelope),
          throwsA(isA<PassphraseRequired>()));
      expect(() => parseInstallationBackup(envelope, passphrase: 'errada!!'),
          throwsA(isA<FormatException>()));
      final parsed = parseInstallationBackup(envelope, passphrase: 'senha-forte-1');
      expect(parsed.legacyPlaintext, isFalse);
      expect(parsed.installation.systemId, 1220);
      expect(parsed.installation.safrPskHex, original.safrPskHex);
      // The share carries the code and zones, never the phone's work log.
      expect(parsed.installation.devices, isEmpty);
      expect(parsed.installation.zones, ['Térreo']);
    });

    test('rejects garbage, sticker QRs and bad keys', () {
      expect(() => parseInstallationBackup('not json'),
          throwsA(isA<FormatException>()));
      expect(
          () => parseInstallationBackup(
              '{"id":"dev-b","mac":"AA:BB:CC:DD:EE:FF","pop":"x"}'),
          throwsA(isA<FormatException>()));
      expect(
          () => parseInstallationBackup(
              jsonEncode(_backupJson(pskHex: 'zz'))),
          throwsA(isA<FormatException>()));
      expect(
          () => parseInstallationBackup(jsonEncode(_backupJson(systemId: 0))),
          throwsA(isA<FormatException>()));
    });
  });

  group('ingest with an imported identity', () {
    late AppDatabase db;
    late int valid;
    late int invalid;
    late SafrIdentity current;
    late SafrIngestService ingest;

    final installation = Installation.fromJson(_backupJson());
    final installKey = SafrIdentity.keyFromHex(installation.safrPskHex)!;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      valid = 0;
      invalid = 0;
      current = SafrIdentity.dev;
      ingest = SafrIngestService(
        db: db,
        identity: () => current,
        onValidFrame: () => valid++,
        onInvalidFrame: () => invalid++,
      );
    });

    tearDown(() => db.close());

    Uint8List boardHeartbeat() => SafrEncoder(
          srcMac: safrMacToBytes('7C:4F:AD:AE:85:90'),
          bootCtr: 10,
          systemId: installation.systemId,
          key: installKey,
        ).encode(msgType: SafrMsgType.heartbeat, payload: _heartbeatPayload());

    test('a provisioned unit is rejected on the bench identity', () async {
      await ingest.handleFrame(boardHeartbeat(), deviceId: 'test');
      expect(valid, 0);
      expect(invalid, 1);
    });

    test('...and accepted once the installation is imported', () async {
      current = SafrIdentity(systemId: installation.systemId, key: installKey);
      await ingest.handleFrame(boardHeartbeat(), deviceId: 'test');
      expect(valid, 1);
      expect(invalid, 0);
      final devices = await db.select(db.meshDevices).get();
      expect(devices.single.mac.toUpperCase(), '7C:4F:AD:AE:85:90');
    });
  });
}
