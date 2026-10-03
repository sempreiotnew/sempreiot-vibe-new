import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../domain/safr/safr_v2_frame.dart' as v2;
import '../../domain/safr/safr_v2_payloads.dart' as v2p;
import '../../domain/safr_frame.dart';
import '../../application/central_installation_provider.dart';
import '../../application/ota_rollout_words.dart';
import '../widgets/safr_frame_text.dart';

class SafrDetailScreen extends StatefulWidget {
  const SafrDetailScreen({super.key, required this.packet});

  final SerialPacket packet;

  @override
  State<SafrDetailScreen> createState() => _SafrDetailScreenState();
}

class _SafrDetailScreenState extends State<SafrDetailScreen> {
  bool _showHex = false;

  @override
  Widget build(BuildContext context) {
    final raw = widget.packet.rawBytes;
    if (raw.length > 1 && (raw[1] == v2.safrVer2 || raw[1] == v2.safrVer3)) {
      return _WireDetailScaffold(
        packet: widget.packet,
        showHex: _showHex,
        onToggleHex: () => setState(() => _showHex = !_showHex),
      );
    }
    final frame = parseSafrFrame(widget.packet.rawBytes);
    final (evtColor, evtLabel) = safrEventStyle(frame.payload?.event);
    final isDecryptFail = frame.decryptionAttempted && !frame.decryptionSuccess;
    final titleColor = isDecryptFail ? AppColors.error : evtColor;
    final titleLabel = isDecryptFail ? 'DECRYPT ERR' : evtLabel;

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundDark,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
          color: AppColors.textSecondaryDark,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: titleColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: titleColor.withValues(alpha: 0.4), width: 0.7),
              ),
              child: Text(
                titleLabel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: titleColor,
                ),
              ),
            ),
            if (frame.validSof) ...[
              const SizedBox(width: 10),
              Text(
                'MSG #${frame.msgId}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: AppColors.textSecondaryDark,
                ),
              ),
            ],
          ],
        ),
        actions: [
          _EncBadge(frame: frame),
          const SizedBox(width: 4),
          IconButton(
            icon: Icon(
              _showHex ? Icons.analytics_outlined : Icons.data_array_rounded,
              size: 18,
            ),
            color: AppColors.textSecondaryDark,
            tooltip: _showHex ? 'Mostrar decodificado' : 'Mostrar hex bruto',
            onPressed: () => setState(() => _showHex = !_showHex),
          ),
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 18),
            color: AppColors.textSecondaryDark,
            tooltip: 'Copiar',
            onPressed: () => _copy(context, frame),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _showHex
          ? _HexBody(bytes: widget.packet.rawBytes)
          : _DecodedBody(frame: frame, receivedAt: widget.packet.receivedAt),
    );
  }

  void _copy(BuildContext context, SafrFrame frame) {
    final buf = StringBuffer();
    buf.writeln(
        '[${safrTimeLabel(widget.packet.receivedAt)}] MSG #${frame.msgId}');
    final p = frame.payload;
    if (p != null) {
      buf.writeln('Event:    ${p.event.name.toUpperCase()}');
      buf.writeln('Device:   ${frame.srcMac}');
      buf.writeln('Time:     ${safrFmtTs(p.timestamp)}');
      if (p.tempTenths != null) {
        buf.writeln('Temp:     ${safrFmtTemp(p.tempTenths)}');
      }
      if (p.smokeRaw != null) buf.writeln('Smoke:    ${p.smokeRaw} ADU');
      if (p.humidity != null) buf.writeln('Humidity: ${p.humidity} %');
      if (p.faultCode != null) {
        buf.writeln('Fault:    ${safrFaultCodeName(p.faultCode!)}');
      }
      buf.writeln('RSSI:     ${p.rssiDbm} dBm');
    } else if (frame.decryptionAttempted && !frame.decryptionSuccess) {
      buf.writeln('Decryption failed — check PSK and USB connection');
    }
    Clipboard.setData(ClipboardData(text: buf.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copiado'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

// ── Decoded body ──────────────────────────────────────────────────────────────

class _DecodedBody extends StatelessWidget {
  const _DecodedBody({required this.frame, required this.receivedAt});

  final SafrFrame frame;
  final DateTime receivedAt;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (frame.parseError != null)
            _ErrorCard(message: frame.parseError!)
          else ...[
            if (frame.decryptionAttempted && !frame.decryptionSuccess)
              const _DecryptFailureCard(),
            if (frame.payload != null)
              _PayloadSections(frame: frame, receivedAt: receivedAt)
            else if (!frame.decryptionAttempted)
              const _ErrorCard(message: 'Frame sem payload decodificado'),
          ],
        ],
      ),
    );
  }
}

class _PayloadSections extends StatelessWidget {
  const _PayloadSections({required this.frame, required this.receivedAt});

  final SafrFrame frame;
  final DateTime receivedAt;

  @override
  Widget build(BuildContext context) {
    final p = frame.payload!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Device ─────────────────────────────────────────
        _Card(
          label: 'DISPOSITIVO',
          icon: Icons.memory_rounded,
          iconColor: AppColors.secondary,
          children: [
            _InfoRow(label: 'MAC', value: frame.srcMac),
            _InfoRow(label: 'Recebido', value: safrTimeLabel(receivedAt)),
            _InfoRow(label: 'Data/hora', value: safrFmtTs(p.timestamp)),
          ],
        ),

        const SizedBox(height: 12),

        // ── Event ───────────────────────────────────────────
        _EventCard(event: p.event),

        // ── Sensors ─────────────────────────────────────────
        if (p.smokeRaw != null) ...[
          const SizedBox(height: 12),
          _Card(
            label: 'SENSORES',
            icon: Icons.sensors_rounded,
            iconColor: AppColors.secondary,
            children: [
              _InfoRow(label: 'Temperatura', value: safrFmtTemp(p.tempTenths)),
              _InfoRow(label: 'Fumaça', value: '${p.smokeRaw} ADU'),
              _InfoRow(label: 'Umidade', value: '${p.humidity} %'),
            ],
          ),
        ],

        // ── Fault ───────────────────────────────────────────
        if (p.faultCode != null) ...[
          const SizedBox(height: 12),
          _FaultCard(payload: p),
        ],

        // ── Power ───────────────────────────────────────────
        const SizedBox(height: 12),
        _PowerCard(payload: p),

        // ── Signal / mesh ───────────────────────────────────
        const SizedBox(height: 12),
        _Card(
          label: 'REDE / MESH',
          icon: Icons.router_rounded,
          iconColor: AppColors.secondary,
          children: [
            _SignalRow(rssi: p.rssiDbm),
            if (p.childCount > 0)
              _InfoRow(
                label: 'Filhos',
                value: '${p.childCount}  →  ${p.children.join(', ')}',
              )
            else
              const _InfoRow(label: 'Papel', value: 'Nó folha (sem filhos)'),
          ],
        ),
      ],
    );
  }
}

// ── Event card ────────────────────────────────────────────────────────────────

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event});

  final SafrEvent event;

  @override
  Widget build(BuildContext context) {
    final (color, label) = safrEventStyle(event);
    final description = switch (event) {
      SafrEvent.ok => 'Sistema operando normalmente.',
      SafrEvent.alert => 'Atenção — condição de pré-alarme detectada.',
      SafrEvent.alarm => 'Alarme ativo — ação imediata necessária!',
      SafrEvent.trouble => 'Falha no sistema — verifique o dispositivo.',
      SafrEvent.unknown => 'Evento desconhecido.',
    };

    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 0.7),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_eventIcon(event), color: color, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: color,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _eventIcon(SafrEvent e) => switch (e) {
        SafrEvent.ok => Icons.check_circle_outline_rounded,
        SafrEvent.alert => Icons.warning_amber_rounded,
        SafrEvent.alarm => Icons.local_fire_department_rounded,
        SafrEvent.trouble => Icons.error_outline_rounded,
        SafrEvent.unknown => Icons.help_outline_rounded,
      };
}

// ── Fault card ────────────────────────────────────────────────────────────────

class _FaultCard extends StatelessWidget {
  const _FaultCard({required this.payload});

  final SafrPayload payload;

  @override
  Widget build(BuildContext context) {
    final faults = <String>[
      if (payload.faultSmoke == true) 'Fumaça',
      if (payload.faultTemp == true) 'Temperatura',
      if (payload.faultBatt == true) 'Bateria',
    ];
    final label = faults.isEmpty
        ? safrFaultCodeName(payload.faultCode!)
        : faults.join(', ');

    return Container(
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: AppColors.error.withValues(alpha: 0.3), width: 0.7),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.report_rounded,
                color: AppColors.error, size: 20),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'FALHA DETECTADA',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: AppColors.error.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.error,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Power card ────────────────────────────────────────────────────────────────

class _PowerCard extends StatelessWidget {
  const _PowerCard({required this.payload});

  final SafrPayload payload;

  @override
  Widget build(BuildContext context) {
    final bits = [
      (
        'Rede elétrica',
        payload.pwrAcOk,
        payload.pwrAcOk ? AppColors.success : AppColors.error,
      ),
      (
        'Boost',
        payload.pwrBoost,
        payload.pwrBoost
            ? AppColors.warning
            : context.textSecondary.withValues(alpha: 0.3),
      ),
      (
        'Carregando',
        payload.pwrCharging,
        payload.pwrCharging
            ? AppColors.secondary
            : context.textSecondary.withValues(alpha: 0.3),
      ),
      (
        'Tamper',
        payload.pwrTamper,
        payload.pwrTamper ? AppColors.error : AppColors.success,
      ),
    ];

    return _Card(
      label: 'ENERGIA',
      icon: Icons.bolt_rounded,
      iconColor: AppColors.warning,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: bits.map((b) {
            final (label, active, color) = b;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: color.withValues(alpha: 0.3), width: 0.6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: active
                          ? color
                          : context.textSecondary.withValues(alpha: 0.4),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

// ── Signal row ────────────────────────────────────────────────────────────────

class _SignalRow extends StatelessWidget {
  const _SignalRow({required this.rssi});

  final int rssi;

  @override
  Widget build(BuildContext context) {
    final color = rssi >= -60
        ? AppColors.success
        : rssi >= -80
            ? AppColors.warning
            : AppColors.error;
    final label = rssi >= -60
        ? 'Excelente'
        : rssi >= -70
            ? 'Bom'
            : rssi >= -80
                ? 'Regular'
                : 'Fraco';

    return Row(
      children: [
        Expanded(
          child: _InfoRow(
            label: 'Sinal (RSSI)',
            value: '$rssi dBm  ·  $label',
            valueColor: color,
          ),
        ),
      ],
    );
  }
}

// ── Decrypt failure card ──────────────────────────────────────────────────────

class _DecryptFailureCard extends StatelessWidget {
  const _DecryptFailureCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: AppColors.error.withValues(alpha: 0.3), width: 0.7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lock_open_rounded,
                  size: 15, color: AppColors.error),
              const SizedBox(width: 8),
              Text(
                'Falha na decriptografia',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.error.withValues(alpha: 0.9),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'O frame chegou com F_ENC ativo. O firmware só envia '
            'frames após criptografar com sucesso — portanto esta '
            'falha é no lado do app, não no firmware.',
            style: TextStyle(
              fontSize: 12,
              color: context.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '• PSK diferente entre firmware e app\n'
            '• Frame corrompido durante transmissão USB\n'
            '• Diferença no CCM entre mbedTLS e PointyCastle',
            style: TextStyle(
              fontSize: 12,
              color: context.textSecondary.withValues(alpha: 0.7),
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Error card ────────────────────────────────────────────────────────────────

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: AppColors.error.withValues(alpha: 0.3), width: 0.7),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 18, color: AppColors.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                color: context.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Hex body ──────────────────────────────────────────────────────────────────

class _HexBody extends StatelessWidget {
  const _HexBody({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.surfaceColor.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: context.borderColor.withValues(alpha: 0.3), width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${bytes.length} bytes  ·  HEX DUMP',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: context.textSecondary.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _hexDump(bytes),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: context.textPrimary.withValues(alpha: 0.85),
                height: 1.7,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Enc badge widget ──────────────────────────────────────────────────────────

class _EncBadge extends StatelessWidget {
  const _EncBadge({required this.frame});

  final SafrFrame frame;

  @override
  Widget build(BuildContext context) {
    if (!frame.isEncrypted) {
      return _chip(context, 'PLAINTEXT', AppColors.warning);
    }
    if (!frame.decryptionAttempted) {
      return _chip(context, 'ENC', AppColors.warning);
    }
    return _chip(
      context,
      frame.decryptionSuccess ? 'ENC ✓' : 'ENC ✗',
      frame.decryptionSuccess ? AppColors.success : AppColors.error,
    );
  }
}

// ── Generic card section ──────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  const _Card({
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.children,
  });

  final String label;
  final IconData icon;
  final Color iconColor;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: context.borderColor.withValues(alpha: 0.4), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(
              children: [
                Icon(icon, size: 13, color: iconColor.withValues(alpha: 0.8)),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: iconColor.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
          // Content
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Info row ──────────────────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: context.textSecondary.withValues(alpha: 0.6),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: valueColor ?? context.textPrimary.withValues(alpha: 0.9),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Shared helpers (public so serial_logs_screen can use them) ────────────────

(Color, String) safrEventStyle(SafrEvent? event) => switch (event) {
      SafrEvent.ok => (AppColors.success, 'OK'),
      SafrEvent.alert => (AppColors.warning, 'ALERT'),
      SafrEvent.alarm => (AppColors.error, 'ALARM'),
      SafrEvent.trouble => (const Color(0xFFFF8C00), 'TROUBLE'),
      _ => (const Color(0xFF888888), 'UNKNOWN'),
    };

String safrTimeLabel(DateTime t) {
  String p(int v) => v.toString().padLeft(2, '0');
  return '${p(t.hour)}:${p(t.minute)}:${p(t.second)}'
      '.${t.millisecond.toString().padLeft(3, '0')}';
}

String safrFmtTs(DateTime ts) {
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${ts.year}-${p(ts.month)}-${p(ts.day)}'
      ' ${p(ts.hour)}:${p(ts.minute)}:${p(ts.second)} UTC';
}

String safrFmtTemp(int? tenths) {
  if (tenths == null) return '—';
  final whole = tenths ~/ 10;
  final frac = tenths.abs() % 10;
  return '$whole.$frac °C';
}

String safrFaultCodeName(int code) => switch (code) {
      0x01 => 'Fumaça',
      0x02 => 'Temperatura',
      0x03 => 'Bateria',
      _ => 'Desconhecido',
    };

Widget _chip(BuildContext context, String label, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: color.withValues(alpha: 0.35), width: 0.6),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 9,
        fontWeight: FontWeight.w700,
        color: color,
        letterSpacing: 0.3,
      ),
    ),
  );
}

String _hexDump(Uint8List bytes) {
  final buf = StringBuffer();
  for (var i = 0; i < bytes.length; i += 16) {
    final end = (i + 16 < bytes.length) ? i + 16 : bytes.length;
    final row = bytes.sublist(i, end);
    final hex = row.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    final ascii = row
        .map((b) => (b >= 32 && b < 127) ? String.fromCharCode(b) : '.')
        .join();
    buf.writeln(
        '${i.toRadixString(16).padLeft(6, '0')}  ${hex.padRight(47)}  $ascii');
  }
  return buf.toString().trimRight();
}

// ── SAFR v2/v3 detail — every field decoded AND explained ────────────────────

/// One decoded fact: label + value + optional plain-language explanation of
/// what the field is for (shown as secondary text under the value).
typedef _Fact = (String, String, String?);

class _WireDetailScaffold extends ConsumerWidget {
  const _WireDetailScaffold({
    required this.packet,
    required this.showHex,
    required this.onToggleHex,
  });

  final SerialPacket packet;
  final bool showHex;
  final VoidCallback onToggleHex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Decrypt with the imported installation's key (was keyless, so every
    // encrypted frame showed a false authentication failure).
    final id = ref.watch(safrIdentityProvider);
    final frame = v2.parseSafrWireFrame(packet.rawBytes,
        key: id.key, expectedSystemId: id.systemId);
    final (color, label) = _badge(frame);

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
          color: context.textSecondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border:
                    Border.all(color: color.withValues(alpha: 0.4), width: 0.7),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'v${frame.ver} · MSG #${frame.msgId}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: context.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              showHex ? Icons.analytics_outlined : Icons.data_array_rounded,
              size: 18,
            ),
            color: context.textSecondary,
            tooltip: showHex ? 'Mostrar decodificado' : 'Mostrar hex bruto',
            onPressed: onToggleHex,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: showHex
          ? _HexBody(bytes: packet.rawBytes)
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (frame.error != null) _WireErrorCard(error: frame.error!),
                _ValidationCard(frame: frame),
                const SizedBox(height: 12),
                _FactsCard(title: 'CABEÇALHO', facts: _headerFacts(frame)),
                const SizedBox(height: 12),
                if (frame.error == null)
                  _FactsCard(
                    title: 'PAYLOAD — ${frame.msgType.name.toUpperCase()}',
                    facts: _payloadFacts(frame),
                  ),
              ],
            ),
    );
  }

  (Color, String) _badge(v2.SafrWireFrame frame) {
    if (frame.error != null) {
      return switch (frame.error!) {
        v2.SafrWireError.authFailed => (AppColors.error, 'AUTH ERR'),
        v2.SafrWireError.crcFailed => (AppColors.error, 'CRC ERR'),
        v2.SafrWireError.foreignSystem => (AppColors.error, 'OUTRO SISTEMA'),
        _ => (AppColors.error, 'PARSE ERR'),
      };
    }
    final look = safrFrameLook(frame);
    return (look.color, look.name.replaceAll('_', ' '));
  }

  List<_Fact> _headerFacts(v2.SafrWireFrame f) => [
        (
          'Versão',
          'SAFR v${f.ver}',
          f.ver == v2.safrVer3
              ? 'Protocolo atual (docs/safr/protocol-safr-v3.md).'
              : 'Protocolo anterior — somente leitura de pacotes antigos.',
        ),
        (
          'Tipo',
          '${safrMsgTypeName(f.msgType, f.msgTypeRaw)} '
              '(0x${f.msgTypeRaw.toRadixString(16).padLeft(2, '0')})',
          _msgTypeExplain(f.msgType),
        ),
        (
          'MSG_ID',
          '#${f.msgId}',
          'Sequência por remetente. O ACK cita este número; retransmissões '
              'rápidas o repetem para o receptor deduplicar.',
        ),
        if (f.systemId != null)
          (
            'SYSTEM_ID',
            '0x${f.systemId!.toRadixString(16).toUpperCase().padLeft(4, '0')}',
            'Identidade da instalação. Sistemas vizinhos são ignorados por '
                'projeto (EN 54-25).',
          ),
        (
          'De (origem)',
          _endpointLabel(f.srcMac),
          'Identidade única do dispositivo — todo sinal identifica o '
              'equipamento específico (NFPA 72).',
        ),
        (
          'Para (destino)',
          _endpointLabel(f.dstMac, broadcast: f.isDstBroadcast),
          null,
        ),
        (
          'TTL / Hops',
          '${f.ttl} / ${f.hops}',
          'TTL: saltos restantes (mata loops de roteamento). Hops: saltos já '
              'percorridos = profundidade do dispositivo na mesh.',
        ),
        (
          'Flags',
          [
            if (f.isEncrypted) 'ENC',
            if (f.ackRequired) 'ACK_REQ',
            if (f.isRetx) 'RETX',
            if (!f.isEncrypted && !f.ackRequired && !f.isRetx) '—',
          ].join(' · '),
          [
            if (f.isEncrypted) 'ENC: payload criptografado (AES-CCM).',
            if (f.ackRequired)
              'ACK_REQ: exige confirmação — obrigatório em ALARM/TROUBLE.',
            if (f.isRetx)
              'RETX: reanúncio periódico (≤60 s) do mesmo evento — NFPA 72.',
            if (!f.isEncrypted)
              'SEM criptografia: rejeitado em produção (spec §4.1).',
          ].join(' '),
        ),
        (
          'Boot / Msg ctr',
          '${f.bootCtr} / ${f.msgCtr}',
          'Contadores que formam o nonce criptográfico e detectam replay: '
              'um quadro repetido/atrasado nunca altera o estado.',
        ),
        ('Tamanho', '${f.lenField} bytes', null),
      ];

  String? _msgTypeExplain(v2.SafrMsgType t) => switch (t) {
        v2.SafrMsgType.event =>
          'Mudança de estado no dispositivo (alarme, falha, normalização).',
        v2.SafrMsgType.heartbeat =>
          'Prova de vida para supervisão (15 s na tomada, 60 s a bateria) — '
              'silêncio de 3 intervalos vira "sem comunicação" (NFPA 72 '
              '≤ 200 s).',
        v2.SafrMsgType.topology =>
          'Mapa da rede: pai, filhos e sinal. De um detector: os pais que '
              'ele ouviu.',
        v2.SafrMsgType.ack =>
          'Confirmação: o quadro citado foi processado (ou recusado, com o '
              'motivo).',
        v2.SafrMsgType.command => 'Comando (§7.6).',
        v2.SafrMsgType.timeSync =>
          'Distribui o relógio real para os dispositivos.',
        v2.SafrMsgType.eventLogReq =>
          'Pedido de reenvio do diário de eventos (EN 54-25: nenhum alarme '
              'se perde).',
        v2.SafrMsgType.eventLogData =>
          'Evento reenviado do diário — ocorreu enquanto a central estava '
              'desconectada.',
        v2.SafrMsgType.installation =>
          'Identidade da instalação, resposta da placa a GET_INSTALLATION. '
              'Nunca leva as chaves.',
        v2.SafrMsgType.nameAnnounce =>
          'O dispositivo anuncia nome, zona, papel, produto e versão do '
              'firmware.',
        v2.SafrMsgType.deviceTable =>
          'Tabela de dispositivos da placa, uma página por quadro (§7.12).',
        v2.SafrMsgType.code =>
          'Código da instalação lido da placa pelo canal de setup (§7.13).',
        v2.SafrMsgType.parentProbe =>
          'Procura de pai ou teste de alcance por ESP-NOW (§7.14).',
        v2.SafrMsgType.parentOffer =>
          'Resposta a uma procura de pai / teste de alcance (§7.15).',
        v2.SafrMsgType.otaPushBegin ||
        v2.SafrMsgType.otaPushChunk ||
        v2.SafrMsgType.otaPushEnd =>
          'Envio de firmware da central para a placa (§13.3).',
        v2.SafrMsgType.otaPushResult =>
          'A placa diz em que ponto está o envio de firmware (§13.3).',
        v2.SafrMsgType.otaStatus =>
          'Progresso de uma unidade na atualização (§13.4).',
        v2.SafrMsgType.otaResult =>
          'Resultado final da atualização de uma unidade (§13.4).',
        v2.SafrMsgType.otaRollout =>
          'Tabela da atualização mantida pela placa (§13.6).',
        v2.SafrMsgType.unknown => null,
      };

  /// Humanized endpoint: the central's addresses read as words, devices keep
  /// their MAC.
  String _endpointLabel(String mac, {bool broadcast = false}) {
    if (broadcast) return 'Central (broadcast)';
    if (mac == v2.safrCentralMac) return 'Central (esta unidade)';
    return mac;
  }

  List<_Fact> _eventFacts(v2p.SafrEventPayload p) => [
        (
          'Evento',
          p.eventType.name.toUpperCase(),
          switch (p.eventType) {
            v2p.SafrEventType.alarm =>
              'ALARME: fica retido na central até rearme manual do operador '
                  '(UL 864/NFPA 72) e é reanunciado a cada ≤60 s.',
            v2p.SafrEventType.trouble =>
              'Falha de equipamento/comunicação — limpa com a normalização '
                  '(RESTORE) correspondente.',
            v2p.SafrEventType.alert =>
              'Supervisão / pré-alarme — informativo, não retém.',
            _ => 'Normalização ou status periódico.',
          },
        ),
        ('Código', p.eventCode.name, _eventCodeExplain(p.eventCode)),
        if (p.devSeq != null)
          (
            'DEV_SEQ',
            '#${p.devSeq}',
            'Identidade do evento: reanúncios e reenvios do diário repetem '
                'este número e são deduplicados — o mesmo alarme nunca vira '
                'dois.',
          ),
        (
          'Horário (disp.)',
          safrFmtTs(p.timestamp),
          'Momento da DETECÇÃO no dispositivo (relógio sincronizado). Pode '
              'diferir do horário de recepção em eventos reenviados do '
              'diário.',
        ),
        if (p.batteryPct != null)
          (
            'Bateria',
            '${p.batteryPct}%',
            'O aviso normativo é o TROUBLE BATT_LOW: dispara com ≥7 dias de '
                'operação restante (NFPA 72).',
          ),
        if (p.smokeRaw != null)
          (
            'Fumaça',
            '${p.smokeRaw} ADU',
            'Leitura bruta do sensor (ADP188BI) — valor cru para tendência '
                'de pré-alarme e auditoria de limiares.',
          ),
        if (p.tempTenths != null)
          (
            'Temperatura',
            '${(p.tempTenths! / 10).toStringAsFixed(1)} °C',
            null
          ),
        if (p.humidityPct != null) ('Umidade', '${p.humidityPct}%', null),
        (
          'Energia',
          [
            if (p.acOk) 'AC',
            if (p.charging) 'carregando',
            if (p.onBattery) 'na bateria',
            if (p.tamper) 'TAMPER',
            if (!p.acOk && !p.charging && !p.onBattery && !p.tamper) '—',
          ].join(' · '),
          'Estado dos GPIOs de energia no momento do evento.',
        ),
        if (p.faultFlags != 0)
          (
            'Falhas ativas',
            '0x${p.faultFlags.toRadixString(16)}',
            'Bitmask de todas as falhas simultâneas; FAULT_CODE indica a '
                'principal.',
          ),
      ];

  String? _eventCodeExplain(v2p.SafrEventCode c) => switch (c) {
        v2p.SafrEventCode.smokeAlarm => 'Fumaça acima do limiar de alarme.',
        v2p.SafrEventCode.heatAlarm => 'Temperatura de alarme.',
        v2p.SafrEventCode.smokeRising => 'Fumaça subindo — pré-alarme.',
        v2p.SafrEventCode.manualTest =>
          'Teste manual (botão) — distinto de alarme real (NFPA 72).',
        v2p.SafrEventCode.tamper => 'Dispositivo removido da base.',
        v2p.SafrEventCode.battLow =>
          'Bateria baixa com ≥7 dias de autonomia restante (NFPA 72).',
        v2p.SafrEventCode.battCritical => 'Bateria crítica — desligamento '
            'iminente.',
        v2p.SafrEventCode.sensorFault => 'Falha no sensor.',
        v2p.SafrEventCode.commFault =>
          'Dispositivo filho inalcançável (reportado pelo pai/root).',
        v2p.SafrEventCode.acLost => 'Rede elétrica perdida — na bateria.',
        v2p.SafrEventCode.restore =>
          'Condição normalizada (FAULT_CODE indica qual). NÃO limpa alarme '
              'retido — só o rearme do operador limpa.',
        v2p.SafrEventCode.rfInterference =>
          'Interferência/degradação no enlace de rádio (EN 54-25).',
        _ => null,
      };

  List<_Fact> _payloadFacts(v2.SafrWireFrame f) {
    switch (f.payload) {
      case v2p.SafrEventPayload p:
        return _eventFacts(p);
      case v2p.SafrHeartbeatPayload p:
        return [
          ('Horário (disp.)', safrFmtTs(p.timestamp), null),
          (
            'Uptime',
            '${p.uptimeS}s',
            'Tempo desde o último boot — quedas frequentes indicam '
                'instabilidade.',
          ),
          if (p.batteryPct != null) ('Bateria', '${p.batteryPct}%', null),
          if (p.tempTenths != null)
            (
              'Temperatura',
              '${(p.tempTenths! / 10).toStringAsFixed(1)} °C',
              null
            ),
          (
            'RSSI → pai',
            p.rssiToParent == null ? '— (root)' : '${p.rssiToParent} dBm',
            'Qualidade do enlace de rádio com o pai. Degradação sustentada '
                'gera TROUBLE de interferência.',
          ),
          ('Pai', _endpointLabel(p.parentMac), null),
          ('Camada', '${p.layer}', 'Profundidade na mesh (root = 0).'),
        ];
      case v2p.SafrTopologyPayload p:
        return [
          (
            'Papel',
            p.role.name,
            'root = ponte serial · node = repetidor · '
                'leaf = sensor a bateria.'
          ),
          ('Camada', '${p.layer}', null),
          ('Pai', _endpointLabel(p.parentMac), null),
          (
            'RSSI → pai',
            p.rssiToParent == null ? '—' : '${p.rssiToParent} dBm',
            null
          ),
          ('Filhos', '${p.children.length}', null),
          for (final c in p.children) ('  ${c.mac}', '${c.rssi} dBm', null),
        ];
      case v2p.SafrAckPayload p:
        return [
          (
            'Confirma MSG',
            '#${p.ackedMsgId}',
            'O remetente daquele MSG_ID para de retransmitir ao receber '
                'este ACK.',
          ),
          (
            'Status',
            switch (p.status) {
              v2p.SafrAckStatus.ok => 'OK',
              v2p.SafrAckStatus.error => 'ERROR',
              v2p.SafrAckStatus.unknownDst => 'UNKNOWN_DST',
              v2p.SafrAckStatus.unknown => '0x${p.status.wire.toRadixString(16)}',
            },
            'OK = processado · ERROR = recebido mas recusado · '
                'UNKNOWN_DST = destino inexistente.',
          ),
          if (p.status == v2p.SafrAckStatus.error && p.detailRaw != 0)
            (
              'Detalhe',
              '${p.detailRaw}',
              'Se confirmava um comando de instalação: '
                  '${p.detail.label.isEmpty ? '—' : p.detail.label}. '
                  'Se confirmava um quadro de atualização: '
                  '${otaReasonLogText(p.detailRaw)}.',
            ),
        ];
      case v2p.SafrCommandPayload p:
        final cmd =
            v2p.SafrCommand.values.where((c) => c.wire == p.cmdRaw).firstOrNull;
        return [
          (
            'Comando',
            safrCommandName(p.cmdRaw),
            switch (cmd) {
              v2p.SafrCommand.linkCheck =>
                'Verificação do enlace de descida a cada 30 s — o root só '
                    'confirma (UL 864/EN 54-25: supervisão nos dois '
                    'sentidos).',
              v2p.SafrCommand.silence =>
                'Silencia sirenes. NÃO limpa o alarme retido — silenciar e '
                    'rearmar são ações distintas (UL 864).',
              v2p.SafrCommand.test => 'Auto-teste — gera ALERT de teste, '
                  'distinto de alarme real.',
              v2p.SafrCommand.relaySet => 'Aciona/desliga o relé (GPIO12).',
              v2p.SafrCommand.identify =>
                'Pisca o LED para localizar o dispositivo fisicamente.',
              v2p.SafrCommand.reset =>
                'REARME do operador: única ação que limpa alarmes retidos '
                    '(UL 864/NFPA 72). A central só limpa após o ACK do '
                    'root.',
              v2p.SafrCommand.getInstallation =>
                'Pede à placa a identidade da instalação (resposta: INST).',
              v2p.SafrCommand.setInstallation =>
                'Grava o código numa placa nova (canal de setup).',
              v2p.SafrCommand.setDevice =>
                'Nome e zona de um dispositivo; a placa repassa a ele.',
              v2p.SafrCommand.retireDevice =>
                'A placa passa a ignorar este dispositivo.',
              v2p.SafrCommand.unretireDevice =>
                'A placa volta a aceitar este dispositivo.',
              v2p.SafrCommand.replaceDevice =>
                'Copia nome e zona de um dispositivo para outro e aposenta '
                    'o antigo.',
              v2p.SafrCommand.decommission =>
                'Reset de fábrica remoto de um dispositivo.',
              v2p.SafrCommand.forgetDevice =>
                'Remove da placa um registro aposentado.',
              v2p.SafrCommand.getDeviceTable =>
                'Pede a tabela de dispositivos (resposta: TABLE).',
              v2p.SafrCommand.getCode =>
                'Pede o código da instalação pelo canal de setup (resposta: '
                    'CODE).',
              v2p.SafrCommand.otaBaud =>
                'Velocidade do cabo durante o envio de firmware.',
              v2p.SafrCommand.otaOffer =>
                'A placa oferece um firmware novo a uma unidade.',
              v2p.SafrCommand.getRollout =>
                'Pede a tabela da atualização (resposta: ROLL).',
              v2p.SafrCommand.otaControl =>
                'Inicia, pausa, retoma ou cancela uma atualização.',
              null => 'Código que este app não conhece.',
            },
          ),
          ('Args', p.args.isEmpty ? '—' : p.args.join(', '), null),
        ];
      case v2p.SafrTimeSyncPayload p:
        return [
          ('Epoch', '${p.epoch}', 'Unix UTC — o root redistribui à mesh.'),
          (
            'Fuso (¼h)',
            '${p.tzOffsetQuarterHours}',
            'Apenas dica de exibição.'
          ),
        ];
      case v2p.SafrEventLogReqPayload p:
        return [
          (
            'Desde JRN_SEQ',
            '#${p.sinceJrnSeq}',
            'Última posição do diário que a central já possui; o root '
                'reenvia tudo o que veio depois.',
          ),
          (
            'Máx. por lote',
            p.maxCount == 0 ? 'padrão (32)' : '${p.maxCount}',
            'Controle de fluxo — o reenvio nunca atropela alarmes vivos.'
          ),
        ];
      case v2p.SafrEventLogDataPayload p:
        return [
          (
            'JRN_SEQ',
            '#${p.jrnSeq}',
            'Posição no diário do root. A central persiste o maior valor '
                'visto e pede a partir dele na próxima reconexão.',
          ),
          (
            'Lote',
            [
              if (p.isLast) 'último do lote',
              if (p.isEmpty) 'diário vazio',
              if (!p.isLast && !p.isEmpty) 'há mais entradas',
            ].join(' · '),
            null,
          ),
          if (!p.isEmpty)
            (
              'Origem',
              p.origSrcMac,
              'Dispositivo que gerou o '
                  'evento original — o quadro em si vem do root.'
            ),
          if (p.event != null) ..._eventFacts(p.event!),
        ];
      case v2p.SafrInstallationPayload p:
        return [
          ('Nome', p.name, null),
          ('SYSTEM_ID', '0x${p.systemId.toRadixString(16).toUpperCase().padLeft(4, '0')}', null),
          ('Canal', '${p.channel}', null),
          ('Rede', p.netSsid, null),
          ('Dispositivos', '${p.enrolled.length}', 'Visão antiga; a tabela completa vem em DEVICE_TABLE.'),
          for (final e in p.enrolled)
            ('  ${e.mac}', [e.name, if (e.zone.isNotEmpty) e.zone].join(' · '), null),
        ];
      case v2p.SafrNameAnnouncePayload p:
        return [
          ('Nome', p.name, null),
          ('Zona', p.zone.isEmpty ? '—' : p.zone, null),
          ('Papel', p.role.name, null),
          if (p.productCode != null)
            ('Produto', '0x${p.productCode!.toRadixString(16).padLeft(4, '0').toUpperCase()}', null),
          if (p.hwRev != null) ('Revisão HW', '${p.hwRev}', null),
          if (p.fwVersion != null) ('Firmware', p.fwVersion!, null),
        ];
      case v2p.SafrDeviceTablePayload p:
        return [
          ('Página', '${p.page} de ${p.pageCount}', null),
          ('Total na placa', '${p.total}', null),
          for (final e in p.entries)
            (
              '  ${e.mac}',
              [
                e.state.name,
                if (e.name.isNotEmpty) e.name,
                if (e.zone.isNotEmpty) e.zone,
              ].join(' · '),
              null,
            ),
        ];
      case v2p.SafrCodePayload p:
        return [
          ('Nome', p.code.name, null),
          ('SYSTEM_ID', '0x${p.code.systemId.toRadixString(16).toUpperCase().padLeft(4, '0')}', null),
          ('Canal', '${p.code.channel}', null),
          ('Chaves', 'não exibidas', 'A rede e a chave SAFR viajam cifradas e não aparecem no registro.'),
        ];
      case v2p.SafrParentProbePayload p:
        return [
          ('Propósito', p.isSurvey ? 'teste de alcance' : 'procura de pai', null),
        ];
      case v2p.SafrParentOfferPayload p:
        return [
          ('Propósito', p.purpose == 1 ? 'teste de alcance' : 'procura de pai', null),
          ('Sinal ouvido', '${p.rssiSeen} dBm', null),
          ('Camada', p.layer == null ? 'sem rede' : '${p.layer}', null),
        ];
      case v2p.SafrUnknownPayload p:
        return [('Payload', '${p.bytes.length} bytes não decodificados', null)];
      case null:
        return const [('Payload', 'não decodificado', null)];
      default:
        // The firmware-update frames (§13): the one-line summary says it all.
        return [('Conteúdo', safrFrameSummary(f), null)];
    }
  }
}

/// Answers, in order, the three questions a fire-panel operator/technician
/// asks about any frame: chegou íntegro? é autêntico? é do meu sistema?
class _ValidationCard extends StatelessWidget {
  const _ValidationCard({required this.frame});

  final v2.SafrWireFrame frame;

  @override
  Widget build(BuildContext context) {
    final crcOk = frame.error != v2.SafrWireError.crcFailed &&
        frame.error != v2.SafrWireError.truncated;
    final bool? authOk = !frame.isEncrypted
        ? null
        : frame.error == v2.SafrWireError.authFailed
            ? false
            : frame.error == null ||
                    frame.error == v2.SafrWireError.payloadParseError
                ? true
                : null;
    final bool? siteOk = frame.systemId == null
        ? null
        : frame.error == v2.SafrWireError.foreignSystem
            ? false
            : true;

    Widget check(String label, bool? ok, String explain) {
      final (icon, color) = ok == null
          ? (Icons.remove_rounded, context.textSecondary.withValues(alpha: 0.5))
          : ok
              ? (Icons.check_circle_rounded, AppColors.success)
              : (Icons.cancel_rounded, AppColors.error);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 8),
            SizedBox(
              width: 110,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: ok == false ? AppColors.error : context.textPrimary,
                ),
              ),
            ),
            Expanded(
              child: Text(
                explain,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.35,
                  color: context.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: context.borderColor.withValues(alpha: 0.7), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'VALIDAÇÃO',
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          check(
            'Integridade',
            crcOk,
            'CRC-16 sobre o quadro inteiro: os bytes chegaram exatamente '
                'como foram enviados.',
          ),
          check(
            'Autenticidade',
            authOk,
            authOk == null
                ? 'Quadro sem criptografia — rejeitado em produção.'
                : 'AES-128-CCM: só um dispositivo com a chave (PSK) desta '
                    'instalação gera este quadro; replay é detectado pelos '
                    'contadores.',
          ),
          check(
            'Instalação',
            siteOk,
            frame.systemId == null
                ? 'Quadro v2 — anterior ao SYSTEM_ID.'
                : siteOk == false
                    ? 'SYSTEM_ID de OUTRA instalação — ignorado por projeto '
                        '(EN 54-25).'
                    : 'SYSTEM_ID confere com esta instalação.',
          ),
        ],
      ),
    );
  }
}

class _FactsCard extends StatelessWidget {
  const _FactsCard({required this.title, required this.facts});

  final String title;
  final List<_Fact> facts;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: context.borderColor.withValues(alpha: 0.7), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 10),
          for (final (label, value, explain) in facts)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 130,
                        child: Text(
                          label,
                          style: TextStyle(
                            color: context.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          value,
                          style: TextStyle(
                            color: context.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (explain != null && explain.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 130, top: 2),
                      child: Text(
                        explain,
                        style: TextStyle(
                          color: context.textSecondary.withValues(alpha: 0.75),
                          fontSize: 10.5,
                          height: 1.35,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _WireErrorCard extends StatelessWidget {
  const _WireErrorCard({required this.error});

  final v2.SafrWireError error;

  @override
  Widget build(BuildContext context) {
    final (title, explanation) = switch (error) {
      v2.SafrWireError.authFailed => (
          'Falha de autenticação',
          'O quadro chegou íntegro (CRC OK), mas a verificação criptográfica '
              'falhou. Causa mais provável: a chave (PSK) do firmware não é a '
              'mesma do aplicativo.',
        ),
      v2.SafrWireError.crcFailed => (
          'Quadro corrompido',
          'Os bytes foram alterados na transmissão (CRC não confere). '
              'Verifique cabo, baud rate e interferência na linha serial.',
        ),
      v2.SafrWireError.foreignSystem => (
          'Quadro de outra instalação',
          'O SYSTEM_ID não corresponde a este sistema. Instalações vizinhas '
              'não interoperam por projeto (EN 54-25) — o quadro foi '
              'registrado e ignorado.',
        ),
      v2.SafrWireError.badVersion => (
          'Versão não suportada',
          'O byte de versão não corresponde a um protocolo SAFR conhecido.',
        ),
      _ => (
          'Falha ao decodificar',
          'O cabeçalho é válido mas o payload não segue o layout esperado '
              'para este tipo de mensagem (veja docs/safr/protocol-safr-v3.md).',
        ),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: AppColors.error.withValues(alpha: 0.4), width: 0.7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: AppColors.error, size: 18),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.error,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            explanation,
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
