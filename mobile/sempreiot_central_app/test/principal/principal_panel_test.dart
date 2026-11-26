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
import 'package:sempreiot_central_app/features/central/presentation/widgets/alarm_strip.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_avatar.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/device_state_tile.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/latched_alarm_banner.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/state_devices.dart';
import 'package:sempreiot_central_app/features/iot/application/presence_provider.dart';
import 'package:sempreiot_central_app/presentation/screens/main/widgets/comm_status_gadget.dart';
import 'package:sempreiot_central_app/presentation/screens/main/widgets/panel_objects.dart';
import 'package:sempreiot_central_app/presentation/screens/main/widgets/principal_panel.dart';

/// Principal, redesigned (2026-11-19): one state block (normal / needs
/// attention / alarm) with the three counts, the central's links and its
/// battery and temperature as objects — on the tablet and on a user's
/// phone, every size, both orientations. The events have their own tab
/// since 2026-11-23 (test/central/events_screen_test.dart); what a row of
/// the event table says, and how it travels to a phone, is still here.
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
      MirrorTrouble(
          name: 'Sala 2',
          why: MirrorTrouble.offline,
          mac: '5A:46:52:00:00:11',
          address: '2º andar',
          productCode: 0x0201),
      MirrorTrouble(
          name: 'Corredor',
          why: MirrorTrouble.battery,
          mac: '5A:46:52:00:00:12',
          address: 'Térreo',
          productCode: 0x0101,
          leaf: true,
          batteryPct: 12),
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
        sensorWet: 0,
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
    List<TopologyNode> nodes = const [],
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
          topologyProvider.overrideWithValue(nodes),
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
        // The events are a tab of their own now.
        expect(find.text('ÚLTIMOS EVENTOS', skipOffstage: false), findsNothing);
        expect(tester.takeException(), isNull);

        await pump(tester, s.value, trouble, phone: phone);
        expect(find.text('2 problemas'), findsOneWidget);
        expect(find.text('Sala 2'), findsOneWidget);
        expect(find.text('bateria baixa'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await pump(tester, s.value, alarm, phone: phone);
        expect(find.text('ALARME — 2 dispositivos'), findsOneWidget);
        // The alarm is rearmed at the tablet, never from a phone.
        expect(find.byKey(LatchedAlarmBanner.keyRearmAll),
            phone ? findsNothing : findsOneWidget);
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

  testWidgets(
      'a unit that needs attention is drawn as Rede draws it — its model, '
      'its state, its name and endereçamento — and a tap is the way to it',
      (tester) async {
    final node = TopologyNode(
      mac: b,
      role: SafrNodeRole.node,
      layer: 2,
      parentMac: a,
      rssi: -60,
      batteryPct: null,
      online: false,
      lastSeenAt: now,
      alarmLatched: false,
      name: 'Sirene Hall',
      address: '2º andar',
      productCode: 0x0201,
    );
    const said = [
      MirrorTrouble(
          name: 'Sirene Hall',
          why: MirrorTrouble.offline,
          mac: b,
          address: '2º andar',
          productCode: 0x0201),
      // A central on an older app says no unit: a name, nothing to open.
      MirrorTrouble(name: 'Corredor', why: MirrorTrouble.battery),
    ];
    const view =
        PanelView(known: true, total: 12, troubles: 2, troubleList: said);
    final tile = find.byKey(DeviceStateTile.keyOf(b));
    InkWell ink() => tester.widget<InkWell>(
        find.descendant(of: tile, matching: find.byType(InkWell)));

    for (final size in sizes.values) {
      // The screen has the map (the tablet; a phone following the mirror).
      await pump(tester, size, view, nodes: [node]);
      expect(
          find.descendant(of: tile, matching: find.byType(DeviceModelAvatar)),
          findsOneWidget);
      expect(
          find.descendant(of: tile, matching: find.byType(DeviceOfflineBadge)),
          findsOneWidget);
      expect(find.text('Sirene Hall'), findsOneWidget);
      expect(find.text('2º andar'), findsOneWidget);
      expect(find.text('sem comunicação'), findsOneWidget);
      expect(ink().onTap, isNotNull);
      expect(find.text('Corredor'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // A phone without the map yet: the same device, from what the
      // central said of it — nothing to open until the map is there.
      await pump(tester, size, view, phone: true);
      expect(
          find.descendant(of: tile, matching: find.byType(DeviceModelAvatar)),
          findsOneWidget);
      expect(
          find.descendant(of: tile, matching: find.byType(DeviceOfflineBadge)),
          findsOneWidget);
      expect(find.text('2º andar'), findsOneWidget);
      expect(ink().onTap, isNull);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
      'the devices are one row that scrolls sideways; the expand button '
      'grows the same block over the whole screen, and the same corner '
      'brings it back', (tester) async {
    for (final size in sizes.values) {
      for (final phone in [false, true]) {
        await pump(tester, size, alarm, phone: phone);
        // No explanation taking a line of the block.
        expect(find.textContaining('O alarme fica retido'), findsNothing);
        final row =
            tester.widget<ListView>(find.byKey(StateDevicesRow.keyList));
        expect(row.scrollDirection, Axis.horizontal);
        expect(find.byKey(SystemStatusBlock.keyCollapse), findsNothing);

        await tester.ensureVisible(find.byKey(SystemStatusBlock.keyExpand));
        await tester.tap(find.byKey(SystemStatusBlock.keyExpand));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200)); // growing
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(milliseconds: 400));

        // The SAME block, over the whole screen: its headline, its counts,
        // the devices with room (a grid, no sideways row), Rearmar tudo.
        final big =
            find.byWidgetPredicate((w) => w is SystemStatusBlock && w.expanded);
        expect(big, findsOneWidget);
        final box = tester.getSize(big);
        expect(box.width, size.width - 2 * stateDevicesMargin);
        expect(box.height, size.height - 2 * stateDevicesMargin);
        Finder inside(Finder f) => find.descendant(of: big, matching: f);
        expect(inside(find.text('ESTADO DO SISTEMA')), findsOneWidget);
        expect(inside(find.text('ALARME — 2 dispositivos')), findsOneWidget);
        expect(inside(find.text('Alarmes')), findsOneWidget);
        expect(inside(find.byType(StateDevicesGrid)), findsOneWidget);
        expect(inside(find.byKey(StateDevicesRow.keyList)), findsNothing);
        expect(inside(find.byKey(LatchedAlarmBanner.keyRearmAll)),
            phone ? findsNothing : findsOneWidget);
        expect(inside(find.text('outside name')), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(SystemStatusBlock.keyCollapse));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(big, findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 30));
      }
    }
  });

  testWidgets('nothing to list: no row, no expand button', (tester) async {
    await pump(tester, const Size(1280, 800), normal);
    expect(find.byKey(SystemStatusBlock.keyExpand), findsNothing);
    expect(find.byKey(StateDevicesRow.keyList), findsNothing);
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

    await pump(tester, const Size(390, 844), PanelView.unknown, phone: true);
    expect(find.text('Verificando…'), findsOneWidget);
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

    test('the kind a line is listed with', () {
      PanelEventKind kind(DeviceEvent r) => panelEventOf(r, name)!.kind;
      expect(kind(row(severity: 3, code: SafrEventCode.smokeAlarm.wire)),
          PanelEventKind.alarm);
      expect(kind(row(severity: 2, code: SafrEventCode.smokeRising.wire)),
          PanelEventKind.alert);
      // A manual test arrives as an "alert": it is news, not a warning.
      expect(kind(row(severity: 2, code: SafrEventCode.manualTest.wire)),
          PanelEventKind.info);
      expect(kind(row(severity: 1, code: SafrEventCode.commFault.wire)),
          PanelEventKind.trouble);
      expect(kind(row(code: SafrEventCode.restore.wire)), PanelEventKind.ok);
      expect(kind(row(detail: '{"synthetic":true,"kind":"device_restored"}')),
          PanelEventKind.ok);
      // News from the central itself is not "OK".
      expect(
          kind(row(
              mac: safrCentralMac,
              detail:
                  '{"synthetic":true,"kind":"root_elected","description":"x"}')),
          PanelEventKind.info);
      // The line says which unit it is about; the central's own says none.
      expect(panelEventOf(row(severity: 1), name)!.mac, a);
      expect(
          panelEventOf(row(mac: safrCentralMac, detail: '{"description":"x"}'),
                  name)!
              .mac,
          isNull);
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

    test('the kind and the unit travel; an older central says neither', () {
      final p = MirrorPanel(
        total: 1,
        troubles: 1,
        troubleList: const [
          MirrorTrouble(
              name: 'Sala 2',
              why: MirrorTrouble.offline,
              mac: b,
              address: '2º andar',
              productCode: 0x0201,
              leaf: true,
              batteryPct: 12)
        ],
        events: [
          MirrorPanelEvent(
              at: now,
              severity: 2,
              text: 'Sala 1 — teste manual',
              kind: PanelEventKind.info,
              mac: a),
          ev(1, 'Sala 2 — sem comunicação', 3),
        ],
      );
      final back = decodeMirrorAlarms(
              encodeMirrorAlarms(at: now, alarms: const [], panel: p))!
          .panel!;
      expect(back.troubleList.single.mac, b);
      expect(back.troubleList.single.address, '2º andar');
      expect(back.troubleList.single.productCode, 0x0201);
      expect(back.troubleList.single.leaf, isTrue);
      expect(back.troubleList.single.batteryPct, 12);
      expect(back.events[0].kind, PanelEventKind.info);
      expect(back.events[0].severity, 2);
      expect(back.events[0].mac, a);
      // Nothing said: the severity's own kind, no unit.
      expect(back.events[1].kind, PanelEventKind.trouble);
      expect(back.events[1].mac, isNull);
    });

    test('an alarm says what a phone needs to draw the unit', () {
      final back = decodeMirrorAlarms(encodeMirrorAlarms(at: now, alarms: [
        MirrorAlarm(
            mac: a,
            name: 'Hall',
            since: now,
            address: '2º andar',
            productCode: 0x0201,
            leaf: true),
        // A central on an older app: the unit and its name only.
        MirrorAlarm(mac: b, name: 'Sala 3'),
      ]))!;
      expect(back.alarms[0].address, '2º andar');
      expect(back.alarms[0].productCode, 0x0201);
      expect(back.alarms[0].leaf, isTrue);
      expect(back.alarms[1].address, isNull);
      expect(back.alarms[1].productCode, isNull);
      expect(back.alarms[1].leaf, isFalse);
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
    (
      'tablet_alarme_expandido',
      const Size(1280, 800),
      alarm,
      false,
      Brightness.dark
    ),
    (
      'phone_alarme_expandido',
      const Size(390, 844),
      alarm,
      true,
      Brightness.dark
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
      if (label.endsWith('_expandido')) {
        await tester.tap(find.byKey(SystemStatusBlock.keyExpand));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
      }
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
