import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/core/theme/app_colors.dart';
import 'package:sempreiot_central_app/features/central/application/alarm_latch_provider.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_codec.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_viewer.dart';
import 'package:sempreiot_central_app/features/central/application/device_command_provider.dart';
import 'package:sempreiot_central_app/features/central/application/panel_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart'
    show safrCentralMac;
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/event_history_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/alarm_strip.dart';
import 'package:sempreiot_central_app/features/iot/application/presence_provider.dart';
import 'package:sempreiot_central_app/presentation/screens/main/widgets/comm_status_gadget.dart';
import 'package:sempreiot_central_app/presentation/screens/main/widgets/panel_objects.dart';
import 'package:sempreiot_central_app/presentation/screens/main/widgets/principal_panel.dart';

/// Principal, redesigned (2026-11-19): one state block (normal / needs
/// attention / alarm) with the three counts, the central's links and its
/// battery and temperature as objects, the last events and their history
/// — on the tablet and on a user's phone, every size, both orientations.
///
/// With PRINCIPAL_PNG_DIR set, the screens are also written as PNGs.
void main() {
  final now = DateTime.now().toUtc();
  const central = 'central-1';
  const a = '5A:46:52:00:00:01';
  const b = '5A:46:52:00:00:02';

  MirrorPanelEvent ev(int severity, String text, int minutesAgo) =>
      MirrorPanelEvent(
          at: now.subtract(Duration(minutes: minutesAgo)),
          severity: severity,
          text: text);

  final events = [
    ev(3, 'outside name — alarme de fumaça', 2),
    ev(1, 'Sala 2 — sem comunicação', 12),
    ev(2, 'Sirene Hall — teste manual', 26),
    ev(0, 'Sala 2 — voltou a comunicar', 40),
    ev(0, 'Placa voltou a responder', 61),
  ];

  const normal = PanelView(known: true, total: 12);
  final withEvents = PanelView(known: true, total: 12, events: events);
  final trouble = PanelView(
    known: true,
    total: 12,
    troubles: 2,
    troubleList: const [
      MirrorTrouble(name: 'Sala 2', why: MirrorTrouble.offline),
      MirrorTrouble(name: 'Corredor', why: MirrorTrouble.battery),
    ],
    events: events,
  );
  final alarm = PanelView(known: true, total: 12, alarms: 2, events: events);

  MeshDevice device(String mac, String name) => MeshDevice(
        mac: mac,
        role: 1,
        layer: 1,
        firstSeenAt: now,
        lastSeenAt: now,
        lastBootCtr: 0,
        lastMsgCtr: 0,
        supervisionState: 0,
        name: name,
        linkKind: 0,
        lastDevSeq: 0,
        alarmLatched: 1,
        alarmLatchedAt: now.subtract(const Duration(minutes: 2)),
        boardFlags: 0,
      );

  const tiles = [
    CommTileData(
        icon: Icons.wifi_rounded,
        label: 'WI-FI',
        channel: PanelObjectKind.wifi,
        statusText: 'Conectado',
        color: AppColors.success),
    CommTileData(
        icon: Icons.usb_rounded,
        label: 'USB',
        channel: PanelObjectKind.usb,
        statusText: 'Conectado',
        color: AppColors.success),
    CommTileData(
        icon: Icons.hub_rounded,
        label: 'REDE INTERNA',
        channel: PanelObjectKind.mesh,
        statusText: 'Conectando…',
        color: AppColors.warning),
    CommTileData(
        icon: Icons.cloud_off_rounded,
        label: 'NUVEM',
        channel: PanelObjectKind.cloud,
        statusText: 'Desconectado',
        color: AppColors.error),
  ];

  late List<(String, DeviceCommandKind)> sent;

  /// Principal on the tablet ([phone] false) or on a user's phone.
  Future<void> pump(
    WidgetTester tester,
    Size size,
    PanelView view, {
    bool phone = false,
    PresenceStatus presence = PresenceStatus.online,
    Brightness brightness = Brightness.dark,
    Key? boundary,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    sent = [];
    final held = [
      if (view.alarms > 0) device(a, 'outside name'),
      if (view.alarms > 1) device(b, 'Sala 3'),
    ];
    // A new scope each time: overrides of a scope already built stay.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localPanelProvider.overrideWithValue(view),
          panelViewProvider.overrideWith((ref, id) => view),
          latchedAlarmsProvider.overrideWith((ref) => Stream.value(held)),
          topologyProvider.overrideWithValue(const []),
          presenceStatusProvider.overrideWith((ref, id) => presence),
          centralAlarmsProvider.overrideWith((ref, id) => MirrorAlarms(
                at: now,
                alarms: [
                  for (final d in held)
                    MirrorAlarm(
                        mac: d.mac,
                        name: d.name,
                        zone: 'Térreo',
                        since: d.alarmLatchedAt),
                ],
              )),
          deviceCommandProvider.overrideWith((ref) => DeviceCommandTracker(
                send: (mac, kind) async {
                  sent.add((mac, kind));
                  return true;
                },
                deliveries: const Stream.empty(),
              )),
        ],
        child: RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: ThemeData(brightness: brightness, useMaterial3: true),
            home: Scaffold(
              backgroundColor: brightness == Brightness.dark
                  ? AppColors.backgroundDark
                  : AppColors.backgroundLight,
              body: PrincipalBody(
                centralId: phone ? central : null,
                commBuilder: (h) =>
                    CommStatusGadget(tiles: tiles, minHeight: h),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  const sizes = {
    'tablet landscape': Size(1280, 800),
    'tablet portrait': Size(800, 1280),
    'phone portrait': Size(390, 844),
    'phone landscape': Size(844, 390),
    'small phone': Size(360, 640),
  };

  for (final s in sizes.entries) {
    for (final phone in [false, true]) {
      final where = phone ? 'phone view' : 'tablet view';
      testWidgets('normal, attention and alarm — $where, ${s.key}',
          (tester) async {
        await pump(tester, s.value, withEvents, phone: phone);
        expect(find.text('Sistema normal'), findsOneWidget);
        expect(find.text('Alarmes'), findsOneWidget);
        expect(find.text('Problemas'), findsOneWidget);
        expect(find.text('COMUNICAÇÃO'), findsOneWidget);
        expect(
            find.text('ÚLTIMOS EVENTOS', skipOffstage: false), findsOneWidget);
        expect(tester.takeException(), isNull);

        await pump(tester, s.value, trouble, phone: phone);
        expect(find.text('2 problemas'), findsOneWidget);
        expect(find.text('Sala 2'), findsOneWidget);
        expect(find.text('bateria baixa'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await pump(tester, s.value, alarm, phone: phone);
        expect(find.text('ALARME — 2 dispositivos'), findsOneWidget);
        // The alarm is rearmed at the tablet, never from a phone.
        expect(
            find.text('Rearmar tudo'), phone ? findsNothing : findsOneWidget);
        expect(find.text('Rearmar'), phone ? findsNothing : findsNWidgets(2));
        expect(find.text('ALARME RETIDO — 2 dispositivos'), findsNothing,
            reason: 'the block says it; no second heading');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('the counts: alarms, attention, and the rest OK', (tester) async {
    await pump(tester, const Size(1280, 800),
        const PanelView(known: true, total: 12, alarms: 1, troubles: 3));
    expect(find.bySemanticsLabel('1 Alarmes'), findsOneWidget);
    expect(find.bySemanticsLabel('3 Problemas'), findsOneWidget);
    expect(find.bySemanticsLabel('8 OK'), findsOneWidget);
  });

  testWidgets('Rearmar in the block sends a RESET to that device alone',
      (tester) async {
    await pump(tester, const Size(1280, 800), alarm);
    await tester.tap(find.byKey(const ValueKey('alarm-rearm-$a')));
    await tester.pump();
    expect(sent, [(a, DeviceCommandKind.reset)]);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('no unit yet, no event yet', (tester) async {
    await pump(tester, const Size(390, 844), const PanelView(known: true));
    expect(find.text('Nenhum dispositivo instalado ainda.'), findsOneWidget);
    expect(find.text('Nenhum evento registrado ainda.', skipOffstage: false),
        findsOneWidget);
    expect(normal.ok, 12);
  });

  testWidgets('a phone: the central offline, and one that sends no events',
      (tester) async {
    await pump(tester, const Size(390, 844), withEvents,
        phone: true, presence: PresenceStatus.offline);
    expect(find.text('Central sem conexão'), findsOneWidget);

    // An alarm held is said first, offline or not.
    await pump(tester, const Size(390, 844), alarm,
        phone: true, presence: PresenceStatus.offline);
    expect(find.text('ALARME — 2 dispositivos'), findsOneWidget);

    // A central on the older app: its alarms only.
    await pump(tester, const Size(390, 844),
        const PanelView(known: true, eventsKnown: false),
        phone: true);
    expect(find.text('Sistema normal'), findsOneWidget);
    expect(find.text('Alarmes'), findsNothing);
    expect(find.text('Nenhum alarme retido na central.'), findsOneWidget);
    expect(find.text('Nenhum dispositivo instalado ainda.'), findsNothing);
    expect(find.byKey(PanelEventsCard.keySeeAll), findsNothing);
    expect(
        find.textContaining('atualize o app da central', skipOffstage: false),
        findsOneWidget);

    await pump(tester, const Size(390, 844), PanelView.unknown, phone: true);
    expect(find.text('Verificando…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('"Ver todos" opens the history', (tester) async {
    await pump(tester, const Size(390, 844), withEvents, phone: true);
    await tester.ensureVisible(find.byKey(PanelEventsCard.keySeeAll));
    await tester.tap(find.byKey(PanelEventsCard.keySeeAll));
    await tester.pumpAndSettle();
    expect(find.byType(EventHistoryScreen), findsOneWidget);
    expect(find.text('Placa voltou a responder'), findsOneWidget);
    expect(find.textContaining('O histórico completo fica na central'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the alarm strip of the other tabs: there only in alarm, a tap '
      'opens Principal', (tester) async {
    var opened = 0;
    Future<void> show(List<MeshDevice> held) => tester.pumpWidget(ProviderScope(
          overrides: [
            latchedAlarmsProvider.overrideWith((ref) => Stream.value(held)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Column(children: [
                AlarmStrip(onOpen: () => opened++),
                const Expanded(child: SizedBox()),
              ]),
            ),
          ),
        ));
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(const []);
    await tester.pump();
    expect(find.byKey(AlarmStrip.keyStrip), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await show([device(a, 'outside name'), device(b, 'Sala 3')]);
    await tester.pump();
    await tester.pump();
    expect(find.text('ALARME — 2 dispositivos'), findsOneWidget);
    expect(find.text('outside name · Sala 3'), findsOneWidget);
    await tester.tap(find.byKey(AlarmStrip.keyStrip));
    expect(opened, 1);
    expect(tester.takeException(), isNull);

    // A narrow phone: how many, without the names, nothing cut.
    tester.view.physicalSize = const Size(360, 640);
    await tester.pumpWidget(const SizedBox());
    await show([device(a, 'outside name'), device(b, 'Sala 3')]);
    await tester.pump();
    await tester.pump();
    expect(find.text('ALARME — 2 dispositivos'), findsOneWidget);
    expect(find.text('outside name · Sala 3'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('the events in words', () {
    DeviceEvent row({
      String mac = a,
      int severity = 0,
      int? code,
      String? errorKind,
      String detail = '{}',
    }) =>
        DeviceEvent(
          id: 1,
          receivedAt: now,
          deviceMac: mac,
          msgType: 1,
          eventCode: code,
          severity: severity,
          detailJson: detail,
          errorKind: errorKind,
        );
    String name(String mac) => mac == a ? 'Sala 1' : mac;

    test('a unit\'s event, by its code', () {
      expect(
          panelEventOf(
                  row(severity: 3, code: SafrEventCode.smokeAlarm.wire), name)!
              .text,
          'Sala 1 — alarme de fumaça');
      expect(panelEventOf(row(code: SafrEventCode.manualTest.wire), name)!.text,
          'Sala 1 — teste manual');
    });

    test('the central\'s own lines, supervision and diagnostics', () {
      expect(
          panelEventOf(
                  row(detail: '{"synthetic":true,"kind":"device_missing"}'),
                  name)!
              .text,
          'Sala 1 — sem comunicação');
      expect(
          panelEventOf(
                  row(
                      mac: safrCentralMac,
                      detail:
                          '{"synthetic":true,"kind":"board_restored","description":"placa voltou a responder"}'),
                  name)!
              .text,
          'Placa voltou a responder');
      expect(panelEventOf(row(mac: b, errorKind: 'auth_failed'), name)!.text,
          '$b — quadro recusado (assinatura inválida)');
    });

    test('an event from the board\'s journal keeps the time it happened', () {
      final then = now.subtract(const Duration(days: 3));
      final e = panelEventOf(
          row(
              code: SafrEventCode.manualTest.wire,
              detail:
                  '{"historic":true,"device_ts":"${then.toIso8601String()}"}'),
          name)!;
      expect(e.at, then);
      expect(e.text, 'Sala 1 — teste manual');
      // A unit that never got the time: listed as old, not as "now".
      final unknown = panelEventOf(
          row(
              code: SafrEventCode.manualTest.wire,
              detail:
                  '{"historic":true,"device_ts":"1970-01-01T00:02:00.000Z"}'),
          name)!;
      expect(unknown.at, now);
      expect(unknown.text, contains('registro antigo'));
    });

    test('the re-announcement of an alarm is not news', () {
      expect(
          panelEventOf(
              row(
                  severity: 3,
                  code: SafrEventCode.smokeAlarm.wire,
                  detail: '{"retx":true}'),
              name),
          isNull);
    });
  });

  group('the alarm message carries the panel', () {
    final alarms = [MirrorAlarm(mac: a, name: 'Hall', since: now)];
    final panel = MirrorPanel(
      total: 12,
      troubles: 2,
      troubleList: const [
        MirrorTrouble(name: 'Sala 2', why: MirrorTrouble.offline)
      ],
      events: events,
    );

    test('there and back', () {
      final back = decodeMirrorAlarms(
          encodeMirrorAlarms(at: now, alarms: alarms, panel: panel))!;
      expect(back.alarms.single.name, 'Hall');
      expect(back.panel!.total, 12);
      expect(back.panel!.troubles, 2);
      expect(back.panel!.troubleList.single.name, 'Sala 2');
      expect(back.panel!.events.length, events.length);
      expect(back.panel!.events.first.text, events.first.text);
      expect(back.panel!.events.first.severity, 3);
    });

    test('a central on the older app: the alarms, no panel', () {
      final back =
          decodeMirrorAlarms(encodeMirrorAlarms(at: now, alarms: alarms))!;
      expect(back.alarms.length, 1);
      expect(back.panel, isNull);
    });

    test('at most 20 events travel, and a new event changes the signature', () {
      final many = MirrorPanel(
          total: 1,
          troubles: 0,
          events: [for (var i = 0; i < 50; i++) ev(0, 'evento $i', i)]);
      final back = decodeMirrorAlarms(
          encodeMirrorAlarms(at: now, alarms: const [], panel: many))!;
      expect(back.panel!.events.length, MirrorPanel.maxEvents);
      expect(mirrorAlarmsSignature(alarms, panel),
          isNot(mirrorAlarmsSignature(alarms, many)));
      expect(mirrorAlarmsSignature(alarms, panel),
          mirrorAlarmsSignature(alarms, panel));
    });
  });

  // ── A look at it ──────────────────────────────────────────────────────
  final pngDir = Platform.environment['PRINCIPAL_PNG_DIR'];
  for (final (label, size, view, phone, brightness) in [
    (
      'tablet_normal',
      const Size(1280, 800),
      withEvents,
      false,
      Brightness.dark
    ),
    ('tablet_problema', const Size(1280, 800), trouble, false, Brightness.dark),
    ('tablet_alarme', const Size(1280, 800), alarm, false, Brightness.dark),
    (
      'tablet_normal_claro',
      const Size(1280, 800),
      withEvents,
      false,
      Brightness.light
    ),
    ('phone_normal', const Size(390, 844), withEvents, true, Brightness.dark),
    ('phone_alarme', const Size(390, 844), alarm, true, Brightness.dark),
  ]) {
    testWidgets('PNG: $label', skip: pngDir == null, (tester) async {
      final root = Platform.environment['FLUTTER_ROOT'];
      if (root != null) {
        final dir = '$root/bin/cache/artifacts/material_fonts';
        await tester.runAsync(() async {
          for (final (family, file) in [
            ('Roboto', 'Roboto-Regular.ttf'),
            ('MaterialIcons', 'MaterialIcons-Regular.otf'),
          ]) {
            final f = File('$dir/$file');
            if (!f.existsSync()) continue;
            final bytes = await f.readAsBytes();
            await (FontLoader(family)
                  ..addFont(Future.value(ByteData.view(bytes.buffer))))
                .load();
          }
        });
      }
      const key = ValueKey('png');
      await pump(tester, size, view,
          phone: phone, brightness: brightness, boundary: key);
      await tester.runAsync(() async {
        final boundary =
            tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
        final image = await boundary.toImage(pixelRatio: 1.5);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$pngDir/principal_$label.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
      });
    });
  }
}
