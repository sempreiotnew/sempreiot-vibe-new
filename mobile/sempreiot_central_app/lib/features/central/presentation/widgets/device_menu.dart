import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/signal_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../application/device_led_provider.dart';
import '../../application/device_sound_provider.dart';
import '../../application/safr_downlink_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_v2_payloads.dart';
import '../screens/device_settings_screen.dart';
import 'device_avatar.dart';

enum _DeviceAction { settings, identify, sound, test, reset }

/// Screen rect of the widget that owns [context] — the anchor the device
/// menu drops from. Accounts for any pan/zoom transform above it.
Rect deviceAnchorOf(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// The dropdown a tap on a device opens (Rede map, Dispositivos): a short
/// header with the live basics (last seen, signal, parent), the device's
/// settings screen, a sound on/off switch and — not on a leaf — Identificar
/// and Testar. RESET joins them only while the device holds a latched alarm.
Future<void> showDeviceMenu({
  required BuildContext context,
  required WidgetRef ref,
  required TopologyNode node,
  required Rect anchor,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final navigator = Navigator.of(context);
  final commandsOn = node.online;
  final silenced = ref.read(deviceSoundProvider).contains(node.mac);

  // Drops from just below the device; the route keeps it on screen in
  // either orientation.
  final below = Rect.fromLTWH(anchor.left, anchor.bottom, anchor.width, 0);
  final action = await showMenu<_DeviceAction>(
    context: context,
    position: RelativeRect.fromRect(below, Offset.zero & overlay.size),
    color: context.surfaceColor,
    constraints: const BoxConstraints(minWidth: 240, maxWidth: 300),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(
        color: context.borderColor.withValues(alpha: 0.6),
        width: 0.5,
      ),
    ),
    items: [
      _HeaderEntry(
        node: node,
        all: ref.read(topologyProvider),
      ),
      const PopupMenuDivider(height: 1),
      _item(context, _DeviceAction.settings, 'Dispositivo', Icons.tune_rounded,
          enabled: true),
      if (!node.isLeaf)
        _item(context, _DeviceAction.identify, 'Identificar',
            Icons.lightbulb_outline_rounded,
            enabled: commandsOn),
      _soundItem(context, silenced: silenced, enabled: commandsOn),
      if (!node.isLeaf)
        _item(context, _DeviceAction.test, 'Testar', Icons.quiz_outlined,
            enabled: commandsOn),
      // The root's ACK is what clears the latch, so this stays available
      // even while the sensor itself is unreachable.
      if (node.alarmLatched)
        _item(
            context, _DeviceAction.reset, 'Rearmar', Icons.restart_alt_rounded,
            enabled: true, color: AppColors.error),
    ],
  );
  if (action == null) return;

  if (action == _DeviceAction.settings) {
    navigator.push(MaterialPageRoute(
      builder: (_) => DeviceSettingsScreen(mac: node.mac),
    ));
    return;
  }

  final (cmd, label, args) = switch (action) {
    _DeviceAction.identify => (SafrCommand.identify, 'Identificar', const [10]),
    _DeviceAction.sound => silenced
        ? (SafrCommand.relaySet, 'Som ligado', const [1])
        : (SafrCommand.silence, 'Som silenciado', const <int>[]),
    _DeviceAction.test => (SafrCommand.test, 'Testar', const <int>[]),
    _ => (SafrCommand.reset, 'Rearmar', const <int>[]),
  };
  final name = deviceDisplayName(node);
  messenger?.showSnackBar(SnackBar(
    content: Text(node.sleeping
        ? '$label → $name: entregue no próximo despertar…'
        : '$label → $name: enviando…'),
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 2),
  ));
  final downlink = ref.read(safrDownlinkProvider);
  // RESET goes through sendReset so the latch clears only on the root's ACK;
  // the sound switch goes through its provider, which keeps the on/off state.
  final ok = action == _DeviceAction.sound
      ? await ref
          .read(deviceSoundProvider.notifier)
          .setSound(node.mac, on: silenced)
      : cmd == SafrCommand.reset
          ? await downlink.sendReset(node.mac)
          : await downlink.sendCommand(node.mac, cmd, args: args);
  // The unit starts its blue IDENTIFY blink on receipt; mirror it.
  if (ok && action == _DeviceAction.identify) {
    ref.read(deviceLedProvider).identify(node.mac, args.first);
  }
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(ok
          ? '$label → $name: confirmado pelo root (ACK ✓✓)'
          : '$label → $name: sem confirmação do root, tente novamente'),
      backgroundColor: ok ? AppColors.success : AppColors.trouble,
      behavior: SnackBarBehavior.floating,
    ));
}

/// One row for sound on/off: the switch shows the state, a tap anywhere on
/// the row flips it.
PopupMenuItem<_DeviceAction> _soundItem(
  BuildContext context, {
  required bool silenced,
  required bool enabled,
}) {
  final c = enabled
      ? context.textPrimary
      : context.textSecondary.withValues(alpha: 0.45);
  return PopupMenuItem<_DeviceAction>(
    value: _DeviceAction.sound,
    enabled: enabled,
    height: 44,
    padding: const EdgeInsets.only(left: 12, right: 4),
    child: Row(
      children: [
        Icon(
          silenced
              ? Icons.notifications_off_outlined
              : Icons.notifications_active_outlined,
          size: 19,
          color: !enabled
              ? c
              : silenced
                  ? AppColors.warning
                  : AppColors.secondary,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              const TextSpan(text: 'Som'),
              TextSpan(
                text: silenced ? '  silenciado' : '  ligado',
                style: TextStyle(
                  color: silenced && enabled
                      ? AppColors.warning
                      : context.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ]),
            style:
                TextStyle(color: c, fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        IgnorePointer(
          child: Switch(
            value: !silenced,
            onChanged: enabled ? (_) {} : null,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    ),
  );
}

PopupMenuItem<_DeviceAction> _item(
  BuildContext context,
  _DeviceAction value,
  String label,
  IconData icon, {
  required bool enabled,
  Color? color,
}) {
  final c = !enabled
      ? context.textSecondary.withValues(alpha: 0.45)
      : color ?? context.textPrimary;
  return PopupMenuItem<_DeviceAction>(
    value: value,
    enabled: enabled,
    height: 44,
    child: Row(
      children: [
        Icon(icon,
            size: 19,
            color: enabled && color == null ? AppColors.secondary : c),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style:
                TextStyle(color: c, fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        if (value == _DeviceAction.settings)
          Icon(Icons.chevron_right_rounded,
              size: 18, color: context.textSecondary),
      ],
    ),
  );
}

/// The menu's non-selectable top: not a disabled PopupMenuItem, which would
/// dim the close button and swallow its semantics.
class _HeaderEntry extends PopupMenuEntry<_DeviceAction> {
  const _HeaderEntry({
    required this.node,
    required this.all,
  });

  final TopologyNode node;
  final List<TopologyNode> all;

  @override
  double get height => 120;

  @override
  bool represents(_DeviceAction? value) => false;

  @override
  State<_HeaderEntry> createState() => _HeaderEntryState();
}

class _HeaderEntryState extends State<_HeaderEntry> {
  @override
  Widget build(BuildContext context) => _MenuHeader(
        node: widget.node,
        all: widget.all,
      );
}

/// Name, state and the basics an operator glances at on the map.
class _MenuHeader extends StatelessWidget {
  const _MenuHeader({
    required this.node,
    required this.all,
  });

  final TopologyNode node;
  final List<TopologyNode> all;

  String? _parentLabel() {
    final mac = node.parentMac;
    if (mac == null) return null;
    for (final n in all) {
      if (n.mac == mac) {
        return n.layer == 0 ? 'Central' : deviceDisplayName(n);
      }
    }
    return mac;
  }

  @override
  Widget build(BuildContext context) {
    final hasName = node.name?.isNotEmpty == true;
    final stateColor = !node.online
        ? AppColors.error
        : node.alarmLatched
            ? AppColors.error
            : node.updating
                ? AppColors.secondary
                : node.sleeping
                    ? context.textSecondary
                    : AppColors.success;
    final parent = _parentLabel();

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      deviceDisplayName(node),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        fontFamily: hasName ? null : 'monospace',
                      ),
                    ),
                    if (hasName)
                      Text(
                        node.mac,
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 10.5,
                          fontFamily: 'monospace',
                        ),
                      ),
                  ],
                ),
              ),
              // Tapping outside also closes the menu, but not everyone
              // knows that: an explicit way out.
              Transform.translate(
                offset: const Offset(8, -6),
                child: IconButton(
                  tooltip: 'Fechar',
                  onPressed: () => Navigator.of(context).pop(),
                  style: IconButton.styleFrom(
                    backgroundColor:
                        context.borderColor.withValues(alpha: 0.35),
                  ),
                  icon: Icon(Icons.close_rounded,
                      size: 18, color: context.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration:
                    BoxDecoration(color: stateColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  node.alarmLatched ? 'Em alarme' : deviceStateLabel(node),
                  style: TextStyle(
                    color: stateColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _fact(context, Icons.schedule_rounded, 'Visto',
              relativeTime(node.lastSeenAt)),
          if (node.rssi != null)
            _fact(context, Icons.network_cell_rounded, 'Sinal',
                '${node.rssi} dBm',
                valueColor: node.sleeping
                    ? context.textSecondary
                    : signalColor(node.rssi)),
          if (parent != null)
            _fact(context, Icons.account_tree_outlined, 'Pai', parent),
          if (node.isLeaf)
            _fact(
              context,
              Icons.device_hub_rounded,
              'Pais ao alcance',
              '${node.parentCandidates.length}',
              valueColor: node.singleParent ? AppColors.warning : null,
            ),
          if (node.batteryPct != null)
            _fact(context, Icons.battery_std_rounded, 'Bateria',
                '${node.batteryPct}%'),
          // v3.5 product identity; "—" until the unit (or the board's table)
          // reports it.
          _fact(context, Icons.inventory_2_outlined, 'Produto',
              node.productLabel.isEmpty ? '—' : node.productLabel,
              valueColor:
                  node.productLabel.isEmpty ? context.textSecondary : null,
              maxLines: 2),
          _fact(context, Icons.system_update_alt_rounded, 'Firmware',
              node.firmwareLabel.isEmpty ? '—' : node.firmwareLabel,
              valueColor:
                  node.firmwareLabel.isEmpty ? context.textSecondary : null),
        ],
      ),
    );
  }

  Widget _fact(BuildContext context, IconData icon, String label, String value,
      {Color? valueColor, int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(icon, size: 13, color: context.textSecondary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(color: context.textSecondary, fontSize: 11.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: valueColor ?? context.textPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
