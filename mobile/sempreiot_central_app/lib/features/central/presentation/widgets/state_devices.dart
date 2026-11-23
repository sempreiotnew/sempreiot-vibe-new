import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/alarm_latch_provider.dart';
import '../../application/central_mirror_codec.dart';
import '../../application/central_mirror_viewer.dart';
import '../../application/panel_provider.dart';
import 'device_state_tile.dart';
import 'latched_alarm_banner.dart';
import 'remote_alarm_banner.dart';

// The devices of Principal's "Estado do sistema" (2026-11-23): the units in
// alarm first, then the units that need attention — each one drawn as Rede
// draws it (device_state_tile.dart).
//
// In the block they are ONE ROW that scrolls sideways ([StateDevicesRow]),
// so the block keeps its height whatever the number of units, with Rearmar
// tudo standing at the end of the row (the tablet, in alarm). The block's
// expand button opens [StateDevicesScreen]: the same units on the whole
// screen, growing out of the block, with a way back.

/// The units to show, in order: in alarm, then needing attention.
class _StateDevices {
  const _StateDevices(
      {required this.alarms, required this.troubles, required this.more});

  final List<Widget> alarms;
  final List<Widget> troubles;

  /// Units that need attention and are not listed (a phone gets the first
  /// ten by name).
  final int more;

  bool get isEmpty => alarms.isEmpty && troubles.isEmpty;
}

_StateDevices _devicesOf(WidgetRef ref, String? centralId) {
  final view = ref.watch(panelViewProvider(centralId));
  final alarms = centralId == null
      ? [
          for (final d
              in ref.watch(latchedAlarmsProvider).valueOrNull ?? const [])
            LatchedDeviceTile(key: ValueKey('alarm-${d.mac}'), device: d),
        ]
      : [
          for (final a in ref.watch(centralAlarmsProvider(centralId))?.alarms ??
              const <MirrorAlarm>[])
            RemoteAlarmTile(key: ValueKey('alarm-${a.mac}'), alarm: a),
        ];
  return _StateDevices(
    alarms: alarms,
    troubles: [for (final t in view.troubleList) TroubleDeviceTile(trouble: t)],
    more: (view.troubles - view.troubleList.length).clamp(0, view.troubles),
  );
}

/// True when Estado do sistema has a unit to show.
bool hasStateDevices(WidgetRef ref, String? centralId) {
  final view = ref.watch(panelViewProvider(centralId));
  return view.alarms > 0 || view.troubleList.isNotEmpty;
}

/// A unit that needs attention: as Rede draws it, and why. A central on an
/// older app says a name only: an icon and the name.
class TroubleDeviceTile extends StatelessWidget {
  const TroubleDeviceTile({super.key, required this.trouble});

  final MirrorTrouble trouble;

  @override
  Widget build(BuildContext context) {
    final mac = trouble.mac;
    final battery = trouble.why == MirrorTrouble.battery;
    final why = Text(
      battery ? 'bateria baixa' : 'sem comunicação',
      maxLines: 1,
      style: const TextStyle(
        color: AppColors.warning,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    );
    if (mac == null) {
      return Container(
        width: DeviceStateTile.width,
        padding: const EdgeInsets.fromLTRB(8, 14, 8, 8),
        decoration: BoxDecoration(
          color: context.bgColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.45)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: DeviceStateTile.avatar,
              child: Icon(
                battery
                    ? Icons.battery_alert_rounded
                    : Icons.sensors_off_rounded,
                color: AppColors.warning,
                size: 30,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              trouble.name,
              maxLines: 1,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            FittedBox(fit: BoxFit.scaleDown, child: why),
          ],
        ),
      );
    }
    return DeviceStateTile(
      mac: mac,
      described: DeviceStateTile.describe(
        mac: mac,
        name: trouble.name,
        address: trouble.address,
        productCode: trouble.productCode,
        leaf: trouble.leaf,
        batteryPct: trouble.batteryPct,
        // Listed for its battery: it answers. Otherwise it is not heard.
        online: battery,
      ),
      accent: AppColors.warning,
      status: why,
    );
  }
}

class _MoreTile extends StatelessWidget {
  const _MoreTile(this.more);
  final int more;

  @override
  Widget build(BuildContext context) => Container(
        width: 64,
        constraints: const BoxConstraints(minHeight: 96),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: context.bgColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
        ),
        child: Text(
          '+ $more',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
}

/// The units as one row that scrolls sideways — the block's height does not
/// grow with their number. On the tablet, in alarm, **Rearmar tudo** stands
/// at the end of the row, as tall as the tiles: no line of its own.
class StateDevicesRow extends ConsumerWidget {
  const StateDevicesRow({super.key, this.centralId});

  /// Null on the tablet; the viewed central on a user's phone.
  final String? centralId;

  static const keyList = ValueKey('state-devices-row');

  /// A tile without / with its Rearmar, at the default text size.
  static const _plain = 150.0;
  static const _withAction = 200.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = _devicesOf(ref, centralId);
    if (devices.isEmpty) return const SizedBox.shrink();
    final rearm = centralId == null && devices.alarms.isNotEmpty;
    // A larger system font makes the tiles taller, never clipped.
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);
    final height = (rearm ? _withAction : _plain) * scale;
    final tiles = [
      ...devices.alarms,
      ...devices.troubles,
      if (devices.more > 0) _MoreTile(devices.more),
    ];

    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView.separated(
              key: keyList,
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.hardEdge,
              itemCount: tiles.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              // Top-aligned: a tile with no Rearmar is shorter than the row.
              itemBuilder: (_, i) =>
                  Align(alignment: Alignment.topCenter, child: tiles[i]),
            ),
          ),
          if (rearm) ...[
            const SizedBox(width: 8),
            const SizedBox(width: 96, child: RearmAllButton(tall: true)),
          ],
        ],
      ),
    );
  }
}

/// The same units with room to be seen: every one of them, wrapping onto
/// as many lines as they need — what the block shows once it is expanded
/// over the whole screen. Rearmar tudo is the last tile (the tablet, in
/// alarm), where it stands in the row.
class StateDevicesGrid extends ConsumerWidget {
  const StateDevicesGrid({super.key, this.centralId});

  final String? centralId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = _devicesOf(ref, centralId);
    if (devices.isEmpty) return const SizedBox.shrink();
    final rearm = centralId == null && devices.alarms.isNotEmpty;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ...devices.alarms,
        ...devices.troubles,
        if (devices.more > 0) _MoreTile(devices.more),
        if (rearm)
          SizedBox(
            width: 96,
            height: StateDevicesRow._withAction * scale,
            child: const RearmAllButton(tall: true),
          ),
      ],
    );
  }
}

/// Expands the status block over the whole screen: [expanded] — the same
/// block, built to fill the screen — grows out of the widget of [origin]
/// (the block where it stands) until it covers everything, and shrinks back
/// into it on the way out. It is the block itself that is resized on every
/// frame, so what is seen while it grows is always the block.
Future<void> openStateDevices(
  BuildContext origin, {
  required WidgetBuilder expanded,
}) {
  final box = origin.findRenderObject();
  final from = box is RenderBox && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : null;
  final background = origin.bgColor;
  return Navigator.of(origin).push(PageRouteBuilder<void>(
    opaque: false,
    transitionDuration: const Duration(milliseconds: 420),
    reverseTransitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (context, _, __) =>
        Material(type: MaterialType.transparency, child: expanded(context)),
    transitionsBuilder: (context, animation, _, child) {
      final t = CurvedAnimation(
        parent: animation,
        curve: Curves.easeInOutCubicEmphasized,
        reverseCurve: Curves.easeInCubic,
      );
      return LayoutBuilder(builder: (context, c) {
        // Where the block ends: the whole screen, inside the safe area,
        // with the page's own margin.
        final safe = MediaQuery.paddingOf(context);
        final full = Rect.fromLTRB(
          safe.left + stateDevicesMargin,
          safe.top + stateDevicesMargin,
          c.maxWidth - safe.right - stateDevicesMargin,
          c.maxHeight - safe.bottom - stateDevicesMargin,
        );
        final rect = RectTween(begin: from ?? full, end: full);
        return AnimatedBuilder(
          animation: t,
          child: child,
          builder: (context, child) => Stack(
            children: [
              // The screen behind fades into the app's own background.
              Positioned.fill(
                child: ColoredBox(
                  color: background.withValues(alpha: t.value.clamp(0.0, 1.0)),
                ),
              ),
              Positioned.fromRect(rect: rect.evaluate(t)!, child: child!),
            ],
          ),
        );
      });
    },
  ));
}

/// The margin around the expanded block.
const stateDevicesMargin = 12.0;
