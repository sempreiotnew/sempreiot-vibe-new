import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/connectivity/network_status_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../features/central/application/central_iot_provider.dart';
import '../../../../features/central/application/serial_link_provider.dart';
import '../../../../features/central/application/supervision_provider.dart';
import '../../../../features/iot/application/presence_provider.dart';
import 'panel_objects.dart';
import 'principal_panel.dart';

/// One communication channel shown in the gadget: a rounded (Apple-style)
/// icon tile with its label and current status underneath.
class CommTileData {
  const CommTileData({
    required this.icon,
    required this.label,
    required this.channel,
    required this.statusText,
    required this.color,
  });

  final IconData icon;
  final String label;

  /// Which object draws it on Principal (panel_objects.dart).
  final PanelObjectKind channel;
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
        channel: PanelObjectKind.wifi,
        statusText: 'Conectado',
        color: AppColors.success,
      ),
    'limited' => const CommTileData(
        icon: Icons.wifi_rounded,
        label: 'WI-FI',
        channel: PanelObjectKind.wifi,
        statusText: 'Limitado',
        color: AppColors.warning,
      ),
    'offline' => const CommTileData(
        icon: Icons.wifi_off_rounded,
        label: 'WI-FI',
        channel: PanelObjectKind.wifi,
        statusText: 'Sem rede',
        color: AppColors.error,
      ),
    _ => CommTileData(
        icon: Icons.wifi_rounded,
        label: 'WI-FI',
        channel: PanelObjectKind.wifi,
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
        channel: PanelObjectKind.usb,
        statusText: 'Conectado',
        color: AppColors.success,
      ),
    'connecting' => const CommTileData(
        icon: Icons.usb_rounded,
        label: 'USB',
        channel: PanelObjectKind.usb,
        statusText: 'Conectando…',
        color: AppColors.warning,
      ),
    'error' => const CommTileData(
        icon: Icons.usb_off_rounded,
        label: 'USB',
        channel: PanelObjectKind.usb,
        statusText: 'Erro',
        color: AppColors.error,
      ),
    'disconnected' => CommTileData(
        icon: Icons.usb_off_rounded,
        label: 'USB',
        channel: PanelObjectKind.usb,
        statusText: 'Desconectado',
        color: context.textSecondary.withValues(alpha: 0.6),
      ),
    _ => CommTileData(
        icon: Icons.usb_rounded,
        label: 'USB',
        channel: PanelObjectKind.usb,
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
        channel: PanelObjectKind.mesh,
        statusText: 'Conectado',
        color: AppColors.success,
      ),
    'connecting' => const CommTileData(
        icon: Icons.hub_rounded,
        label: 'REDE INTERNA',
        channel: PanelObjectKind.mesh,
        statusText: 'Conectando…',
        color: AppColors.warning,
      ),
    'disconnected' => CommTileData(
        icon: Icons.hub_rounded,
        label: 'REDE INTERNA',
        channel: PanelObjectKind.mesh,
        statusText: 'Desconectado',
        color: context.textSecondary.withValues(alpha: 0.6),
      ),
    _ => CommTileData(
        icon: Icons.hub_rounded,
        label: 'REDE INTERNA',
        channel: PanelObjectKind.mesh,
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
        channel: PanelObjectKind.cloud,
        statusText: 'Conectado',
        color: AppColors.success,
      ),
    'connecting' => const CommTileData(
        icon: Icons.cloud_rounded,
        label: 'NUVEM',
        channel: PanelObjectKind.cloud,
        statusText: 'Conectando…',
        color: AppColors.warning,
      ),
    'disconnected' => const CommTileData(
        icon: Icons.cloud_off_rounded,
        label: 'NUVEM',
        channel: PanelObjectKind.cloud,
        statusText: 'Desconectado',
        color: AppColors.error,
      ),
    _ => CommTileData(
        icon: Icons.cloud_rounded,
        label: 'NUVEM',
        channel: PanelObjectKind.cloud,
        statusText: 'Verificando…',
        color: context.textSecondary.withValues(alpha: 0.6),
      ),
  };
}

/// COMUNICAÇÃO gadget for the central's own dashboard (CENTRAL mode):
/// reads the device's local Wi-Fi, USB and MQTT state.
class CentralCommGadget extends ConsumerWidget {
  const CentralCommGadget({super.key, this.minHeight = 0});

  final double minHeight;

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

    return CommStatusGadget(minHeight: minHeight, tiles: [
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
  const UserCentralCommGadget(
      {super.key, required this.identityId, this.minHeight = 0});

  final String identityId;
  final double minHeight;

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

    return CommStatusGadget(minHeight: minHeight, tiles: [
      _wifiTile(context, wifi),
      _usbTile(context, usb),
      _meshTile(context, mesh),
      _cloudTile(context, cloud),
    ]);
  }
}

/// Dumb rendering of the gadget: Principal's "Comunicação" card, one
/// object per channel (the router, the board's cable, the units' network,
/// the cloud — panel_objects.dart) with its name and its state in words
/// underneath. The object's size follows the available width so it fits
/// phones, tablets and web without overflowing.
class CommStatusGadget extends StatelessWidget {
  const CommStatusGadget({super.key, required this.tiles, this.minHeight = 0});

  final List<CommTileData> tiles;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    return PanelCard(
      title: 'COMUNICAÇÃO',
      minHeight: minHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final slotWidth = constraints.maxWidth / tiles.length;
          final objectWidth = (slotWidth * 0.72).clamp(52.0, 104.0);

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final tile in tiles)
                Expanded(child: _CommTile(data: tile, width: objectWidth)),
            ],
          );
        },
      ),
    );
  }
}

class _CommTile extends StatelessWidget {
  const _CommTile({required this.data, required this.width});

  final CommTileData data;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '${data.label} — ${data.statusText}',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PanelObject(
            kind: data.channel,
            accent: data.color,
            ok: data.statusText == 'Conectado',
            width: width,
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                data.label,
                maxLines: 1,
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
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
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
