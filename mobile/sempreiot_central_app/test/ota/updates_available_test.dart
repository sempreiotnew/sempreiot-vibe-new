import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/device_update_source.dart';
import 'package:sempreiot_central_app/features/central/application/device_update_state.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/ota/firmware_release.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

/// The round badge on "Atualizar dispositivos" (docs/ota/ota-internet-plan.md
/// D4, §5.2): only a HIGHER published version is an update.
void main() {
  const board = '5A:46:52:00:00:00';
  const root = '5A:46:52:00:00:01';
  const siren = '5A:46:52:00:00:02';
  const leaf = '5A:46:52:00:00:04';

  TopologyNode unit(String mac, int layer, int product, String? fw,
          {bool online = true}) =>
      TopologyNode(
        mac: mac,
        role: layer == 0 ? SafrNodeRole.root : SafrNodeRole.node,
        layer: layer,
        parentMac: null,
        rssi: null,
        batteryPct: null,
        online: online,
        lastSeenAt: DateTime.now().toUtc(),
        alarmLatched: false,
        productCode: product,
        fwVersion: fw,
      );

  FirmwareRelease release(String version, List<SafrProductFamily> families) =>
      FirmwareRelease(
        version: version,
        bucket: 'sempreiot-releases',
        region: 'us-east-1',
        images: {
          for (final f in families)
            f: FirmwareReleaseImage(
                key: 'bench/$version/${f.name}-$version.bin',
                size: 1,
                sha256: '0' * 64,
                project: 'sempreiot-${f.name}'),
        },
      );

  const all = [
    SafrProductFamily.board,
    SafrProductFamily.node,
    SafrProductFamily.leaf,
  ];

  test('units below the highest published version have an update', () {
    final u = computeUpdatesAvailable([
      unit(board, 0, 0x0100, '0.3.3'),
      unit(root, 1, 0x0204, '0.3.4'),
      unit(siren, 2, 0x0201, '0.3.3'),
      unit(leaf, 3, 0x0301, '0.3.10'),
    ], [
      release('0.3.4', all),
      release('0.3.3', all),
    ]);
    expect(u.units[SafrProductFamily.board], [deviceUpdateBoardKey]);
    expect(u.units[SafrProductFamily.node], [siren]);
    expect(u.units.containsKey(SafrProductFamily.leaf), isFalse,
        reason: 'a lower published version is never an update');
    expect(u.count, 2);
    expect(u.countText, '2 dispositivos');
    expect(u.versions[SafrProductFamily.node], '0.3.4');
  });

  test('a unit that never said its version counts; an offline one does not',
      () {
    final u = computeUpdatesAvailable([
      unit(root, 1, 0x0204, null),
      unit(siren, 2, 0x0201, '0.1.0', online: false),
    ], [
      release('0.3.4', [SafrProductFamily.node]),
    ]);
    expect(u.units[SafrProductFamily.node], [root]);
  });

  test('nothing published: no badge', () {
    final u = computeUpdatesAvailable([unit(root, 1, 0x0204, '0.1.0')], []);
    expect(u.any, isFalse);
    expect(u.count, 0);
  });

  test('a pre-release is below its release', () {
    final u = computeUpdatesAvailable([
      unit(root, 1, 0x0204, '0.4.0-dev'),
    ], [
      release('0.4.0', [SafrProductFamily.node]),
    ]);
    expect(u.count, 1);
  });

  test('the app (phone, web) with no central open: no badge, no database',
      () {
    // Web 2026-10-05: the badge read the tablet's units with no central
    // open, and the local database does not exist on the web — the app
    // bar crashed. topologyProvider must not even be built.
    final c = ProviderContainer(overrides: [
      appIsCentralProvider.overrideWithValue(false),
      topologyProvider.overrideWith(
          (ref) => throw StateError('the tablet\'s units were read')),
    ]);
    addTearDown(c.dispose);
    expect(c.read(updatesAvailableProvider).any, isFalse);
    expect(c.read(firmwareReleasesViewProvider).known, isFalse);
    expect(c.read(deviceUpdateSourceProvider), DeviceUpdateSource.internet);
  });
}
