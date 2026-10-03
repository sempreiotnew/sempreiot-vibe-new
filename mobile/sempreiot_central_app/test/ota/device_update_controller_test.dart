import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/central_installation_provider.dart';
import 'package:sempreiot_central_app/features/central/application/device_update_controller.dart';
import 'package:sempreiot_central_app/features/central/application/device_update_history.dart';
import 'package:sempreiot_central_app/features/central/application/device_update_state.dart';
import 'package:sempreiot_central_app/features/central/application/firmware_library_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_controller.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_state.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_controller.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_state.dart';
import 'package:sempreiot_central_app/features/central/application/safr_ingest_provider.dart';
import 'package:sempreiot_central_app/features/central/application/serial_link_provider.dart';
import 'package:sempreiot_central_app/features/central/application/serial_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/data/services/firmware_file_picker.dart';
import 'package:sempreiot_central_app/features/central/data/services/firmware_library_store.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_identity.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

import 'fake_board.dart';
import 'fake_firmware.dart';
import 'fake_rollout.dart';

class _MemoryStore implements FirmwareLibraryStore {
  final files = <String, Uint8List>{};

  @override
  Future<List<StoredFirmwareFile>> list() async => [
        for (final e in files.entries)
          StoredFirmwareFile(
              name: e.key, size: e.value.length, modified: DateTime(2026)),
      ];

  @override
  Future<Uint8List> read(String name) async => files[name]!;

  @override
  Future<StoredFirmwareFile> save(String name, Uint8List bytes) async {
    files[name] = bytes;
    return StoredFirmwareFile(
        name: name, size: bytes.length, modified: DateTime(2026));
  }

  @override
  Future<void> delete(String name) async => files.remove(name);
}

/// "Atualizar dispositivos" against a board that plays the push and the
/// rollout byte for byte (fake_board.dart + fake_rollout.dart), through the
/// real push and rollout controllers.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final identity = SafrIdentity(
    systemId: 0x4A17,
    key: Uint8List.fromList([for (var i = 0; i < 16; i++) 0x30 + i]),
  );

  const rolloutTimings = OtaRolloutTimings(
    answerTimeout: Duration(milliseconds: 150),
    controlAckTimeout: Duration(milliseconds: 100),
    controlAttempts: 2,
    pageAfterControl: Duration(milliseconds: 150),
    pageSetTimeout: Duration(milliseconds: 80),
    rollingSilence: Duration(milliseconds: 200),
    watchdogPeriod: Duration(milliseconds: 50),
  );
  const pushTimings = OtaPushTimings(
    baudAckTimeout: Duration(milliseconds: 80),
    baudAttempts: 2,
    beginAckTimeout: Duration(milliseconds: 100),
    beginAttempts: 2,
    probeAckTimeout: Duration(milliseconds: 80),
    probeAttempts: 1,
    resultGrace: Duration(milliseconds: 40),
    chunkAckTimeout: Duration(milliseconds: 120),
    chunkMaxFailures: 5,
    endAckTimeout: Duration(milliseconds: 80),
    endAttempts: 2,
    verdictTimeout: Duration(milliseconds: 600),
    linkLossTimeout: Duration(milliseconds: 900),
    linkPoll: Duration(milliseconds: 15),
    boardConfirmTimeout: Duration(milliseconds: 1500),
    firstPokeAfter: Duration(milliseconds: 80),
    pokeInterval: Duration(milliseconds: 60),
    selfTestWindow: Duration(milliseconds: 600),
  );
  const updateTimings = DeviceUpdateTimings(
    nodeUnit: Duration(seconds: 5),
    leafUnit: Duration(seconds: 5),
    heldWait: Duration(seconds: 2),
    heldPoll: Duration(milliseconds: 10),
    meshBack: Duration(seconds: 4),
    meshPoll: Duration(milliseconds: 20),
  );

  const node = SafrProductFamily.node;
  const root = '5A:46:52:00:00:01';
  const siren = '5A:46:52:00:00:02';
  const button = '5A:46:52:00:00:03';
  const detector = '5A:46:52:00:00:04';
  const failTwice = [
    (FakePlay.failSelfTest, SafrOtaReason.selftestFail),
    (FakePlay.failSelfTest, SafrOtaReason.selftestFail),
    (FakePlay.update, SafrOtaReason.none),
  ];

  late AppDatabase db;
  late FakeRollout mesh;
  late FakeBoard board;
  late ProviderContainer container;
  late _MemoryStore store;

  FakeRollout threeUnits({
    List<(FakePlay, SafrOtaReason)>? sirenPlays,
    bool withDetector = false,
  }) =>
      FakeRollout(identity: identity)
        ..stored[0x02] = '0.2.0'
        ..rootMac = root
        ..units.addAll([
          FakeUnit(root, name: 'Repetidor', product: 0x0204, layer: 1),
          FakeUnit(siren,
              name: 'Sirene hall',
              product: 0x0201,
              parent: root,
              plays: sirenPlays),
          FakeUnit(button, name: 'Botoeira', product: 0x0202, parent: root),
          if (withDetector)
            FakeUnit(detector,
                name: 'Detector', product: 0x0301, layer: 3, parent: siren),
        ]);

  Future<void> boot(FakeRollout m, {List<String> library = const []}) async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    mesh = m;
    store = _MemoryStore();
    for (final name in library) {
      final dash = name.indexOf('-');
      final family = name.substring(0, dash);
      final version = name.substring(dash + 1, name.length - 4);
      store.files[name] = fakeFirmware(
          project: 'sempreiot-$family', version: version, size: 6 * 4096);
    }
    board = FakeBoard(identity: identity, rollout: mesh);
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      serialProvider.overrideWith((ref) => board),
      safrIdentityProvider.overrideWithValue(identity),
      otaRolloutTimingsProvider.overrideWithValue(rolloutTimings),
      otaPushTimingsProvider.overrideWithValue(pushTimings),
      deviceUpdateTimingsProvider.overrideWithValue(updateTimings),
      firmwareLibraryStoreProvider.overrideWithValue(store),
    ]);
    container.read(safrIngestProvider);
    container.read(otaRolloutProvider);
    container.read(deviceUpdateProvider);
    board.plug();
    await _until(
      () => container.read(serialLinkProvider) == SerialLinkStatus.connected,
      what: 'the link to come up',
    );
    await _until(() => container.read(otaRolloutProvider).boardAnswered == true,
        what: 'the board to answer GET_ROLLOUT');
    mesh.announceUnits();
    await _until(
        () =>
            container.read(topologyProvider).where((n) => n.layer > 0).length ==
            mesh.units.length,
        what: 'the units on the map');
    await container.read(firmwareLibraryProvider.notifier).load();
  }

  tearDown(() async {
    mesh.close();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    container.dispose();
    await db.close();
  });

  /// The board restarts into its new image: its access point goes down and
  /// the mesh joins it again [after] (every unit heard again then).
  void meshRejoins({Duration after = const Duration(milliseconds: 300)}) {
    board.onRestart = () => Timer(after, () => mesh.announceUnits());
  }

  DeviceUpdateController update() =>
      container.read(deviceUpdateProvider.notifier);
  DeviceUpdateRun run() => container.read(deviceUpdateProvider)!;
  FirmwareLibraryEntry image(SafrProductFamily f, String v) =>
      container.read(firmwareLibraryProvider).image(f, v)!;
  List<SafrOtaFilterKind> starts() => [
        for (final c in mesh.controls)
          if (c.action == SafrOtaAction.start) c.filter.kind,
      ];
  Future<void> ended() =>
      _until(() => container.read(deviceUpdateProvider)?.running == false,
          what: 'the run to end', within: const Duration(seconds: 15));

  group('chosen units', () {
    test('one rollout per unit, the root last; the others untouched', () async {
      await boot(threeUnits(), library: ['node-0.2.0.bin']);

      final refused = await update().start(
          family: node, keys: [root, siren], image: image(node, '0.2.0'));
      expect(refused, isNull);
      await ended();

      expect(mesh.offered, [siren, root], reason: 'the root goes last');
      expect(starts(), [SafrOtaFilterKind.unit, SafrOtaFilterKind.unit]);
      expect(mesh.unit(button).offers, 0);
      expect(board.images, isEmpty,
          reason: 'the board already held 0.2.0: nothing is pushed');
      expect(run().end, DeviceUpdateEnd.done);
      expect(run().units[siren]!.state, SafrOtaUnitState.done);
      expect(run().units[siren]!.version, '0.2.0');
      expect(run().units[root]!.state, SafrOtaUnitState.done);
    });

    test('every unit of the family: one at a time, the root last', () async {
      await boot(threeUnits(), library: ['node-0.2.0.bin']);

      await update().start(
          family: node,
          keys: [root, siren, button],
          image: image(node, '0.2.0'));
      await ended();

      expect(starts(), everyElement(SafrOtaFilterKind.unit),
          reason: 'never the board\'s own queue: it may not know the root');
      expect(mesh.offered, [siren, button, root]);
      expect(run().end, DeviceUpdateEnd.done);
      expect(run().count(SafrOtaUnitState.done), 3);
    });

    test('the deepest first: a parent after its children, the root last',
        () async {
      final m = threeUnits();
      // siren → button: the push button hangs off the siren.
      m.unit(button)
        ..layer = 3
        ..parent = siren;
      await boot(m, library: ['node-0.2.0.bin']);

      await update().start(
          family: node,
          keys: [root, siren, button],
          image: image(node, '0.2.0'));
      await ended();

      expect(mesh.offered, [button, siren, root]);
      expect(run().end, DeviceUpdateEnd.done);
    });

    test('the image goes to the board first when it does not hold it',
        () async {
      final m = threeUnits()..stored.clear();
      await boot(m, library: ['node-0.2.0.bin']);

      await update()
          .start(family: node, keys: [siren], image: image(node, '0.2.0'));
      await ended();

      expect(board.imageVersions[0x02], '0.2.0');
      expect(mesh.offered, [siren]);
      expect(run().end, DeviceUpdateEnd.done);
    });

    test('a unit that fails: PARCIAL, and "Tentar de novo" offers it again',
        () async {
      await boot(threeUnits(sirenPlays: failTwice),
          library: ['node-0.2.0.bin']);

      await update()
          .start(family: node, keys: [siren], image: image(node, '0.2.0'));
      await ended();

      expect(run().end, DeviceUpdateEnd.partial);
      final failed = run().units[siren]!;
      expect(failed.state, SafrOtaUnitState.failed);
      expect(failed.reason, SafrOtaReason.selftestFail);

      expect(update().retryFailed(), isNull);
      await ended();

      expect(run().end, DeviceUpdateEnd.done);
      expect(run().units[siren]!.state, SafrOtaUnitState.done);
      expect(mesh.offered, [siren, siren, siren]);
    });

    test('"Reinstalar": chosen on purpose, it is offered again', () async {
      final m = threeUnits();
      m.unit(siren).version = '0.2.0';
      await boot(m, library: ['node-0.2.0.bin']);

      await update().start(
          family: node,
          keys: [siren],
          image: image(node, '0.2.0'),
          reinstall: true);
      await ended();

      expect(mesh.offered, [siren]);
      expect(run().units[siren]!.note, isNull);
      expect(run().end, DeviceUpdateEnd.done);
    });

    test('the history keeps every update, the retry included', () async {
      await boot(threeUnits(sirenPlays: failTwice),
          library: ['node-0.2.0.bin']);
      await update().start(
          family: node,
          keys: [siren],
          image: image(node, '0.2.0'),
          by: 'admin');
      await ended();
      await update().written;

      final history = container.read(deviceUpdateHistoryProvider);
      var runs = await history.recent();
      expect(runs, hasLength(1));
      var (run, units) = runs.single;
      expect(run.startedBy, 'admin');
      expect(run.target, '0.2.0');
      expect(run.outcome, 'partial');
      expect(units.single.unitKey, siren);
      expect(units.single.state, 'failed');
      expect(units.single.reasonRaw, SafrOtaReason.selftestFail.wire);

      update().retryFailed(by: 'admin');
      await ended();
      await update().written;
      runs = await history.recent();
      (run, units) = runs.single;
      expect(run.outcome, 'done', reason: 'the same update, now complete');
      expect(units.single.state, 'done');
      expect(units.single.versionBefore, '0.1.0');
      expect(units.single.versionAfter, '0.2.0');

      final mine = await history.ofUnit(siren);
      expect(deviceUpdateHistoryLine(mine.single.$1, mine.single.$2),
          endsWith('v0.1.0 → v0.2.0 · Atualizado'));
      final csv = deviceUpdateHistoryCsv(runs);
      expect(csv.split('\n').first, startsWith('inicio,fim,por'));
      expect(csv, contains('"$siren","node","0.1.0","0.2.0","done"'));
      final audit = await db.recentAudit();
      expect(
          audit.map((a) => '${a.actor} ${a.action}'),
          containsAll(
              ['admin ota_update_started', 'admin ota_update_retried']));
    });

    test('a unit already on the version is not offered it again', () async {
      final m = threeUnits();
      m.unit(siren).version = '0.2.0';
      await boot(m, library: ['node-0.2.0.bin']);

      await update().start(
          family: node, keys: [siren, button], image: image(node, '0.2.0'));
      await ended();

      expect(mesh.offered, [button]);
      expect(run().units[siren]!.note, 'Já estava nesta versão.');
      expect(run().end, DeviceUpdateEnd.done);
    });
  });

  group('Atualizar tudo', () {
    test('the board first, then every node', () async {
      final m = threeUnits()..stored.clear();
      await boot(m,
          library: ['board-0.2.0.bin', 'node-0.2.0.bin', 'leaf-0.2.0.bin']);

      expect(
          container.read(firmwareLibraryProvider).completeVersions, ['0.2.0']);
      meshRejoins();
      expect(await update().startAll('0.2.0'), isNull);
      expect(run().phases, [SafrProductFamily.board, node],
          reason: 'no detector on the map: no detector phase');
      await ended();

      expect(board.runningVersion, '0.2.0');
      expect(run().units[deviceUpdateBoardKey]!.state, SafrOtaUnitState.done);
      expect(starts(), everyElement(SafrOtaFilterKind.unit));
      expect(mesh.offered.last, root);
      expect(run().end, DeviceUpdateEnd.done);
    });

    test('a node fails: it asks before the detectors; "Parar aqui" stops',
        () async {
      final m = threeUnits(sirenPlays: failTwice, withDetector: true)
        ..stored.clear();
      await boot(m,
          library: ['board-0.2.0.bin', 'node-0.2.0.bin', 'leaf-0.2.0.bin']);

      meshRejoins();
      await update().startAll('0.2.0');
      expect(run().phases,
          [SafrProductFamily.board, node, SafrProductFamily.leaf]);
      await _until(() => run().stage == DeviceUpdateStage.deciding,
          what: 'the question before the detectors',
          within: const Duration(seconds: 15));

      expect(run().units[siren]!.state, SafrOtaUnitState.failed);
      update().decide(goOn: false);

      expect(run().end, DeviceUpdateEnd.stopped);
      expect(run().units[detector]!.state, SafrOtaUnitState.skipped);
      expect(mesh.unit(detector).offers, 0);
    });

    test(
        'a node the board cannot offer now: the detectors wait '
        '(bench 2026-10-02)', () async {
      final m = threeUnits(withDetector: true)..stored.clear();
      await boot(m,
          library: ['board-0.2.0.bin', 'node-0.2.0.bin', 'leaf-0.2.0.bin']);
      // The board's table does not have it (just restarted, say): it
      // refuses that offer. The tablet still hears it.
      m.unit(button).online = false;

      meshRejoins();
      await update().startAll('0.2.0');
      await _until(() => run().stage == DeviceUpdateStage.deciding,
          what: 'the question before the detectors',
          within: const Duration(seconds: 15));

      expect(starts(), everyElement(SafrOtaFilterKind.unit));
      expect(mesh.offered.last, root, reason: 'the root still last');
      expect(run().units[siren]!.state, SafrOtaUnitState.done);
      expect(run().units[root]!.state, SafrOtaUnitState.done);
      expect(run().units[button]!.state, isNot(SafrOtaUnitState.done));
      expect(run().notUpdated(node).map((u) => u.key), [button]);
      expect(mesh.unit(detector).offers, 0,
          reason: 'never on to the detectors with a node not updated');

      // Back on the board's table: "Tentar de novo" offers it.
      m.unit(button).online = true;
      expect(update().retryFailed(), isNull);
      await _until(() => run().phase == 2 || !run().running,
          what: 'the nodes to be done', within: const Duration(seconds: 15));
      expect(run().units[button]!.state, SafrOtaUnitState.done);
      update().abort();
    });

    test(
        'the board restarted: nothing is offered before the nodes are heard '
        'again (bench 2026-10-02)', () async {
      final m = threeUnits()..stored.clear();
      await boot(m,
          library: ['board-0.2.0.bin', 'node-0.2.0.bin', 'leaf-0.2.0.bin']);
      int? offeredBeforeBack;
      board.onRestart = () => Timer(const Duration(milliseconds: 1500), () {
            offeredBeforeBack = mesh.offered.length;
            mesh.announceUnits();
          });

      await update().startAll('0.2.0');
      await _until(() => run().stage == DeviceUpdateStage.reconnecting,
          what: 'the wait for the mesh', within: const Duration(seconds: 10));
      expect(run().boardRestartedAt, isNotNull);
      await ended();

      expect(offeredBeforeBack, 0, reason: 'no offer while the mesh was down');
      expect(mesh.offered, [siren, button, root]);
      expect(run().end, DeviceUpdateEnd.done);
    });

    test('the board fails its self-test: nothing else is touched', () async {
      final m = threeUnits()..stored.clear();
      await boot(m,
          library: ['board-0.2.0.bin', 'node-0.2.0.bin', 'leaf-0.2.0.bin']);
      board.failSelfTest = true;

      await update().startAll('0.2.0');
      await ended();

      expect(run().end, DeviceUpdateEnd.failed);
      expect(run().units[deviceUpdateBoardKey]!.state, SafrOtaUnitState.failed);
      expect(mesh.offered, isEmpty);
      expect(board.imageVersions[0x02], isNull,
          reason: 'the node image was never sent');
    });
  });

  test('importing keeps SempreIoT images only, named by what they are',
      () async {
    await boot(threeUnits());
    final said =
        await container.read(firmwareLibraryProvider.notifier).importFiles([
      PickedFirmware(
          name: 'whatever.bin',
          bytes: fakeFirmware(project: 'sempreiot-leaf', version: '0.3.0')),
      PickedFirmware(name: 'notes.txt', bytes: Uint8List.fromList([1, 2, 3])),
    ]);

    expect(
        said,
        '1 firmware guardado no tablet · notes.txt: não é um '
        'firmware SempreIoT');
    expect(store.files.keys, ['leaf-0.3.0.bin']);
    final lib = container.read(firmwareLibraryProvider);
    expect(lib.of(SafrProductFamily.leaf).single.version, '0.3.0');
  });

  test('a run is refused while another runs', () async {
    await boot(threeUnits(), library: ['node-0.2.0.bin']);
    await update()
        .start(family: node, keys: [siren], image: image(node, '0.2.0'));
    expect(
        await update()
            .start(family: node, keys: [button], image: image(node, '0.2.0')),
        'Já há uma atualização em andamento.');
    await ended();
    expect(run().stage, DeviceUpdateStage.ended);
    update().dismiss();
    expect(container.read(deviceUpdateProvider), isNull);
    // The board's own table is still there for the old screens.
    expect(container.read(otaRolloutProvider).families[node], isNotNull);
    expect(container.read(otaPushProvider).phase, OtaPushPhase.idle);
  });
}

Future<void> _until(
  FutureOr<bool> Function() test, {
  required String what,
  Duration within = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(within);
  while (!await test()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
