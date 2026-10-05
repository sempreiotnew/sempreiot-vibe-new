import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/alarm_latch_provider.dart';
import 'package:sempreiot_central_app/features/central/application/credentials_admin_provider.dart';
import 'package:sempreiot_central_app/features/central/application/device_update_controller.dart';
import 'package:sempreiot_central_app/features/central/application/device_update_source.dart';
import 'package:sempreiot_central_app/features/central/application/device_update_state.dart';
import 'package:sempreiot_central_app/features/central/application/firmware_library_provider.dart';
import 'package:sempreiot_central_app/features/central/application/firmware_release_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_board_events_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_pin_policy.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_controller.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_report.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_state.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_controller.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_report.dart';
import 'package:sempreiot_central_app/features/central/application/safr_traffic_provider.dart';
import 'package:sempreiot_central_app/features/central/application/serial_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/data/services/firmware_library_store.dart';
import 'package:sempreiot_central_app/features/central/data/services/release_downloader.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/device_update_screen.dart';
import 'package:sempreiot_central_app/features/iot/domain/entities/mqtt_message_entity.dart';

import 'fake_firmware.dart';

class _Port extends SerialNotifier {
  _Port() : super.detached();

  @override
  Future<bool> portWrite(Uint8List bytes) async => true;

  @override
  Future<bool> portSetBaud(int baud) async => true;
}

class _Push extends OtaPushController {
  _Push(super.ref);
}

class _Rollout extends OtaRolloutController {
  _Rollout(super.ref);

  @override
  Future<void> refresh() async {}
}

/// A run already where the test wants it.
class _Update extends DeviceUpdateController {
  _Update(super.ref, DeviceUpdateRun? initial) {
    state = initial;
  }

  /// Who started what: (family, version, by).
  final starts = <(SafrProductFamily, String, String)>[];

  /// Where each start's image came from.
  final sources = <DeviceUpdateSource>[];

  @override
  Future<String?> start({
    required SafrProductFamily family,
    required Iterable<String> keys,
    required FirmwareLibraryEntry image,
    bool reinstall = false,
    String by = 'system',
    DeviceUpdateSource source = DeviceUpdateSource.manual,
  }) async {
    starts.add((family, image.version, by));
    sources.add(source);
    return null;
  }
}

/// The published images, by S3 key.
class _S3 implements ReleaseDownloader {
  final objects = <String, Uint8List>{};

  @override
  Future<Uint8List> download(
          {required String bucket,
          required String region,
          required String key}) async =>
      objects[key] ?? (throw const ReleaseDownloadException('404'));
}

late _S3 _s3;

/// The controller the screen got.
late _Update _update;

class _Store implements FirmwareLibraryStore {
  _Store(this.files);
  final Map<String, Uint8List> files;

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

const _board = '7C:4F:AD:AE:85:90';
const _root = '5A:46:52:00:00:01';
const _siren = '5A:46:52:00:00:02';
const _button = '5A:46:52:00:00:03';
const _leaf = '5A:46:52:00:00:04';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final now = DateTime.now().toUtc();

  TopologyNode node(String mac, int layer, SafrNodeRole role, String? parent,
          {required int product, String? name}) =>
      TopologyNode(
        mac: mac,
        role: role,
        layer: layer,
        parentMac: parent,
        rssi: layer == 0 ? null : -62,
        batteryPct: null,
        online: true,
        lastSeenAt: now,
        alarmLatched: false,
        productCode: product,
        fwVersion: '0.1.0',
        name: name,
      );

  final mesh = <TopologyNode>[
    node(_board, 0, SafrNodeRole.root, null, product: 0x0100),
    node(_root, 1, SafrNodeRole.root, _board,
        product: 0x0201, name: 'Sirene Hall'),
    node(_siren, 2, SafrNodeRole.node, _root,
        product: 0x0201, name: 'Sirene Corredor'),
    node(_button, 2, SafrNodeRole.node, _root,
        product: 0x0202, name: 'Acionador Recepção'),
    node(_leaf, 3, SafrNodeRole.leaf, _siren,
        product: 0x0301, name: 'Detector Sala'),
  ];

  Uint8List image(String family, String version) =>
      fakeFirmware(project: 'sempreiot-$family', version: version);

  const sizes = <String, Size>{
    'tablet landscape': Size(1280, 800),
    'tablet portrait': Size(800, 1280),
    'phone portrait': Size(360, 640),
    'phone landscape': Size(640, 360),
  };

  Future<void> pump(WidgetTester tester, Size size,
      {DeviceUpdateRun? run,
      EditorRole? pinGranted,
      DeviceUpdateSource source = DeviceUpdateSource.manual}) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    // The choice the tablet remembers (Internet | Manual).
    await tester.runAsync(() => db.setMeta('ota_update_source', source.name));
    _s3 = _S3();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _Store({
      'node-0.2.0.bin': image('node', '0.2.0'),
      'node-0.1.0.bin': image('node', '0.1.0'),
      'board-0.2.0.bin': image('board', '0.2.0'),
      'leaf-0.2.0.bin': image('leaf', '0.2.0'),
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          serialProvider.overrideWith((ref) => _Port()),
          activeAlarmProvider.overrideWithValue(false),
          topologyProvider.overrideWithValue(mesh),
          safrTrafficProvider.overrideWithValue(SafrTrafficBus()),
          boardDeviceProvider.overrideWith((ref) => Stream.value(null)),
          otaPushProvider.overrideWith((ref) => _Push(ref)),
          otaPushViewProvider.overrideWithValue(const OtaPushState()),
          otaRolloutProvider.overrideWith((ref) => _Rollout(ref)),
          otaHeldOnBoardProvider.overrideWithValue(const {}),
          firmwareLibraryStoreProvider.overrideWithValue(store),
          releaseDownloaderProvider.overrideWithValue(_s3),
          appIsCentralProvider.overrideWithValue(true),
          deviceUpdateProvider
              .overrideWith((ref) => _update = _Update(ref, run)),
          if (pinGranted != null)
            otaPinGrantProvider.overrideWith((ref) => pinGranted),
        ],
        child: const MaterialApp(home: DeviceUpdateScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// The screen leaves; its clock and the map's timers stop.
  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  DeviceUpdateUnit unit(String key, SafrProductFamily f, SafrOtaUnitState s,
          {int percent = 0, String version = '0.1.0', int reason = 0}) =>
      DeviceUpdateUnit(
        key: key,
        family: f,
        state: s,
        percent: percent,
        attempts: s == SafrOtaUnitState.failed ? 2 : 1,
        reasonRaw: reason,
        versionBefore: '0.1.0',
        version: version,
      );

  DeviceUpdateRun allRun(DeviceUpdateStage stage,
          {SafrOtaUnitState siren = SafrOtaUnitState.downloading,
          DeviceUpdateEnd? end}) =>
      DeviceUpdateRun(
        all: true,
        phases: const [
          SafrProductFamily.board,
          SafrProductFamily.node,
          SafrProductFamily.leaf,
        ],
        phase: 1,
        target: '0.2.0',
        queues: const {
          SafrProductFamily.board: [deviceUpdateBoardKey],
          SafrProductFamily.node: [_button, _siren, _root],
          SafrProductFamily.leaf: [_leaf],
        },
        units: {
          deviceUpdateBoardKey: unit(deviceUpdateBoardKey,
              SafrProductFamily.board, SafrOtaUnitState.done,
              version: '0.2.0'),
          _button: unit(_button, SafrProductFamily.node, SafrOtaUnitState.done,
              version: '0.2.0'),
          _siren: unit(_siren, SafrProductFamily.node, siren,
              percent: 43, reason: SafrOtaReason.selftestFail.wire),
          _root: unit(_root, SafrProductFamily.node, SafrOtaUnitState.waiting),
          _leaf: unit(_leaf, SafrProductFamily.leaf, SafrOtaUnitState.waiting),
        },
        stage: stage,
        end: end,
        startedAt: DateTime.now().subtract(const Duration(minutes: 2)),
      );

  for (final s in sizes.entries) {
    testWidgets('nothing running: the map, the strip and the bar — ${s.key}',
        (tester) async {
      await pump(tester, s.value);
      expect(tester.takeException(), isNull);
      expect(find.text('Atualizar dispositivos'), findsOneWidget);
      expect(find.text('CENTRAL'), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-node')), findsOneWidget);
      expect(find.byKey(const ValueKey('update-all')), findsOneWidget);
      expect(find.text('ATIVOS'), findsOneWidget, reason: 'Rede\'s strip');
    });

    testWidgets('a run: pill, phases, the unit\'s ring — ${s.key}',
        (tester) async {
      await pump(tester, s.value, run: allRun(DeviceUpdateStage.rolling));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('FASE 2 DE 3 · NÓS · ATUALIZANDO · 1 DE 3'),
          findsOneWidget);
      expect(find.byKey(const ValueKey('phase-stepper')), findsOneWidget);
      expect(find.textContaining('1 de 3 nós atualizados'), findsOneWidget);
      expect(find.byKey(const ValueKey('ota-unit-ring')), findsOneWidget);
      expect(find.text('Pausar'), findsOneWidget);
      expect(find.text('Cancelar'), findsOneWidget);
      await leave(tester);
    });
  }

  testWidgets('a tap chooses a unit; another family replaces the choice',
      (tester) async {
    await pump(tester, const Size(1280, 800));

    await tester.tap(find.text('Sirene Corredor'));
    await tester.pump();
    expect(find.text('1 nó selecionado'), findsOneWidget);
    expect(find.byKey(const ValueKey('update-selected')), findsOneWidget);

    await tester.tap(find.text('Acionador Recepção'));
    await tester.pump();
    expect(find.text('2 nós selecionados'), findsOneWidget);

    await tester.tap(find.text('Detector Sala'));
    await tester.pump();
    expect(find.text('1 detector selecionado'), findsOneWidget);
    expect(find.textContaining('Um tipo de firmware por vez'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('quick-node')));
    await tester.pump();
    expect(find.text('3 nós selecionados'), findsOneWidget);
    expect(find.byKey(const ValueKey('update-selected')), findsNWidgets(3));

    await tester.tap(find.text('Limpar'));
    await tester.pump();
    expect(find.byKey(const ValueKey('update-all')), findsOneWidget);
  });

  testWidgets('"Atualizar": the newest firmware of that family, pre-chosen',
      (tester) async {
    await pump(tester, const Size(1280, 800));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('quick-node')));
    await tester.pump();
    await tester.tap(find.text('Atualizar'));
    await settle(tester);

    expect(find.text('Atualizar 3 nós'), findsOneWidget);
    expect(find.text('MAIS NOVO'), findsOneWidget);
    expect(find.text('É a versão que eles já rodam'), findsOneWidget);
    expect(find.text('Atualizar para v0.2.0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<void> openUpdateSheet(WidgetTester tester) async {
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('quick-node')));
    await tester.pump();
    await tester.tap(find.text('Atualizar'));
    await settle(tester);
  }

  /// The catalog ota_release.sh would announce: [version] of the three
  /// families, published (its images in the fake S3).
  Future<void> publish(WidgetTester tester, String version) async {
    final images = <String, Object?>{};
    for (final f in const ['board', 'node', 'leaf']) {
      final bytes = image(f, version);
      final key = 'bench/$version/$f-$version.bin';
      _s3.objects[key] = bytes;
      images[f] = {
        'key': key,
        'size': bytes.length,
        'sha256': crypto.sha256.convert(bytes).toString(),
        'project': 'sempreiot-$f',
      };
    }
    final container = ProviderScope.containerOf(
        tester.element(find.byType(DeviceUpdateScreen)));
    await tester.runAsync(() async {
      container.read(firmwareReleasesProvider.notifier).onMessage(
          MqttMessageEntity(
            topic: firmwareCatalogTopic(otaReleaseChannel),
            payload: jsonEncode({
              'v': 1,
              'channel': 'bench',
              'bucket': 'sempreiot-releases',
              'region': 'us-east-1',
              'releases': [
                {
                  'version': version,
                  'published': '2026-10-05T16:00:00Z',
                  'published_by': {'who': 'tallesaugusto'},
                  'notes': 'Leaf: new parent on the same wake',
                  'images': images,
                }
              ],
            }),
          ),
          null);
      await container.read(firmwareReleasesProvider.notifier).syncNewest();
    });
    await settle(tester);
  }

  for (final s in sizes.entries) {
    testWidgets('Internet: the switch and what is published — ${s.key}',
        (tester) async {
      await pump(tester, s.value, source: DeviceUpdateSource.internet);
      await settle(tester);
      expect(find.byKey(const ValueKey('update-source')), findsOneWidget);
      expect(find.text('Aguardando a lista de versões da internet…'),
          findsOneWidget);
      await publish(tester, '0.3.4');
      expect(find.text('5 dispositivos com atualização para v0.3.4'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Internet: the published versions, no file to choose',
      (tester) async {
    await pump(tester, const Size(1280, 800),
        source: DeviceUpdateSource.internet, pinGranted: EditorRole.admin);
    await settle(tester);
    await publish(tester, '0.3.4');
    await openUpdateSheet(tester);

    expect(find.text('VERSÕES PUBLICADAS NA INTERNET'), findsOneWidget);
    expect(find.text('MAIS NOVO'), findsOneWidget);
    expect(find.text('Procurar no tablet'), findsNothing);
    expect(find.textContaining('publicado por tallesaugusto'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-confirm')));
    await settle(tester);
    expect(_update.starts, [(SafrProductFamily.node, '0.3.4', 'admin')]);
    expect(_update.sources, [DeviceUpdateSource.internet]);
  });

  testWidgets('Manual: today\'s files, chosen on the tablet', (tester) async {
    await pump(tester, const Size(1280, 800),
        source: DeviceUpdateSource.internet);
    await settle(tester);
    await tester.tap(find.text('Manual'));
    await settle(tester);
    expect(find.text('Aguardando a lista de versões da internet…'),
        findsNothing);
    await openUpdateSheet(tester);
    expect(find.text('FIRMWARE NO TABLET'), findsOneWidget);
    expect(find.text('Procurar no tablet'), findsOneWidget);
  });

  testWidgets('an update starts only after the PIN', (tester) async {
    await pump(tester, const Size(1280, 800));
    await openUpdateSheet(tester);
    await tester.tap(find.byKey(const ValueKey('update-confirm')));
    await settle(tester);

    expect(find.text('Acesso restrito'), findsWidgets);
    expect(find.textContaining('PIN Master ou de Nível 4'), findsOneWidget);
    expect(_update.starts, isEmpty);
  });

  testWidgets('the PIN given once in this session is not asked again (bench)',
      (tester) async {
    expect(otaPinOncePerSession, isTrue,
        reason: 'before-production item 8: production asks every time');
    await pump(tester, const Size(1280, 800), pinGranted: EditorRole.admin);
    await openUpdateSheet(tester);
    await tester.tap(find.byKey(const ValueKey('update-confirm')));
    await settle(tester);

    expect(find.text('Acesso restrito'), findsNothing);
    expect(_update.starts, [(SafrProductFamily.node, '0.2.0', 'admin')]);
  });

  testWidgets('the version they run can be chosen: "Reinstalar", asked first',
      (tester) async {
    await pump(tester, const Size(1280, 800));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('quick-node')));
    await tester.pump();
    await tester.tap(find.text('Atualizar'));
    await settle(tester);

    expect(find.text('REINSTALAR'), findsOneWidget);
    await tester.tap(find.text('É a versão que eles já rodam'));
    await tester.pump();
    expect(find.text('Reinstalar v0.1.0'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-confirm')));
    await settle(tester);
    expect(find.text('Reinstalar a mesma versão?'), findsOneWidget);
    await tester.tap(find.text('Voltar'));
    await settle(tester);
    expect(find.text('Reinstalar a mesma versão?'), findsNothing);
    expect(find.text('Atualizar 3 nós'), findsOneWidget,
        reason: 'nothing started; the sheet is still open');
    expect(tester.takeException(), isNull);
  });

  for (final sz in sizes.entries) {
    testWidgets(
        '"Atualizar tudo": the newest image of each family, in phases '
        '(${sz.key})', (tester) async {
      await pump(tester, sz.value);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('update-all')));
      await settle(tester);

      expect(find.text('A VERSÃO MAIS NOVA DE CADA, NO TABLET'), findsOneWidget);
      expect(find.text('Placa'), findsWidgets);
      expect(find.text('Nós (3)'), findsOneWidget);
      expect(find.text('Detectores (1)'), findsOneWidget);
      // node-0.1.0 and node-0.2.0 are on the tablet: the newer goes.
      expect(find.text('→ v0.2.0'), findsNWidgets(3));
      expect(find.text('3 de 3 atualizam'), findsOneWidget);
      final confirm = tester.widget<FilledButton>(
          find.byKey(const ValueKey('update-confirm')));
      expect(confirm.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await leave(tester);
    });

    testWidgets('Firmwares no tablet: listed by family, one removed (${sz.key})',
        (tester) async {
      await pump(tester, sz.value);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('firmware-library')));
      await settle(tester);

      expect(find.text('Firmwares no tablet'), findsOneWidget);
      expect(find.text('MAIS NOVO'), findsNWidgets(3));
      final remove =
          find.byKey(const ValueKey('firmware-remove-node-0.1.0.bin'));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('firmware-remove-confirm')));
      await settle(tester);

      expect(find.byKey(const ValueKey('firmware-remove-node-0.1.0.bin')),
          findsNothing);
      expect(find.byKey(const ValueKey('firmware-remove-node-0.2.0.bin')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await leave(tester);
    });
  }

  testWidgets('the board restarted: it waits for the mesh, and says so',
      (tester) async {
    final r =
        allRun(DeviceUpdateStage.reconnecting, siren: SafrOtaUnitState.waiting);
    // Heard after the restart: none of the nodes yet (the mesh's frames
    // are all older than now).
    await pump(tester, const Size(1280, 800),
        run: r.copyWith(boardRestartedAt: DateTime.now().toUtc()));
    expect(find.textContaining('FASE 2 DE 3 · NÓS · AGUARDANDO A REDE'),
        findsOneWidget);
    expect(
        find.textContaining(
            'a placa reiniciou: aguardando os nós voltarem · 0 de 3'),
        findsOneWidget);
    expect(find.text('Cancelar'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await leave(tester);
  });

  testWidgets('a node failed: tentar de novo, parar aqui, continuar',
      (tester) async {
    await pump(tester, const Size(1280, 800),
        run:
            allRun(DeviceUpdateStage.deciding, siren: SafrOtaUnitState.failed));
    // Every node not updated is named: the one that failed and the root
    // the board never reached.
    expect(
        find.text('2 nós não foram atualizados: Sirene Corredor, Sirene Hall'),
        findsOneWidget);
    expect(find.text('Tentar de novo (2)'), findsOneWidget);
    expect(find.text('Parar aqui'), findsOneWidget);
    expect(find.text('Continuar'), findsOneWidget);
    expect(find.text('AGUARDANDO SUA DECISÃO'), findsOneWidget);
    await leave(tester);
  });

  testWidgets('it ended: a tap on the failed unit says why', (tester) async {
    await pump(tester, const Size(1280, 800),
        run: allRun(DeviceUpdateStage.ended,
            siren: SafrOtaUnitState.failed, end: DeviceUpdateEnd.stopped));
    expect(find.text('Parado antes dos detectores'), findsOneWidget);
    expect(find.text('Concluir'), findsOneWidget);

    await tester.tap(find.text('Sirene Corredor'));
    await settle(tester);
    expect(find.textContaining('não passou no autoteste'), findsOneWidget);
    expect(find.text('2 tentativas'), findsOneWidget);
  });
}
