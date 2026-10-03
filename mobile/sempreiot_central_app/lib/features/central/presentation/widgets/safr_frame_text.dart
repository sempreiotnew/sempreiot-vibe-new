import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../application/ota_rollout_words.dart';
import '../../domain/safr/safr_product.dart';
import '../../domain/safr/safr_v2_frame.dart';
import '../../domain/safr/safr_v2_payloads.dart';

// How the protocol console names, colours and summarises a SAFR v3 frame —
// one place for the Logs seriais rows and the frame detail screen, so both
// follow docs/safr/protocol-safr-v3.md (§7 message types, §7.6 commands,
// §13 firmware update) and never drift apart. Every MSG_TYPE the parser
// knows has a case here; a new one fails the exhaustive switch below.

/// The console filter a frame belongs to.
enum SafrLogGroup {
  events('Eventos'),
  network('Rede'),
  commands('Comandos'),
  installation('Instalação'),
  update('Atualização'),
  errors('Erros');

  const SafrLogGroup(this.label);
  final String label;
}

/// Chip colour, chip text (≤ 7 chars) and the protocol name of a frame.
typedef SafrFrameLook = ({Color color, String chip, String name});

const _network = Color(0xFF38BDF8);
const _topology = Color(0xFFA78BFA);
const _command = Color(0xFFF472B6);
const _time = Color(0xFF34D399);
const _journal = Color(0xFFFBBF24);
const _install = Color(0xFF94A3B8);
const _update = Color(0xFF818CF8);

/// Protocol name of a COMMAND code, as the spec writes it (`SET_DEVICE`,
/// `OTA_CONTROL`, …); `CMD 0x2A` for a code this app does not know.
String safrCommandName(int raw) {
  for (final c in SafrCommand.values) {
    if (c.wire == raw) return _upperSnake(c.name);
  }
  return 'CMD 0x${_hex2(raw)}';
}

/// Protocol name of a MSG_TYPE (`EVENT_LOG_DATA`, `OTA_PUSH_RESULT`, …).
String safrMsgTypeName(SafrMsgType t, int raw) => t == SafrMsgType.unknown
    ? 'MSG_TYPE 0x${_hex2(raw)}'
    : _upperSnake(t.name);

String _upperSnake(String camel) => camel
    .replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]}')
    .toUpperCase();

String _hex2(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();

String _hex4(int v) => v.toRadixString(16).padLeft(4, '0').toUpperCase();

/// Which console filter a decoded, valid frame falls under.
SafrLogGroup safrLogGroup(SafrMsgType t) => switch (t) {
      SafrMsgType.event ||
      SafrMsgType.eventLogReq ||
      SafrMsgType.eventLogData =>
        SafrLogGroup.events,
      SafrMsgType.heartbeat ||
      SafrMsgType.topology ||
      SafrMsgType.nameAnnounce ||
      SafrMsgType.timeSync ||
      SafrMsgType.parentProbe ||
      SafrMsgType.parentOffer =>
        SafrLogGroup.network,
      SafrMsgType.ack || SafrMsgType.command => SafrLogGroup.commands,
      SafrMsgType.installation ||
      SafrMsgType.deviceTable ||
      SafrMsgType.code =>
        SafrLogGroup.installation,
      SafrMsgType.otaPushBegin ||
      SafrMsgType.otaPushChunk ||
      SafrMsgType.otaPushEnd ||
      SafrMsgType.otaPushResult ||
      SafrMsgType.otaStatus ||
      SafrMsgType.otaResult ||
      SafrMsgType.otaRollout =>
        SafrLogGroup.update,
      SafrMsgType.unknown => SafrLogGroup.errors,
    };

/// Look of a frame that decoded (no [SafrWireFrame.error]).
SafrFrameLook safrFrameLook(SafrWireFrame f) {
  final name = safrMsgTypeName(f.msgType, f.msgTypeRaw);
  return switch (f.payload) {
    SafrEventPayload p => switch (p.eventType) {
        SafrEventType.alarm => (color: AppColors.error, chip: 'ALARM', name: name),
        SafrEventType.alert => (color: AppColors.warning, chip: 'ALERT', name: name),
        SafrEventType.trouble => (color: AppColors.trouble, chip: 'TROUBLE', name: name),
        _ => (color: AppColors.success, chip: 'OK', name: name),
      },
    SafrHeartbeatPayload _ => (color: _network, chip: 'HB', name: name),
    SafrTopologyPayload _ => (color: _topology, chip: 'TOPO', name: name),
    // Cyan is the system's one "confirmed" colour (LED language, Rede map).
    SafrAckPayload p => p.status == SafrAckStatus.ok
        ? (color: AppColors.ledCyan, chip: 'ACK', name: name)
        : (color: AppColors.error, chip: 'NACK', name: name),
    SafrCommandPayload _ => (color: _command, chip: 'CMD', name: name),
    SafrTimeSyncPayload _ => (color: _time, chip: 'TIME', name: name),
    SafrEventLogReqPayload _ => (color: _journal, chip: 'LOG?', name: name),
    SafrEventLogDataPayload _ => (color: _journal, chip: 'LOG', name: name),
    SafrInstallationPayload _ => (color: _install, chip: 'INST', name: name),
    SafrNameAnnouncePayload _ => (color: _network, chip: 'NAME', name: name),
    SafrDeviceTablePayload _ => (color: _install, chip: 'TABLE', name: name),
    SafrCodePayload _ => (color: _install, chip: 'CODE', name: name),
    SafrParentProbePayload _ => (color: _topology, chip: 'PROBE', name: name),
    SafrParentOfferPayload _ => (color: _topology, chip: 'OFFER', name: name),
    SafrOtaPushBeginPayload _ ||
    SafrOtaPushChunkPayload _ ||
    SafrOtaPushEndPayload _ =>
      (color: _update, chip: 'PUSH', name: name),
    SafrOtaPushResultPayload p => (
        color: switch (p.phase) {
          SafrOtaPushPhase.ok => AppColors.ledCyan,
          SafrOtaPushPhase.failed => AppColors.error,
          SafrOtaPushPhase.receiving => _update,
        },
        chip: 'PUSH',
        name: name,
      ),
    SafrOtaStatusPayload _ => (color: _update, chip: 'OTA', name: name),
    SafrOtaResultPayload p => p.ok
        ? (color: AppColors.ledCyan, chip: 'OTA OK', name: name)
        : (color: AppColors.error, chip: 'OTA ERR', name: name),
    SafrOtaRolloutPayload _ => (color: _update, chip: 'ROLL', name: name),
    SafrUnknownPayload _ || null => (color: AppColors.warning, chip: '?', name: name),
  };
}

/// One line with what the frame says, for the console row.
String safrFrameSummary(SafrWireFrame f) {
  switch (f.payload) {
    case SafrEventPayload p:
      return [
        safrEventCodeName(p.eventCode, p.eventCodeRaw),
        if (p.tempTenths != null) '${(p.tempTenths! / 10).toStringAsFixed(1)}C',
        if (p.smokeRaw != null) 'smk:${p.smokeRaw}',
        if (p.batteryPct != null) 'bat:${p.batteryPct}%',
        if (p.devSeq != null) 'ev:${p.devSeq}',
      ].join(' ');
    case SafrHeartbeatPayload p:
      return [
        p.layer == 0 ? 'placa' : 'L${p.layer}',
        if (p.rssiToParent != null) '${p.rssiToParent}dBm',
        if (p.batteryPct != null) 'bat:${p.batteryPct}%',
        'up:${_duration(p.uptimeS)}',
      ].join(' ');
    case SafrTopologyPayload p:
      return p.role == SafrNodeRole.leaf
          ? 'detector · ${p.children.length} candidato(s) a pai'
          : '${_roleWord(p.role)} L${p.layer} · ${p.children.length} filho(s)';
    case SafrAckPayload p:
      final status = switch (p.status) {
        SafrAckStatus.ok => '',
        SafrAckStatus.error =>
          ' ERRO${p.detailRaw != 0 ? ' (detalhe ${p.detailRaw})' : ''}',
        SafrAckStatus.unknownDst => ' destino desconhecido',
        SafrAckStatus.unknown => ' status 0x${_hex2(p.status.wire)}',
      };
      return 'confirma #${p.ackedMsgId}$status';
    case SafrCommandPayload p:
      return safrCommandName(p.cmdRaw);
    case SafrTimeSyncPayload p:
      return _utc(p.epoch);
    case SafrEventLogReqPayload p:
      return 'diário desde #${p.sinceJrnSeq}';
    case SafrEventLogDataPayload p:
      return p.isEmpty
          ? 'diário vazio'
          : 'diário #${p.jrnSeq}${p.isLast ? ' (fim)' : ''}';
    case SafrInstallationPayload p:
      return '"${p.name}" 0x${_hex4(p.systemId)} canal ${p.channel} · '
          '${p.enrolled.length} disp.';
    case SafrNameAnnouncePayload p:
      return [
        '"${p.name}"',
        if (p.zone.isNotEmpty) 'zona ${p.zone}',
        if (p.fwVersion != null && p.fwVersion!.isNotEmpty) 'fw ${p.fwVersion}',
      ].join(' · ');
    case SafrDeviceTablePayload p:
      return 'pág. ${p.page}/${p.pageCount} · ${p.entries.length} de ${p.total}';
    case SafrCodePayload p:
      // Never the keys: the console is for reading, not for leaking.
      return '"${p.code.name}" 0x${_hex4(p.code.systemId)} (canal de setup)';
    case SafrParentProbePayload p:
      return p.isSurvey ? 'teste de alcance' : 'detector procura pai';
    case SafrParentOfferPayload p:
      return '${p.rssiSeen}dBm · '
          '${p.layer == null ? 'sem rede' : 'L${p.layer}'}';
    case SafrOtaPushBeginPayload p:
      return '${_family(p.family)} ${p.version} · ${_kb(p.size)}';
    case SafrOtaPushChunkPayload p:
      return 'bloco ${p.seq} · ${p.len} B';
    case SafrOtaPushEndPayload _:
      return 'fim do envio';
    case SafrOtaPushResultPayload p:
      return switch (p.phase) {
        SafrOtaPushPhase.receiving => 'recebendo · próximo bloco ${p.nextSeq}',
        SafrOtaPushPhase.ok => '${_family(p.family)} ${p.version} verificado',
        SafrOtaPushPhase.failed => 'falhou · ${otaReasonLogText(p.reasonRaw)}',
      };
    case SafrOtaStatusPayload p:
      return otaUnitStateLog(p.state, p.percent);
    case SafrOtaResultPayload p:
      return p.ok
          ? 'atualizado · ${p.version}'
          : '${otaReasonLogText(p.reasonRaw)} · roda ${p.version}';
    case SafrOtaRolloutPayload p:
      return '${_rolloutState(p.state)} · ${_family(p.family)} '
          '${p.target} · pág. ${p.page}/${p.pageCount} · ${p.total} unid.';
    case SafrUnknownPayload p:
      return '${p.bytes.length} B não decodificados';
    case null:
      return '';
  }
}

/// Protocol name of an EVENT_CODE (`SMOKE_ALARM`, `RESTORE`, …).
String safrEventCodeName(SafrEventCode c, int raw) =>
    c == SafrEventCode.unknown ? 'CODE 0x${_hex2(raw)}' : _upperSnake(c.name);

String _roleWord(SafrNodeRole r) => switch (r) {
      SafrNodeRole.root => 'raiz',
      SafrNodeRole.node => 'nó',
      SafrNodeRole.leaf => 'detector',
      SafrNodeRole.unknown => '?',
    };

String _family(int wire) {
  final f = SafrProductFamily.fromWire(wire);
  return f == SafrProductFamily.unknown ? 'família 0x${_hex2(wire)}' : f.label;
}

String _rolloutState(SafrOtaRolloutState s) => switch (s) {
      SafrOtaRolloutState.idle => 'parada',
      SafrOtaRolloutState.staged => 'imagem guardada',
      SafrOtaRolloutState.rolling => 'atualizando',
      SafrOtaRolloutState.paused => 'pausada',
      SafrOtaRolloutState.done => 'concluída',
      SafrOtaRolloutState.partial => 'concluída com falhas',
    };

String _utc(int epoch) {
  final t = DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true);
  String p(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${p(t.month)}-${p(t.day)} '
      '${p(t.hour)}:${p(t.minute)}:${p(t.second)} UTC';
}

String _kb(int bytes) => '${(bytes / 1024).toStringAsFixed(0)} KB';

String _duration(int s) {
  if (s < 120) return '${s}s';
  if (s < 7200) return '${s ~/ 60}min';
  if (s < 172800) return '${s ~/ 3600}h';
  return '${s ~/ 86400}d';
}
