import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sempreiot_central_app/core/theme/app_colors.dart';
import 'package:sempreiot_central_app/features/central/application/central_mirror_codec.dart';
import 'package:sempreiot_central_app/features/central/application/event_groups.dart';
import 'package:sempreiot_central_app/features/central/application/events_view_prefs.dart';
import 'package:sempreiot_central_app/features/central/application/panel_provider.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/presentation/screens/events_screen.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/event_group_tiles.dart';

/// Eventos, its own tab (2026-11-23): every event to the second, by day;
/// a test is an AVISO, never an ALERTA; filters, search, "Limpar" (which
/// erases nothing) and more of the history — on the tablet and on a
/// user's phone, every size, both orientations.
///
/// With EVENTS_PNG_DIR set, the screens are also written as PNGs.
void main() {
  final now = DateTime.now().toUtc();
  const central = 'central-1';
  const a = '5A:46:52:00:00:01';

  MirrorPanelEvent ev(PanelEventKind kind, String text, Duration ago,
          {String? mac}) =>
      MirrorPanelEvent(
        at: now.subtract(ago),
        severity: switch (kind) {
          PanelEventKind.alarm => 3,
          PanelEventKind.alert => 2,
          PanelEventKind.trouble => 1,
          _ => 0,
        },
        text: text,
        kind: kind,
        mac: mac,
      );

  final events = [
    ev(PanelEventKind.alarm, 'outside name — alarme de fumaça',
        const Duration(minutes: 2),
        mac: a),
    ev(PanelEventKind.info, 'Sirene Hall — teste manual',
        const Duration(minutes: 5),
        mac: a),
    ev(
        PanelEventKind.trouble,
        'Sirene 2º andar — ficou 3 min 10 s sem caminho até a central · o '
        'dispositivo ao qual estava ligado saiu do ar · tentou 2 vizinhos · '
        'voltou por outro dispositivo',
        const Duration(minutes: 12),
        mac: a),
    ev(PanelEventKind.alert, 'Sala 3 — pré-alarme (fumaça subindo)',
        const Duration(minutes: 26)),
    ev(PanelEventKind.ok, 'Sala 2 — voltou a comunicar',
        const Duration(minutes: 40)),
    ev(PanelEventKind.info, 'A raiz da rede mudou para Sirene Hall',
        const Duration(days: 1, minutes: 3)),
    ev(PanelEventKind.ok, 'Placa voltou a responder', const Duration(days: 3)),
  ];

  /// Eventos on the tablet ([phone] false) or on a user's phone.
  Future<void> pump(
    WidgetTester tester,
    Size size,
    List<MirrorPanelEvent> list, {
    bool phone = false,
    bool grouped = false,
    PanelView? view,
    Brightness brightness = Brightness.dark,
    Key? boundary,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // A new scope each time: overrides of a scope already built stay.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // The tablet's table: as many as asked, as the real provider.
          localPanelEventsProvider
              .overrideWith((ref, limit) => list.take(limit).toList()),
          panelViewProvider.overrideWith((ref, id) =>
              view ?? PanelView(known: true, total: 12, events: list)),
          topologyProvider.overrideWithValue(const []),
          eventsGroupedProvider.overrideWith(() => _View(grouped)),
        ],
        child: RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: ThemeData(brightness: brightness, useMaterial3: true),
            home: Scaffold(
              backgroundColor: brightness == Brightness.dark
                  ? AppColors.backgroundDark
                  : AppColors.backgroundLight,
              body: EventsScreen(centralId: phone ? central : null),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
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
      testWidgets('the list — $where, ${s.key}', (tester) async {
        await pump(tester, s.value, events, phone: phone);
        expect(find.text('ALARME'), findsOneWidget);
        // A test is news: AVISO, in its own colour — never ALERTA.
        final badge = tester.widget<Text>(find.text('AVISO').first);
        expect(badge.style!.color, AppColors.info);
        expect(find.textContaining(RegExp('HOJE|ONTEM')), findsWidgets);
        expect(tester.takeException(), isNull);

        // The whole list scrolls to its end without an overflow.
        await tester.dragUntilVisible(
          find.textContaining(phone ? 'fica na central' : 'Fim da lista'),
          find.byType(ListView),
          const Offset(0, -300),
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('a short screen: the search and the filters scroll away',
      (tester) async {
    await pump(tester, const Size(844, 260), events);
    expect(find.byKey(EventsScreen.keySearch), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();
    expect(find.byKey(EventsScreen.keySearch), findsNothing);
    expect(tester.takeException(), isNull);

    // Nothing to list: still no overflow.
    await pump(tester, const Size(844, 260), const []);
    expect(find.text('Nenhum evento registrado ainda'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long line is shown whole', (tester) async {
    await pump(tester, const Size(390, 844), events);
    final line = tester
        .widget<Text>(find.textContaining('voltou por outro dispositivo'));
    expect(line.maxLines, isNull);
    expect(line.overflow, isNull);
  });

  testWidgets('the filters, with how many of each', (tester) async {
    await pump(tester, const Size(1280, 800), events);
    expect(find.bySemanticsLabel('Todos, 7'), findsOneWidget);
    expect(find.bySemanticsLabel('Avisos, 2'), findsOneWidget);
    expect(find.bySemanticsLabel('Alarmes, 1'), findsOneWidget);

    await tester.tap(find.byKey(EventsScreen.keyFilter(PanelEventKind.info)));
    await tester.pump();
    expect(find.text('Sirene Hall — teste manual'), findsOneWidget);
    expect(find.text('outside name — alarme de fumaça'), findsNothing);

    // The same filter again: everything back.
    await tester.tap(find.byKey(EventsScreen.keyFilter(PanelEventKind.info)));
    await tester.pump();
    expect(find.text('outside name — alarme de fumaça'), findsOneWidget);
  });

  testWidgets('the search, by what the line says', (tester) async {
    await pump(tester, const Size(1280, 800), events);
    await tester.enterText(find.byKey(EventsScreen.keySearch), 'sala 2');
    await tester.pump();
    expect(find.text('Sala 2 — voltou a comunicar'), findsOneWidget);
    expect(find.text('Sirene Hall — teste manual'), findsNothing);

    await tester.enterText(find.byKey(EventsScreen.keySearch), 'zzz');
    await tester.pump();
    expect(find.text('Nada encontrado'), findsOneWidget);
  });

  testWidgets('"Limpar" empties the screen and erases nothing', (tester) async {
    await pump(tester, const Size(1280, 800), events);
    await tester.tap(find.byKey(EventsScreen.keyClear));
    await tester.pump();
    expect(find.text('Nenhum evento desde a limpeza'), findsOneWidget);
    expect(find.text('Sirene Hall — teste manual'), findsNothing);
    expect(find.bySemanticsLabel('Todos, 0'), findsOneWidget);

    await tester.tap(find.byKey(EventsScreen.keyShowAll));
    await tester.pump();
    expect(find.text('Sirene Hall — teste manual'), findsOneWidget);
    expect(find.byKey(EventsScreen.keyShowAll), findsNothing);
  });

  test('an event after the line is listed, one before it is not', () {
    final scope = ProviderContainer();
    addTearDown(scope.dispose);
    expect(scope.read(eventsClearedAtProvider(null)), isNull);
    scope.read(eventsClearedAtProvider(null).notifier).clear(now);
    expect(scope.read(eventsClearedAtProvider(null)), now);
    // Each central has its own line.
    expect(scope.read(eventsClearedAtProvider(central)), isNull);
    scope.read(eventsClearedAtProvider(null).notifier).showAll();
    expect(scope.read(eventsClearedAtProvider(null)), isNull);
  });

  testWidgets('the tablet reads more of its table when asked', (tester) async {
    final many = [
      for (var i = 0; i < eventsPageSize + 30; i++)
        ev(PanelEventKind.ok, 'evento $i', Duration(seconds: i)),
    ];
    await pump(tester, const Size(1280, 800), many);
    expect(find.bySemanticsLabel('Todos, $eventsPageSize'), findsOneWidget);
    await tester.dragUntilVisible(find.byKey(EventsScreen.keyMore),
        find.byType(ListView), const Offset(0, -2000));
    await tester.tap(find.byKey(EventsScreen.keyMore));
    await tester.pump();
    expect(
        find.bySemanticsLabel('Todos, ${eventsPageSize + 30}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone: nothing yet, and a central that sends no events',
      (tester) async {
    await pump(tester, const Size(390, 844), const [],
        phone: true, view: PanelView.unknown);
    expect(find.text('Verificando…'), findsOneWidget);

    await pump(tester, const Size(390, 844), const [],
        phone: true, view: const PanelView(known: true, eventsKnown: false));
    expect(find.textContaining('atualize o app da central'), findsOneWidget);

    await pump(tester, const Size(390, 844), const [], phone: true);
    expect(find.text('Nenhum evento registrado ainda'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ── Agrupado ──────────────────────────────────────────────────────────
  // 2026-11-23, 16:34 → 16:36: five units with no path at the same time,
  // as the central listed them, plus what else was in the list.
  const b = '5A:46:52:00:00:02';
  const c = '5A:46:52:00:00:03';
  final end = now.subtract(const Duration(minutes: 20));
  MirrorPanelEvent outage(String name, String mac, int seconds,
      {int cause = 3, int end_ = 3, Duration after = Duration.zero}) {
    final o = PanelOutage(
        duration: Duration(seconds: seconds),
        cause: cause,
        flags: 2,
        rescues: 1,
        restarts: 1,
        end: end_);
    return MirrorPanelEvent(
      at: end.add(after),
      severity: 1,
      mac: mac,
      outage: o,
      zone: 'Bloco A',
      address: 'Corredor 2º andar',
      text: '$name — ficou sem caminho até a central',
    );
  }

  final incident = [
    outage('8598', c, 128, end_: 2, after: const Duration(seconds: 1)),
    outage('2329', b, 134),
    outage('f56c', a, 133, cause: 2),
    MirrorPanelEvent(
        at: end.subtract(const Duration(seconds: 30)),
        severity: 0,
        mac: a,
        comm: PanelCommChange.restored,
        text: 'f56c — voltou a comunicar'),
    MirrorPanelEvent(
        at: end.subtract(const Duration(seconds: 30)),
        severity: 1,
        mac: a,
        comm: PanelCommChange.missing,
        text: 'f56c — sem comunicação'),
    // Long before: a silence and its return, and a line by itself.
    MirrorPanelEvent(
        at: end.subtract(const Duration(minutes: 30)),
        severity: 0,
        mac: b,
        comm: PanelCommChange.restored,
        text: '2329 — voltou a comunicar'),
    MirrorPanelEvent(
        at: end.subtract(const Duration(minutes: 31)),
        severity: 1,
        mac: b,
        comm: PanelCommChange.missing,
        text: '2329 — sem comunicação'),
    ev(PanelEventKind.info, 'Sirene Hall — teste manual',
        const Duration(hours: 2),
        mac: a),
  ];

  test('lines that happened together are one group', () {
    final groups = groupEvents(incident);
    expect(groups, hasLength(3));
    final g = groups[0] as NetworkIncident;
    expect(g.units, hasLength(3));
    expect(g.related, hasLength(2));
    expect(g.lines, hasLength(5));
    // It began 134 s before the reports of that second.
    expect(g.from, end.subtract(const Duration(seconds: 134)));
    expect(g.to, end.add(const Duration(seconds: 1)));
    // The one whose own link broke is where it began.
    expect(g.origins.single.name, 'f56c');
    expect(g.originsAreAll, isFalse);
    expect(g.restarted, 3);
    expect(g.backAsRoot.single.name, '8598');
    expect(incidentTitle(g), contains('3 dispositivos ficaram 2 min 15 s'));
    expect(
        incidentFacts(g),
        containsAll([
          'começou em f56c',
          'todos reiniciaram sozinhos',
          '8598 voltou como raiz'
        ]));

    final gap = groups[1] as CommGap;
    expect(gap.duration, const Duration(minutes: 1));
    expect((groups[2] as SingleEvent).event.text, contains('teste manual'));
    // Nothing is lost and nothing is listed twice.
    expect(groups.expand((g) => g.lines).toSet(), incident.toSet());
    expect(groups.expand((g) => g.lines), hasLength(incident.length));
  });

  test('outages apart in time are apart; a silence with no return stays', () {
    final groups = groupEvents([
      outage('2329', b, 30),
      MirrorPanelEvent(
          at: end.subtract(const Duration(hours: 1)),
          severity: 1,
          mac: a,
          outage: const PanelOutage(duration: Duration(seconds: 40)),
          text: 'f56c — ficou 40 s sem caminho até a central'),
      MirrorPanelEvent(
          at: end.subtract(const Duration(hours: 3)),
          severity: 1,
          mac: c,
          comm: PanelCommChange.missing,
          text: '8598 — sem comunicação'),
    ]);
    expect(groups.map((g) => g.runtimeType),
        [NetworkIncident, NetworkIncident, SingleEvent]);
    final one = groups.first as NetworkIncident;
    expect(one.origins, isEmpty);
    expect(incidentTitle(one), startsWith('2329 — ficou 30 s'));
  });

  test(
      'a unit that left for a better signal is where the incident began; '
      'moves that worked are no incident', () {
    MirrorPanelEvent move(String name, String mac, Duration ago,
            {bool clean = true}) =>
        MirrorPanelEvent(
          at: end.subtract(ago),
          severity: clean ? 0 : 1,
          kind: clean ? PanelEventKind.info : PanelEventKind.trouble,
          mac: mac,
          outage: PanelOutage(
              duration: Duration(seconds: clean ? 6 : 133),
              cause: 6,
              end: clean ? 4 : 3,
              restarts: clean ? 0 : 1),
          text: clean
              ? '$name — mudou de Hall para Escada, por um sinal melhor '
                  '(-86 para -71 dBm) · levou 6 s'
              : '$name — ficou 2 min 13 s sem caminho até a central · saiu '
                  'de Hall para Escada, por um sinal melhor · reiniciou '
                  'sozinho 1 vez · não ligou nele e voltou por outro caminho',
        );

    // Two units moved an hour apart, and each got there: two lines.
    final calm = groupEvents([
      move('f56c', a, const Duration(hours: 1)),
      move('2329', b, const Duration(hours: 2)),
    ]);
    expect(calm.map((g) => g.runtimeType), [SingleEvent, SingleEvent]);

    // One left for a better signal, did not get there, and the units
    // under it lost the path: one incident, begun by the one that left.
    final groups = groupEvents([
      outage('8598', c, 128),
      outage('2329', b, 134),
      move('f56c', a, Duration.zero, clean: false),
    ]);
    final g = groups.single as NetworkIncident;
    expect(g.units, hasLength(3));
    expect(g.origins.single.name, 'f56c');
    // A unit restarted itself: it got lost trying. A trouble.
    expect(g.reorganisation, isFalse);
    expect(g.origins.single.words.first,
        'saiu de Hall para Escada, por um sinal melhor');
    expect(incidentFacts(g), contains('começou em f56c'));
  });

  // Decided 2026-11-24: re-forming on purpose is news; a trouble only when
  // a unit gets lost trying.
  group('the network re-forming for a stronger signal', () {
    MirrorPanelEvent line(String name, String mac, int seconds,
            {int cause = 3, int end_ = 3, int restarts = 0}) =>
        MirrorPanelEvent(
          at: end,
          severity: 1,
          mac: mac,
          outage: PanelOutage(
              duration: Duration(seconds: seconds),
              cause: cause,
              rescues: 1,
              restarts: restarts,
              end: end_),
          text: '$name — ficou $seconds s sem caminho até a central',
        );
    MirrorPanelEvent comm(String name, String mac, PanelCommChange c) =>
        MirrorPanelEvent(
          at: end.subtract(const Duration(seconds: 5)),
          severity: c == PanelCommChange.missing ? 1 : 0,
          mac: mac,
          comm: c,
          text: '$name — ${c.name}',
        );

    test('is news: the unit that moved and the units under it', () {
      final lines = [
        line('8598', c, 24),
        line('2329', b, 26),
        line('f56c', a, 28, cause: 6), // left by itself, came back another way
        comm('2329', b, PanelCommChange.restored),
        comm('2329', b, PanelCommChange.missing),
        ev(PanelEventKind.trouble, 'Sala 9 — bateria baixa',
            const Duration(hours: 3)),
      ];
      expect(lines.take(3).map((e) => e.kind),
          everyElement(PanelEventKind.trouble));
      final listed = listReorganisationsAsNews(lines);
      expect(
          listed.take(5).map((e) => e.kind), everyElement(PanelEventKind.info));
      // What has nothing to do with it keeps its kind.
      expect(listed.last.kind, PanelEventKind.trouble);
      final g = groupEvents(listed).first as NetworkIncident;
      expect(g.reorganisation, isTrue);
      expect(incidentTitle(g),
          'A rede se reorganizou para um sinal melhor · 3 dispositivos · 28 s');
    });

    test('is a trouble when a unit got lost trying', () {
      // One of them had to restart itself.
      final restarted = [
        line('2329', b, 134, restarts: 1),
        line('f56c', a, 28, cause: 6),
      ];
      expect(listReorganisationsAsNews(restarted).map((e) => e.kind),
          everyElement(PanelEventKind.trouble));

      // One went silent in it and was not heard again: that line stays.
      final silent = listReorganisationsAsNews([
        line('f56c', a, 28, cause: 6),
        comm('8598', c, PanelCommChange.missing),
      ]);
      expect(silent.first.kind, PanelEventKind.info);
      expect(silent.last.kind, PanelEventKind.trouble);

      // No unit moved by itself: an outage is an outage.
      expect(
          listReorganisationsAsNews([line('2329', b, 26), line('8598', c, 24)])
              .map((e) => e.kind),
          everyElement(PanelEventKind.trouble));
    });

    testWidgets('on the screen: one blue tile, counted under Avisos',
        (tester) async {
      final lines = [
        line('8598', c, 24),
        line('2329', b, 26),
        line('f56c', a, 28, cause: 6),
      ];
      for (final grouped in [true, false]) {
        await pump(tester, const Size(1280, 800), lines, grouped: grouped);
        expect(find.bySemanticsLabel('Avisos, 3'), findsOneWidget);
        expect(find.bySemanticsLabel('Problemas, 0'), findsOneWidget);
        expect(find.text('PROBLEMA'), findsNothing);
        expect(find.text('AVISO'), grouped ? findsOneWidget : findsNWidgets(3));
        expect(tester.takeException(), isNull);
      }
    });
  });

  test('the central sends what a phone needs to group the same way', () {
    final sent = decodeMirrorAlarms(encodeMirrorAlarms(
      at: now,
      alarms: const [],
      panel: MirrorPanel(total: 5, troubles: 0, events: incident),
    ))!
        .panel!
        .events;
    expect(sent, hasLength(incident.length));
    expect(sent.first.outage!.toWire(), incident.first.outage!.toWire());
    expect(sent[3].comm, PanelCommChange.restored);
    expect(sent.first.zone, 'Bloco A');
    expect(sent.first.address, 'Corredor 2º andar');
    expect(sent.last.zone, isNull);
    expect(sent.last.outage, isNull);
    final groups = groupEvents(sent);
    expect(groups.first, isA<NetworkIncident>());
    expect((groups.first as NetworkIncident).units, hasLength(3));
  });

  for (final s in sizes.entries) {
    for (final phone in [false, true]) {
      final where = phone ? 'phone view' : 'tablet view';
      testWidgets('grouped — $where, ${s.key}', (tester) async {
        await pump(tester, s.value, incident, phone: phone, grouped: true);
        // One tile for the incident, one line for the silence, one line.
        expect(find.byType(IncidentTile), findsOneWidget);
        expect(find.byType(CommGapRow), findsOneWidget);
        expect(find.textContaining('3 dispositivos ficaram'), findsOneWidget);
        expect(
            find.textContaining('ficou 1 min sem comunicação'), findsOneWidget);
        // The units themselves are on the tile.
        expect(find.byKey(EventUnitAvatar.keyOf(c)), findsWidgets);
        expect(find.text('2329 — sem comunicação'), findsNothing);
        expect(tester.takeException(), isNull);

        // Open: each unit's part and the lines it was made of.
        final g = groupEvents(incident).first as NetworkIncident;
        await tester.tap(find.byKey(IncidentTile.keyToggle(g)));
        await tester.pumpAndSettle();
        expect(find.text('ONDE COMEÇOU'), findsOneWidget);
        expect(find.textContaining('LINHAS DO REGISTRO · 5'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.dragUntilVisible(
          find.textContaining(phone ? 'fica na central' : 'Fim da lista'),
          find.byType(ListView),
          const Offset(0, -300),
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('the switch: grouped, then every line', (tester) async {
    await pump(tester, const Size(1280, 800), incident, grouped: true);
    expect(find.byType(IncidentTile), findsOneWidget);
    // The filters count lines, in either view.
    expect(find.bySemanticsLabel('Todos, 8'), findsOneWidget);

    await tester.tap(find.byKey(EventsScreen.keyLines));
    await tester.pump();
    expect(find.byType(IncidentTile), findsNothing);
    expect(find.text('2329 — sem comunicação'), findsOneWidget);
    expect(find.byType(EventRow), findsNWidgets(8));

    await tester.tap(find.byKey(EventsScreen.keyGrouped));
    await tester.pump();
    expect(find.byType(IncidentTile), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('zona and endereçamento: columns when wide, a line when not',
      (tester) async {
    final lines = [incident.first];
    await pump(tester, const Size(1280, 800), lines);
    expect(find.text('ZONA'), findsOneWidget);
    expect(find.text('ENDEREÇAMENTO'), findsOneWidget);
    expect(find.text('Bloco A'), findsOneWidget);
    expect(find.text('Corredor 2º andar'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // A line with no unit: a dash in each column.
    await pump(tester, const Size(1280, 800),
        [ev(PanelEventKind.ok, 'Placa voltou a responder', Duration.zero)]);
    expect(find.text('—'), findsNWidgets(2));

    // A phone: no columns, where the unit is under what happened.
    await pump(tester, const Size(390, 844), lines, phone: true);
    expect(find.text('ZONA'), findsNothing);
    expect(find.text('Bloco A · Corredor 2º andar'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The search finds a line by where its unit is.
    await pump(tester, const Size(1280, 800), incident);
    await tester.enterText(find.byKey(EventsScreen.keySearch), 'corredor');
    await tester.pump();
    expect(find.bySemanticsLabel('Todos, 8'), findsOneWidget);
    expect(find.byType(EventRow), findsNWidgets(3));
  });

  // ── A look at it ──────────────────────────────────────────────────────
  final pngDir = Platform.environment['EVENTS_PNG_DIR'];
  for (final (label, size, phone, brightness) in [
    ('tablet', const Size(1280, 800), false, Brightness.dark),
    ('tablet_retrato', const Size(800, 1280), false, Brightness.dark),
    ('tablet_claro', const Size(1280, 800), false, Brightness.light),
    ('phone', const Size(390, 844), true, Brightness.dark),
    ('phone_paisagem', const Size(844, 390), true, Brightness.dark),
    ('linhas_colunas', const Size(1280, 800), false, Brightness.dark),
    ('agrupado_tablet', const Size(1280, 800), false, Brightness.dark),
    ('agrupado_tablet_retrato', const Size(800, 1280), false, Brightness.dark),
    ('agrupado_tablet_claro', const Size(1280, 800), false, Brightness.light),
    ('agrupado_phone', const Size(390, 844), true, Brightness.dark),
    ('agrupado_phone_paisagem', const Size(844, 390), true, Brightness.dark),
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
      final grouped = label.startsWith('agrupado');
      await pump(tester, size,
          grouped || label.startsWith('linhas') ? incident : events,
          phone: phone,
          grouped: grouped,
          brightness: brightness,
          boundary: key);
      if (grouped) {
        final g = groupEvents(incident).first as NetworkIncident;
        await tester.tap(find.byKey(IncidentTile.keyToggle(g)));
        await tester.pumpAndSettle();
      }
      await tester.runAsync(() async {
        final boundary =
            tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
        final image = await boundary.toImage(pixelRatio: 1.5);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$pngDir/eventos_$label.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
      });
    });
  }
}

/// The view a test starts in.
class _View extends EventsGrouped {
  _View(this._grouped);
  final bool _grouped;

  @override
  bool build() => _grouped;
}
