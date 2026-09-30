import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_report.dart';
import 'package:sempreiot_central_app/features/central/application/ota_push_state.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_report.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_state.dart';
import 'package:sempreiot_central_app/features/central/application/ota_rollout_words.dart';
import 'package:sempreiot_central_app/features/central/application/topology_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/firmware_update_widgets.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/ota_rollout_widgets.dart';

/// What a rollout means, in words and for the maps (protocol §13.6): pure
/// functions over a state.
void main() {
  const node = SafrProductFamily.node;
  const leaf = SafrProductFamily.leaf;
  const root = '5A:46:52:00:00:01';
  const siren = '5A:46:52:00:00:02';
  const button = '5A:46:52:00:00:03';
  final t0 = DateTime(2026, 9, 29, 14);

  OtaRolloutUnit row(
    String mac,
    SafrOtaUnitState s, {
    int percent = 0,
    int attempts = 0,
    int reason = 0,
    String version = '0.1.0',
    String? before = '0.1.0',
    DateTime? since,
  }) =>
      OtaRolloutUnit(
        mac: mac,
        productCode: 0x0201,
        state: s,
        percent: percent,
        attempts: attempts,
        reasonRaw: reason,
        version: version,
        versionBefore: before,
        changedAt: t0,
        activeSince: since ?? (s.active ? t0 : null),
      );

  OtaFamilyRollout family(
    SafrOtaRolloutState state, {
    List<OtaRolloutUnit> units = const [],
    SafrProductFamily of = node,
    String target = '0.2.0',
    OtaPauseCause? cause,
    DateTime? endedAt,
    int? total,
  }) =>
      OtaFamilyRollout(
        family: of,
        state: state,
        target: target,
        total: total ?? units.length,
        units: units,
        updatedAt: t0,
        startedAt: t0,
        endedAt: endedAt,
        pauseCause: cause,
      );

  OtaRolloutState state(List<OtaFamilyRollout> families,
          {bool? answered = true}) =>
      OtaRolloutState(
        boardAnswered: answered,
        families: {for (final f in families) f.family: f},
      );

  String nameOf(String mac) => switch (mac) {
        root => 'Repetidor escada',
        siren => 'Sirene hall',
        button => 'Botoeira garagem',
        _ => mac,
      };

  group('what the board holds', () {
    test('the board\'s headers, when it answered', () {
      final s = state([
        family(SafrOtaRolloutState.staged),
        family(SafrOtaRolloutState.done, of: leaf, target: '0.3.1'),
      ]);
      expect(otaHeldOnBoard(s, const {node: '0.1.9'}),
          {node: '0.2.0', leaf: '0.3.1'});
      expect(otaNothingSentYet(s, node), isTrue);
      expect(otaNothingSentYet(s, leaf), isFalse);
    });

    test('this session\'s memory, when it never did', () {
      const session = {node: '0.1.9'};
      expect(otaHeldOnBoard(const OtaRolloutState(), session), session);
      expect(
          otaHeldOnBoard(
              const OtaRolloutState(boardAnswered: false), session),
          session);
      expect(otaNothingSentYet(const OtaRolloutState(), node), isTrue);
    });

    test('a header with no version holds nothing', () {
      final s = state([family(SafrOtaRolloutState.staged, target: '')]);
      expect(otaHeldOnBoard(s, const {node: '0.1.9'}), isEmpty);
    });

    test('the line of the link card', () {
      expect(otaHeldLine(node, '0.2.0', null),
          'firmware de rede elétrica 0.2.0 · ainda não enviado aos dispositivos');
      expect(
          otaHeldLine(node, '0.2.0', family(SafrOtaRolloutState.rolling)),
          'firmware de rede elétrica 0.2.0 · sendo enviado aos dispositivos');
      expect(otaHeldLine(node, '0.2.0', family(SafrOtaRolloutState.paused)),
          'firmware de rede elétrica 0.2.0 · envio aos dispositivos pausado');
      expect(otaHeldLine(node, '0.2.0', family(SafrOtaRolloutState.done)),
          'firmware de rede elétrica 0.2.0 · enviado aos dispositivos');
      expect(
          otaHeldLine(node, '0.2.0', family(SafrOtaRolloutState.partial)),
          'firmware de rede elétrica 0.2.0 · enviado a parte dos dispositivos');
      expect(otaHeldLine(leaf, '0.3.1', family(SafrOtaRolloutState.staged)),
          'firmware de bateria 0.3.1 · ainda não enviado aos dispositivos');
    });
  });

  group('the header', () {
    test('ENVIANDO, PAUSADO, PAUSADO POR ALARME, CONCLUÍDO, PARCIAL', () {
      expect(otaRolloutHeadline(family(SafrOtaRolloutState.rolling)),
          'ENVIANDO');
      expect(otaRolloutHeadline(family(SafrOtaRolloutState.paused)),
          'PAUSADO');
      expect(
          otaRolloutHeadline(family(SafrOtaRolloutState.paused,
              cause: OtaPauseCause.operator)),
          'PAUSADO');
      expect(
          otaRolloutHeadline(family(SafrOtaRolloutState.paused,
              cause: OtaPauseCause.alarm)),
          'PAUSADO POR ALARME');
      expect(otaRolloutHeadline(family(SafrOtaRolloutState.done)),
          'CONCLUÍDO');
      expect(otaRolloutHeadline(family(SafrOtaRolloutState.partial)),
          'PARCIAL');
    });

    test('counts', () {
      final f = family(SafrOtaRolloutState.partial, units: [
        row(root, SafrOtaUnitState.done),
        row(siren, SafrOtaUnitState.failed, reason: 8),
        row(button, SafrOtaUnitState.skipped, reason: 11),
        row('x', SafrOtaUnitState.waiting),
        row('y', SafrOtaUnitState.downloading),
      ]);
      expect(f.doneCount, 1);
      expect(f.failedCount, 1);
      expect(f.skippedCount, 1);
      expect(f.settledCount, 3);
      expect(f.unitCount, 5);
      expect(f.current!.mac, 'y');
      expect(f.failures.single.mac, siren);
      expect(otaCountsText(f), '1 atualizado, 1 ignorado, 1 com falha, de 5');
      expect(
          otaCountsText(family(SafrOtaRolloutState.done, units: [
            row(root, SafrOtaUnitState.done),
            row(siren, SafrOtaUnitState.done),
          ])),
          '2 atualizados, de 2');
    });

    test('a header ahead of its rows: the header\'s total counts', () {
      expect(family(SafrOtaRolloutState.rolling, total: 7).unitCount, 7);
    });
  });

  group('a unit, in words', () {
    test('every state', () {
      expect(
        [
          for (final s in SafrOtaUnitState.values) otaUnitStateText(s, 40),
        ],
        [
          'Aguardando',
          'Oferta enviada',
          'Baixando 40 %',
          'Verificando',
          'Reiniciando',
          'Autoteste',
          'Atualizado',
          'Falhou',
          'Ignorado',
        ],
      );
      expect(otaUnitStateLog(SafrOtaUnitState.downloading, 70),
          'baixando 70 %');
    });

    test('every reason has words of its own, none about the push', () {
      final texts = <String>{};
      for (final r in SafrOtaReason.values) {
        final t = otaUnitReasonText(r, raw: r.wire);
        if (r == SafrOtaReason.none) {
          expect(t, isEmpty);
          continue;
        }
        expect(t, isNotEmpty, reason: r.name);
        expect(t.endsWith('.'), isTrue, reason: r.name);
        expect(t.contains('arquivo'), isFalse,
            reason: '${r.name}: the operator sent no file to this unit');
        expect(texts.add(t), isTrue, reason: '${r.name} repeats another');
      }
      expect(otaUnitReasonText(SafrOtaReason.unknown, raw: 42),
          'Motivo desconhecido (código 42).');
      expect(otaReasonLogText(8),
          'motivo 8: o dispositivo não conseguiu baixar a imagem da placa');
      expect(otaReasonLogText(42),
          'motivo 42: motivo desconhecido (código 42)');
      expect(otaReasonLogText(0), 'motivo 0');
    });

    test('the tries: ATTEMPTS counts the offers that failed', () {
      expect(otaAttemptsText(row(siren, SafrOtaUnitState.downloading)),
          isNull);
      expect(
          otaAttemptsText(
              row(siren, SafrOtaUnitState.waiting, attempts: 1, reason: 8)),
          'falhou uma vez, será tentado de novo');
      expect(
          otaAttemptsText(
              row(siren, SafrOtaUnitState.downloading, attempts: 1)),
          '2ª tentativa');
      expect(otaAttemptsText(row(siren, SafrOtaUnitState.done, attempts: 1)),
          'na 2ª tentativa');
      expect(
          otaAttemptsText(row(siren, SafrOtaUnitState.failed, attempts: 2)),
          '2 tentativas');
      expect(
          otaAttemptsText(row(siren, SafrOtaUnitState.failed, attempts: 1)),
          '1 tentativa');
      expect(
          otaAttemptsText(row(siren, SafrOtaUnitState.skipped, attempts: 1)),
          isNull);
    });

    test('"versão agora → alvo"', () {
      expect(
          otaVersionChangeText(row(siren, SafrOtaUnitState.waiting), '0.2.0'),
          '0.1.0 → 0.2.0');
      // The board does not know what it runs: the registry may.
      expect(
          otaVersionChangeText(
              row(siren, SafrOtaUnitState.waiting, version: ''), '0.2.0',
              known: '0.1.0-dev'),
          '0.1.0-dev → 0.2.0');
      expect(
          otaVersionChangeText(
              row(siren, SafrOtaUnitState.waiting, version: ''), '0.2.0'),
          '— → 0.2.0');
      expect(
          otaVersionChangeText(
              row(siren, SafrOtaUnitState.done, version: '0.2.0'), '0.2.0'),
          '0.1.0 → 0.2.0');
      expect(
          otaVersionChangeText(
              row(siren, SafrOtaUnitState.done,
                  version: '0.2.0', before: null),
              '0.2.0'),
          '0.2.0');
      // Failed: it runs what it ran, the target is still the target.
      expect(
          otaVersionChangeText(
              row(siren, SafrOtaUnitState.failed, reason: 9), '0.2.0'),
          '0.1.0 → 0.2.0');
    });

    test('a row of the table, for the log', () {
      expect(
          otaUnitRowLog(row(siren, SafrOtaUnitState.failed,
              attempts: 2, reason: 10)),
          'falhou, 2 tentativas, motivo 10: o dispositivo não respondeu a '
          'tempo, versão 0.1.0');
      expect(
          otaUnitRowLog(
              row(siren, SafrOtaUnitState.downloading, percent: 30)),
          'baixando 30 %, versão 0.1.0');
    });

    test('why the board refused what the tablet asked', () {
      expect(
          otaControlRefusal(SafrOtaAction.start, SafrOtaReason.badArgs),
          'A placa recusou: ela não tem a imagem guardada, ou nenhum '
          'dispositivo online passa pelo filtro escolhido.');
      expect(otaControlRefusal(SafrOtaAction.pause, SafrOtaReason.badArgs),
          'A placa recusou: não há atualização em andamento para pausar.');
      expect(otaControlRefusal(SafrOtaAction.start, SafrOtaReason.busy),
          'A placa já está com uma atualização em andamento.');
      expect(
          otaControlRefusal(SafrOtaAction.resume, SafrOtaReason.busyAlarm),
          'A placa recusou: houve alarme nos últimos 10 minutos. Tente de '
          'novo depois.');
      expect(otaControlRefusal(SafrOtaAction.start, SafrOtaReason.none),
          'A placa recusou o pedido.');
    });

    test('the filter, in words', () {
      expect(otaFilterText(const SafrOtaFilter.all()),
          'todos os dispositivos');
      expect(otaFilterText(const SafrOtaFilter.product(0x0201)),
          'produto Sirene (0x0201)');
      expect(otaFilterText(const SafrOtaFilter.product(0x0277)),
          'produto Produto desconhecido 0x0277 (0x0277)');
      expect(otaFilterText(const SafrOtaFilter.zone('Térreo')),
          'zona "Térreo"');
      expect(otaFilterText(const SafrOtaFilter.unit(siren)),
          'dispositivo $siren');
      expect(
          otaFilterText(const SafrOtaFilter.unit(siren),
              unitName: 'Sirene hall'),
          'dispositivo Sirene hall ($siren)');
    });
  });

  group('the banner', () {
    final units = [
      row(root, SafrOtaUnitState.waiting),
      row(siren, SafrOtaUnitState.done, version: '0.2.0'),
      row(button, SafrOtaUnitState.downloading, percent: 40),
    ];

    test('what is going where, which of how many, how far', () {
      final b = otaRolloutBanner(
        state([family(SafrOtaRolloutState.rolling, units: units)]),
        nameOf: nameOf,
      )!;
      expect(b.kind, OtaRolloutBannerKind.rolling);
      expect(b.line, 'Atualização: placa → Botoeira garagem (2 de 3)');
      expect(b.tail, '40 %');
      expect(b.fullLine,
          'Atualização: placa → Botoeira garagem (2 de 3) · 40 %');
      expect(b.progress, closeTo(0.4, 1e-9));
      expect(b.running, isTrue);
      expect(b.tone, OtaReportTone.progress);
    });

    test('a phase with no number', () {
      final b = otaRolloutBanner(
        state([
          family(SafrOtaRolloutState.rolling, units: [
            row(siren, SafrOtaUnitState.selfTest, percent: 100),
          ]),
        ]),
        nameOf: nameOf,
      )!;
      expect(b.fullLine, 'Atualização: placa → Sirene hall (1 de 1) · '
          'autoteste');
      expect(b.progress, isNull);
    });

    test('between two units', () {
      final b = otaRolloutBanner(
        state([
          family(SafrOtaRolloutState.rolling, units: [
            row(root, SafrOtaUnitState.waiting),
            row(siren, SafrOtaUnitState.done),
          ]),
        ]),
        nameOf: nameOf,
      )!;
      expect(b.line, 'Atualização: placa → dispositivos de rede elétrica '
          '(1 de 2 concluídos)');
      expect(b.tail, 'próximo');
    });

    test('paused', () {
      final b = otaRolloutBanner(
        state([
          family(SafrOtaRolloutState.paused,
              units: units, cause: OtaPauseCause.alarm),
        ]),
        nameOf: nameOf,
      )!;
      expect(b.kind, OtaRolloutBannerKind.paused);
      expect(b.line, 'Atualização pausada por alarme: 1 de 3 concluídos · '
          'Botoeira garagem termina a sua');
      expect(b.tail, 'pausado');
      expect(b.running, isTrue);
      expect(b.tone, OtaReportTone.warning);
    });

    test('done and partial are news only when this session saw them end',
        () {
      final ended = DateTime(2026, 9, 29, 14, 6);
      final done = [
        row(root, SafrOtaUnitState.done),
        row(siren, SafrOtaUnitState.done),
      ];
      expect(
          otaRolloutBanner(
              state([family(SafrOtaRolloutState.done, units: done)]),
              nameOf: nameOf),
          isNull);
      final b = otaRolloutBanner(
        state([
          family(SafrOtaRolloutState.done, units: done, endedAt: ended),
        ]),
        nameOf: nameOf,
      )!;
      expect(b.kind, OtaRolloutBannerKind.done);
      expect(b.line,
          'Atualização concluída: 2 de 2 dispositivos na versão 0.2.0');
      expect(b.tail, isNull);
      expect(b.running, isFalse);
      expect(b.endedAt, ended);
      expect(b.tone, OtaReportTone.good);

      final p = otaRolloutBanner(
        state([
          family(SafrOtaRolloutState.partial,
              units: [
                row(root, SafrOtaUnitState.done),
                row(siren, SafrOtaUnitState.failed, reason: 9),
              ],
              endedAt: ended),
        ]),
        nameOf: nameOf,
      )!;
      expect(p.line, 'Atualização parcial: 1 atualizado, 1 com falha, de 2 · '
          'versão 0.2.0');
      expect(p.tone, OtaReportTone.warning, reason: 'never the green');

      // Closed by the operator.
      expect(
        otaRolloutBanner(
          state([
            family(SafrOtaRolloutState.done, units: done, endedAt: ended),
          ]),
          nameOf: nameOf,
          dismissed: ended,
        ),
        isNull,
      );
    });

    test('nothing to say: staged, nothing at all', () {
      expect(
          otaRolloutBanner(state([family(SafrOtaRolloutState.staged)]),
              nameOf: nameOf),
          isNull);
      expect(otaRolloutBanner(const OtaRolloutState(), nameOf: nameOf),
          isNull);
    });
  });

  group('the maps', () {
    test('unit by unit, and who downloads', () {
      final o = otaRolloutOverlay(
        state([
          family(SafrOtaRolloutState.rolling, units: [
            row(root, SafrOtaUnitState.waiting),
            row(siren, SafrOtaUnitState.done, version: '0.2.0'),
            row(button, SafrOtaUnitState.downloading, percent: 40),
          ]),
        ]),
        rootMac: root,
      );
      expect(o.downloading, button);
      expect(o[root]!.caption, 'por último');
      expect(o[root]!.last, isTrue);
      expect(o[root]!.updating, isFalse);
      expect(o[siren]!.state, SafrOtaUnitState.done);
      expect(o[siren]!.version, '0.2.0');
      expect(o[button]!.updating, isTrue);
      expect(o[button]!.progress, closeTo(0.4, 1e-9));
      expect(o[button]!.caption, 'baixando 40 %');
      expect(o['nobody'], isNull);
    });

    test('a unit that waits and is not the root: "aguardando"', () {
      final o = otaRolloutOverlay(
        state([
          family(SafrOtaRolloutState.rolling,
              units: [row(siren, SafrOtaUnitState.waiting)]),
        ]),
        rootMac: root,
      );
      expect(o[siren]!.caption, 'aguardando');
    });

    test('the root that is being updated is not "por último" any more', () {
      final o = otaRolloutOverlay(
        state([
          family(SafrOtaRolloutState.rolling, units: [
            row(root, SafrOtaUnitState.rebooting, percent: 100),
          ]),
        ]),
        rootMac: root,
      );
      expect(o[root]!.last, isFalse);
      expect(o[root]!.caption, 'reiniciando');
      expect(o[root]!.progress, isNull, reason: 'the ring turns');
      expect(o.downloading, isNull, reason: 'no packets: nothing travels');
    });

    test('paused: nobody new downloads, the one that does goes on', () {
      final o = otaRolloutOverlay(state([
        family(SafrOtaRolloutState.paused, units: [
          row(siren, SafrOtaUnitState.downloading, percent: 60),
          row(button, SafrOtaUnitState.waiting),
        ]),
      ]));
      expect(o.downloading, siren);
    });

    test('equal when it reads the same: a map is rebuilt once per change',
        () {
      OtaRolloutOverlay at(int percent) => otaRolloutOverlay(state([
            family(SafrOtaRolloutState.rolling, units: [
              row(siren, SafrOtaUnitState.downloading, percent: percent),
            ]),
          ]));
      expect(at(40), at(40));
      expect(at(40).hashCode, at(40).hashCode);
      expect(at(40) == at(50), isFalse);
      expect(otaRolloutOverlay(const OtaRolloutState()),
          OtaRolloutOverlay.none);
      expect(
          otaRolloutOverlay(state([family(SafrOtaRolloutState.staged)])),
          OtaRolloutOverlay.none);
    });

    test('over before the app looked: nothing on the map; seen ending: there '
        'until closed', () {
      final ended = DateTime(2026, 9, 29, 14, 6);
      final rows = [row(siren, SafrOtaUnitState.done, version: '0.2.0')];
      expect(
          otaRolloutOverlay(
              state([family(SafrOtaRolloutState.done, units: rows)])),
          OtaRolloutOverlay.none);
      final seen = state([
        family(SafrOtaRolloutState.done, units: rows, endedAt: ended),
      ]);
      expect(otaRolloutOverlay(seen)[siren]!.state, SafrOtaUnitState.done);
      expect(otaRolloutOverlay(seen, dismissed: ended),
          OtaRolloutOverlay.none);
    });

    TopologyNode unit(String mac, int layer, String? parent) => TopologyNode(
          mac: mac,
          role: SafrNodeRole.node,
          layer: layer,
          parentMac: parent,
          rssi: -60,
          batteryPct: null,
          online: true,
          lastSeenAt: t0,
          alarmLatched: false,
        );

    test('the way of the image: the board, the parents, the unit', () {
      const board = '7C:4F:AD:AE:85:90';
      final nodes = [
        unit(board, 0, null),
        unit(root, 1, board),
        unit(siren, 2, root),
        unit(button, 3, siren),
      ];
      expect(otaDownloadPath(nodes, button, '@central'),
          ['@central', root, siren, button]);
      expect(otaDownloadPath(nodes, root, '@central'), ['@central', root]);
      expect(otaDownloadPath(nodes, 'nobody', '@central'), isNull);
      // The board is folded into the CENTRAL: never a hop of its own.
      expect(otaDownloadPath(nodes, board, '@central'), isNull);
    });

    test('a parent the map does not have, and a loop', () {
      expect(
          otaDownloadPath(
              [unit(siren, 2, 'AA:AA:AA:AA:AA:AA')], siren, '@central'),
          ['@central', siren]);
      expect(
          otaDownloadPath([
            unit(siren, 2, button),
            unit(button, 2, siren),
          ], siren, '@central'),
          ['@central', button, siren]);
    });
  });

  group('who can be updated', () {
    TopologyNode unit(
      String mac, {
      String? name,
      String? zone,
      int? product,
      bool online = true,
      SafrNodeRole role = SafrNodeRole.node,
      int layer = 2,
      SafrDeviceState? board,
    }) =>
        TopologyNode(
          mac: mac,
          role: role,
          layer: layer,
          parentMac: null,
          rssi: -60,
          batteryPct: null,
          online: online,
          lastSeenAt: t0,
          alarmLatched: false,
          name: name,
          zone: zone,
          productCode: product,
          boardState: board,
        );

    final nodes = [
      unit('B', layer: 0, role: SafrNodeRole.root, product: 0x0100),
      unit(root, name: 'Repetidor', zone: 'Térreo', product: 0x0204, layer: 1),
      unit(siren, name: 'sirene hall', zone: 'Térreo', product: 0x0201),
      unit(button, name: 'Botoeira', zone: 'Garagem', product: 0x0202),
      unit('S2',
          name: 'Sirene 2', zone: 'Garagem', product: 0x0201, online: false),
      unit('OLD'), // never said its product
      unit('GONE',
          name: 'Aposentado',
          product: 0x0201,
          board: SafrDeviceState.retired),
      unit('L', role: SafrNodeRole.leaf, product: 0x0301, zone: 'Térreo'),
    ];

    test('the units of the family, by name; the board and the leaves are not',
        () {
      final c = OtaRolloutCandidates.of(nodes, node);
      expect(c.units.map((n) => n.mac), [button, root, 'S2', siren]);
      expect(c.unknownProduct.map((n) => n.mac), ['OLD']);
      final l = OtaRolloutCandidates.of(nodes, leaf);
      expect(l.units.map((n) => n.mac), ['L']);
    });

    test('the products and the zones that are there', () {
      final c = OtaRolloutCandidates.of(nodes, node);
      expect(c.products.map((p) => p.code), [0x0201, 0x0202, 0x0204]);
      expect(c.zones, ['Garagem', 'Térreo']);
    });

    test('the board queues who is online and passes the filter', () {
      final c = OtaRolloutCandidates.of(nodes, node);
      expect(c.reachable(const SafrOtaFilter.all()).map((n) => n.mac),
          [button, root, siren]);
      expect(c.passing(const SafrOtaFilter.all()), hasLength(4));
      expect(
          c.reachable(const SafrOtaFilter.product(0x0201)).map((n) => n.mac),
          [siren]);
      expect(c.passing(const SafrOtaFilter.product(0x0201)), hasLength(2));
      expect(c.reachable(const SafrOtaFilter.zone('Garagem')).map((n) => n.mac),
          [button]);
      expect(c.reachable(const SafrOtaFilter.unit('S2')), isEmpty);
      expect(c.reachable(const SafrOtaFilter.unit(root)).single.mac, root);
      expect(c.reachable(const SafrOtaFilter.zone('Cobertura')), isEmpty);
    });
  });

  group('the log of both', () {
    OtaLogLine at(int s, String text) =>
        OtaLogLine(t0.add(Duration(seconds: s)), text);

    test('by time; the push first when two lines share an instant', () {
      final push = [at(0, 'p0'), at(4, 'p4'), at(9, 'p9')];
      final ro = [at(2, 'r2'), at(4, 'r4'), at(12, 'r12')];
      expect([for (final l in otaMergedLog(push, ro)) l.text],
          ['p0', 'r2', 'p4', 'r4', 'p9', 'r12']);
      expect(otaMergedLog(push, const []), same(push));
      expect(otaMergedLog(const [], ro), same(ro));
    });
  });

  group('the 300 s', () {
    test('counted from when the row entered an active state', () {
      final u = row(siren, SafrOtaUnitState.rebooting, since: t0);
      expect(u.updatingAt(t0.add(const Duration(seconds: 299))), isTrue);
      expect(u.updatingAt(t0.add(const Duration(seconds: 300))), isFalse);
      expect(row(siren, SafrOtaUnitState.done).updatingAt(t0), isFalse);
      expect(row(siren, SafrOtaUnitState.waiting).updatingAt(t0), isFalse);
      expect(otaUpdatingGrace, const Duration(seconds: 300));
      expect(const OtaRolloutTimings().updatingGrace, otaUpdatingGrace);
    });
  });
}
