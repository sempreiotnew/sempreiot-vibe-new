import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/serial_link_provider.dart';
import '../../application/serial_logs_provider.dart';
import '../../application/central_installation_provider.dart';
import '../../domain/safr/safr_parser.dart';
import '../../domain/safr/safr_v2_frame.dart';
import '../../domain/safr/safr_v2_payloads.dart';
import '../../domain/safr_frame.dart';
import 'safr_detail_screen.dart';

/// Logs seriais — the protocol console: every SAFR frame on the wire, with
/// per-frame validation (CRC + authentication + site identity) and live link
/// counters. This is the screen that PROVES the message crossed the system
/// intact — it doubles as the protocol-validation instrument (SAFR v3).
class SerialLogsScreen extends ConsumerStatefulWidget {
  const SerialLogsScreen({super.key});

  @override
  ConsumerState<SerialLogsScreen> createState() => _SerialLogsScreenState();
}

class _SerialLogsScreenState extends ConsumerState<SerialLogsScreen> {
  final ScrollController _scroll = ScrollController();
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 48;
    if (_autoScroll != atBottom) setState(() => _autoScroll = atBottom);
  }

  void _scrollToBottom() {
    if (!_autoScroll) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _jumpToBottomAndResume() {
    setState(() => _autoScroll = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showLegend(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const _LegendSheet(),
    );
  }

  void _copyAll(List<SerialPacket> entries) {
    if (entries.isEmpty) return;
    final text = entries
        .map((e) =>
            '[${safrTimeLabel(e.receivedAt)}] ${e.deviceId} ${e.hexPreview}')
        .join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Logs copiados'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final logsAsync = ref.watch(serialLogsProvider);
    final status = ref.watch(serialLinkProvider);

    ref.listen(serialLogsProvider, (prev, next) {
      final prevLen = prev?.valueOrNull?.length ?? 0;
      final nextLen = next.valueOrNull?.length ?? 0;
      if (nextLen > prevLen) _scrollToBottom();
    });

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        title: const Text('Logs seriais'),
        backgroundColor: context.bgColor,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Legenda — o que significa cada informação',
            icon: const Icon(Icons.help_outline_rounded, size: 19),
            onPressed: () => _showLegend(context),
          ),
          IconButton(
            tooltip: 'Copiar tudo',
            icon: const Icon(Icons.copy_rounded, size: 18),
            onPressed: () => _copyAll(logsAsync.valueOrNull ?? const []),
          ),
          IconButton(
            tooltip: 'Limpar',
            icon: Icon(Icons.delete_sweep_rounded,
                size: 19, color: AppColors.error.withValues(alpha: 0.8)),
            onPressed: () => ref.read(appDatabaseProvider).deleteAllPackets(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _ValidationHeader(status: status),
          Expanded(
            child: logsAsync.when(
              data: (entries) => entries.isEmpty
                  ? _EmptyState(status: status)
                  : Stack(
                      children: [
                        _Console(entries: entries, scroll: _scroll),
                        if (!_autoScroll)
                          Positioned(
                            bottom: 12,
                            right: 12,
                            child: _ScrollResumeButton(
                              onTap: _jumpToBottomAndResume,
                            ),
                          ),
                      ],
                    ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Erro: $e')),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Validation header: link + counters ───────────────────────────────────────

class _ValidationHeader extends ConsumerWidget {
  const _ValidationHeader({required this.status});
  final SerialLinkStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(serialStatsProvider).valueOrNull ??
        (total: 0, crcErr: 0, authErr: 0);
    final wire = ref.watch(serialWireDiagProvider).valueOrNull ??
        (bytes: 0, dropped: 0, frames: 0);
    final verified = stats.total - stats.authErr;

    final (dotColor, statusText) = switch (status) {
      SerialLinkStatus.connected => (AppColors.success, 'RECEBENDO'),
      SerialLinkStatus.connecting => (AppColors.warning, 'AGUARDANDO'),
      SerialLinkStatus.error => (AppColors.error, 'ERRO'),
      SerialLinkStatus.disconnected => (
          context.textSecondary.withValues(alpha: 0.4),
          'SEM USB',
        ),
    };

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderColor.withValues(alpha: 0.6)),
      ),
      child: Column(
        children: [
          // Row 1: link state + wire-level proof that bytes are arriving.
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  boxShadow: status == SerialLinkStatus.connected
                      ? [
                          BoxShadow(
                            color: dotColor.withValues(alpha: 0.7),
                            blurRadius: 6,
                          )
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                statusText,
                style: TextStyle(
                  color: dotColor,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              Text(
                '${_fmtBytes(wire.bytes)} bytes recebidos',
                style: TextStyle(
                  color: wire.bytes > 0
                      ? AppColors.secondary
                      : context.textSecondary,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Divider(height: 1, color: context.borderColor.withValues(alpha: 0.5)),
          const SizedBox(height: 8),
          // Row 2: protocol validation counters.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _Counter(
                label: 'QUADROS',
                value: '${stats.total}',
                color: context.textPrimary,
              ),
              _Counter(
                label: 'VERIFICADOS',
                value: '$verified',
                color: AppColors.success,
                icon: Icons.verified_user_rounded,
              ),
              _Counter(
                label: 'FALHA AUTH',
                value: '${stats.authErr}',
                color:
                    stats.authErr > 0 ? AppColors.error : context.textSecondary,
              ),
              _Counter(
                label: 'FALHA CRC',
                value: '${stats.crcErr}',
                color:
                    stats.crcErr > 0 ? AppColors.error : context.textSecondary,
              ),
              _Counter(
                label: 'DESCARTADOS',
                value: '${wire.dropped}',
                color: wire.dropped > 0 && wire.frames == 0
                    ? AppColors.error
                    : context.textSecondary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _fmtBytes(int b) {
  if (b < 1024) return '$b';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}k';
  return '${(b / (1024 * 1024)).toStringAsFixed(1)}M';
}

class _Counter extends StatelessWidget {
  const _Counter({
    required this.label,
    required this.value,
    required this.color,
    this.icon,
  });

  final String label;
  final String value;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 14,
              height: 1.0,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
      const SizedBox(height: 1),
      Text(
        label,
        style: TextStyle(
          color: context.textSecondary,
          fontSize: 7.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    ]);
  }
}

// ── Console list ─────────────────────────────────────────────────────────────

class _Console extends StatelessWidget {
  const _Console({required this.entries, required this.scroll});

  final List<SerialPacket> entries;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(
        // Follows the app theme: deep panel in dark mode, soft surface in
        // light mode — same information, no hardcoded "terminal black".
        color: context.isDark ? const Color(0xFF070B12) : context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderColor.withValues(alpha: 0.6)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ListView.builder(
          controller: scroll,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          itemCount: entries.length,
          itemBuilder: (context, i) => _FrameRow(packet: entries[i]),
        ),
      ),
    );
  }
}

class _FrameRow extends ConsumerWidget {
  const _FrameRow({required this.packet});
  final SerialPacket packet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Decrypt with the imported installation's key so the log shows the TRUE
    // authentication result (the viewer used to parse with no key, which made
    // every encrypted frame read as "falha de autenticação").
    final id = ref.watch(safrIdentityProvider);
    final result =
        parseSafr(packet.rawBytes, key: id.key, expectedSystemId: id.systemId);
    final row = switch (result) {
      SafrWireResult(:final frame) => _wireRow(frame),
      SafrV1Result(:final frame) => _v1Row(frame),
      _ => const _RowData(
          typeColor: AppColors.error,
          typeLabel: '??',
          route: '—',
          info: 'quadro não reconhecido',
          authOk: null,
        ),
    };

    final timeColor = context.textSecondary.withValues(alpha: 0.6);
    final routeColor = context.textPrimary.withValues(alpha: 0.85);
    final infoColor = context.textSecondary;

    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SafrDetailScreen(packet: packet)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            // time (mono, dim)
            Text(
              safrTimeLabel(packet.receivedAt),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 9.5,
                color: timeColor,
              ),
            ),
            const SizedBox(width: 8),
            // msg-type chip
            Container(
              width: 46,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 2),
              decoration: BoxDecoration(
                color: row.typeColor.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: row.typeColor.withValues(alpha: 0.45),
                  width: 0.5,
                ),
              ),
              child: Text(
                row.typeLabel,
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                  color: row.typeColor,
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Direction: ↑ uplink (mesh → central) · ↓ downlink echo.
            Icon(
              row.downlink
                  ? Icons.arrow_downward_rounded
                  : Icons.arrow_upward_rounded,
              size: 11,
              color: infoColor.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 4),
            // sender + info
            Expanded(
              child: RichText(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10.5,
                  ),
                  children: [
                    TextSpan(
                      text: 'de ',
                      style: TextStyle(color: infoColor),
                    ),
                    TextSpan(
                      text: row.route,
                      style: TextStyle(
                        color: routeColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (row.info.isNotEmpty)
                      TextSpan(
                        text: '  ${row.info}',
                        style: TextStyle(color: infoColor),
                      ),
                  ],
                ),
              ),
            ),
            // size
            Text(
              '${packet.byteLength}B',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                color: timeColor,
              ),
            ),
            const SizedBox(width: 10),
            // validation glyphs: CRC (framing) + lock (authentication)
            Icon(Icons.check_rounded,
                size: 12, color: AppColors.success.withValues(alpha: 0.8)),
            const SizedBox(width: 4),
            if (row.authOk != null)
              Icon(
                row.authOk! ? Icons.lock_rounded : Icons.lock_open_rounded,
                size: 11,
                color: row.authOk!
                    ? AppColors.success.withValues(alpha: 0.8)
                    : AppColors.error,
              )
            else
              const SizedBox(width: 11),
          ],
        ),
      ),
    );
  }

  _RowData _wireRow(SafrWireFrame frame) {
    if (frame.error != null) {
      final label = switch (frame.error!) {
        SafrWireError.authFailed => 'AUTH',
        SafrWireError.crcFailed => 'CRC',
        SafrWireError.foreignSystem => 'ALHEIO',
        _ => 'ERR',
      };
      return _RowData(
        typeColor: AppColors.error,
        typeLabel: label,
        route: frame.srcMac.isEmpty ? '—' : frame.srcMac,
        info: switch (frame.error!) {
          SafrWireError.authFailed => 'falha de autenticação (PSK)',
          SafrWireError.crcFailed => 'quadro corrompido',
          SafrWireError.foreignSystem =>
            'outro sistema (ID 0x${(frame.systemId ?? 0).toRadixString(16).toUpperCase()})',
          _ => 'não decodificado',
        },
        authOk: frame.error == SafrWireError.authFailed ? false : null,
      );
    }

    final (color, label) = switch (frame.payload) {
      SafrEventPayload p => switch (p.eventType) {
          SafrEventType.alarm => (AppColors.error, 'ALARM'),
          SafrEventType.alert => (AppColors.warning, 'ALERT'),
          SafrEventType.trouble => (AppColors.trouble, 'TROUBLE'),
          _ => (AppColors.success, 'OK'),
        },
      SafrHeartbeatPayload _ => (const Color(0xFF38BDF8), 'HB'),
      SafrTopologyPayload _ => (const Color(0xFFA78BFA), 'TOPO'),
      SafrAckPayload _ => (AppColors.success, 'ACK'),
      SafrCommandPayload _ => (const Color(0xFFF472B6), 'CMD'),
      SafrTimeSyncPayload _ => (const Color(0xFF34D399), 'TIME'),
      SafrEventLogReqPayload _ => (const Color(0xFFFBBF24), 'LOG?'),
      SafrEventLogDataPayload _ => (const Color(0xFFFBBF24), 'LOG'),
      _ => (AppColors.warning, '?'),
    };

    // Badges after the info text:
    //  ⚑ = pede confirmação (F_ACK_REQ) · ↻ = reanúncio ≤60 s (F_RETX)
    //  v2 = protocolo anterior, somente leitura
    final badges = [
      if (frame.ackRequired) ' ⚑',
      if (frame.isRetx) ' ↻',
      if (frame.ver == safrVer2) ' v2',
    ].join();

    return _RowData(
      typeColor: color,
      typeLabel: label,
      route: frame.srcMac == safrCentralMac ? 'central' : frame.srcMac,
      info: '${_wireInfo(frame)} #${frame.msgId}$badges',
      authOk: frame.isEncrypted ? true : null,
      downlink: frame.srcMac == safrCentralMac,
    );
  }

  String _wireInfo(SafrWireFrame frame) {
    switch (frame.payload) {
      case SafrEventPayload p:
        final parts = <String>[];
        if (p.tempTenths != null) {
          parts.add('${(p.tempTenths! / 10).toStringAsFixed(1)}C');
        }
        if (p.smokeRaw != null) parts.add('smk:${p.smokeRaw}');
        if (p.batteryPct != null) parts.add('bat:${p.batteryPct}%');
        if (p.devSeq != null) parts.add('ev:${p.devSeq}');
        return parts.join(' ');
      case SafrHeartbeatPayload p:
        return 'L${p.layer}'
            '${p.rssiToParent != null ? ' ${p.rssiToParent}dBm' : ''}'
            '${p.batteryPct != null ? ' bat:${p.batteryPct}%' : ''}';
      case SafrTopologyPayload p:
        return '${p.children.length} filho(s)';
      case SafrAckPayload p:
        return 'confirma #${p.ackedMsgId}';
      case SafrCommandPayload p:
        final name = SafrCommand.values
            .where((c) => c.wire == p.cmdRaw)
            .map((c) => c.name)
            .firstOrNull;
        return name ?? 'cmd:0x${p.cmdRaw.toRadixString(16)}';
      case SafrTimeSyncPayload p:
        return 'epoch:${p.epoch}';
      case SafrEventLogReqPayload p:
        return 'diário desde #${p.sinceJrnSeq}';
      case SafrEventLogDataPayload p:
        return p.isEmpty
            ? 'diário vazio'
            : 'diário #${p.jrnSeq}${p.isLast ? ' (fim)' : ''}';
      default:
        return '';
    }
  }

  _RowData _v1Row(SafrFrame frame) {
    final fail = frame.decryptionAttempted && !frame.decryptionSuccess;
    return _RowData(
      typeColor: fail ? AppColors.error : const Color(0xFF64748B),
      typeLabel: 'v1',
      route: frame.validSof ? frame.srcMac : '—',
      info: fail ? 'falha na decriptografia' : 'protocolo antigo',
      authOk: frame.decryptionAttempted ? frame.decryptionSuccess : null,
    );
  }
}

class _RowData {
  const _RowData({
    required this.typeColor,
    required this.typeLabel,
    required this.route,
    required this.info,
    required this.authOk,
    this.downlink = false,
  });

  final Color typeColor;
  final String typeLabel;
  final String route;
  final String info;
  final bool? authOk; // null = plaintext / not applicable
  final bool downlink; // frame emitted by the central (echo of our TX)
}

// ── Legend: what every information on this screen means ─────────────────────

class _LegendSheet extends StatelessWidget {
  const _LegendSheet();

  @override
  Widget build(BuildContext context) {
    Widget section(String title) => Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 6),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
              color: AppColors.secondary.withValues(alpha: 0.9),
            ),
          ),
        );

    Widget item(String term, String meaning, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 92,
                child: Text(
                  term,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: color ?? context.textPrimary,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  meaning,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.35,
                    color: context.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        );

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: context.borderColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Legenda do console SAFR',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: context.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Cada linha é um quadro do protocolo SAFR v3 no barramento '
            'serial. Toque em uma linha para ver todos os campos '
            'decodificados e explicados.',
            style: TextStyle(
                fontSize: 11.5, height: 1.4, color: context.textSecondary),
          ),
          section('CONTADORES DO CABEÇALHO'),
          item('QUADROS', 'Total de quadros recebidos e armazenados.'),
          item(
              'VERIFICADOS',
              'Quadros que passaram nas DUAS verificações: integridade '
                  '(CRC) e autenticidade criptográfica (AES-CCM). Só quadros '
                  'verificados atualizam o estado dos dispositivos.'),
          item(
              'FALHA AUTH',
              'Bytes chegaram íntegros, mas a chave (PSK) não confere — '
                  'chave errada ou sistema vizinho. O quadro é registrado e '
                  'ignorado.',
              color: AppColors.error),
          item(
              'FALHA CRC',
              'Bytes corrompidos na transmissão (cabo, ruído, baud rate). '
                  'O receptor descarta 1 byte e ressincroniza.',
              color: AppColors.error),
          item(
              'DESCARTADOS',
              'Bytes que não formaram quadro válido (ex.: texto de boot do '
                  'ESP32). Alguns são normais ao conectar.'),
          section('TIPOS DE MENSAGEM'),
          item(
              'ALARM',
              'Alarme de incêndio. Prioridade máxima; fica '
                  'RETIDO na central até rearme manual do operador '
                  '(UL 864 / NFPA 72).',
              color: AppColors.error),
          item('ALERT', 'Supervisão / pré-alarme (ex.: fumaça subindo).',
              color: AppColors.warning),
          item('TROUBLE', 'Falha de equipamento ou comunicação.',
              color: AppColors.trouble),
          item('OK', 'Normalização (RESTORE) ou status periódico.',
              color: AppColors.success),
          item(
              'HB',
              'Heartbeat — prova de vida a cada 15 s (60 s em '
                  'sensores a bateria). Silêncio por 3 intervalos ⇒ TROUBLE '
                  '"dispositivo ausente" (NFPA 72: ≤200 s).'),
          item('TOPO', 'Topologia — quem é filho de quem na rede mesh.'),
          item('ACK', 'Confirmação de recebimento de um quadro crítico.'),
          item(
              'CMD',
              'Comando da central: silenciar, teste, rearme (RESET), '
                  'verificação de enlace (LINK_CHECK a cada 30 s).'),
          item('TIME', 'Sincronização de relógio para os dispositivos.'),
          item(
              'LOG? / LOG',
              'Diário de eventos: a central pede (LOG?) e o '
                  'root reenvia (LOG) eventos ocorridos enquanto o cabo estava '
                  'desconectado — nenhum alarme se perde (EN 54-25).'),
          section('SÍMBOLOS DA LINHA'),
          item(
              '↑ / ↓',
              '↑ subida (dispositivo → central) · '
                  '↓ descida (central → rede).'),
          item('#n', 'MSG_ID — número de sequência usado pelo ACK.'),
          item(
              '⚑',
              'Quadro pede confirmação (F_ACK_REQ). Obrigatório em '
                  'ALARM e TROUBLE.'),
          item(
              '↻',
              'Reanúncio: o mesmo alarme é repetido a cada ≤60 s até '
                  'normalizar ou ser rearmado (NFPA 72). Não duplica o evento.'),
          item(
              'ev:n',
              'DEV_SEQ — identidade do evento. Reanúncios e '
                  'reenvios do diário têm o mesmo ev:n e são deduplicados.'),
          item('✓', 'CRC OK — o quadro chegou íntegro.',
              color: AppColors.success),
          item(
              '🔒',
              'Cadeado fechado: autenticidade verificada (AES-CCM). '
                  'Aberto: falha de autenticação.',
              color: AppColors.success),
          item('v2', 'Quadro do protocolo anterior (somente leitura).'),
          item(
              'ALHEIO',
              'SYSTEM_ID de outra instalação — ignorado por '
                  'projeto (EN 54-25: sistemas vizinhos não interoperam).',
              color: AppColors.error),
        ],
      ),
    );
  }
}

// ── Scroll resume ────────────────────────────────────────────────────────────

class _ScrollResumeButton extends StatelessWidget {
  const _ScrollResumeButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.warning.withValues(alpha: 0.4),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.vertical_align_bottom_rounded,
                size: 14, color: AppColors.warning),
            SizedBox(width: 6),
            Text(
              'Retomar scroll',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.warning,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Empty state ──────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.status});
  final SerialLinkStatus status;

  @override
  Widget build(BuildContext context) {
    final (icon, title, subtitle, color) = switch (status) {
      SerialLinkStatus.connected => (
          Icons.usb_rounded,
          'Aguardando dados...',
          'Conectado — nenhum dado recebido ainda.',
          AppColors.success,
        ),
      SerialLinkStatus.connecting => (
          Icons.usb_rounded,
          'Conectando...',
          'Porta aberta — aguardando quadros SAFR válidos.',
          AppColors.warning,
        ),
      SerialLinkStatus.error => (
          Icons.usb_off_rounded,
          'Erro de comunicação',
          'Dados chegam mas não validam — verifique a chave (PSK) e o cabo.',
          AppColors.error,
        ),
      SerialLinkStatus.disconnected => (
          Icons.usb_off_rounded,
          'USB desconectado',
          'Conecte um dispositivo serial para ver os logs.',
          context.textSecondary.withValues(alpha: 0.4),
        ),
    };

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(18),
              border:
                  Border.all(color: color.withValues(alpha: 0.2), width: 0.8),
            ),
            child: Icon(icon, size: 28, color: color.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
