import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show AsyncValueX;
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
        {
          'mac': '7C:4F:AD:AE:85:90',
          'id': 'dev-b',
          'name': 'Sirene 1',
          'zone': 'Térreo'
        },
      ],
    };

Uint8List _heartbeatPayload({int layer = 1}) => Uint8List.fromList([
      0x68,
      0x6E,
      0x2F,
      0x01,
      0x00,
      0x00,
      0x0E,
      0x10,
      0x01,
      0x64,
      0x00,
      0xFA,
      0xBE,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x01,
      layer,
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
      final parsed =
          parseInstallationBackup(envelope, passphrase: 'senha-forte-1');
      expect(parsed.legacyPlaintext, isFalse);
      expect(parsed.installation.systemId, 1220);
      expect(parsed.installation.safrPskHex, original.safrPskHex);
      // The share carries the code and endereçamentos (read from the
      // pre-2026-10-28 'zones' key too), never the phone's work log.
      expect(parsed.installation.devices, isEmpty);
      expect(parsed.installation.addresses, ['Térreo']);
    });

    test('rejects garbage, sticker QRs and bad keys', () {
      expect(() => parseInstallationBackup('not json'),
          throwsA(isA<FormatException>()));
      expect(
          () => parseInstallationBackup(
              '{"id":"dev-b","mac":"AA:BB:CC:DD:EE:FF","pop":"x"}'),
          throwsA(isA<FormatException>()));
      expect(
          () => parseInstallationBackup(jsonEncode(_backupJson(pskHex: 'zz'))),
          throwsA(isA<FormatException>()));
      expect(
          () => parseInstallationBackup(jsonEncode(_backupJson(systemId: 0))),
          throwsA(isA<FormatException>()));
    });
  });

  group('CentralInstallationNotifier identity changes', () {
    late AppDatabase db;
    late CentralInstallationNotifier notifier;
    var forgotten = 0;

    Future<void> seedUnits() async {
      final now = DateTime.now().toUtc();
      await db.into(db.meshDevices).insert(MeshDevicesCompanion.insert(
          mac: '7C:4F:AD:AE:85:90', firstSeenAt: now, lastSeenAt: now));
      await db.replaceLabels(1, {1: 'Térreo'});
      await db.into(db.deviceEvents).insert(DeviceEventsCompanion.insert(
          receivedAt: now,
          deviceMac: '7C:4F:AD:AE:85:90',
          msgType: 0,
          severity: 0,
          detailJson: '{}'));
    }

    Future<(int, int, int)> counts() async => (
          (await db.select(db.meshDevices).get()).length,
          (await db.select(db.deviceLabels).get()).length,
          (await db.select(db.deviceEvents).get()).length,
        );

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      forgotten = 0;
      FlutterSecureStorage.setMockInitialValues({});
      notifier = CentralInstallationNotifier(
        CentralInstallationStore(),
        forgetUnits: () async {
          forgotten++;
          await db.forgetInstallationUnits();
        },
      );
      await Future<void>.delayed(Duration.zero);
      await seedUnits();
    });

    tearDown(() => db.close());

    test('Desvincular forgets every unit, label and event', () async {
      await notifier.adopt(Installation.fromJson(_backupJson()));
      await seedUnits();
      await notifier.clear();
      expect(notifier.state.valueOrNull, isNull);
      expect(await counts(), (0, 0, 0));
    });

    test('adopting another SYSTEM_ID starts from an empty registry', () async {
      await notifier.adopt(Installation.fromJson(_backupJson()));
      expect(await counts(), (0, 0, 0), reason: 'bench rows are not its');
      await seedUnits();
      await notifier.adopt(Installation.fromJson(_backupJson(systemId: 77)));
      expect(await counts(), (0, 0, 0));
    });

    test('re-adopting the same SYSTEM_ID keeps the units', () async {
      await notifier.adopt(Installation.fromJson(_backupJson()));
      final before = forgotten;
      await seedUnits();
      await notifier.adopt(Installation.fromJson(_backupJson()));
      await notifier.import(jsonEncode(_backupJson()));
      expect(forgotten, before);
      expect(await counts(), (1, 1, 1));
    });

    test('clearing with no installation forgets nothing', () async {
      await notifier.clear();
      expect(forgotten, 0);
      expect(await counts(), (1, 1, 1));
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
