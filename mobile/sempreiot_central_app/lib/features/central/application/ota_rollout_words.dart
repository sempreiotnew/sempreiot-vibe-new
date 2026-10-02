import '../domain/safr/safr_product.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'ota_rollout_state.dart';

// The rollout in plain pt-BR: one place, so the update screen, the Rede
// maps and the log say the same thing. Pure functions; nothing here decides
// anything about the rollout.

/// Why the battery units' image cannot be sent yet (protocol §13.5).
/// Under a battery image's form (protocol §13.5): what to expect of a leaf.
const otaLeafNote =
    'Um detector a bateria recebe a oferta quando acorda (a cada minuto), '
    'baixa o firmware nessa hora se a bateria estiver acima de 60 % e faz o '
    'autoteste na ativação seguinte. Conte uns 3 minutos por detector.';

/// A leaf that was offered the image: it hears it on its next wake.
const otaLeafOfferedText = 'Aguarda a próxima ativação';

/// "firmware de rede elétrica".
String otaFirmwareWord(SafrProductFamily family) => switch (family) {
      SafrProductFamily.board => 'firmware da placa',
      SafrProductFamily.node => 'firmware de rede elétrica',
      SafrProductFamily.leaf => 'firmware de bateria',
      SafrProductFamily.unknown => 'firmware',
    };

/// The units of a family: "dispositivos de rede elétrica".
String otaUnitsWord(SafrProductFamily family) => switch (family) {
      SafrProductFamily.node => 'dispositivos de rede elétrica',
      SafrProductFamily.leaf => 'detectores a bateria',
      _ => 'dispositivos',
    };

String otaActionWord(SafrOtaAction action) => switch (action) {
      SafrOtaAction.start => 'Iniciar',
      SafrOtaAction.pause => 'Pausar',
      SafrOtaAction.resume => 'Retomar',
      SafrOtaAction.abort => 'Cancelar',
    };

/// The filter, for the log and the confirmation.
String otaFilterText(SafrOtaFilter filter, {String? unitName}) =>
    switch (filter.kind) {
      SafrOtaFilterKind.all => 'todos os dispositivos',
      SafrOtaFilterKind.product =>
        'produto ${SafrProduct.fromCode(filter.product)?.label ?? safrProductCodeHex(filter.product)}'
            ' (${safrProductCodeHex(filter.product)})',
      SafrOtaFilterKind.zone => 'zona "${filter.zone}"',
      SafrOtaFilterKind.unit => unitName == null || unitName.isEmpty
          ? 'dispositivo ${filter.mac}'
          : 'dispositivo $unitName (${filter.mac})',
    };

/// The header of a rollout, in capitals as on the card.
String otaRolloutHeadline(OtaFamilyRollout f) => switch (f.state) {
      SafrOtaRolloutState.idle => 'SEM ATUALIZAÇÃO',
      SafrOtaRolloutState.staged => 'GUARDADO NA PLACA',
      SafrOtaRolloutState.rolling => 'ENVIANDO',
      SafrOtaRolloutState.paused => f.pauseCause == OtaPauseCause.alarm
          ? 'PAUSADO POR ALARME'
          : 'PAUSADO',
      SafrOtaRolloutState.done => 'CONCLUÍDO',
      SafrOtaRolloutState.partial => 'PARCIAL',
    };

/// Why it is paused and what makes it go on.
String otaPauseCauseText(OtaPauseCause cause) => switch (cause) {
      OtaPauseCause.operator => 'a pedido do operador',
      OtaPauseCause.alarm => 'há alarme na instalação',
      OtaPauseCause.unknown => 'a placa não disse o motivo',
    };

/// Under the header of a paused rollout.
String otaPauseHint(OtaPauseCause? cause) => switch (cause) {
      OtaPauseCause.alarm =>
        'Um alarme pausou a atualização. O dispositivo que estava baixando '
            'termina; nenhum outro começa. Rearme a central e toque em '
            'Retomar.',
      OtaPauseCause.operator =>
        'Pausado por você. O dispositivo que estava baixando termina; '
            'nenhum outro começa até você tocar em Retomar.',
      _ => 'A placa pausou a atualização (ela pausa sozinha quando reinicia '
          'ou quando passa um alarme). Toque em Retomar para continuar.',
    };

/// A unit's state in words, with the percent while it downloads.
String otaUnitStateText(SafrOtaUnitState state, int percent) =>
    switch (state) {
      SafrOtaUnitState.waiting => 'Aguardando',
      SafrOtaUnitState.offered => 'Oferta enviada',
      SafrOtaUnitState.downloading => 'Baixando $percent %',
      SafrOtaUnitState.verifying => 'Verificando',
      SafrOtaUnitState.rebooting => 'Reiniciando',
      SafrOtaUnitState.selfTest => 'Autoteste',
      SafrOtaUnitState.done => 'Atualizado',
      SafrOtaUnitState.failed => 'Falhou',
      SafrOtaUnitState.skipped => 'Ignorado',
    };

/// The same, in lower case, for the log and the map captions.
String otaUnitStateLog(SafrOtaUnitState state, int percent) =>
    otaUnitStateText(state, percent).toLowerCase();

/// The tries of a unit, in words; null when it is on its first and nothing
/// failed. `ATTEMPTS` counts the offers that ended without the new image
/// running, as the board counts them (ota_rollout.c `attempt_failed`): 1 on
/// a unit that waits = it failed once and will be offered the image again.
String? otaAttemptsText(OtaRolloutUnit u) {
  final n = u.attempts;
  if (n <= 0) return null;
  return switch (u.state) {
    SafrOtaUnitState.failed => n == 1 ? '1 tentativa' : '$n tentativas',
    SafrOtaUnitState.done => 'na ${n + 1}ª tentativa',
    SafrOtaUnitState.skipped => null,
    SafrOtaUnitState.waiting =>
      'falhou ${n == 1 ? 'uma vez' : '$n vezes'}, será tentado de novo',
    _ => '${n + 1}ª tentativa',
  };
}

/// One row of the board's table, for the log.
String otaUnitRowLog(OtaRolloutUnit u) {
  final attempts = otaAttemptsText(u);
  final parts = <String>[
    otaUnitStateLog(u.state, u.percent),
    if (attempts != null) attempts,
    if (u.reasonRaw != 0) otaReasonLogText(u.reasonRaw),
    if (u.version.isNotEmpty) 'versão ${u.version}',
  ];
  return parts.join(', ');
}

/// "0.1.0 → 0.2.0": what the unit runs now and the version it is getting;
/// once it runs the target, what it ran before and what it runs. [known]:
/// the version the registry has for it, when the rollout has none.
String otaVersionChangeText(
  OtaRolloutUnit u,
  String target, {
  String? known,
}) {
  final now = u.version.isNotEmpty ? u.version : (known ?? '');
  final before = u.versionBefore;
  if (u.state == SafrOtaUnitState.done) {
    final runs = now.isEmpty ? target : now;
    return before == null || before.isEmpty || before == runs
        ? runs
        : '$before → $runs';
  }
  return '${now.isEmpty ? '—' : now} → $target';
}

/// "motivo 9: o novo firmware não passou no autoteste…".
String otaReasonLogText(int raw) {
  final label = otaUnitReasonText(SafrOtaReason.fromWire(raw), raw: raw);
  final text =
      label.endsWith('.') ? label.substring(0, label.length - 1) : label;
  if (text.isEmpty) return 'motivo $raw';
  return 'motivo $raw: ${text[0].toLowerCase()}${text.substring(1)}';
}

/// Why a unit was not updated, in plain words. Empty for "no reason".
String otaUnitReasonText(SafrOtaReason reason, {int? raw}) => switch (reason) {
      SafrOtaReason.none => '',
      SafrOtaReason.notNewer =>
        'Já estava nesta versão ou em uma mais nova.',
      SafrOtaReason.busyAlarm =>
        'O dispositivo estava em alarme ou com falha e recusou a '
            'atualização.',
      SafrOtaReason.lowBattery => 'Bateria fraca demais para atualizar.',
      SafrOtaReason.sigFail =>
        'O dispositivo recusou a imagem: ela não tem a assinatura da '
            'SempreIoT.',
      SafrOtaReason.shaFail =>
        'A imagem chegou corrompida ao dispositivo.',
      SafrOtaReason.wrongFamily =>
        'A imagem é de outro tipo de dispositivo.',
      SafrOtaReason.noSpace => 'Não há espaço no dispositivo para a imagem.',
      SafrOtaReason.httpErr =>
        'O dispositivo não conseguiu baixar a imagem da placa.',
      SafrOtaReason.selftestFail =>
        'O novo firmware não passou no autoteste; o dispositivo voltou à '
            'versão anterior.',
      SafrOtaReason.timedOut => 'O dispositivo não respondeu a tempo.',
      SafrOtaReason.aborted =>
        'A atualização foi cancelada antes de chegar a este dispositivo.',
      SafrOtaReason.badArgs => 'O dispositivo não entendeu a oferta.',
      SafrOtaReason.busy =>
        'O dispositivo já estava ocupado com outra atualização.',
      SafrOtaReason.badCrc => 'Os dados chegaram corrompidos.',
      SafrOtaReason.outOfOrder => 'Os dados chegaram fora de ordem.',
      SafrOtaReason.badVersion =>
        'A versão da imagem não tem um formato válido.',
      SafrOtaReason.forceRefused =>
        'O dispositivo não aceita instalação forçada.',
      SafrOtaReason.notValidated =>
        'O novo firmware iniciou mas reiniciou (travou, ou faltou energia) '
            'antes de concluir o autoteste; o dispositivo voltou à versão '
            'anterior.',
      SafrOtaReason.notBooted =>
        'O novo firmware foi gravado mas nunca chegou a iniciar; o '
            'dispositivo continua na versão anterior.',
      SafrOtaReason.unknown =>
        'Motivo desconhecido${raw == null ? '' : ' (código $raw)'}.',
    };

/// Why the board refused an OTA_CONTROL, for the operator.
String otaControlRefusal(SafrOtaAction action, SafrOtaReason reason) {
  switch (reason) {
    case SafrOtaReason.badArgs:
      return action == SafrOtaAction.start
          ? 'A placa recusou: ela não tem a imagem guardada, ou nenhum '
              'dispositivo online passa pelo filtro escolhido.'
          : 'A placa recusou: não há atualização em andamento para '
              '${otaActionWord(action).toLowerCase()}.';
    case SafrOtaReason.busy:
      return 'A placa já está com uma atualização em andamento.';
    case SafrOtaReason.busyAlarm:
      return 'A placa recusou: houve alarme nos últimos 10 minutos. Tente de '
          'novo depois.';
    default:
      final why = otaUnitReasonText(reason);
      return why.isEmpty ? 'A placa recusou o pedido.' : 'A placa recusou: $why';
  }
}

/// "3 atualizados, 1 ignorado, 1 com falha, de 5".
String otaCountsText(OtaFamilyRollout f) {
  String n(int v, String one, String many) => '$v ${v == 1 ? one : many}';
  final parts = <String>[
    n(f.doneCount, 'atualizado', 'atualizados'),
    if (f.skippedCount > 0) n(f.skippedCount, 'ignorado', 'ignorados'),
    if (f.failedCount > 0) '${f.failedCount} com falha',
  ];
  return '${parts.join(', ')}, de ${f.unitCount}';
}

/// The chip's reset reason (`esp_reset_reason_t`) carried in the DETAIL byte
/// of an OTA_RESULT with NOT_VALIDATED (§13.4): what ended the new image.
String otaResetReasonText(int code) => switch (code) {
      1 => 'ligou de novo (energia)',
      2 => 'reset externo (pino)',
      3 => 'reinício por software',
      4 => 'travamento do firmware (panic)',
      5 => 'watchdog de interrupção',
      6 => 'watchdog de tarefa',
      7 => 'watchdog',
      8 => 'saída de deep sleep',
      9 => 'queda de tensão (brownout)',
      10 => 'reset por SDIO',
      11 => 'reset por USB',
      12 => 'reset por JTAG',
      13 => 'erro de eFuse',
      14 => 'glitch de energia',
      15 => 'CPU travada (dupla exceção)',
      _ => 'motivo de reinício $code',
    };
