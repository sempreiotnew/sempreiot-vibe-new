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
import 'package:sempreiot_central_app/features/central/application/serial_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/core/theme/app_colors.dart';
import 'package:sempreiot_central_app/features/central/domain/ota/firmware_image.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/firmware_update_screen.dart';

import 'fake_firmware.dart';

/// The controller as the screen sees it: a state, and what was asked of it.
class _Controller extends OtaPushController {
  _Controller(super.ref, OtaPushState initial) {
    state = initial;
  }

  String? blocker;
  final started = <bool>[]; // force of every start()
  int picks = 0;
  int cancels = 0;

  @override
  Future<String?> startBlocker() async => blocker;

  @override
  Future<String?> start({bool force = false}) async {
    started.add(force);
    return null;
  }

  @override
  Future<void> pickFile() async => picks++;

  @override
  void cancel() => cancels++;
}

/// The rollout as the screen sees it: nothing of it here, and no board asked.
class _Rollout extends OtaRolloutController {
  _Rollout(super.ref);

  @override
  Future<void> refresh() async {}
}

class _Port extends SerialNotifier {
  _Port() : super.detached();

  @override
  Future<bool> portWrite(Uint8List bytes) async => true;

  @override
  Future<bool> portSetBaud(int baud) async => true;
}

FirmwareFile _file(
    {String project = 'sempreiot-board', int size = 912 * 1024}) {
  final bytes = fakeFirmware(project: project, version: '0.2.0', size: size);
  return FirmwareFile(
    name: '$project-0.2.0.bin',
    bytes: bytes,
    header: FirmwareImageHeader.parse(bytes),
    sha256: Uint8List.fromList([for (var i = 0; i < 32; i++) 0x10 + i]),
  );
}

MeshDevice _board(String fw) => MeshDevice(
      mac: '7C:4F:AD:AE:85:90',
      role: 0,
      layer: 0,
      firstSeenAt: DateTime.utc(2026, 9, 29),
      lastSeenAt: DateTime.utc(2026, 9, 29),
      lastHeartbeatAt: DateTime.utc(2026, 9, 29),
      lastBootCtr: 3,
      lastMsgCtr: 9,
      supervisionState: 0,
      lastDevSeq: 0,
      alarmLatched: 0,
      boardFlags: 0,
      productCode: 0x0100,
      fwVersion: fw,
    );

const _boardMac = '7C:4F:AD:AE:85:90';

/// A unit as the Rede map and "Versões em execução" know it.
TopologyNode _unit(
  String mac, {
  int layer = 2,
  SafrNodeRole role = SafrNodeRole.node,
  String? name,
  int? productCode,
  String? fw,
}) =>
    TopologyNode(
      mac: mac,
      role: role,
      layer: layer,
      parentMac: null,
      rssi: -60,
      batteryPct: null,
      online: true,
      lastSeenAt: DateTime.now().toUtc(),
      alarmLatched: false,
      name: name,
      productCode: productCode,
      fwVersion: fw,
    );

TopologyNode _boardUnit(String fw) => _unit(_boardMac,
    layer: 0, role: SafrNodeRole.root, productCode: 0x0100, fw: fw);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const sizes = <String, Size>{
    'tablet landscape': Size(1280, 800),
    'tablet portrait': Size(800, 1280),
    'phone portrait': Size(360, 640),
    'phone landscape': Size(640, 360),
  };

  final t0 = DateTime(2026, 9, 29, 14, 3, 20);
  List<OtaLogLine> log(List<String> lines) => [
        for (var i = 0; i < lines.length; i++)
          OtaLogLine(t0.add(Duration(seconds: i)), lines[i]),
      ];

  List<OtaStep> steps(
    FirmwareFile file,
    Map<OtaStepId, (OtaStepStatus, String?)> said,
  ) =>
      [
        for (final id in OtaStepId.values)
          if (file.family == SafrProductFamily.board ||
              (id != OtaStepId.boardRestart && id != OtaStepId.confirm))
            OtaStep(
              id,
              status: said[id]?.$1 ?? OtaStepStatus.waiting,
              startedAt: said[id] == null ? null : DateTime.now(),
              took: said[id]?.$1 == OtaStepStatus.done ||
                      said[id]?.$1 == OtaStepStatus.failed
                  ? const Duration(milliseconds: 1400)
                  : null,
              note: said[id]?.$2,
            ),
      ];

  late _Controller controller;

  Future<void> pump(
    WidgetTester tester,
    Size size,
    OtaPushState state, {
    bool linkUp = true,
    bool alarm = false,
    String boardRuns = '0.1.0',
    List<TopologyNode> units = const [],
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
          boardDeviceProvider
              .overrideWith((ref) => Stream.value(_board(boardRuns))),
          topologyProvider.overrideWithValue([_boardUnit(boardRuns), ...units]),
          otaPushProvider
              .overrideWith((ref) => controller = _Controller(ref, state)),
          otaRolloutProvider.overrideWith((ref) => _Rollout(ref)),
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

  /// "Detalhes" opens on a tap.
  Future<void> openDetails(WidgetTester tester) async {
    final header = find.text('Detalhes');
    await tester.scrollUntilVisible(header, 120,
        scrollable: find.byType(Scrollable).first);
    await Scrollable.ensureVisible(tester.element(header), alignment: 0.5);
    await tester.pump();
    await tester.tap(header);
    await tester.pump();
  }

  Future<void> reveal(WidgetTester tester, Finder f) async {
    await tester.scrollUntilVisible(f, 120,
        scrollable: find.byType(Scrollable).first);
    // Built is not yet on the screen: bring all of it in.
    await Scrollable.ensureVisible(tester.element(f), alignment: 0.5);
    await tester.pump();
  }

  group('in every size', () {
    for (final s in sizes.entries) {
      testWidgets('nothing chosen yet — ${s.key}', (tester) async {
        await pump(tester, s.value, const OtaPushState());
        expect(find.text('Atualização de firmware'), findsOneWidget);
        // Nothing was sent: no report card, the versions come first.
        expect(find.byKey(const ValueKey('ota-report-card')), findsNothing);
        await reveal(tester, find.text('VERSÕES EM EXECUÇÃO'));
        await reveal(tester, find.text('0.1.0'));
        await reveal(tester, find.text('Conectada · 115200 bps'));
        await reveal(tester, find.text('Escolher arquivo'));
        expect(find.text('Enviar para a placa'), findsNothing);
        await tester.tap(find.text('Escolher arquivo'));
        expect(controller.picks, 1);
        // The steps and the log wait under "Detalhes".
        expect(find.text('Nada aconteceu ainda.'), findsNothing);
        await openDetails(tester);
        await reveal(tester, find.text('Nada aconteceu ainda.'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('sending, with its numbers — ${s.key}', (tester) async {
        final file = _file();
        await pump(
          tester,
          s.value,
          OtaPushState(
            phase: OtaPushPhase.sending,
            file: file,
            chunksDone: 96,
            bytesDone: 96 * 4096,
            kbPerSecond: 412.4,
            retries: 1,
            baud: 921600,
            startedAt: DateTime.now(),
            steps: steps(file, {
              OtaStepId.readFile: (OtaStepStatus.done, 'placa 0.2.0, 912 KB'),
              OtaStepId.linkSpeed: (OtaStepStatus.done, '921600 bps'),
              OtaStepId.begin: (OtaStepStatus.done, 'desde o início'),
              OtaStepId.send: (OtaStepStatus.running, null),
            }),
            log: log([
              'Arquivo escolhido: sempreiot-board-0.2.0.bin — placa, versão '
                  '0.2.0, 912 KB, SHA-256 10111213…2c2d2e2f',
              'Velocidade: 921600 bps (a placa confirmou)',
              'Bloco 40: sem resposta em 3 s, reenviado (1 de 5)',
              'Envio: 40 % — 92 de 228 blocos, 410 KB/s',
            ]),
          ),
        );

        // What is going where, at the top.
        await reveal(tester, find.text('Enviando para a placa'));
        await reveal(tester, find.text('42 % · 96 de 228 blocos'));
        await reveal(tester, find.text('Firmware da placa 0.2.0'));
        await reveal(tester, find.text('Conectada · 921600 bps'));
        await reveal(tester, find.text('Cancelar envio'));
        await tester.tap(find.text('Cancelar envio'));
        expect(controller.cancels, 1);
        expect(find.text('Enviar para a placa'), findsNothing);
        expect(find.text('Escolher outro arquivo'), findsNothing);

        await reveal(tester, find.text('Envio'));
        for (final id in OtaStepId.values) {
          await reveal(tester, find.text(id.label));
        }
        await reveal(tester, find.byType(LinearProgressIndicator).last);
        expect(
          find.textContaining('96 de 228 blocos · 42 % · 412 KB/s · faltam '),
          findsOneWidget,
        );
        await reveal(tester,
            find.text('Bloco 40: sem resposta em 3 s, reenviado (1 de 5)'));
        expect(find.text('14:03:22'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('waiting for the board, in words and seconds — ${s.key}',
          (tester) async {
        final file = _file();
        await pump(
          tester,
          s.value,
          OtaPushState(
            phase: OtaPushPhase.boardRestarting,
            file: file,
            chunksDone: 228,
            bytesDone: file.size,
            kbPerSecond: 400,
            waitingFor: 'aguardando a placa reiniciar',
            waitingSince: DateTime.now().subtract(const Duration(seconds: 7)),
            startedAt: DateTime.now(),
            steps: steps(file, {
              OtaStepId.readFile: (OtaStepStatus.done, null),
              OtaStepId.linkSpeed: (OtaStepStatus.done, '921600 bps'),
              OtaStepId.begin: (OtaStepStatus.done, 'desde o início'),
              OtaStepId.send: (OtaStepStatus.done, '228 de 228 blocos'),
              OtaStepId.verify: (OtaStepStatus.done, 'imagem aprovada'),
              OtaStepId.boardRestart: (OtaStepStatus.running, null),
            }),
          ),
        );
        // Top to bottom, as the page is laid out.
        await reveal(tester, find.text('A placa está reiniciando'));
        await reveal(
            tester, find.textContaining('Aguardando a placa reiniciar · '));
        await reveal(
            tester,
            find.text('Pode sair desta tela: a atualização continua e '
                'aparece na tela Rede.'));
        await reveal(tester, find.text('Não é possível cancelar agora'));
        await reveal(tester, find.text('Reinício da placa'));
        await reveal(
            tester, find.textContaining('aguardando a placa reiniciar · '));
        // The seconds move.
        await tester.pump(const Duration(seconds: 2));
        await reveal(
            tester, find.textContaining('aguardando a placa reiniciar · '));
        expect(tester.takeException(), isNull);
      });

      testWidgets('the end, with what happened — ${s.key}', (tester) async {
        final file = _file();
        final started = DateTime.now().subtract(const Duration(seconds: 95));
        await pump(
          tester,
          s.value,
          OtaPushState(
            phase: OtaPushPhase.rolledBack,
            file: file,
            chunksDone: 228,
            bytesDone: file.size,
            kbPerSecond: 398,
            retries: 2,
            resumes: 1,
            message: 'A placa testou a versão 0.2.0, não passou no autoteste '
                'e voltou para a versão anterior. Ela continua com a versão '
                '0.1.0.',
            boardVersion: '0.1.0',
            startedAt: started,
            endedAt: started.add(const Duration(seconds: 95)),
            storedOnBoard: const {SafrProductFamily.node: '0.2.0'},
            steps: steps(file, {
              for (final id in OtaStepId.values) id: (OtaStepStatus.done, null),
              OtaStepId.confirm: (
                OtaStepStatus.failed,
                'A placa testou a versão 0.2.0, não passou no autoteste.'
              ),
            }),
            log: log(['Resultado: voltou à versão anterior']),
          ),
        );

        await reveal(tester, find.text('A placa voltou à versão anterior'));
        await reveal(tester, find.text('Guardado na placa'));
        expect(
          find.text('firmware de rede elétrica 0.2.0 · ainda não enviado aos '
              'dispositivos'),
          findsOneWidget,
        );
        await reveal(tester, find.text('Enviar de novo'));
        // It did not end well: "Detalhes" is open.
        await reveal(tester, find.text('Tempo total'));
        expect(find.text('1 min 35 s'), findsOneWidget);
        await reveal(tester, find.text('Blocos reenviados'));
        await reveal(tester, find.text('Retomadas'));
        await reveal(tester, find.text('Velocidade média'));
        expect(find.text('398 KB/s'), findsOneWidget);
        await reveal(tester, find.text('Autoteste / confirmação'));
        await reveal(
            tester,
            find.text(
                'A placa testou a versão 0.2.0, não passou no autoteste.'));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('a board image', () {
    testWidgets('asks before it starts: the site will be unsupervised',
        (tester) async {
      await pump(tester, const Size(1280, 800), OtaPushState(file: _file()));
      await reveal(tester, find.text('Enviar para a placa'));
      await tester.tap(find.text('Enviar para a placa'));
      await tester.pumpAndSettle();

      expect(find.text('Atualizar a placa?'), findsOneWidget);
      expect(find.textContaining('30 segundos'), findsOneWidget);
      expect(find.textContaining('sem supervisão'), findsOneWidget);
      expect(find.textContaining('Versão atual: 0.1.0'), findsOneWidget);
      expect(find.textContaining('Nova versão: 0.2.0'), findsOneWidget);
      expect(controller.started, isEmpty);

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(controller.started, isEmpty);

      await tester.tap(find.text('Enviar para a placa'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Atualizar a placa'));
      await tester.pumpAndSettle();
      expect(controller.started, [false]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the question fits a phone on its side', (tester) async {
      await pump(tester, const Size(640, 360), OtaPushState(file: _file()));
      await reveal(tester, find.text('Enviar para a placa'));
      await tester.tap(find.text('Enviar para a placa'));
      await tester.pumpAndSettle();
      expect(find.text('Atualizar a placa?'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cannot be started while an alarm is latched', (tester) async {
      await pump(tester, const Size(800, 1280), OtaPushState(file: _file()),
          alarm: true);
      await reveal(tester, find.text('Enviar para a placa'));
      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Enviar para a placa'),
          matching: find.bySubtype<FilledButton>(),
        ),
      );
      expect(button.onPressed, isNull);
      expect(
        find.text('Há alarme ativo. Rearme a central antes de atualizar a '
            'placa.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Enviar para a placa'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Atualizar a placa?'), findsNothing);
      expect(controller.started, isEmpty);
    });

    testWidgets('what the controller refuses is said', (tester) async {
      await pump(tester, const Size(800, 1280), OtaPushState(file: _file()));
      controller.blocker = 'Há alarme ativo. Rearme a central antes de '
          'atualizar a placa.';
      await reveal(tester, find.text('Enviar para a placa'));
      await tester.tap(find.text('Enviar para a placa'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Atualizar a placa?'), findsNothing);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(controller.started, isEmpty);
    });
  });

  group('a node image', () {
    testWidgets('starts without a question, alarm or not', (tester) async {
      await pump(
        tester,
        const Size(800, 1280),
        OtaPushState(file: _file(project: 'sempreiot-node')),
        alarm: true,
      );
      expect(find.text('Para'), findsOneWidget);
      await reveal(tester, find.text('Enviar para a placa'));
      await tester.tap(find.text('Enviar para a placa'));
      await tester.pumpAndSettle();
      expect(find.text('Atualizar a placa?'), findsNothing);
      expect(controller.started, [false]);
    });
  });

  testWidgets('without the board on the cable nothing can be sent',
      (tester) async {
    await pump(tester, const Size(800, 1280), OtaPushState(file: _file()),
        linkUp: false);
    expect(find.text('Cabo USB desconectado'), findsOneWidget);
    await reveal(tester, find.text('Enviar para a placa'));
    expect(
      find.text('A placa não está respondendo. Verifique o cabo USB.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Enviar para a placa'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(controller.started, isEmpty);
  });

  testWidgets('a file that was refused says why', (tester) async {
    await pump(
      tester,
      const Size(360, 640),
      const OtaPushState(
          fileError: 'Este arquivo não é um firmware SempreIoT.'),
    );
    expect(
        find.text('Este arquivo não é um firmware SempreIoT.'), findsOneWidget);
    expect(find.text('Escolher arquivo'), findsOneWidget);
    expect(find.text('Enviar para a placa'), findsNothing);
  });

  testWidgets('the file says what it is', (tester) async {
    await pump(tester, const Size(800, 1280), OtaPushState(file: _file()));
    expect(find.text('sempreiot-board-0.2.0.bin'), findsOneWidget);
    expect(find.text('placa (sempreiot-board)'), findsOneWidget);
    expect(find.text('0.2.0'), findsOneWidget);
    expect(find.text('912 KB · 228 blocos'), findsOneWidget);
    expect(find.text('10111213…2c2d2e2f'), findsOneWidget);
  });

  testWidgets('"Copiar" puts the whole log on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await pump(
      tester,
      const Size(800, 1280),
      OtaPushState(
        file: _file(),
        log: log([
          'BEGIN aceito: a placa quer o bloco 0',
          'Ligação perdida no bloco 12',
          'Ligação de volta',
        ]),
      ),
    );
    expect(find.text('Copiar'), findsNothing);
    await reveal(tester, find.text('0 passos · 3 linhas de registro'));
    await openDetails(tester);
    await reveal(tester, find.text('Copiar'));
    expect(find.text('3 linhas'), findsOneWidget);
    await tester.tap(find.text('Copiar'));
    await tester.pump();

    expect(
      copied,
      '14:03:20  BEGIN aceito: a placa quer o bloco 0\n'
      '14:03:21  Ligação perdida no bloco 12\n'
      '14:03:22  Ligação de volta',
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Registro copiado.'), findsOneWidget);
  });

  // ── What happened, in plain words ─────────────────────────────────────────

  OtaPushState ended(
    OtaPushPhase phase, {
    String project = 'sempreiot-board',
    String? message,
    String? boardVersion,
    String? before = '0.1.0-dev',
    SafrOtaReason? reason,
    bool boardRestarted = false,
    Map<SafrProductFamily, String> stored = const {},
  }) {
    final file = _file(project: project);
    final started = DateTime(2026, 9, 29, 14, 0);
    return OtaPushState(
      phase: phase,
      file: file,
      chunksDone: 228,
      bytesDone: file.size,
      kbPerSecond: 400,
      message: message,
      reason: reason,
      boardVersion: boardVersion,
      boardVersionBefore: before,
      boardRestarted: boardRestarted,
      storedOnBoard: stored,
      startedAt: started,
      endedAt: started.add(const Duration(seconds: 40)),
      steps: steps(file, {
        for (final id in OtaStepId.values) id: (OtaStepStatus.done, null),
      }),
      log: log(['Resultado']),
    );
  }

  Color cardColor(WidgetTester tester) {
    final card =
        tester.widget<Container>(find.byKey(const ValueKey('ota-report-card')));
    return ((card.decoration! as BoxDecoration).border! as Border).top.color;
  }

  group('the report card', () {
    for (final s in sizes.entries) {
      testWidgets('an image that was only stored — ${s.key}', (tester) async {
        await pump(
          tester,
          s.value,
          ended(
            OtaPushPhase.stored,
            project: 'sempreiot-node',
            message: 'Guardado na placa: unidades de rede elétrica 0.2.0.',
            stored: const {SafrProductFamily.node: '0.2.0'},
          ),
          boardRuns: '0.1.0-dev',
        );
        await reveal(tester, find.text('Imagem guardada na placa'));
        await reveal(
            tester,
            find.text('Só a placa. Ela guardou o firmware das unidades de '
                'rede elétrica 0.2.0.'));
        // Impossible to read as "the devices were updated".
        await reveal(
            tester,
            find.text('Nenhum dispositivo foi atualizado. Os dispositivos '
                'continuam com o firmware que já tinham até você usar '
                '"Enviar aos dispositivos" na tela Atualização de '
                'firmware.'));
        expect(find.text('Placa atualizada'), findsNothing);
        expect(find.textContaining('→'), findsNothing);
        // Not the look of a success.
        final color = cardColor(tester);
        expect(color.g == AppColors.success.g && color.r == AppColors.success.r,
            isFalse);
        // It ended well: the steps and the log stay folded.
        expect(find.text('ANDAMENTO'), findsNothing);
        expect(find.text('Copiar'), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the board runs the new version — ${s.key}', (tester) async {
        await pump(
          tester,
          s.value,
          ended(
            OtaPushPhase.confirmed,
            message: 'A placa reiniciou e está com a versão 0.2.0.',
            boardVersion: '0.2.0',
            boardRestarted: true,
          ),
          boardRuns: '0.2.0',
        );
        await reveal(tester, find.text('Placa atualizada'));
        await reveal(tester, find.text('0.1.0-dev → 0.2.0'));
        await reveal(
            tester, find.text('A placa. Ela reiniciou e passou no autoteste.'));
        await reveal(
            tester,
            find.text('A placa trocou da versão 0.1.0-dev para a versão '
                '0.2.0. Nenhum outro dispositivo foi alterado.'));
        expect(find.text('ANDAMENTO'), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the board went back — ${s.key}', (tester) async {
        await pump(
          tester,
          s.value,
          ended(
            OtaPushPhase.rolledBack,
            message: 'A placa testou a versão 0.2.0, não passou no '
                'autoteste e voltou para a versão anterior.',
            boardVersion: '0.1.0-dev',
            reason: SafrOtaReason.selftestFail,
            boardRestarted: true,
          ),
          boardRuns: '0.1.0-dev',
        );
        await reveal(tester, find.text('A placa voltou à versão anterior'));
        await reveal(
            tester,
            find.text('A placa testou a versão 0.2.0 e não passou no '
                'autoteste.'));
        await reveal(
            tester,
            find.text('Nada mudou: a placa voltou para a versão 0.1.0-dev. '
                'Nenhum outro dispositivo foi alterado.'));
        // It did not end well: the steps are open.
        await reveal(tester, find.text('ANDAMENTO'));
        expect(tester.takeException(), isNull);
      });

      testWidgets('verified, not confirmed yet — ${s.key}', (tester) async {
        final file = _file();
        await pump(
          tester,
          s.value,
          OtaPushState(
            phase: OtaPushPhase.boardRestarting,
            file: file,
            chunksDone: 228,
            bytesDone: file.size,
            boardVersionBefore: '0.1.0-dev',
            waitingFor: 'placa respondeu, aguardando confirmação',
            waitingSince: DateTime.now().subtract(const Duration(seconds: 7)),
            startedAt: DateTime.now(),
            steps: steps(file, {
              OtaStepId.readFile: (OtaStepStatus.done, null),
              OtaStepId.linkSpeed: (OtaStepStatus.done, null),
              OtaStepId.begin: (OtaStepStatus.done, null),
              OtaStepId.send: (OtaStepStatus.done, null),
              OtaStepId.verify: (OtaStepStatus.done, 'imagem aprovada'),
              OtaStepId.boardRestart: (OtaStepStatus.done, null),
              OtaStepId.confirm: (OtaStepStatus.running, null),
            }),
          ),
          boardRuns: '0.1.0-dev',
        );
        await reveal(tester, find.text('A placa está em autoteste'));
        await reveal(tester,
            find.textContaining('Placa respondeu, aguardando confirmação · '));
        await reveal(tester, find.textContaining('Ainda não confirmado.'));
        await reveal(
            tester,
            find.textContaining(
                'Antes do envio ela estava com a versão 0.1.0-dev.'));
        expect(find.text('Placa atualizada'), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('it failed: why, and nothing changed — ${s.key}',
          (tester) async {
        await pump(
          tester,
          s.value,
          ended(
            OtaPushPhase.failed,
            message: 'A placa parou de responder durante o envio.',
            reason: SafrOtaReason.timedOut,
          ),
          boardRuns: '0.1.0-dev',
        );
        await reveal(tester, find.text('A atualização não foi concluída'));
        await reveal(
            tester, find.text('A placa parou de responder durante o envio.'));
        await reveal(
            tester, find.text('Ninguém. A placa não ficou com esta imagem.'));
        await reveal(
            tester,
            find.text('Nada mudou na placa. Ela continua com a versão '
                '0.1.0-dev.'));
        await reveal(tester, find.text('ANDAMENTO'));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the board refused the file', (tester) async {
      await pump(
        tester,
        const Size(1280, 800),
        ended(
          OtaPushPhase.failed,
          message: SafrOtaReason.notNewer.label,
          reason: SafrOtaReason.notNewer,
        ),
        boardRuns: '0.2.0',
      );
      await reveal(
          tester,
          find.text('A versão do arquivo não é mais nova que a '
              'instalada.'));
      await reveal(tester, find.textContaining('Nada mudou na placa.'));
    });

    testWidgets('a node image that failed: no device was updated',
        (tester) async {
      await pump(
        tester,
        const Size(800, 1280),
        ended(
          OtaPushPhase.failed,
          project: 'sempreiot-node',
          message: SafrOtaReason.noSpace.label,
          reason: SafrOtaReason.noSpace,
        ),
      );
      await reveal(
          tester, find.text('Não há espaço na placa para este arquivo.'));
      await reveal(
          tester,
          find.text('Nada mudou na placa e nenhum dispositivo foi '
              'atualizado.'));
    });

    testWidgets('the board restarted and never answered: not "nothing changed"',
        (tester) async {
      await pump(
        tester,
        const Size(1280, 800),
        ended(
          OtaPushPhase.failed,
          message: 'A placa não voltou a responder depois de reiniciar. '
              'Verifique o cabo USB.',
          reason: SafrOtaReason.timedOut,
          boardRestarted: true,
        ),
      );
      await reveal(tester, find.text('A atualização não foi confirmada'));
      await reveal(tester, find.textContaining('Não se sabe.'));
      expect(find.textContaining('Nada mudou'), findsNothing);
    });

    testWidgets('"Detalhes" opens and closes on a tap', (tester) async {
      await pump(
        tester,
        const Size(800, 1280),
        ended(
          OtaPushPhase.confirmed,
          boardVersion: '0.2.0',
          boardRestarted: true,
        ),
      );
      await reveal(tester, find.text('7 passos · 1 linha de registro'));
      expect(find.text('ANDAMENTO'), findsNothing);
      await openDetails(tester);
      await reveal(tester, find.text('ANDAMENTO'));
      await reveal(tester, find.text('Tempo total'));
      await reveal(tester, find.text('Copiar'));
      await openDetails(tester);
      expect(find.text('ANDAMENTO'), findsNothing);
      expect(find.text('Copiar'), findsNothing);
    });

    testWidgets('a node file says, before it is sent, that it is only stored',
        (tester) async {
      await pump(
        tester,
        const Size(360, 640),
        OtaPushState(file: _file(project: 'sempreiot-node')),
      );
      await reveal(
          tester,
          find.textContaining('Este arquivo fica guardado na placa. Nenhum '
              'dispositivo é atualizado neste envio'));
      expect(tester.takeException(), isNull);
    });
  });

  // ── What every unit runs now ──────────────────────────────────────────────

  group('"Versões em execução"', () {
    final site = [
      _unit('5A:46:52:00:00:01',
          layer: 1,
          role: SafrNodeRole.root,
          name: 'Sirene térreo',
          productCode: 0x0201,
          fw: '0.1.0-dev'),
      // Firmware older than v3.5: it never said what it runs.
      _unit('5A:46:52:00:00:02'),
      _unit('5A:46:52:00:00:09',
          layer: 3,
          role: SafrNodeRole.leaf,
          name: 'Detector sala',
          productCode: 0x0301,
          fw: '0.1.0-dev'),
    ];

    for (final s in sizes.entries) {
      testWidgets('the board first, then by family; pending — ${s.key}',
          (tester) async {
        await pump(
          tester,
          s.value,
          ended(
            OtaPushPhase.stored,
            project: 'sempreiot-node',
            stored: const {SafrProductFamily.node: '0.2.0'},
          ),
          boardRuns: '0.1.0-dev',
          units: site,
        );
        await reveal(tester, find.text('VERSÕES EM EXECUÇÃO'));
        await reveal(tester, find.text('PLACA'));
        await reveal(tester, find.text('Central (placa) · SIOT-BOARD-01'));
        await reveal(tester, find.text('REDE ELÉTRICA · 2'));
        await reveal(tester, find.text('Sirene térreo'));
        await reveal(tester, find.text('Sirene · SIOT-SIREN-01'));
        await reveal(tester, find.text('5A:46:52:00:00:02'));
        await reveal(tester, find.text('Produto não informado'));
        await reveal(tester, find.text('—'));
        await reveal(tester, find.text('BATERIA · 1'));
        await reveal(tester, find.text('Detector sala'));

        // Every unit still runs what it ran.
        expect(find.text('0.1.0-dev', skipOffstage: false), findsNWidgets(3));
        // The image waits for the two mains powered units, and only them.
        expect(
          find.text('na placa: 0.2.0 (ainda não enviado)', skipOffstage: false),
          findsNWidgets(2),
        );

        // Top to bottom: board, mains, battery.
        double y(String text) =>
            tester.getTopLeft(find.text(text, skipOffstage: false)).dy;
        expect(y('PLACA'), lessThan(y('REDE ELÉTRICA · 2')));
        expect(y('REDE ELÉTRICA · 2'), lessThan(y('BATERIA · 1')));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('nothing stored: nothing pending', (tester) async {
      await pump(tester, const Size(1280, 800), const OtaPushState(),
          boardRuns: '0.1.0-dev', units: site);
      expect(
          find.textContaining('na placa:', skipOffstage: false), findsNothing);
    });

    testWidgets('a unit that already runs the stored version is not pending',
        (tester) async {
      await pump(
        tester,
        const Size(1280, 800),
        const OtaPushState(
            storedOnBoard: {SafrProductFamily.leaf: '0.1.0-dev'}),
        boardRuns: '0.1.0-dev',
        units: site,
      );
      expect(
          find.textContaining('na placa:', skipOffstage: false), findsNothing);
    });

    testWidgets('a long group folds, and opens on a tap', (tester) async {
      await pump(
        tester,
        const Size(800, 1280),
        const OtaPushState(),
        units: [
          for (var i = 1; i <= 7; i++)
            _unit('5A:46:52:00:00:1$i',
                name: 'Sirene $i', productCode: 0x0201, fw: '0.1.0'),
        ],
      );
      await reveal(tester, find.text('REDE ELÉTRICA · 7'));
      expect(find.text('Sirene 4', skipOffstage: false), findsOneWidget);
      expect(find.text('Sirene 5', skipOffstage: false), findsNothing);
      await reveal(tester, find.text('Mostrar todas (7)'));
      await tester.tap(find.text('Mostrar todas (7)'));
      await tester.pump();
      await reveal(tester, find.text('Sirene 7'));
      await reveal(tester, find.text('Mostrar menos'));
      expect(tester.takeException(), isNull);
    });
  });
}
