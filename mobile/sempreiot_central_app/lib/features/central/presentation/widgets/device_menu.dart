import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart' show safrBroadcastMac;
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/signal_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../application/central_mirror_viewer.dart';
import '../../application/device_command_provider.dart';
import '../../application/device_sound_provider.dart';
import '../../application/root_election_provider.dart';
import '../../application/topology_provider.dart';
import '../screens/device_settings_screen.dart';
import 'device_avatar.dart';
import '../../application/system_test_provider.dart';
import 'device_command_widgets.dart';
import 'system_test_sheets.dart';
import 'ota_rede_widgets.dart' show firmwareTagText;

/// Screen rect of the widget that owns [context] — the anchor the device
/// popover points at. Accounts for any pan/zoom transform above it.
Rect deviceAnchorOf(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// The popover a tap on a unit opens (Rede): the unit's 3D model
/// with its live LED, its state and role, the facts an installer glances at
/// (signal, last frame, parent, level, battery, firmware), the commands and
/// "Abrir dispositivo". It points at the unit and stays on screen in either
/// orientation (below, above or beside it, scrolling when short).
///
/// A command closes it: the answer is drawn on the map itself — the packet
/// going down, a check on the CENTRAL when the board takes it, two on the
/// unit when the unit confirms (device_command_provider.dart).
///
/// On a user's phone viewing a central (the mirror) there are the facts,
/// Dispositivo and Identificar — asked to the central, which sends it.
/// Nothing else is commanded from a phone.
Future<void> showDeviceMenu({
  required BuildContext context,
  required WidgetRef ref,
  required TopologyNode node,
  required Rect anchor,
}) async {
  final navigator = Navigator.of(context);
  final action = await showGeneralDialog<_DeviceAction>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Fechar',
    barrierColor: Colors.black.withValues(alpha: 0.18),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, __, ___) => _DevicePopoverRoute(
      mac: node.mac,
      initial: node,
      anchor: anchor,
    ),
    transitionBuilder: (_, animation, __, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
  );
  if (action == null) return;

  switch (action) {
    case _OpenDevice():
      navigator.push(MaterialPageRoute(
        builder: (_) => DeviceSettingsScreen(mac: node.mac),
      ));
    case _RunCommand(:final kind):
      // The map tells what happens; the popover is gone so it can be seen.
      ref.read(deviceCommandProvider.notifier).run(
            node.mac,
            kind,
            waitsForWake: node.sleeping,
          );
  }
}

sealed class _DeviceAction {
  const _DeviceAction();
}

class _OpenDevice extends _DeviceAction {
  const _OpenDevice();
}

class _RunCommand extends _DeviceAction {
  const _RunCommand(this.kind);
  final DeviceCommandKind kind;
}

// ── Placement ──────────────────────────────────────────────────────────────

enum _Side { below, above, right, left }

/// Where the card went, for the pointer drawn towards the unit.
class _Placement {
  const _Placement(this.card, this.side, this.target);
  final Rect card;
  final _Side side;
  final Offset target;
}

/// Puts the card below the unit when it fits, else above, else beside it
/// (landscape: little height, plenty of width), else where there is the
/// most room — always inside the safe area with a margin.
class _PopoverLayout extends SingleChildLayoutDelegate {
  _PopoverLayout({
    required this.anchor,
    required this.padding,
    required this.placement,
    this.width = defaultWidth,
  });

  final Rect anchor;
  final EdgeInsets padding;
  final ValueNotifier<_Placement?> placement;

  /// The card's width when the screen allows it.
  final double width;

  static const margin = 12.0;
  static const gap = 14.0;
  static const defaultWidth = 340.0;

  /// A short, wide screen (a phone on its side): two columns, facts beside
  /// the commands, so nothing waits below the fold.
  static const wideWidth = 620.0;
  static const shortHeight = 460.0;

  static bool isWide(Rect area) =>
      area.height < shortHeight && area.width >= wideWidth;

  Rect _area(Size size) => Rect.fromLTRB(
        padding.left + margin,
        padding.top + margin,
        size.width - padding.right - margin,
        size.height - padding.bottom - margin,
      );

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final area = _area(constraints.biggest);
    final room = [
      anchor.top - gap - area.top,
      area.bottom - anchor.bottom - gap,
      area.height,
    ].reduce(math.max);
    return BoxConstraints(
      maxWidth: isWide(area) ? wideWidth : math.min(width, area.width),
      minWidth: isWide(area) ? wideWidth : math.min(width, area.width),
      maxHeight: math.max(160.0, room),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size child) {
    final area = _area(size);
    final below = area.bottom - anchor.bottom - gap;
    final above = anchor.top - gap - area.top;
    final right = area.right - anchor.right - gap;
    final left = anchor.left - gap - area.left;

    bool fits(_Side s) => switch (s) {
          _Side.below => below >= child.height,
          _Side.above => above >= child.height,
          _Side.right => right >= child.width,
          _Side.left => left >= child.width,
        };
    // Once placed, the card keeps its side while it still fits: a fact that
    // changes under it must never make it jump to the other side.
    final kept = placement.value?.side;
    _Side side;
    if (kept != null && fits(kept)) {
      side = kept;
    } else if (below >= child.height) {
      side = _Side.below;
    } else if (above >= child.height) {
      side = _Side.above;
    } else if (math.max(right, left) >= child.width) {
      side = right >= left ? _Side.right : _Side.left;
    } else {
      side = below >= above ? _Side.below : _Side.above;
    }

    double clampX(double x) =>
        x.clamp(area.left, math.max(area.left, area.right - child.width));
    double clampY(double y) =>
        y.clamp(area.top, math.max(area.top, area.bottom - child.height));

    final Offset at;
    final Offset target;
    switch (side) {
      case _Side.below:
        at = Offset(clampX(anchor.center.dx - child.width / 2),
            clampY(anchor.bottom + gap));
        target = Offset(anchor.center.dx, anchor.bottom);
      case _Side.above:
        at = Offset(clampX(anchor.center.dx - child.width / 2),
            clampY(anchor.top - gap - child.height));
        target = Offset(anchor.center.dx, anchor.top);
      case _Side.right:
        at = Offset(
            anchor.right + gap, clampY(anchor.center.dy - child.height / 2));
        target = Offset(anchor.right, anchor.center.dy);
      case _Side.left:
        at = Offset(anchor.left - gap - child.width,
            clampY(anchor.center.dy - child.height / 2));
        target = Offset(anchor.left, anchor.center.dy);
    }
    placement.value = _Placement(at & child, side, target);
    return at;
  }

  @override
  bool shouldRelayout(_PopoverLayout old) =>
      old.anchor != anchor || old.padding != padding;
}

/// The little pointer from the card's edge towards the unit.
class _PointerPainter extends CustomPainter {
  _PointerPainter(this.placement, this.color, this.border)
      : super(repaint: placement);
  final ValueNotifier<_Placement?> placement;
  final Color color;
  final Color border;

  @override
  void paint(Canvas canvas, Size size) {
    final p = placement.value;
    if (p == null) return;
    const half = 9.0;
    const depth = 9.0;
    final r = p.card;
    final path = Path();
    switch (p.side) {
      case _Side.below:
        final x = p.target.dx.clamp(r.left + 24, r.right - 24);
        path
          ..moveTo(x - half, r.top + 1)
          ..lineTo(x, r.top - depth)
          ..lineTo(x + half, r.top + 1);
      case _Side.above:
        final x = p.target.dx.clamp(r.left + 24, r.right - 24);
        path
          ..moveTo(x - half, r.bottom - 1)
          ..lineTo(x, r.bottom + depth)
          ..lineTo(x + half, r.bottom - 1);
      case _Side.right:
        final y = p.target.dy.clamp(r.top + 24, r.bottom - 24);
        path
          ..moveTo(r.left + 1, y - half)
          ..lineTo(r.left - depth, y)
          ..lineTo(r.left + 1, y + half);
      case _Side.left:
        final y = p.target.dy.clamp(r.top + 24, r.bottom - 24);
        path
          ..moveTo(r.right - 1, y - half)
          ..lineTo(r.right + depth, y)
          ..lineTo(r.right - 1, y + half);
    }
    canvas
      ..drawPath(path, Paint()..color = color)
      ..drawPath(
        path,
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
  }

  @override
  bool shouldRepaint(_PointerPainter old) =>
      old.color != color || old.border != border;
}

class _DevicePopoverRoute extends StatefulWidget {
  const _DevicePopoverRoute({
    required this.mac,
    required this.initial,
    required this.anchor,
  });
  final String mac;
  final TopologyNode initial;
  final Rect anchor;

  @override
  State<_DevicePopoverRoute> createState() => _DevicePopoverRouteState();
}

class _DevicePopoverRouteState extends State<_DevicePopoverRoute>
    with SingleTickerProviderStateMixin {
  final _placement = ValueNotifier<_Placement?>(null);
  late final _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..forward();

  @override
  void dispose() {
    _placement.dispose();
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final card = context.surfaceColor;
    final border = AppColors.secondary.withValues(alpha: 0.35);
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _PointerPainter(_placement, card, border),
            ),
          ),
        ),
        CustomSingleChildLayout(
          delegate: _PopoverLayout(
            anchor: widget.anchor,
            padding: MediaQuery.paddingOf(context),
            placement: _placement,
          ),
          child: AnimatedBuilder(
            animation: _enter,
            builder: (_, child) {
              final t = Curves.easeOutCubic.transform(_enter.value);
              final side = _placement.value?.side ?? _Side.below;
              final slide = switch (side) {
                _Side.below => const Offset(0, -10),
                _Side.above => const Offset(0, 10),
                _Side.right => const Offset(-10, 0),
                _Side.left => const Offset(10, 0),
              };
              return Transform.translate(
                offset: slide * (1 - t),
                child: Transform.scale(
                  scale: 0.96 + 0.04 * t,
                  child: child,
                ),
              );
            },
            child: _DevicePopover(mac: widget.mac, initial: widget.initial),
          ),
        ),
      ],
    );
  }
}

// ── The card ───────────────────────────────────────────────────────────────

class _DevicePopover extends ConsumerWidget {
  const _DevicePopover({required this.mac, required this.initial});
  final String mac;
  final TopologyNode initial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Live: the facts move while the popover is open (a frame arrives, the
    // unit falls asleep, the root changes).
    final all = ref.watch(topologyProvider);
    final node = all.where((n) => n.mac == mac).firstOrNull ?? initial;
    final election = ref.watch(rootElectionProvider);
    final viewOnly = ref.watch(mirrorViewOnlyProvider);
    final command = ref.watch(deviceCommandProvider)[mac];
    final silenced =
        !viewOnly && ref.watch(deviceSoundProvider).contains(node.mac);
    final isRoot = node.online && node.mac == election.rootMac;
    final isCandidate =
        election.electing && election.candidates.contains(node.mac);

    return Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.secondary.withValues(alpha: 0.35),
          ),
          boxShadow: [
            BoxShadow(
              color:
                  Colors.black.withValues(alpha: context.isDark ? 0.5 : 0.16),
              blurRadius: 28,
              offset: const Offset(0, 12),
            ),
            BoxShadow(
              color: AppColors.secondary.withValues(alpha: 0.10),
              blurRadius: 24,
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(builder: (context, c) {
          final header = _Header(
            node: node,
            isRoot: isRoot,
            isCandidate: isCandidate,
          );
          final facts = _Facts(node: node, all: all);
          final commands = _Commands(
            node: node,
            viewOnly: viewOnly,
            silenced: silenced,
            command: command,
          );
          final open = _OpenButton(
            onTap: () => Navigator.of(context).pop(const _OpenDevice()),
          );
          // A phone on its side: the same blocks in two columns.
          // (The card's border takes a pixel each side: compare with room.)
          if (c.maxWidth >= _PopoverLayout.wideWidth - 40) {
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: facts),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              commands,
                              const SizedBox(height: 10),
                              open,
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                  child: facts,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
                  child: commands,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                  child: open,
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

/// State colour of a unit, as the map and the Dispositivos list use it.
Color _stateColor(BuildContext context, TopologyNode node) {
  if (!node.online || node.alarmLatched) return AppColors.error;
  if (node.updating) return AppColors.secondary;
  if (node.sleeping) return context.textSecondary;
  return AppColors.success;
}

class _Header extends StatelessWidget {
  const _Header({
    required this.node,
    required this.isRoot,
    required this.isCandidate,
  });
  final TopologyNode node;
  final bool isRoot;
  final bool isCandidate;

  @override
  Widget build(BuildContext context) {
    final hasName = node.name?.isNotEmpty == true;
    final state = _stateColor(context, node);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primary.withValues(alpha: context.isDark ? 0.55 : 0.10),
            state.withValues(alpha: context.isDark ? 0.10 : 0.06),
          ],
        ),
        border: Border(
          bottom: BorderSide(
            color: context.borderColor.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The model on a soft glow in the state's colour.
          Container(
            width: 68,
            height: 68,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  state.withValues(alpha: 0.28),
                  state.withValues(alpha: 0.0),
                ],
              ),
            ),
            child: DeviceModelAvatar(
              node: node,
              isRoot: isRoot,
              isCandidate: isCandidate,
              size: 56,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                Text(
                  deviceDisplayName(node),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: hasName ? 16 : 13,
                    height: 1.15,
                    fontWeight: FontWeight.w800,
                    fontFamily: hasName ? null : 'monospace',
                  ),
                ),
                const SizedBox(height: 3),
                if (node.productLabel.isNotEmpty)
                  Text(
                    // Non-breaking hyphens: the model code never splits.
                    node.productLabel.replaceAll('-', '\u2011'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (hasName)
                  Text(
                    node.mac,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.textSecondary.withValues(alpha: 0.8),
                      fontSize: 10,
                      fontFamily: 'monospace',
                      letterSpacing: -0.2,
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _Chip(
                      label: node.alarmLatched
                          ? 'Em alarme'
                          : deviceStateLabel(node),
                      color: state,
                      dot: true,
                    ),
                    if (isRoot)
                      const _Chip(label: 'ROOT', color: AppColors.success)
                    else if (isCandidate)
                      const _Chip(label: 'CANDIDATO', color: AppColors.warning),
                    if (node.layer > 0)
                      _Chip(
                        label: 'Nível ${node.layer}',
                        color: context.textSecondary,
                      ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Fechar',
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(Icons.close_rounded,
                size: 20, color: context.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color, this.dot = false});
  final String label;
  final Color color;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 4),
                ],
              ),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Facts ──────────────────────────────────────────────────────────────────

class _Facts extends StatelessWidget {
  const _Facts({required this.node, required this.all});
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
    final parent = _parentLabel();
    final wake = node.nextWakeInSeconds;
    final tiles = <Widget>[
      _SignalTile(rssi: node.rssi, sleeping: node.sleeping),
      _FactTile(
        icon: Icons.schedule_rounded,
        label: 'ÚLTIMO SINAL',
        value: relativeTime(node.lastSeenAt),
        sub: !node.isLeaf
            ? null
            : node.sleeping
                ? (wake == null
                    ? 'acorda a qualquer momento'
                    : 'acorda em $wake s')
                : 'acordado agora',
      ),
      if (parent != null)
        _FactTile(
          icon: Icons.account_tree_outlined,
          label: 'PAI',
          value: parent,
        ),
      if (node.isLeaf)
        _FactTile(
          icon: Icons.device_hub_rounded,
          label: 'PAIS AO ALCANCE',
          value: '${node.parentCandidates.length}',
          valueColor: node.singleParent ? AppColors.warning : null,
          sub: node.singleParent ? 'recomendado: 2 ou mais' : null,
        ),
      if (node.batteryPct != null)
        _FactTile(
          icon: Icons.battery_std_rounded,
          label: 'BATERIA',
          value: '${node.batteryPct}%',
          valueColor: node.batteryPct! < 20 ? AppColors.warning : null,
        ),
      _FactTile(
        icon: Icons.memory_rounded,
        label: 'FIRMWARE',
        value: node.firmwareLabel.isEmpty
            ? '—'
            : firmwareTagText(node.firmwareLabel),
        valueColor: node.firmwareLabel.isEmpty ? context.textSecondary : null,
      ),
    ];
    return LayoutBuilder(builder: (context, c) {
      const gap = 8.0;
      final w = (c.maxWidth - gap) / 2;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final t in tiles) SizedBox(width: w, child: t)],
      );
    });
  }
}

class _TileFrame extends StatelessWidget {
  const _TileFrame({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Fixed height: a line that appears (the next wake, a warning) must not
    // make the card grow under the operator's finger.
    return Container(
      height: 66,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      decoration: BoxDecoration(
        color: context.bgColor.withValues(alpha: context.isDark ? 0.55 : 0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderColor.withValues(alpha: 0.5)),
      ),
      child: child,
    );
  }
}

class _FactTile extends StatelessWidget {
  const _FactTile({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.sub,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    return _TileFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 12, color: context.textSecondary),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 8.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor ?? context.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (sub != null)
            Text(
              sub!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.textSecondary, fontSize: 9.5),
            ),
        ],
      ),
    );
  }
}

/// Signal: the dBm in the product's one colour scale and four bars.
class _SignalTile extends StatelessWidget {
  const _SignalTile({required this.rssi, required this.sleeping});
  final int? rssi;
  final bool sleeping;

  @override
  Widget build(BuildContext context) {
    final tier = signalTier(rssi);
    final color = sleeping ? context.textSecondary : signalColor(rssi);
    final bars = switch (tier) {
      SignalTier.good => 4,
      SignalTier.weak => 2,
      SignalTier.poor => 1,
      SignalTier.unknown => 0,
    };
    final word = switch (tier) {
      SignalTier.good => 'bom',
      SignalTier.weak => 'fraco',
      SignalTier.poor => 'ruim',
      SignalTier.unknown => 'sem leitura',
    };
    return _TileFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.network_cell_rounded,
                  size: 12, color: context.textSecondary),
              const SizedBox(width: 5),
              Text(
                'SINAL',
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 8.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Text(
                  rssi == null ? '—' : '$rssi dBm',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: rssi == null ? context.textSecondary : color,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              for (var i = 0; i < 4; i++)
                Container(
                  width: 3.5,
                  height: 4.0 + i * 3,
                  margin: const EdgeInsets.only(right: 2, bottom: 2),
                  decoration: BoxDecoration(
                    color: i < bars
                        ? color
                        : context.borderColor.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
            ],
          ),
          Text(
            sleeping ? '$word · no último despertar' : word,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: context.textSecondary, fontSize: 9.5),
          ),
        ],
      ),
    );
  }
}

// ── Commands ───────────────────────────────────────────────────────────────

class _Commands extends StatelessWidget {
  const _Commands({
    required this.node,
    required this.viewOnly,
    required this.silenced,
    required this.command,
  });
  final TopologyNode node;
  final bool viewOnly;
  final bool silenced;
  final DeviceCommandStatus? command;

  @override
  Widget build(BuildContext context) {
    final online = node.online;
    final busy = command?.inFlight == true;
    void run(DeviceCommandKind k) => Navigator.of(context).pop(_RunCommand(k));

    final buttons = <Widget>[
      if (!node.isLeaf)
        _CommandButton(
          icon: Icons.lightbulb_outline_rounded,
          label: 'Identificar',
          hint: 'LED azul piscando $identifyBlinkSeconds s',
          enabled: online && !busy,
          onTap: () => run(DeviceCommandKind.identify),
        ),
      if (!viewOnly && !node.isLeaf)
        _CommandButton(
          icon: Icons.fact_check_outlined,
          label: 'Testar',
          hint: 'gera um evento de teste',
          enabled: online && !busy,
          onTap: () => run(DeviceCommandKind.test),
        ),
      if (!viewOnly)
        _CommandButton(
          icon: silenced
              ? Icons.notifications_off_outlined
              : Icons.notifications_active_outlined,
          label: silenced ? 'Ligar som' : 'Silenciar',
          hint: silenced ? 'som silenciado agora' : 'som ligado agora',
          accent: silenced ? AppColors.warning : null,
          enabled: online && !busy,
          onTap: () => run(silenced
              ? DeviceCommandKind.soundOn
              : DeviceCommandKind.soundOff),
        ),
      // The confirmation is what clears the latch, so this stays available
      // even while the sensor itself is unreachable.
      if (!viewOnly && node.alarmLatched)
        _CommandButton(
          icon: Icons.restart_alt_rounded,
          label: 'Rearmar',
          hint: 'limpa o alarme retido',
          accent: AppColors.error,
          enabled: !busy,
          onTap: () => run(DeviceCommandKind.reset),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One fixed line: the status comes and goes without the card
        // changing height.
        SizedBox(
          height: 18,
          child: Row(
            children: [
              Text(
                'COMANDOS',
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              if (command != null) CommandTicks(status: command!, size: 15),
            ],
          ),
        ),
        const SizedBox(height: 6),
        if (!online && !node.alarmLatched)
          const _Notice(
            icon: Icons.link_off_rounded,
            text: 'Sem comunicação — os comandos voltam quando a unidade '
                'for ouvida de novo.',
          )
        else if (node.isLeaf && buttons.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: _Notice(
              icon: Icons.bedtime_outlined,
              text: 'Detector a bateria: o comando fica com o pai e é '
                  'entregue no próximo despertar.',
            ),
          ),
        if (online || node.alarmLatched)
          LayoutBuilder(builder: (context, c) {
            const gap = 8.0;
            final w = (c.maxWidth - gap) / 2;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final b in buttons) SizedBox(width: w, child: b),
              ],
            );
          }),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: context.borderColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: context.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CommandButton extends StatefulWidget {
  const _CommandButton({
    required this.icon,
    required this.label,
    required this.hint,
    required this.enabled,
    required this.onTap,
    this.accent,
  });
  final IconData icon;
  final String label;
  final String hint;
  final bool enabled;
  final VoidCallback onTap;
  final Color? accent;

  @override
  State<_CommandButton> createState() => _CommandButtonState();
}

class _CommandButtonState extends State<_CommandButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent ?? AppColors.secondary;
    final enabled = widget.enabled;
    final fg = enabled ? context.textPrimary : context.textSecondary;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            color: enabled
                ? accent.withValues(alpha: _hover ? 0.20 : 0.11)
                : context.borderColor.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: enabled
                  ? accent.withValues(alpha: _hover ? 0.75 : 0.40)
                  : context.borderColor.withValues(alpha: 0.4),
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: enabled ? widget.onTap : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 9, 8, 9),
                child: Row(
                  children: [
                    Icon(widget.icon,
                        size: 20,
                        color: enabled
                            ? accent
                            : context.textSecondary.withValues(alpha: 0.5)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: fg,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            widget.hint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.textSecondary,
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OpenButton extends StatelessWidget {
  const _OpenButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonal(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.tune_rounded, size: 18),
          SizedBox(width: 8),
          Flexible(
            child: Text(
              'Abrir dispositivo',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          SizedBox(width: 4),
          Icon(Icons.chevron_right_rounded, size: 18),
        ],
      ),
    );
  }
}

// ── The Central's popover ──────────────────────────────────────────────────

/// A tap on the CENTRAL chip (Rede): the board's basics and **Teste do
/// sistema** — one TEST to every unit at once. The map tells the rest: the
/// clock under each unit until its own ACK comes back (a sleeping
/// detector's on its next wake), ✓ beside the Central when the board takes
/// it, ✓✓ with the wave when the LAST unit confirmed. Disabled while a test
/// runs. On a phone viewing the central: the basics only.
/// What the Central's popover asks for when it closes.
enum CentralMenuAction { startTest, cancelTest, history }

Future<void> showCentralMenu({
  required BuildContext context,
  required WidgetRef ref,
  required TopologyNode? board,
  required Rect anchor,
}) async {
  final action = await showGeneralDialog<CentralMenuAction>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Fechar',
    barrierColor: Colors.black.withValues(alpha: 0.18),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, __, ___) => _CentralPopoverRoute(
      board: board,
      anchor: anchor,
    ),
    transitionBuilder: (_, animation, __, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
  );
  switch (action) {
    case CentralMenuAction.startTest:
      ref.read(systemTestControllerProvider.notifier).start();
    case CentralMenuAction.cancelTest:
      ref.read(systemTestControllerProvider.notifier).cancel();
    case CentralMenuAction.history:
      if (context.mounted) showSystemTestHistory(context);
    case null:
      break;
  }
}

class _CentralPopoverRoute extends StatefulWidget {
  const _CentralPopoverRoute({required this.board, required this.anchor});
  final TopologyNode? board;
  final Rect anchor;

  @override
  State<_CentralPopoverRoute> createState() => _CentralPopoverRouteState();
}

class _CentralPopoverRouteState extends State<_CentralPopoverRoute> {
  final _placement = ValueNotifier<_Placement?>(null);

  @override
  void dispose() {
    _placement.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final card = context.surfaceColor;
    final border = AppColors.secondary.withValues(alpha: 0.35);
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _PointerPainter(_placement, card, border),
            ),
          ),
        ),
        CustomSingleChildLayout(
          delegate: _PopoverLayout(
            anchor: widget.anchor,
            padding: MediaQuery.paddingOf(context),
            placement: _placement,
            // Three units per row in the test's grid.
            width: 420,
          ),
          child: _CentralPopover(board: widget.board),
        ),
      ],
    );
  }
}

class _CentralPopover extends ConsumerWidget {
  const _CentralPopover({required this.board});
  final TopologyNode? board;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewOnly = ref.watch(mirrorViewOnlyProvider);
    final units =
        ref.watch(topologyProvider).where((n) => n.layer > 0 && n.online);
    final sleepers = units.where((n) => n.isLeaf).length;
    final commands = ref.watch(deviceCommandProvider);
    final test = commands[safrBroadcastMac];
    final running = test?.broadcastRunning == true;
    final tally = test == null
        ? null
        : ref.read(deviceCommandProvider.notifier).broadcastTally;
    final linkUp = ref.watch(boardLinkUpProvider);
    final b = board;
    // Every unit, as on Dispositivos, with its outcome in the test.
    final grid = [
      for (final n in ref.watch(topologyProvider))
        if (n.layer > 0 && !n.awaitingSignal) n
    ]..sort((x, y) => deviceDisplayName(x).compareTo(deviceDisplayName(y)));

    return Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(20),
          border:
              Border.all(color: AppColors.secondary.withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(
              color:
                  Colors.black.withValues(alpha: context.isDark ? 0.5 : 0.16),
              blurRadius: 28,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppColors.primary
                          .withValues(alpha: context.isDark ? 0.55 : 0.10),
                      AppColors.secondary.withValues(alpha: 0.06),
                    ],
                  ),
                  border: Border(
                    bottom: BorderSide(
                        color: context.borderColor.withValues(alpha: 0.5)),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [AppColors.primary, Color(0xFF2E6DA4)],
                        ),
                        border: Border.all(
                            color: AppColors.secondary.withValues(alpha: 0.7),
                            width: 1.6),
                      ),
                      child: const Icon(Icons.tablet_mac_rounded,
                          color: Colors.white, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 2),
                          Text(
                            'Central',
                            style: TextStyle(
                              color: context.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            [
                              if (b != null) b.mac,
                              if (b?.fwVersion?.isNotEmpty == true)
                                firmwareTagText(b!.fwVersion!),
                            ].join('  ·  '),
                            style: TextStyle(
                              color: context.textSecondary,
                              fontSize: 10.5,
                              fontFamily: 'monospace',
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _Chip(
                                label: linkUp ? 'Placa ligada' : 'Sem placa',
                                color: linkUp
                                    ? AppColors.success
                                    : AppColors.error,
                                dot: true,
                              ),
                              _Chip(
                                label: '${units.length} '
                                    '${units.length == 1 ? 'dispositivo' : 'dispositivos'}',
                                color: context.textSecondary,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Fechar',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.close_rounded,
                          size: 20, color: context.textSecondary),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 22,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'TESTE DO SISTEMA',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: context.textSecondary,
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.0,
                              ),
                            ),
                          ),
                          if (test != null) ...[
                            CommandTicks(status: test, size: 15),
                            const SizedBox(width: 6),
                          ],
                          // The last tests and their reports — on the
                          // tablet and on a phone alike (the mirror's).
                          TextButton.icon(
                            key: const ValueKey('central-test-history'),
                            onPressed: () => Navigator.of(context)
                                .pop(CentralMenuAction.history),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 0),
                              minimumSize: const Size(0, 22),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(Icons.history_rounded, size: 15),
                            label: const Text(
                              'Últimos testes',
                              style: TextStyle(
                                  fontSize: 10.5, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      test != null
                          ? (tally?.text ?? 'Em andamento…')
                          : viewOnly
                              ? 'Nenhum teste em andamento. O teste é '
                                  'iniciado na central; o resultado aparece '
                                  'aqui e em Últimos testes.'
                              : 'Envia TESTAR a todos os ${units.length} '
                                  'dispositivos de uma vez. Cada um confirma '
                                  'por conta própria; os detectores a bateria '
                                  '($sleepers) no próximo despertar, em até '
                                  '1 min. Sirenes e botoeiras geram um evento '
                                  'de teste.',
                      style: TextStyle(
                        color: context.textSecondary,
                        fontSize: 11,
                        height: 1.3,
                      ),
                    ),
                    if (!viewOnly) ...[
                      const SizedBox(height: 10),
                      // While a test runs the same button cancels it: the
                      // units still waiting read "cancelado" and the
                      // report says so.
                      if (running)
                        OutlinedButton.icon(
                          key: const ValueKey('central-test-cancel'),
                          onPressed: () => Navigator.of(context)
                              .pop(CentralMenuAction.cancelTest),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(44),
                            foregroundColor: AppColors.error,
                            side: BorderSide(
                                color: AppColors.error.withValues(alpha: 0.7)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          icon:
                              const Icon(Icons.stop_circle_outlined, size: 18),
                          label: const Text(
                            'Cancelar teste',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        )
                      else
                        FilledButton.icon(
                          key: const ValueKey('central-test-all'),
                          onPressed: !linkUp
                              ? null
                              : () => Navigator.of(context)
                                  .pop(CentralMenuAction.startTest),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(44),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          icon: const Icon(Icons.fact_check_outlined, size: 18),
                          label: const Text(
                            'Testar tudo',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              if (grid.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'DISPOSITIVOS',
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 8),
                      LayoutBuilder(builder: (context, c) {
                        const gap = 8.0;
                        final perRow = c.maxWidth >= 300 ? 3 : 2;
                        final w = (c.maxWidth - gap * (perRow - 1)) / perRow;
                        return Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (final n in grid)
                              SizedBox(
                                width: w,
                                child: _TestUnitTile(
                                  node: n,
                                  status: test == null ||
                                          commands[n.mac]?.kind != test.kind
                                      ? null
                                      : commands[n.mac],
                                ),
                              ),
                          ],
                        );
                      }),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One unit in the Central's grid: its model, its name and — during a
/// system test — its outcome: the clock (Pendente / Próximo despertar),
/// cyan ✓✓ Confirmado, red Sem comunicação / Sem resposta. Outside a test,
/// its state.
class _TestUnitTile extends StatelessWidget {
  const _TestUnitTile({required this.node, required this.status});
  final TopologyNode node;
  final DeviceCommandStatus? status;

  @override
  Widget build(BuildContext context) {
    final s = status;
    final color = s == null
        ? _stateColor(context, node)
        : commandStepColor(s.step) == AppColors.ledBlue
            ? context.textSecondary
            : commandStepColor(s.step);
    return Container(
      key: ValueKey('test-tile-${node.mac}'),
      padding: const EdgeInsets.fromLTRB(6, 10, 6, 8),
      decoration: BoxDecoration(
        color: context.bgColor.withValues(alpha: context.isDark ? 0.55 : 0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: s == null
              ? context.borderColor.withValues(alpha: 0.5)
              : color.withValues(alpha: 0.55),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DeviceModelAvatar(node: node, size: 44),
          const SizedBox(height: 8),
          Text(
            deviceDisplayName(node),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (s != null) ...[
                CommandTicks(status: s, size: 13),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  s == null
                      ? (node.alarmLatched
                          ? 'Em alarme'
                          : deviceStateLabel(node))
                      : commandOutcomeLabel(s),
                  key: s == null ? null : ValueKey('test-outcome-${node.mac}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
