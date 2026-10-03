import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/central_installation_provider.dart';
import '../../application/serial_link_provider.dart';
import '../../application/serial_logs_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_identity.dart';
import '../../domain/safr/safr_parser.dart';
import '../../domain/safr/safr_v2_frame.dart';
import '../../domain/safr_frame.dart';
import '../widgets/device_avatar.dart' show deviceDisplayName;
import '../widgets/safr_frame_text.dart';
import 'safr_detail_screen.dart';

/// Logs seriais — the protocol console: every SAFR v3 frame the board sent
/// the tablet, with per-frame validation (CRC + authentication + site
/// identity), live link counters and a filter by kind. Names, colours and
/// one-line summaries come from safr_frame_text.dart, which covers every
/// MSG_TYPE of docs/safr/protocol-safr-v3.md (§7, §13). Frames the tablet
/// sends are not stored, so they are not listed.
class SerialLogsScreen extends ConsumerStatefulWidget {
  const SerialLogsScreen({super.key});

  @override
  ConsumerState<SerialLogsScreen> createState() => _SerialLogsScreenState();
}

class _SerialLogsScreenState extends ConsumerState<SerialLogsScreen> {
  final ScrollController _scroll = ScrollController();
  bool _autoScroll = true;

  /// Null = every frame.
  SafrLogGroup? _group;

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

  void _copyAll(List<_Decoded> entries) {
    if (entries.isEmpty) return;
    final text = entries.map((d) {
      final r = d.row;
      return '[${safrTimeLabel(d.packet.receivedAt)}] ${r.typeLabel} '
          '${r.route} ${r.info} | ${d.packet.hexPreview}';
    }).join('\n');
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
    final id = ref.watch(safrIdentityProvider);
    final names = {
      for (final n in ref.watch(topologyProvider)) n.mac: deviceDisplayName(n),
    };

    ref.listen(serialLogsProvider, (prev, next) {
      final prevLen = prev?.valueOrNull?.length ?? 0;
      final nextLen = next.valueOrNull?.length ?? 0;
      if (nextLen > prevLen) _scrollToBottom();
    });

    final all = [
      for (final p in logsAsync.valueOrNull ?? const <SerialPacket>[])
        _decode(p, id, names),
    ];
    final shown =
        _group == null ? all : all.where((d) => d.group == _group).toList();

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        title: const Text('Logs seriais'),
        backgroundColor: context.bgColor,
        foregroundColor: context.textPrimary,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Legenda — o que significa cada informação',
            icon: const Icon(Icons.help_outline_rounded, size: 19),
            onPressed: () => _showLegend(context),
          ),
          IconButton(
            tooltip: 'Copiar o que está na lista',
            icon: const Icon(Icons.copy_rounded, size: 18),
            onPressed: () => _copyAll(shown),
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
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _ValidationHeader(status: status),
            _GroupFilter(
              selected: _group,
              counts: {
                for (final g in SafrLogGroup.values)
                  g: all.where((d) => d.group == g).length,
              },
              total: all.length,
              onSelected: (g) => setState(() => _group = g),
            ),
            Expanded(
              child: logsAsync.when(
                data: (_) => all.isEmpty
                    ? _EmptyState(status: status)
                    : shown.isEmpty
                        ? Center(
                            child: Text(
                              'Nenhum quadro de "${_group!.label}" entre os '
                              'últimos ${all.length}.',
                              style: TextStyle(
                                  color: context.textSecondary, fontSize: 12),
                            ),
                          )
                        : Stack(
                            children: [
                              _Console(entries: shown, scroll: _scroll),
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
      SerialLinkStatus.stalled => (AppColors.error, 'PLACA MUDA'),
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

// ── Group filter ─────────────────────────────────────────────────────────────

class _GroupFilter extends StatelessWidget {
  const _GroupFilter({
    required this.selected,
    required this.counts,
    required this.total,
    required this.onSelected,
  });

  final SafrLogGroup? selected;
  final Map<SafrLogGroup, int> counts;
  final int total;
  final ValueChanged<SafrLogGroup?> onSelected;

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, int n, SafrLogGroup? g) {
      final on = selected == g;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Text('$label $n'),
          selected: on,
          showCheckmark: false,
          onSelected: (_) => onSelected(g),
          labelStyle: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: on ? AppColors.white : context.textSecondary,
          ),
          selectedColor: AppColors.secondary,
          backgroundColor: context.surfaceColor,
          side: BorderSide(
            color: on
                ? AppColors.secondary
                : context.borderColor.withValues(alpha: 0.6),
          ),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
        children: [
          chip('Todos', total, null),
          for (final g in SafrLogGroup.values)
            if (counts[g]! > 0 || selected == g) chip(g.label, counts[g]!, g),
        ],
      ),
    );
  }
}

// ── Decoding ─────────────────────────────────────────────────────────────────

/// One stored packet, parsed once per build with the installation's key so
/// the row shows the TRUE authentication result.
class _Decoded {
  const _Decoded(this.packet, this.row, this.group);
  final SerialPacket packet;
  final _RowData row;
  final SafrLogGroup group;
}

_Decoded _decode(
    SerialPacket packet, SafrIdentity id, Map<String, String> names) {
  final result =
      parseSafr(packet.rawBytes, key: id.key, expectedSystemId: id.systemId);
  return switch (result) {
    SafrWireResult(:final frame) => _Decoded(
        packet,
        _wireRow(frame, names),
        frame.error != null ? SafrLogGroup.errors : safrLogGroup(frame.msgType),
      ),
    SafrV1Result(:final frame) =>
      _Decoded(packet, _v1Row(frame), SafrLogGroup.errors),
    _ => _Decoded(
        packet,
        const _RowData(
          typeColor: AppColors.error,
          typeLabel: '??',
          route: '—',
          info: 'quadro não reconhecido',
          authOk: null,
        ),
        SafrLogGroup.errors,
      ),
  };
}

String _who(String mac, Map<String, String> names) {
  if (mac == safrCentralMac) return 'central';
  if (mac.isEmpty) return '—';
  return names[mac] ?? mac;
}

_RowData _wireRow(SafrWireFrame frame, Map<String, String> names) {
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
      route: _who(frame.srcMac, names),
      info: switch (frame.error!) {
        SafrWireError.authFailed => 'falha de autenticação (chave SAFR)',
        SafrWireError.crcFailed => 'quadro corrompido',
        SafrWireError.foreignSystem => frame.systemId == 0
            ? 'canal de setup (SYSTEM_ID 0x0000)'
            : 'outro sistema (ID 0x${(frame.systemId ?? 0).toRadixString(16).toUpperCase()})',
        SafrWireError.badVersion => 'versão desconhecida (VER ${frame.ver})',
        SafrWireError.truncated => 'quadro incompleto',
        SafrWireError.payloadParseError =>
          '${safrMsgTypeName(frame.msgType, frame.msgTypeRaw)} '
              'com payload inválido',
      },
      authOk: frame.error == SafrWireError.authFailed ? false : null,
    );
  }

  final look = safrFrameLook(frame);

  // Badges after the info text:
  //  ⚑ = pede confirmação (F_ACK_REQ) · ↻ = reanúncio ≤60 s (F_RETX)
  //  v2 = protocolo anterior, somente leitura
  final badges = [
    if (frame.ackRequired) ' ⚑',
    if (frame.isRetx) ' ↻',
    if (frame.ver == safrVer2) ' v2',
  ].join();

  final summary = safrFrameSummary(frame);
  return _RowData(
    typeColor: look.color,
    typeLabel: look.chip,
    route: _who(frame.srcMac, names),
    info: '${summary.isEmpty ? '' : '$summary '}#${frame.msgId}$badges',
    authOk: frame.isEncrypted ? true : null,
    downlink: frame.srcMac == safrCentralMac,
  );
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

// ── Console list ─────────────────────────────────────────────────────────────

class _Console extends StatelessWidget {
  const _Console({required this.entries, required this.scroll});

  final List<_Decoded> entries;
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
          itemBuilder: (context, i) => _FrameRow(entry: entries[i]),
        ),
      ),
    );
  }
}

class _FrameRow extends StatelessWidget {
  const _FrameRow({required this.entry});
  final _Decoded entry;

  @override
  Widget build(BuildContext context) {
    final packet = entry.packet;
    final row = entry.row;
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
              width: 54,
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
                maxLines: 1,
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                  color: row.typeColor,
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Direction: ↑ to the tablet · ↓ sent as the central.
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
  final bool downlink; // SRC_MAC is the central's
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
            'Cada linha é um quadro SAFR v3 que a placa enviou a esta '
            'central pelo cabo (docs/safr/protocol-safr-v3.md). Os quadros '
            'que a central envia não ficam no registro. Toque em uma linha '
            'para ver todos os campos decodificados.',
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
              'Bytes chegaram íntegros, mas a chave SAFR não confere — '
                  'instalação errada nesta central ou placa trocada.',
              color: AppColors.error),
          item(
              'FALHA CRC',
              'Bytes corrompidos na transmissão (cabo, ruído, velocidade). '
                  'O receptor descarta 1 byte e ressincroniza.',
              color: AppColors.error),
          item(
              'DESCARTADOS',
              'Bytes que não formaram quadro válido (ex.: texto de boot do '
                  'ESP32). Alguns são normais ao conectar.'),
          section('FILTROS'),
          item('Eventos', 'EVENT, LOG? e LOG.'),
          item('Rede', 'HB, TOPO, NAME, TIME, PROBE e OFFER.'),
          item('Comandos', 'CMD e ACK / NACK.'),
          item('Instalação', 'INST, TABLE e CODE.'),
          item('Atualização', 'PUSH, OTA e ROLL (firmware, §13).'),
          item('Erros', 'Quadros que não passaram na validação.'),
          section('EVENTOS'),
          item(
              'ALARM',
              'Alarme de incêndio. Prioridade máxima; fica RETIDO na '
                  'central até o rearme do operador (UL 864 / NFPA 72).',
              color: AppColors.error),
          item('ALERT', 'Supervisão / pré-alarme (fumaça subindo, teste).',
              color: AppColors.warning),
          item('TROUBLE', 'Falha de equipamento, bateria ou comunicação.',
              color: AppColors.trouble),
          item('OK', 'Normalização (RESTORE) ou status periódico.',
              color: AppColors.success),
          item(
              'LOG? / LOG',
              'Diário de eventos: a central pede (LOG?) e a placa reenvia '
                  '(LOG) o que aconteceu enquanto o cabo estava '
                  'desconectado — nenhum alarme se perde (EN 54-25).'),
          section('REDE'),
          item(
              'HB',
              'Heartbeat — prova de vida: a cada 15 s nos dispositivos na '
                  'tomada e na placa; a cada 60 s nos detectores a bateria. '
                  'Silêncio por 3 intervalos (45 s / 180 s) ⇒ "sem '
                  'comunicação" (NFPA 72 ≤ 200 s).'),
          item(
              'TOPO',
              'Topologia — enviada quando o dispositivo muda de nível na '
                  'rede. De um detector: os pais que ele ouviu, a cada '
                  'vínculo.'),
          item(
              'NAME',
              'O dispositivo diz nome, zona, produto e versão do firmware.'),
          item('TIME', 'Relógio distribuído aos dispositivos.'),
          item(
              'PROBE / OFFER',
              'Procura de pai e teste de alcance (ESP-NOW). Normalmente '
                  'não chegam à central.'),
          section('COMANDOS'),
          item(
              'CMD',
              'Comando no protocolo: silenciar, teste, rearme, identificar, '
                  'nome e zona, aposentar, apagar, atualização…'),
          item(
              'ACK',
              'Confirmação: o comando ou quadro #n foi processado. Ciano é a '
                  'única cor de "confirmado" do sistema.',
              color: AppColors.ledCyan),
          item(
              'NACK',
              'ACK com ERRO ou destino desconhecido. O detalhe diz o motivo '
                  '(toque na linha).',
              color: AppColors.error),
          section('INSTALAÇÃO'),
          item('INST', 'Identidade da instalação, resposta da placa.'),
          item(
              'TABLE',
              'Tabela de dispositivos da placa, em páginas: estado, nome, '
                  'zona, produto e versão de cada unidade.'),
          item(
              'CODE',
              'O código da instalação lido da placa pelo canal de setup '
                  '("Ler código da placa"). As chaves nunca aparecem aqui.'),
          section('ATUALIZAÇÃO DE FIRMWARE'),
          item(
              'PUSH',
              'Envio do firmware da central para a placa: a placa diz qual '
                  'bloco quer a seguir e, no fim, se a imagem foi verificada.'),
          item('OTA', 'Progresso de uma unidade: oferta, baixando %, '
              'verificando, reiniciando, autoteste.'),
          item('OTA OK / ERR', 'Resultado final de uma unidade e a versão que '
              'ela roda agora.'),
          item('ROLL', 'Tabela da atualização na placa: estado e cada unidade.'),
          section('SÍMBOLOS DA LINHA'),
          item(
              '↑ / ↓',
              '↑ chegou à central · ↓ quadro com a origem da central.'),
          item('de …', 'Quem enviou: o nome do dispositivo, se conhecido; '
              'senão o MAC.'),
          item('#n', 'MSG_ID — número de sequência citado pelo ACK.'),
          item(
              '⚑',
              'Quadro pede confirmação (F_ACK_REQ): ALARM, TROUBLE, '
                  'resultado de atualização.'),
          item(
              '↻',
              'Reanúncio: o mesmo alarme é repetido a cada ≤60 s até '
                  'normalizar ou ser rearmado (NFPA 72). Não duplica o evento.'),
          item(
              'ev:n',
              'DEV_SEQ — identidade do evento. Reanúncios e reenvios do '
                  'diário têm o mesmo ev:n e são deduplicados.'),
          item('✓', 'CRC OK — o quadro chegou íntegro.',
              color: AppColors.success),
          item(
              '🔒',
              'Cadeado fechado: autenticidade verificada (AES-CCM). '
                  'Aberto: falha de autenticação.',
              color: AppColors.success),
          item('v2 / v1', 'Quadro de um protocolo anterior (somente leitura).'),
          item(
              'ALHEIO',
              'SYSTEM_ID de outra instalação — ignorado por projeto '
                  '(EN 54-25). 0x0000 = canal de setup da placa.',
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
      SerialLinkStatus.stalled => (
          Icons.usb_off_rounded,
          'Placa sem resposta',
          'A porta está aberta mas a placa parou de enviar quadros.',
          AppColors.error,
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
