import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/alarm_latch_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_board_events_provider.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_controller.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_state.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_controller.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_state.dart';
import 'package:sempreiot_central_app/features/central/application/root_election_provider.dart';
import 'package:sempreiot_central_app/features/central/application/serial_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/firmware_update_screen.dart';

/// "Atualização de firmware", the part that sends the image the board holds
/// to the units (protocol §13.6): the form, the confirmation, the header,
/// the table, the buttons — tablet and phone, portrait and landscape.
class _Push extends OtaPushController {
  _Push(super.ref, OtaPushState initial) {
    state = initial;
  }
}

/// The rollout as the screen sees it: a state, and what was asked of it.
class _Rollout extends OtaRolloutController {
  _Rollout(super.ref, OtaRolloutState initial) {
    state = initial;
  }

  int refreshes = 0;
  String? blocker;
  String? refusal;
  final started = <(SafrProductFamily, SafrOtaFilter, int?)>[];
  final steered = <String>[];

  void show(OtaRolloutState s) => state = s;

  @override
  Future<void> refresh() async => refreshes++;

  @override
  Future<String?> startBlocker(SafrProductFamily family) async => blocker;

  @override
  Future<String?> start(
    SafrProductFamily family,
    SafrOtaFilter filter, {
    int? expected,
    String? filterText,
  }) async {
    started.add((family, filter, expected));
    return refusal;
  }

  @override
  Future<String?> pause(SafrProductFamily family) async {
    steered.add('pause');
    return refusal;
  }

  @override
  Future<String?> resume(SafrProductFamily family) async {
    steered.add('resume');
    return refusal;
  }

  @override
  Future<String?> abort(SafrProductFamily family) async {
    steered.add('abort');
    return refusal;
  }
}

class _Port extends SerialNotifier {
  _Port() : super.detached();

  @override
  Future<bool> portWrite(Uint8List bytes) async => true;

  @override
  Future<bool> portSetBaud(int baud) async => true;
}

class _Root extends RootElectionNotifier {
  _Root(super.db, String? root) {
    state = RootElectionState(
        rootMac: root, candidates: {if (root != null) root});
  }

  @override
  void tick() {}
}

const _boardMac = '7C:4F:AD:AE:85:90';
const _root = '5A:46:52:00:00:01';
const _siren = '5A:46:52:00:00:02';
const _button = '5A:46:52:00:00:03';
const _io = '5A:46:52:00:00:04';
const _old = '5A:46:52:00:00:05';
const _leaf = '5A:46:52:00:00:06';

const node = SafrProductFamily.node;
const leaf = SafrProductFamily.leaf;

TopologyNode _unit(
  String mac, {
  int layer = 2,
  SafrNodeRole role = SafrNodeRole.node,
  String? name,
  String? zone,
  int? productCode,
  String? fw = '0.1.0',
  bool online = true,
}) =>
    TopologyNode(
      mac: mac,
      role: role,
      layer: layer,
      parentMac: null,
      rssi: -60,
      batteryPct: null,
      online: online,
      lastSeenAt: DateTime.now().toUtc(),
      alarmLatched: false,
      name: name,
      zone: zone,
      productCode: productCode,
      fwVersion: fw,
    );

final _mesh = <TopologyNode>[
  _unit(_boardMac,
      layer: 0, role: SafrNodeRole.root, productCode: 0x0100, fw: '0.2.0'),
  _unit(_root,
      layer: 1,
      role: SafrNodeRole.root,
      name: 'Repetidor escada',
      zone: 'Térreo',
      productCode: 0x0204),
  _unit(_siren, name: 'Sirene hall', zone: 'Térreo', productCode: 0x0201),
  _unit(_button,
      name: 'Botoeira garagem', zone: 'Garagem', productCode: 0x0202),
  _unit(_io,
      name: 'Módulo bombas',
      zone: 'Garagem',
      productCode: 0x0203,
      online: false),
  _unit(_old, fw: null), // never said what it is
  _unit(_leaf,
      role: SafrNodeRole.leaf,
      layer: 3,
      name: 'Detector sala',
      productCode: 0x0301),
];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const sizes = <String, Size>{
    'tablet landscape': Size(1280, 800),
    'tablet portrait': Size(800, 1280),
    'phone portrait': Size(360, 640),
    'phone landscape': Size(640, 360),
  };

  final t0 = DateTime(2026, 9, 29, 14, 3, 20);

  OtaRolloutUnit row(
    String mac,
    SafrOtaUnitState s, {
    int product = 0x0201,
    int percent = 0,
    int attempts = 0,
    int reason = 0,
    String version = '0.1.0',
    String? before = '0.1.0',
  }) =>
      OtaRolloutUnit(
        mac: mac,
        productCode: product,
        state: s,
        percent: percent,
        attempts: attempts,
        reasonRaw: reason,
        version: version,
        versionBefore: before,
        changedAt: t0,
        activeSince: s.active ? DateTime.now() : null,
      );

  OtaRolloutState staged({Map<SafrProductFamily, String>? held}) =>
      OtaRolloutState(
        boardAnswered: true,
        families: {
          for (final e
              in (held ?? const {SafrProductFamily.node: '0.2.0'}).entries)
            e.key: OtaFamilyRollout(
              family: e.key,
              state: SafrOtaRolloutState.staged,
              target: e.value,
              updatedAt: t0,
            ),
        },
      );

  OtaRolloutState rolling({
    SafrOtaRolloutState state = SafrOtaRolloutState.rolling,
    OtaPauseCause? cause,
    List<OtaRolloutUnit>? units,
    DateTime? startedAt,
    bool exact = true,
    DateTime? endedAt,
    List<OtaLogLine> log = const [],
  }) {
    final rows = units ??
        [
          row(_root, SafrOtaUnitState.waiting, product: 0x0204),
          row(_siren, SafrOtaUnitState.done, version: '0.2.0'),
          row(_button, SafrOtaUnitState.downloading,
              product: 0x0202, percent: 40),
        ];
    return OtaRolloutState(
      boardAnswered: true,
      log: log,
      families: {
        node: OtaFamilyRollout(
          family: node,
          state: state,
          target: '0.2.0',
          total: rows.length,
          units: rows,
          updatedAt: DateTime.now(),
          startedAt: startedAt ??
              DateTime.now().subtract(const Duration(seconds: 125)),
          startedAtExact: exact,
          endedAt: endedAt,
          pauseCause: cause,
        ),
      },
    );
  }

  late _Rollout rollout;

  Future<void> pump(
    WidgetTester tester,
    Size size,
    OtaRolloutState state, {
    OtaPushState push = const OtaPushState(),
    bool linkUp = true,
    bool alarm = false,
    List<TopologyNode>? nodes,
    String? root = _root,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final port = _Port();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          serialProvider.overrideWith((ref) => port),
          activeAlarmProvider.overrideWithValue(alarm),
          boardDeviceProvider.overrideWith((ref) => Stream.value(null)),
          topologyProvider.overrideWithValue(nodes ?? _mesh),
          rootElectionProvider.overrideWith((ref) => _Root(db, root)),
          otaPushProvider.overrideWith((ref) => _Push(ref, push)),
          otaRolloutProvider
              .overrideWith((ref) => rollout = _Rollout(ref, state)),
        ],
        child: const MaterialApp(home: FirmwareUpdateScreen()),
      ),
    );
    if (linkUp) {
      port.debugSetConnected(true);
      port.debugReceive(SafrEncoder(bootCtr: 1).encode(
        msgType: SafrMsgType.heartbeat,
        payload: Uint8List(SafrTimeSyncPayload.wireLength),
      ));
    }
    await tester.pump(const Duration(milliseconds: 50));
    // The link status looks at the port once a second.
    await tester.pump(const Duration(milliseconds: 1100));
  }

  Future<void> reveal(WidgetTester tester, Finder f) async {
    final list = find.byType(Scrollable).first;
    if (f.evaluate().isEmpty) {
      // Not built: it may be above. From the top, then.
      tester.state<ScrollableState>(list).position.jumpTo(0);
      await tester.pump();
    }
    await tester.scrollUntilVisible(f, 120, scrollable: list);
    // Built is not yet on the screen: bring all of it in.
    await Scrollable.ensureVisible(tester.element(f), alignment: 0.5);
    await tester.pump();
  }

  /// The whole page, top to bottom: anything that does not fit throws.
  Future<void> walk(WidgetTester tester) async {
    final list = find.byType(Scrollable).first;
    for (var i = 0; i < 40; i++) {
      await tester.drag(list, const Offset(0, -260));
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  }

  const card = ValueKey('ota-rollout-node');
  const leafCard = ValueKey('ota-rollout-leaf');
  Finder inCard(Finder f, [Key key = card]) =>
      find.descendant(of: find.byKey(key), matching: f);
  Finder inRow(String mac, Finder f) => find.descendant(
      of: find.byKey(ValueKey('ota-rollout-row-$mac')), matching: f);

  group('what the board holds', () {
    for (final s in sizes.entries) {
      testWidgets('a staged image and the form to send it — ${s.key}',
          (tester) async {
        await pump(tester, s.value, staged());
        expect(rollout.refreshes, 1, reason: 'asked when the screen opens');

        await reveal(tester, find.text('DISPOSITIVOS'));
        await reveal(tester,
            find.text('Na placa: firmware de rede elétrica 0.2.0'));
        await reveal(
            tester,
            find.text('Guardado na placa. Nenhum dispositivo recebeu esta '
                'versão ainda.'));
        await reveal(tester, find.text('ENVIAR AOS DISPOSITIVOS'));
        for (final chip in const [
          'Todos',
          'Por produto',
          'Por zona',
          'Um dispositivo',
        ]) {
          await reveal(tester, inCard(find.text(chip)));
        }
        // Three are online and said their product; one is silent; one never
        // said what it is. The battery detector is of another family.
        await reveal(
            tester,
            find.text('3 dispositivos receberão a versão 0.2.0, um de cada '
                'vez.'));
        await reveal(tester,
            find.text('1 sem comunicação: não será atualizado.'));
        await reveal(
            tester,
            find.text(
                '1 não informou o produto e não será atualizado.'));
        await reveal(tester, inCard(find.text('Enviar aos dispositivos')));
        // Above it, what the link card says of it.
        await reveal(
            tester,
            find.text('firmware de rede elétrica 0.2.0 · ainda não enviado '
                'aos dispositivos'));
        await walk(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the battery image: stored, and the button says why not — '
          '${s.key}', (tester) async {
        await pump(tester, s.value,
            staged(held: const {node: '0.2.0', leaf: '0.3.1'}));
        await reveal(
            tester, find.text('Na placa: firmware de bateria 0.3.1'));
        await reveal(
            tester,
            find.text('Os detectores a bateria serão atualizados em uma '
                'etapa futura. A imagem fica guardada na placa até lá.'));
        final button = tester.widget<FilledButton>(find.ancestor(
          of: inCard(find.text('Enviar aos dispositivos'), leafCard),
          matching: find.byType(FilledButton),
        ));
        expect(button.onPressed, isNull);
        // No filter to choose: nothing can be sent.
        expect(inCard(find.text('Todos'), leafCard), findsNothing);
        await walk(tester);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('nothing held: no section at all', (tester) async {
      await pump(tester, const Size(800, 1280),
          const OtaRolloutState(boardAnswered: true));
      expect(find.text('DISPOSITIVOS'), findsNothing);
      expect(find.byKey(card), findsNothing);
      expect(find.text('Guardado na placa'), findsNothing);
    });

    testWidgets('a board that never answered: what this session stored',
        (tester) async {
      await pump(
        tester,
        const Size(800, 1280),
        const OtaRolloutState(boardAnswered: false),
        push: const OtaPushState(storedOnBoard: {node: '0.2.0'}),
      );
      await reveal(
          tester, find.text('Na placa: firmware de rede elétrica 0.2.0'));
      await reveal(
          tester,
          find.text('A placa não informou o que guarda: isto é o que este '
              'tablet enviou a ela nesta sessão.'));
      await reveal(tester, inCard(find.text('Enviar aos dispositivos')));
    });

    testWidgets('the board\'s word wins over the session\'s memory',
        (tester) async {
      await pump(
        tester,
        const Size(800, 1280),
        staged(held: const {node: '0.2.1'}),
        push: const OtaPushState(storedOnBoard: {node: '0.2.0'}),
      );
      await reveal(
          tester, find.text('Na placa: firmware de rede elétrica 0.2.1'));
      expect(find.textContaining('0.2.0 · ainda não enviado'), findsNothing);
    });
  });

  group('sending', () {
    Future<void> send(WidgetTester tester) async {
      final button = inCard(find.text('Enviar aos dispositivos'));
      await reveal(tester, button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    for (final s in sizes.entries) {
      testWidgets('to all: the question names how many, one at a time, the '
          'root last — ${s.key}', (tester) async {
        await pump(tester, s.value, staged());
        await send(tester);

        expect(find.text('Atualizar 3 dispositivos?'), findsOneWidget);
        final said = tester
            .widget<Text>(find.descendant(
              of: find.byType(AlertDialog),
              matching: find.textContaining('A placa vai enviar'),
            ))
            .data!;
        expect(said, contains('firmware de rede elétrica 0.2.0'));
        expect(said, contains('a 3 dispositivos'));
        expect(said, contains('todos os dispositivos'));
        expect(said, contains('Eles reiniciam um de cada vez'));
        expect(said,
            contains('Repetidor escada é o root da malha e é atualizado por '
                'último'));
        expect(said, contains('Se um alarme acontecer'));
        expect(tester.takeException(), isNull);
        expect(rollout.started, isEmpty, reason: 'not before the yes');

        await tester.tap(find.text('Atualizar 3 dispositivos'));
        await tester.pumpAndSettle();
        expect(rollout.started, [(node, const SafrOtaFilter.all(), 3)]);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the operator says no: nothing is asked of the board',
        (tester) async {
      await pump(tester, const Size(800, 1280), staged());
      await send(tester);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(rollout.started, isEmpty);
    });

    testWidgets('by product: the products that are there, with how many',
        (tester) async {
      await pump(tester, const Size(360, 640), staged());
      await reveal(tester, inCard(find.text('Por produto')));
      await tester.tap(inCard(find.text('Por produto')));
      await tester.pump();
      // The first product there is, in code order.
      await reveal(tester, find.text('Sirene · 1'));
      await reveal(
          tester,
          find.text(
              '1 dispositivo receberá a versão 0.2.0, um de cada vez.'));

      await tester.tap(find.text('Sirene · 1'));
      await tester.pumpAndSettle();
      for (final p in const [
        'Acionador manual · 1',
        'Módulo de E/S · 1',
        'Repetidor · 1',
      ]) {
        expect(find.text(p), findsWidgets);
      }
      await tester.tap(find.text('Repetidor · 1').last);
      await tester.pumpAndSettle();

      await send(tester);
      expect(find.text('Atualizar 1 dispositivo?'), findsOneWidget);
      final said = tester
          .widget<Text>(find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('A placa vai enviar'),
          ))
          .data!;
      expect(said, contains('a 1 dispositivo (produto Repetidor (0x0204))'));
      expect(said, contains('Ele reinicia'));
      await tester.tap(find.text('Atualizar 1 dispositivo'));
      await tester.pumpAndSettle();
      expect(rollout.started, [
        (node, const SafrOtaFilter.product(0x0204), 1),
      ]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('by zone', (tester) async {
      await pump(tester, const Size(640, 360), staged());
      await reveal(tester, inCard(find.text('Por zona')));
      await tester.tap(inCard(find.text('Por zona')));
      await tester.pump();
      // Garagem: the push button, and the I/O module that is silent.
      await reveal(tester, find.text('Garagem · 2'));
      await reveal(
          tester,
          find.text(
              '1 dispositivo receberá a versão 0.2.0, um de cada vez.'));
      await reveal(tester,
          find.text('1 sem comunicação: não será atualizado.'));
      await send(tester);
      await tester.tap(find.text('Atualizar 1 dispositivo'));
      await tester.pumpAndSettle();
      expect(rollout.started, [
        (node, const SafrOtaFilter.zone('Garagem'), 1),
      ]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('one unit; one that is silent cannot be sent to',
        (tester) async {
      await pump(tester, const Size(360, 640), staged());
      await reveal(tester, inCard(find.text('Um dispositivo')));
      await tester.tap(inCard(find.text('Um dispositivo')));
      await tester.pump();
      await reveal(tester, find.text('Botoeira garagem'));
      await tester.tap(find.text('Botoeira garagem'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Módulo bombas (sem comunicação)').last);
      await tester.pumpAndSettle();
      await reveal(
          tester,
          find.text(
              'Nenhum dispositivo online para receber a versão 0.2.0.'));
      final button = tester.widget<FilledButton>(find.ancestor(
        of: inCard(find.text('Enviar aos dispositivos')),
        matching: find.byType(FilledButton),
      ));
      expect(button.onPressed, isNull);

      await tester.tap(find.text('Módulo bombas (sem comunicação)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sirene hall').last);
      await tester.pumpAndSettle();
      await send(tester);
      await tester.tap(find.text('Atualizar 1 dispositivo'));
      await tester.pumpAndSettle();
      expect(rollout.started, [(node, const SafrOtaFilter.unit(_siren), 1)]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an alarm is latched: the button is off and says why',
        (tester) async {
      await pump(tester, const Size(360, 640), staged(), alarm: true);
      await reveal(
          tester,
          inCard(find.text('Há alarme ativo. Rearme a central antes de '
              'atualizar os dispositivos.')));
      final button = tester.widget<FilledButton>(find.ancestor(
        of: inCard(find.text('Enviar aos dispositivos')),
        matching: find.byType(FilledButton),
      ));
      expect(button.onPressed, isNull);
    });

    testWidgets('the cable is out: the button is off and says why',
        (tester) async {
      await pump(tester, const Size(360, 640), staged(), linkUp: false);
      await reveal(
          tester,
          inCard(find.text(
              'A placa não está respondendo. Verifique o cabo USB.')));
      final button = tester.widget<FilledButton>(find.ancestor(
        of: inCard(find.text('Enviar aos dispositivos')),
        matching: find.byType(FilledButton),
      ));
      expect(button.onPressed, isNull);
    });

    testWidgets('the board refuses: the operator is told why',
        (tester) async {
      await pump(tester, const Size(800, 1280), staged());
      rollout.refusal = 'A placa recusou: houve alarme nos últimos 10 '
          'minutos. Tente de novo depois.';
      await send(tester);
      await tester.tap(find.text('Atualizar 3 dispositivos'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(rollout.refusal!), findsOneWidget);
    });
  });

  group('while it rolls', () {
    for (final s in sizes.entries) {
      testWidgets('header, table and buttons — ${s.key}', (tester) async {
        await pump(tester, s.value, rolling());

        await reveal(tester, find.byKey(const ValueKey('ota-rollout-headline')));
        expect(inCard(find.text('ENVIANDO')), findsOneWidget);
        final counts = tester
            .widget<Text>(find.byKey(const ValueKey('ota-rollout-counts')))
            .data!;
        expect(counts, startsWith('1 de 3 atualizado · há 2 min 0'));

        // One row per unit, in the order of the board's table.
        await reveal(tester, find.byKey(const ValueKey('ota-rollout-table')));
        await reveal(tester, inRow(_root, find.text('Repetidor escada')));
        expect(inRow(_root, find.text('Repetidor')), findsOneWidget);
        expect(inRow(_root, find.text('0.1.0 → 0.2.0')), findsOneWidget);
        expect(inRow(_root, find.text('Aguardando · por último')),
            findsOneWidget);
        expect(inRow(_root, find.text('ROOT · POR ÚLTIMO')), findsOneWidget);

        await reveal(tester, inRow(_siren, find.text('Sirene hall')));
        expect(inRow(_siren, find.text('Sirene')), findsOneWidget);
        expect(inRow(_siren, find.text('0.1.0 → 0.2.0')), findsOneWidget);
        expect(inRow(_siren, find.text('Atualizado')), findsOneWidget);

        await reveal(tester, inRow(_button, find.text('Botoeira garagem')));
        expect(inRow(_button, find.text('Acionador manual')), findsOneWidget);
        expect(inRow(_button, find.text('Baixando 40 %')), findsOneWidget);
        final bar = tester.widget<LinearProgressIndicator>(
            inRow(_button, find.byType(LinearProgressIndicator)));
        expect(bar.value, closeTo(0.4, 1e-9));

        // It runs: what can be done is pause and cancel, not send.
        await reveal(tester, inCard(find.text('Pausar')));
        await reveal(tester, inCard(find.text('Cancelar')));
        expect(inCard(find.text('Retomar')), findsNothing);
        expect(inCard(find.text('Enviar aos dispositivos')), findsNothing);
        expect(find.byKey(const ValueKey('ota-rollout-failures')),
            findsNothing);
        await reveal(
            tester,
            find.text('firmware de rede elétrica 0.2.0 · sendo enviado aos '
                'dispositivos'));

        await reveal(tester, inCard(find.text('Pausar')));
        await tester.tap(inCard(find.text('Pausar')));
        await tester.pump();
        expect(rollout.steered, ['pause']);
        await walk(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgets('paused by an alarm — ${s.key}', (tester) async {
        await pump(
          tester,
          s.value,
          rolling(
            state: SafrOtaRolloutState.paused,
            cause: OtaPauseCause.alarm,
          ),
          alarm: true,
        );
        await reveal(tester, inCard(find.text('PAUSADO POR ALARME')));
        await reveal(
            tester,
            find.textContaining('Um alarme pausou a atualização. O '
                'dispositivo que estava baixando termina'));
        await reveal(tester, inCard(find.text('Retomar')));
        expect(inCard(find.text('Pausar')), findsNothing);
        await tester.tap(inCard(find.text('Retomar')));
        await tester.pump();
        expect(rollout.steered, ['resume']);
        await walk(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgets('cancel asks first — ${s.key}', (tester) async {
        await pump(tester, s.value, rolling());
        await reveal(tester, inCard(find.text('Cancelar')));
        await tester.tap(inCard(find.text('Cancelar')));
        await tester.pumpAndSettle();

        expect(find.text('Cancelar a atualização?'), findsOneWidget);
        expect(
          find.textContaining('O dispositivo que está sendo atualizado agora '
              'termina a sua atualização. O dispositivo que ainda aguarda '
              'não será atualizado.'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Continuar atualizando'));
        await tester.pumpAndSettle();
        expect(rollout.steered, isEmpty);

        await tester.tap(inCard(find.text('Cancelar')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancelar a atualização'));
        await tester.pumpAndSettle();
        expect(rollout.steered, ['abort']);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('paused by the operator, and by nobody the tablet knows of',
        (tester) async {
      await pump(
        tester,
        const Size(800, 1280),
        rolling(
          state: SafrOtaRolloutState.paused,
          cause: OtaPauseCause.operator,
        ),
      );
      await reveal(tester, inCard(find.text('PAUSADO')));
      await reveal(tester, find.textContaining('Pausado por você.'));

      rollout.show(rolling(
        state: SafrOtaRolloutState.paused,
        cause: OtaPauseCause.unknown,
      ));
      await tester.pump();
      await reveal(tester, find.textContaining('A placa pausou a atualização'));
    });

    testWidgets('learned in the middle: for how long is "at least"',
        (tester) async {
      await pump(tester, const Size(800, 1280), rolling(exact: false));
      await reveal(tester, find.byKey(const ValueKey('ota-rollout-counts')));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('ota-rollout-counts')))
            .data,
        contains('há pelo menos 2 min 0'),
      );
    });

    testWidgets('the states, in words', (tester) async {
      await pump(
        tester,
        const Size(800, 1280),
        rolling(units: [
          row(_root, SafrOtaUnitState.offered, product: 0x0204),
          row(_siren, SafrOtaUnitState.verifying, percent: 100),
          row(_button, SafrOtaUnitState.rebooting,
              product: 0x0202, percent: 100, attempts: 1),
          row(_io, SafrOtaUnitState.selfTest, product: 0x0203, percent: 100),
          row(_old, SafrOtaUnitState.skipped,
              reason: 1, version: '0.2.0', before: null),
        ]),
      );
      await reveal(tester, inRow(_root, find.text('Oferta enviada')));
      // The root is being updated: it is not waiting for its turn any more.
      expect(inRow(_root, find.text('ROOT')), findsOneWidget);
      await reveal(tester, inRow(_siren, find.text('Verificando')));
      await reveal(tester, inRow(_button, find.text('Reiniciando')));
      expect(inRow(_button, find.text('2ª tentativa')), findsOneWidget);
      await reveal(tester, inRow(_io, find.text('Autoteste')));
      await reveal(tester, inRow(_old, find.text('Ignorado')));
      // No name: its address, whole.
      expect(inRow(_old, find.text(_old)), findsOneWidget);
      expect(
          inRow(_old,
              find.text('Já estava nesta versão ou em uma mais nova.')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a unit that failed once and waits for its second offer',
        (tester) async {
      await pump(
        tester,
        const Size(360, 640),
        rolling(units: [
          row(_siren, SafrOtaUnitState.waiting, attempts: 1, reason: 8),
          row(_button, SafrOtaUnitState.downloading,
              product: 0x0202, percent: 70),
        ]),
      );
      await reveal(tester, inRow(_siren, find.text('Aguardando')));
      expect(
        inRow(
            _siren,
            find.text('Falhou uma vez, será tentado de novo · O dispositivo '
                'não conseguiu baixar a imagem da placa.')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('when it ended', () {
    for (final s in sizes.entries) {
      testWidgets('partial: the failures together, at the end — ${s.key}',
          (tester) async {
        final started = DateTime(2026, 9, 29, 14);
        await pump(
          tester,
          s.value,
          rolling(
            state: SafrOtaRolloutState.partial,
            startedAt: started,
            endedAt: started.add(const Duration(seconds: 312)),
            units: [
              row(_root, SafrOtaUnitState.done,
                  product: 0x0204, version: '0.2.0'),
              row(_siren, SafrOtaUnitState.failed, attempts: 2, reason: 9),
              row(_button, SafrOtaUnitState.failed,
                  product: 0x0202, attempts: 2, reason: 10),
              row(_io, SafrOtaUnitState.skipped,
                  product: 0x0203, reason: 11),
            ],
          ),
        );
        await reveal(tester, inCard(find.text('PARCIAL')));
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('ota-rollout-counts')))
              .data,
          '1 de 4 atualizado · 1 ignorado · 2 com falha · em 5 min 12 s',
        );
        await reveal(tester, inRow(_siren, find.text('Falhou')));
        expect(
          inRow(
              _siren,
              find.text('2 tentativas · O novo firmware não passou no '
                  'autoteste; o dispositivo voltou à versão anterior.')),
          findsOneWidget,
        );
        await reveal(
            tester, find.byKey(const ValueKey('ota-rollout-failures')));
        Finder inFailures(Finder f) => find.descendant(
            of: find.byKey(const ValueKey('ota-rollout-failures')),
            matching: f);
        expect(inFailures(find.text('NÃO FORAM ATUALIZADOS · 2')),
            findsOneWidget);
        expect(
          inFailures(find.text('Sirene hall: O novo firmware não passou no '
              'autoteste; o dispositivo voltou à versão anterior. Continua '
              'na versão 0.1.0.')),
          findsOneWidget,
        );
        expect(
          inFailures(find.text('Botoeira garagem: O dispositivo não '
              'respondeu a tempo. Continua na versão 0.1.0.')),
          findsOneWidget,
        );
        // Cancelled before its turn is not a failure.
        expect(inFailures(find.textContaining('Módulo bombas')), findsNothing);
        await reveal(
            tester,
            inRow(
                _io,
                find.text('A atualização foi cancelada antes de chegar a '
                    'este dispositivo.')));

        // It is over: it can be sent again.
        await reveal(tester, inCard(find.text('ENVIAR DE NOVO')));
        await reveal(tester, inCard(find.text('Enviar aos dispositivos')));
        expect(inCard(find.text('Pausar')), findsNothing);
        expect(inCard(find.text('Cancelar')), findsNothing);
        await reveal(
            tester,
            find.text('firmware de rede elétrica 0.2.0 · enviado a parte dos '
                'dispositivos'));
        await walk(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgets('done — ${s.key}', (tester) async {
        final started = DateTime(2026, 9, 29, 14);
        await pump(
          tester,
          s.value,
          rolling(
            state: SafrOtaRolloutState.done,
            startedAt: started,
            endedAt: started.add(const Duration(seconds: 95)),
            units: [
              row(_root, SafrOtaUnitState.done,
                  product: 0x0204, version: '0.2.0', attempts: 1),
              row(_siren, SafrOtaUnitState.done, version: '0.2.0'),
              row(_button, SafrOtaUnitState.done,
                  product: 0x0202, version: '0.2.0', before: null),
            ],
          ),
        );
        await reveal(tester, inCard(find.text('CONCLUÍDO')));
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('ota-rollout-counts')))
              .data,
          '3 de 3 atualizados · em 1 min 35 s',
        );
        await reveal(tester, inRow(_root, find.text('Atualizado')));
        expect(inRow(_root, find.text('ROOT')), findsOneWidget);
        expect(inRow(_root, find.text('Na 2ª tentativa')), findsOneWidget);
        expect(inRow(_root, find.text('0.1.0 → 0.2.0')), findsOneWidget);
        // What it ran before is not known: what it runs.
        await reveal(tester, inRow(_button, find.text('0.2.0')));
        expect(find.byKey(const ValueKey('ota-rollout-failures')),
            findsNothing);
        await reveal(
            tester,
            find.text('firmware de rede elétrica 0.2.0 · enviado aos '
                'dispositivos'));
        await walk(tester);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a rollout that was over before the app looked: no time',
        (tester) async {
      await pump(
        tester,
        const Size(800, 1280),
        rolling(
          state: SafrOtaRolloutState.done,
          exact: false,
          units: [row(_siren, SafrOtaUnitState.done, version: '0.2.0')],
        ),
      );
      await reveal(tester, find.byKey(const ValueKey('ota-rollout-counts')));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('ota-rollout-counts')))
            .data,
        '1 de 1 atualizado',
      );
    });
  });

  group('the log', () {
    List<OtaLogLine> lines(DateTime from, List<String> text) => [
          for (var i = 0; i < text.length; i++)
            OtaLogLine(from.add(Duration(seconds: 2 * i)), text[i]),
        ];

    testWidgets('the rollout\'s lines and the push\'s, by time, and "Copiar" '
        'takes all of them', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await pump(
        tester,
        const Size(800, 1280),
        rolling(
          log: lines(t0.add(const Duration(seconds: 1)), [
            'Pedido à placa: enviar firmware de rede elétrica 0.2.0 aos '
                'dispositivos — filtro: todos os dispositivos; 3 '
                'dispositivos pelo registro do tablet',
            'Iniciar: a placa aceitou',
            'Sirene hall [$_siren] → estado: baixando 40 %',
          ]),
        ),
        push: OtaPushState(log: lines(t0, ['Resultado: guardado', 'Resumo'])),
      );
      // It rolls: the details are open.
      await reveal(tester, find.text('REGISTRO'));
      await reveal(tester, find.text('5 linhas'));
      await reveal(tester, find.text('Iniciar: a placa aceitou'));
      await reveal(tester, find.text('Copiar'));
      await tester.tap(find.text('Copiar'));
      await tester.pump();

      expect(copied!.split('\n'), [
        '14:03:20  Resultado: guardado',
        '14:03:21  Pedido à placa: enviar firmware de rede elétrica 0.2.0 '
            'aos dispositivos — filtro: todos os dispositivos; 3 '
            'dispositivos pelo registro do tablet',
        '14:03:22  Resumo',
        '14:03:23  Iniciar: a placa aceitou',
        '14:03:25  Sirene hall [$_siren] → estado: baixando 40 %',
      ]);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
