import '../domain/ota/firmware_version.dart';
import '../domain/safr/safr_product.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'device_update_selection.dart';
import 'device_update_state.dart';
import 'ota_push_state.dart';
import 'ota_rollout_state.dart' show OtaPauseCause;
import 'ota_rollout_words.dart';

// The words of "Atualizar dispositivos", in one place (pt-BR). Widgets only
// lay them out.

/// `v0.1.1`.
String vText(String version) =>
    version.isEmpty || version.startsWith('v') ? version : 'v$version';

/// "Placa" / "Nós" / "Detectores": the phases of "Atualizar tudo".
String deviceUpdatePhaseName(SafrProductFamily f) => switch (f) {
      SafrProductFamily.board => 'Placa',
      SafrProductFamily.node => 'Nós',
      SafrProductFamily.leaf => 'Detectores',
      SafrProductFamily.unknown => '',
    };

/// "placa v0.3.0 · nós v0.2.1 · detectores v0.1.4": the targets of an
/// "Atualizar tudo", one per family, in phase order.
String deviceUpdateTargetsText(Map<SafrProductFamily, String> targets) => [
      for (final e in targets.entries)
        '${deviceUpdatePhaseName(e.key).toLowerCase()} ${vText(e.value)}',
    ].join(' · ');

/// "a placa", "1 nó", "4 nós", "2 detectores".
String deviceUpdateCount(SafrProductFamily f, int n) => switch (f) {
      SafrProductFamily.board => 'a placa',
      SafrProductFamily.node => n == 1 ? '1 nó' : '$n nós',
      SafrProductFamily.leaf => n == 1 ? '1 detector' : '$n detectores',
      SafrProductFamily.unknown => '$n',
    };

/// "4 nós selecionados", "Placa selecionada".
String deviceUpdateSelectionTitle(DeviceUpdateSelection s) {
  final f = s.family;
  if (f == null) return '';
  if (f == SafrProductFamily.board) return 'Placa selecionada';
  final n = s.keys.length;
  return '${deviceUpdateCount(f, n)} ${n == 1 ? 'selecionado' : 'selecionados'}';
}

/// What a unit of the run does now.
String deviceUpdateUnitText(DeviceUpdateUnit u) {
  if (u.family == SafrProductFamily.leaf &&
      u.state == SafrOtaUnitState.offered) {
    return otaLeafOfferedText;
  }
  if (u.state == SafrOtaUnitState.skipped) return 'Não atualizado';
  return otaUnitStateText(u.state, u.percent);
}

/// Why a unit was not updated; empty = nothing to say.
String deviceUpdateWhy(DeviceUpdateUnit u) {
  final note = u.note;
  if (note != null && note.isNotEmpty) return note;
  return otaUnitReasonText(u.reason, raw: u.reasonRaw);
}

/// `2 min 05 s`, `45 s`.
String deviceUpdateDuration(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final m = s ~/ 60, r = s % 60;
  return m > 0 ? '$m min ${r.toString().padLeft(2, '0')} s' : '$r s';
}

/// How a line of the bar reads.
enum DeviceUpdateTone { info, ok, warn, error }

class DeviceUpdateBarText {
  const DeviceUpdateBarText(this.title, this.sub,
      [this.tone = DeviceUpdateTone.info]);
  final String title;
  final String sub;
  final DeviceUpdateTone tone;
}

/// Seconds a mains unit takes from offer to self-test (brief §8).
const _secondsPerNode = 40;

/// The bottom bar while a run is on screen.
DeviceUpdateBarText deviceUpdateBarText(
  DeviceUpdateRun run,
  OtaPushState push,
  DateTime now, {
  required String Function(String key) nameOf,
  ({int back, int total})? meshBack,
}) {
  final fam = run.family;
  final target = vText(run.targetOf(fam));
  final phase = run.all ? 'Fase ${run.phase + 1}: ' : '';
  final units = run.unitsOf(fam);
  final done = units.where((u) => u.state == SafrOtaUnitState.done).length;
  final failed = units.where((u) => u.state == SafrOtaUnitState.failed).length;
  final elapsed = deviceUpdateDuration(now.difference(run.startedAt));

  switch (run.stage) {
    case DeviceUpdateStage.pushing:
      final pct = (push.progress * 100).round();
      if (fam == SafrProductFamily.board) {
        return switch (push.phase) {
          OtaPushPhase.verifying => DeviceUpdateBarText(
              '${phase}a placa está verificando $target',
              'Assinatura e integridade da imagem'),
          OtaPushPhase.boardRestarting => DeviceUpdateBarText(
              '${phase}a placa está reiniciando com $target',
              'A central fica uns 30 s sem supervisão'
                  '${run.all ? ' · se falhar, nada mais é tocado' : ''}'),
          _ => DeviceUpdateBarText('${phase}enviando $target à placa · $pct %',
              '${push.chunksDone} de ${push.chunksTotal} blocos pelo cabo'),
        };
      }
      return DeviceUpdateBarText(
        '${phase}enviando $target para ${_these(fam)} · $pct %',
        '${push.chunksDone} de ${push.chunksTotal} blocos pelo cabo · depois '
            'a placa atualiza um de cada vez',
      );

    case DeviceUpdateStage.rolling:
      final counts = '$done de ${units.length} '
          '${fam == SafrProductFamily.leaf ? 'detectores' : 'nós'} atualizados'
          '${failed > 0 ? ' · $failed com falha' : ''}';
      if (run.pausedBy == OtaPauseCause.alarm) {
        return DeviceUpdateBarText(
            'Pausado por alarme · $counts',
            'O que estava baixando termina; nenhum outro começa. Rearme a '
                'central e toque em Retomar.',
            DeviceUpdateTone.error);
      }
      if (run.paused) {
        return DeviceUpdateBarText(
            'Pausado · $counts',
            'Nenhum dispositivo começa até você tocar em Retomar.',
            DeviceUpdateTone.warn);
      }
      if (fam == SafrProductFamily.leaf) {
        return DeviceUpdateBarText(
            '$phase$counts',
            'Em segundo plano: cada detector atualiza quando acordar. Pode '
                'sair desta tela; a Rede mostra o andamento.');
      }
      final cur = run.current;
      final left = units.where((u) => !u.state.settled).length;
      final remaining = left * _secondsPerNode;
      return DeviceUpdateBarText(
        '$phase$counts',
        [
          if (cur != null) 'Agora: ${nameOf(cur.key)}',
          'há $elapsed',
          if (remaining > 0) 'faltam ~${(remaining / 60).ceil()} min',
          'para $target',
        ].join(' · '),
      );

    case DeviceUpdateStage.reconnecting:
      final b = meshBack;
      return DeviceUpdateBarText(
        '${phase}a placa reiniciou: aguardando os nós voltarem'
            '${b == null || b.total == 0 ? '' : ' · ${b.back} de ${b.total}'}',
        'Os dispositivos se reconectam à placa sozinhos; o envio continua '
            'assim que todos voltarem (até 5 min).',
      );

    case DeviceUpdateStage.deciding:
      final bad = [for (final u in run.notUpdated(fam)) nameOf(u.key)];
      return DeviceUpdateBarText(
        bad.length == 1
            ? '1 nó não foi atualizado: ${bad.single}'
            : '${bad.length} nós não foram atualizados: ${bad.join(', ')}',
        'Os detectores se ligam pelos nós. Tente de novo, continue mesmo '
        'assim ou pare aqui.',
        DeviceUpdateTone.warn,
      );

    case DeviceUpdateStage.ended:
      return _ended(run, target, now, nameOf);
  }
}

DeviceUpdateBarText _ended(
  DeviceUpdateRun run,
  String target,
  DateTime now,
  String Function(String key) nameOf,
) {
  final took =
      deviceUpdateDuration((run.endedAt ?? now).difference(run.startedAt));
  final done = run.count(SafrOtaUnitState.done);
  final total = run.units.length;
  final failed = run.count(SafrOtaUnitState.failed);
  // Not updated without a failure: skipped by the board, never offered.
  final left = run.notUpdatedCount - failed;
  switch (run.end) {
    case DeviceUpdateEnd.done:
      return DeviceUpdateBarText(
        run.all
            ? 'Tudo atualizado para $target'
            : run.family == SafrProductFamily.board
                ? 'Placa atualizada para $target'
                : '$done de $total atualizados para $target',
        'Levou $took',
        DeviceUpdateTone.ok,
      );
    case DeviceUpdateEnd.partial:
      return DeviceUpdateBarText(
        '$done de $total atualizados para $target'
            '${failed > 0 ? ' · $failed com falha' : ''}'
            '${left > 0 ? ' · $left não ${left == 1 ? 'recebeu' : 'receberam'}' : ''}',
        '${failed + left > 0 ? 'Toque num dispositivo para ver o motivo · ' : ''}'
            'levou $took',
        DeviceUpdateTone.warn,
      );
    case DeviceUpdateEnd.stopped:
      final nodes = run.unitsOf(SafrProductFamily.node);
      final nodesDone =
          nodes.where((u) => u.state == SafrOtaUnitState.done).length;
      return DeviceUpdateBarText(
        'Parado antes dos detectores',
        'Placa e $nodesDone de ${nodes.length} nós em $target · os detectores '
            'continuam como estavam',
        DeviceUpdateTone.warn,
      );
    case DeviceUpdateEnd.cancelled:
      return const DeviceUpdateBarText(
        'Atualização cancelada',
        'O que já tinha terminado fica na versão nova; o resto continua como '
            'estava.',
        DeviceUpdateTone.warn,
      );
    case DeviceUpdateEnd.failed:
    case null:
      return DeviceUpdateBarText(
        run.family == SafrProductFamily.board
            ? 'A placa não foi atualizada'
            : 'A atualização não começou',
        run.message ?? 'O envio à placa falhou.',
        DeviceUpdateTone.error,
      );
  }
}

String _these(SafrProductFamily f) => switch (f) {
      SafrProductFamily.node => 'os nós',
      SafrProductFamily.leaf => 'os detectores',
      _ => 'a placa',
    };

/// Under a phase of "Atualizar tudo", in the firmware sheet.
String deviceUpdatePhaseHow(SafrProductFamily f) => switch (f) {
      SafrProductFamily.board =>
        'reinicia; a central fica uns 30 s sem supervisão',
      SafrProductFamily.node => 'um de cada vez, o ROOT por último',
      SafrProductFamily.leaf =>
        'quando acordam, com bateria acima de 60 %; em segundo plano',
      SafrProductFamily.unknown => '',
    };

/// What happens once the operator confirms, in the firmware sheet.
String deviceUpdateSheetInfo(SafrProductFamily? f, {required bool all}) {
  if (all) {
    return 'Se a placa falhar, nada mais é tocado. Se algum nó falhar, você '
        'decide antes dos detectores. Um alarme pausa tudo.';
  }
  return switch (f) {
    SafrProductFamily.board =>
      'O tablet envia à placa pelo cabo (~15 s). A placa reinicia e faz o '
          'autoteste: a central fica uns 30 s sem supervisão. Se algo falhar, '
          'ela volta sozinha à versão anterior.',
    SafrProductFamily.leaf => otaLeafNote,
    _ => 'O tablet envia à placa pelo cabo (~15 s). Depois a placa atualiza '
        'um de cada vez, o ROOT por último; cada um fica uns 40 s '
        'reiniciando. Um alarme pausa tudo.',
  };
}

/// What the chosen units run, for the bar and the firmware sheet: "roda
/// v0.2.5", "rodam v0.2.5", "rodam v0.2.5 a v2.2.5"; empty when none said.
String deviceUpdateRunsText(List<String> runs) {
  final known = {
    for (final r in runs)
      if (r.isNotEmpty) r
  }.toList()
    ..sort(compareFirmwareVersions);
  if (known.isEmpty) return '';
  final verb = runs.length == 1 ? 'roda' : 'rodam';
  return known.length == 1
      ? '$verb ${vText(known.single)}'
      : '$verb ${vText(known.first)} a ${vText(known.last)}';
}

/// Under a firmware that cannot go to the chosen units because it is not
/// newer than what they run: the same version, or an older one — and which.
String deviceUpdateNotNewerText(String version, List<String> runs) {
  final known = [
    for (final r in runs)
      if (r.isNotEmpty) r
  ]..sort(compareFirmwareVersions);
  final one = runs.length == 1;
  if (known.isEmpty) return '';
  if (known.every((r) => compareFirmwareVersions(r, version) == 0)) {
    return 'É a versão que ${one ? 'ele já roda' : 'eles já rodam'}';
  }
  return 'Mais antiga que a que ${one ? 'ele roda' : 'eles rodam'} '
      '(${vText(known.last)})';
}

/// A firmware against what the chosen units run.
enum DeviceUpdateVersionKind {
  /// Newer than what at least one of them runs (or one never said).
  newer,

  /// What every one of them runs: a reinstall.
  same,

  /// Older: going back.
  older,
}

DeviceUpdateVersionKind deviceUpdateVersionKind(
    String version, List<String> runs) {
  if (runs.isEmpty ||
      runs.any((r) => r.isEmpty || compareFirmwareVersions(version, r) > 0)) {
    return DeviceUpdateVersionKind.newer;
  }
  if (runs.every((r) => compareFirmwareVersions(r, version) == 0)) {
    return DeviceUpdateVersionKind.same;
  }
  return DeviceUpdateVersionKind.older;
}

/// The confirm button of the firmware sheet.
String deviceUpdateConfirmText(DeviceUpdateVersionKind kind, String version,
    {required bool all}) {
  final v = vText(version);
  return switch (kind) {
    DeviceUpdateVersionKind.newer =>
      all ? 'Atualizar tudo para $v' : 'Atualizar para $v',
    DeviceUpdateVersionKind.older =>
      all ? 'Voltar tudo para $v' : 'Voltar para $v',
    DeviceUpdateVersionKind.same =>
      all ? 'Reinstalar tudo ($v)' : 'Reinstalar $v',
  };
}

/// The question before an older version or a reinstall; null = no question.
({String title, String body})? deviceUpdateAskFirst(
    DeviceUpdateVersionKind kind, String version, List<String> runs) {
  const production = 'Em produção os dispositivos só aceitam uma versão mais '
      'nova e recusam esta; na bancada a regra de versão está desligada.';
  final now = deviceUpdateRunsText(runs);
  return switch (kind) {
    DeviceUpdateVersionKind.newer => null,
    DeviceUpdateVersionKind.older => (
        title: 'Voltar para uma versão anterior?',
        body:
            '${now.isEmpty ? 'Os dispositivos vão' : '${_capitalised(now)} e vão'} '
            'para ${vText(version)}, mais antiga. $production',
      ),
    DeviceUpdateVersionKind.same => (
        title: 'Reinstalar a mesma versão?',
        body:
            '${vText(version)} é instalada de novo, com a reinicialização e o '
            'autoteste. $production',
      ),
  };
}

String _capitalised(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
