import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/connectivity/network_status_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../features/central/application/central_iot_provider.dart';
import '../../../../features/central/application/serial_link_provider.dart';
import '../../../../features/central/application/supervision_provider.dart';
import '../../../../features/iot/application/presence_provider.dart';

/// One communication channel shown in the gadget: a rounded (Apple-style)
/// icon tile with its label and current status underneath.
class CommTileData {
  const CommTileData({
    required this.icon,
    required this.label,
    required this.statusText,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String statusText;
  final Color color;
}

// ── Shared tile builders ─────────────────────────────────────────────────────
// The USER view of a central must be a mirror of what the central itself
// shows, so both modes map their state strings through these builders —
// same state, same label, same color. A null state renders "Verificando…".

CommTileData _wifiTile(BuildContext context, String? state) {
  return switch (state) {
    'online' => const CommTileData(
        icon: Icons.wifi_rounded,
        label: 'WI-FI',
        statusText: 'Conectado',
        color: AppColors.success,
      ),
    'limited' => const CommTileData(
        icon: Icons.wifi_rounded,
        label: 'WI-FI',
        statusText: 'Limitado',
        color: AppColors.warning,
      ),
    'offline' => const CommTileData(
        icon: Icons.wifi_off_rounded,
        label: 'WI-FI',
        statusText: 'Sem rede',
        color: AppColors.error,
      ),
    _ => CommTileData(
        icon: Icons.wifi_rounded,
        label: 'WI-FI',
        statusText: 'Verificando…',
        color: context.textSecondary.withValues(alpha: 0.6),
      ),
  };
}

CommTileData _usbTile(BuildContext context, String? state) {
  return switch (state) {
    'connected' => const CommTileData(
        icon: Icons.usb_rounded,
        label: 'USB',
        statusText: 'Conectado',
        color: AppColors.success,
      ),
    'connecting' => const CommTileData(
        icon: Icons.usb_rounded,
        label: 'USB',
        statusText: 'Conectando…',
        color: AppColors.warning,
      ),
    'error' => const CommTileData(
        icon: Icons.usb_off_rounded,
        label: 'USB',
        statusText: 'Erro',
        color: AppColors.error,
      ),
    'disconnected' => CommTileData(
        icon: Icons.usb_off_rounded,
        label: 'USB',
        statusText: 'Desconectado',
        color: context.textSecondary.withValues(alpha: 0.6),
      ),
    _ => CommTileData(
        icon: Icons.usb_rounded,
        label: 'USB',
        statusText: 'Verificando…',
        color: context.textSecondary.withValues(alpha: 0.6),
      ),
  };
}

CommTileData _meshTile(BuildContext context, String? state) {
  return switch (state) {
    'connected' => const CommTileData(
        icon: Icons.hub_rounded,
        label: 'REDE INTERNA',
        statusText: 'Conectado',
        color: AppColors.success,
      ),
    'connecting' => const CommTileData(
        icon: Icons.hub_rounded,
        label: 'REDE INTERNA',
        statusText: 'Conectando…',
        color: AppColors.warning,
      ),
    'disconnected' => CommTileData(
        icon: Icons.hub_rounded,
        label: 'REDE INTERNA',
        statusText: 'Desconectado',
        color: context.textSecondary.withValues(alpha: 0.6),
      ),
    _ => CommTileData(
        icon: Icons.hub_rounded,
        label: 'REDE INTERNA',
        statusText: 'Verificando…',
        color: context.textSecondary.withValues(alpha: 0.6),
      ),
  };
}

CommTileData _cloudTile(BuildContext context, String? state) {
  return switch (state) {
    'connected' => const CommTileData(
        icon: Icons.cloud_done_rounded,
        label: 'NUVEM',
        statusText: 'Conectado',
        color: AppColors.success,
      ),
    'connecting' => const CommTileData(
        icon: Icons.cloud_rounded,
        label: 'NUVEM',
        statusText: 'Conectando…',
        color: AppColors.warning,
      ),
    'disconnected' => const CommTileData(
        icon: Icons.cloud_off_rounded,
        label: 'NUVEM',
        statusText: 'Desconectado',
        color: AppColors.error,
      ),
    _ => CommTileData(
        icon: Icons.cloud_rounded,
        label: 'NUVEM',
        statusText: 'Verificando…',
        color: context.textSecondary.withValues(alpha: 0.6),
      ),
  };
}

/// COMUNICAÇÃO gadget for the central's own dashboard (CENTRAL mode):
/// reads the device's local Wi-Fi, USB and MQTT state.
class CentralCommGadget extends ConsumerWidget {
  const CentralCommGadget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(networkStatusProvider);
    // Protocol-driven: "Conectado" means valid SAFR frames are flowing, not
    // merely that a USB port is open (docs/safr/protocol-safr-v3.md §8).
    final link = ref.watch(serialLinkProvider);
    final mesh = ref.watch(meshLinkStateProvider);
    final iot = ref.watch(centralIotConnectionProvider);

    final cloudState = iot.isLoading
        ? 'connecting'
        : (iot.valueOrNull ?? false)
            ? 'connected'
            : 'disconnected';

    return CommStatusGadget(tiles: [
      _wifiTile(context, network.name),
      _usbTile(context, link.name),
      _meshTile(context, mesh),
      _cloudTile(context, cloudState),
    ]);
  }
}

/// COMUNICAÇÃO gadget for a central viewed by a USER: renders the state the
/// central itself publishes over MQTT (retained presence payload) — never
/// the phone's own connectivity — through the same tile builders the
/// central uses, so both screens always match.
class UserCentralCommGadget extends ConsumerWidget {
  const UserCentralCommGadget({super.key, required this.identityId});

  final String identityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(centralLiveStatusProvider(identityId));

    // Offline central: its cloud link is down, its network is unreachable
    // and any retained wifi/usb values are stale — mirror what the central
    // itself would show in that situation.
    final (String? wifi, String? usb, String? mesh, String? cloud) =
        switch (status.presence) {
      PresenceStatus.online => (
          status.wifi,
          status.usb,
          status.mesh ?? 'disconnected',
          'connected',
        ),
      PresenceStatus.offline => (
          'offline',
          'disconnected',
          'disconnected',
          'disconnected',
        ),
      PresenceStatus.unknown => (null, null, null, null),
    };

    return CommStatusGadget(tiles: [
      _wifiTile(context, wifi),
      _usbTile(context, usb),
      _meshTile(context, mesh),
      _cloudTile(context, cloud),
    ]);
  }
}

/// Dumb rendering of the gadget: a surface card with one rounded icon tile
/// per channel. Tile size adapts to the available width so it fits phones,
/// tablets and web without overflowing.
class CommStatusGadget extends StatelessWidget {
  const CommStatusGadget({super.key, required this.tiles});

  final List<CommTileData> tiles;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: context.borderColor.withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Icon scales with the slot width but stays in a comfortable
          // range on tablets/web, where the row is also capped and centered.
          final slotWidth = constraints.maxWidth / tiles.length;
          final iconSize = (slotWidth * 0.45).clamp(44.0, 56.0);

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Row(
                children: [
                  for (final tile in tiles)
                    Expanded(child: _CommTile(data: tile, size: iconSize)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CommTile extends StatelessWidget {
  const _CommTile({required this.data, required this.size});

  final CommTileData data;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '${data.label} — ${data.statusText}',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: data.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(size * 0.28),
              border: Border.all(
                color: data.color.withValues(alpha: 0.3),
                width: 0.8,
              ),
            ),
            child: Icon(data.icon, color: data.color, size: size * 0.44),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                data.label,
                maxLines: 1,
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                data.statusText,
                maxLines: 1,
                style: TextStyle(
                  color: data.color,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
