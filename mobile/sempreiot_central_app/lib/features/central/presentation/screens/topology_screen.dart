import 'dart:ui' show Tangent;
import 'dart:async';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/signal_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../application/safr_downlink_provider.dart';
import '../../application/safr_traffic_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_v2_payloads.dart';
import '../widgets/editor_gate.dart';
import '../../application/credentials_admin_provider.dart';
import '../../application/root_election_provider.dart';

/// Rede — live map of the fire-alarm mesh. Central on top, root marked,
/// curved glowing links, and dots with trails traveling along the real path
/// of every frame: visible proof that messages cross the system.
class TopologyScreen extends ConsumerStatefulWidget {
  const TopologyScreen({super.key, this.embedded = false});

  /// True when hosted inside the Rede tab (no own Scaffold/AppBar).
  final bool embedded;

  @override
  ConsumerState<TopologyScreen> createState() => _TopologyScreenState();
}

/// Pseudo-MAC of the central in the graph (top of the tree).
const _centralKey = '@central';

/// The map's zoom factor. The map is only ever translated and uniformly
/// scaled, so the x-axis entry IS the scale. Never read the "max scale on
/// axis" helper here: it also looks at the z axis, which reads 1.0 whenever
/// the map is zoomed OUT below 1:1 — the landscape opening view — and every
/// zoom, pan clamp and label position then computed with the wrong scale.
double _scaleOf(Matrix4 m) => m.storage[0];

/// Opacity of a device (and its link) that has been silent for longer than
/// [topologyStaleAfter]: still on the map, visibly faded.
const _staleOpacity = 0.32;

class _TopologyScreenState extends ConsumerState<TopologyScreen>
    with SingleTickerProviderStateMixin {
  /// Floor for pinch/button zoom-out; the fit scale may go below it when
  /// the tree is taller than the viewport (landscape), so the effective
  /// minimum is min(_minZoom, fit).
  static const _minZoom = 0.5;
  static const _maxZoom = 4.0;

  late final AnimationController _ticker;
  final _dots = <_TrafficDot>[];
  final _transform = TransformationController();
  Size _viewSize = Size.zero;
  Size _canvasSize = Size.zero;

  /// (viewport, canvas) the current transform was fitted for; a change in
  /// either (rotation, a new layer) re-fits so the tree never ends up
  /// off-screen or cropped.
  (Size, Size)? _fittedFor;
  StreamSubscription<SafrTrafficTick>? _trafficSub;

  /// A change of the tree's shape (a node joined, left or moved layer)
  /// re-fits only once the shape has held still for this long, so a
  /// failover does not make the map jump on every intermediate state.
  /// A viewport change (rotation) still re-fits at once.
  static const _refitSettle = Duration(milliseconds: 1500);
  Timer? _refitTimer;

  @override
  void initState() {
    super.initState();
    // Continuous vsync clock: the painter derives dot positions and pulse
    // phases from wall time, so one controller animates everything.
    _ticker =
        AnimationController(vsync: this, duration: const Duration(days: 1))
          ..repeat();
    _trafficSub = ref.read(safrTrafficProvider).stream.listen(_onTraffic);
  }

  @override
  void dispose() {
    _refitTimer?.cancel();
    _trafficSub?.cancel();
    _transform.dispose();
    _ticker.dispose();
    super.dispose();
  }

  /// Button zoom: pivots on the tree's centre line and the screen's middle.
  void _zoomBy(double factor) => _applyZoom(factor);

  /// Scales the map by [factor], clamped to the zoom limits, about a pivot
  /// in SCREEN space: x = the tree's own centre line (so the tree never
  /// moves sideways on its own — the old code pivoted on a canvas point and
  /// drifted), y = [pivotY] (the fingers' row for a pinch) or the middle
  /// of the screen (buttons).
  void _applyZoom(double factor, {double? pivotY}) {
    final current = _scaleOf(_transform.value);
    final target =
        (current * factor).clamp(math.min(_minZoom, _fitScale), _maxZoom);
    final applied = target / current;
    if (applied == 1.0) return;
    final treeCentreX =
        _transform.value.getTranslation().x + _canvasSize.width / 2 * current;
    final c = Offset(treeCentreX, pivotY ?? _viewSize.height / 2);
    final about = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(applied, applied, applied, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
    _transform.value = _clamped(about * _transform.value);
  }

  /// Moves the map by [delta] screen pixels.
  void _applyPan(Offset delta) {
    if (delta == Offset.zero) return;
    _transform.value = _clamped(
        Matrix4.translationValues(delta.dx, delta.dy, 0) * _transform.value);
  }

  /// Keeps at least part of the canvas on screen: the map can be dragged
  /// around freely but never completely lost (margin in screen pixels).
  Matrix4 _clamped(Matrix4 m) {
    const margin = 320.0;
    final s = _scaleOf(m);
    final t = m.getTranslation();
    final slackX = _viewSize.width - _canvasSize.width * s;
    final slackY = _viewSize.height - _canvasSize.height * s;
    final tx = t.x
        .clamp(math.min(slackX, 0.0) - margin, math.max(slackX, 0.0) + margin);
    final ty = t.y
        .clamp(math.min(slackY, 0.0) - margin, math.max(slackY, 0.0) + margin);
    if (tx == t.x && ty == t.y) return m;
    return m.clone()..setTranslationRaw(tx, ty, 0);
  }

  // Pinch / drag. Flutter reports both through one scale gesture: `scale`
  // is cumulative since the gesture started and the focal point is the
  // fingers' centre (or the single finger).
  double _gestureScale = 1.0;
  Offset _gestureFocal = Offset.zero;

  void _onScaleStart(ScaleStartDetails d) {
    _gestureScale = 1.0;
    _gestureFocal = d.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.scale != _gestureScale && _gestureScale != 0) {
      _applyZoom(d.scale / _gestureScale, pivotY: d.localFocalPoint.dy);
      _gestureScale = d.scale;
    }
    _applyPan(d.localFocalPoint - _gestureFocal);
    _gestureFocal = d.localFocalPoint;
  }

  /// Below this the chips stop being readable, so the opening view never
  /// goes smaller — a very tall tree is panned instead.
  static const _fitFloor = 0.7;

  /// Opening/"fit" scale: the whole canvas in the viewport when that stays
  /// readable, else [_fitFloor]; never above 1:1.
  double get _fitScale {
    if (_viewSize.isEmpty || _canvasSize.isEmpty) return 1.0;
    final fit = math.min(_viewSize.width / _canvasSize.width,
        _viewSize.height / _canvasSize.height);
    return fit.clamp(_fitFloor, 1.0);
  }

  /// "Ajustar à tela": the tree centred in the viewport (in landscape it
  /// opens zoomed out rather than cropped). When it is still bigger than the
  /// screen at the readable floor it stays centred across (the central on
  /// the centre line, the outer siblings reached by panning) and starts at
  /// the top.
  void _fitToView() {
    final s = _fitScale;
    final tx = (_viewSize.width - _canvasSize.width * s) / 2;
    final ty = math.max(0.0, (_viewSize.height - _canvasSize.height * s) / 2);
    _transform.value = Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(s, s, s, 1);
  }

  void _onTraffic(SafrTrafficTick tick) {
    final nodes = {
      for (final n in ref.read(topologyProvider))
        if (n.layer > 0) n.mac: n
    };
    final origin = nodes[tick.mac];
    if (origin == null) return;
    // Only animate real events (alert/alarm/trouble) from AC nodes. Their
    // routine traffic — heartbeats every 15 s, topology, ACKs — used to spawn
    // a dot every time (the constant blue balls); those are dropped so the
    // walk-test dot stands out. A battery leaf is the exception: it wakes
    // once a minute and its every frame is the news that it is alive, so its
    // heartbeat travels the tree as a calm accent-coloured packet
    // (protocol §12.2; reference row 6.8).
    final leafRoutine = tick.severity < 1 && origin.isLeaf &&
        tick.direction == SafrTrafficDirection.uplink;
    // The tablet's ACK going back down is the cyan the unit's LED shows when
    // it arrives: worth a packet for any unit (walk test: blue up, cyan down).
    final ackDown = tick.ack && tick.direction == SafrTrafficDirection.downlink;
    if (tick.severity < 1 && !leafRoutine && !ackDown) return;

    // Path from the device up to the central, following parent links.
    final path = <String>[tick.mac];
    var cursor = nodes[tick.mac];
    var guard = 0;
    while (cursor?.parentMac != null &&
        nodes.containsKey(cursor!.parentMac) &&
        guard++ < 8) {
      path.add(cursor.parentMac!);
      cursor = nodes[cursor.parentMac];
    }
    path.add(_centralKey);

    _dots.add(_TrafficDot(
      path: tick.direction == SafrTrafficDirection.uplink
          ? path
          : path.reversed.toList(),
      // Colours = the units' LED language (reference §3.7 row 7.7, §3.6.2):
      // red alarm · orange trouble · cyan = the tablet's ACK · blue = a
      // frame sent (heartbeat, test, name, command). No amber: an ALERT such
      // as the walk test is "blue then cyan" on the unit, so here too.
      color: switch (tick.severity) {
        3 => AppColors.error,
        1 => AppColors.trouble,
        _ => ackDown ? AppColors.ledCyan : AppColors.ledBlue,
      },
      startedAt: DateTime.now(),
      // A leaf's packet crosses each hop a little slower: one hop more than a
      // node (leaf → parent) and the eye should be able to follow it.
      duration: Duration(milliseconds: (leafRoutine ? 700 : 550) * (path.length - 1)),
    ));
    if (_dots.length > 40) _dots.removeRange(0, _dots.length - 40);
  }

  @override
  Widget build(BuildContext context) {
    // The board (layer 0) is folded into the CENTRAL chip, not drawn as its
    // own node; the mesh (layer 1+) hangs off the central directly.
    final allNodes = ref.watch(topologyProvider);
    // Who is root — or that the mesh is still deciding (root_election_provider).
    final election = ref.watch(rootElectionProvider);
    TopologyNode? board;
    final nodes = <TopologyNode>[];
    for (final n in allNodes) {
      if (n.layer == 0) {
        board ??= n;
      } else {
        nodes.add(n);
      }
    }
    final boardMac = board?.mac;

    final body = Column(
      children: [
        _MeshStatusBar(nodes: nodes, election: election, onClear: _clearRegistry),
        Expanded(
          child: nodes.isEmpty
              ? const _EmptyMesh()
              : LayoutBuilder(builder: (context, constraints) {
                  final size =
                      Size(constraints.maxWidth, constraints.maxHeight);
                  _viewSize = size;
                  final layout = _MeshLayout.compute(nodes, size);
                  _canvasSize = layout.canvas;
                  final key = (size, layout.canvas);
                  if (_fittedFor != key) {
                    final viewportChanged =
                        _fittedFor == null || _fittedFor!.$1 != size;
                    _fittedFor = key;
                    _refitTimer?.cancel();
                    if (viewportChanged) {
                      WidgetsBinding.instance
                          .addPostFrameCallback((_) => _fitToView());
                    } else {
                      _refitTimer = Timer(_refitSettle, () {
                        if (mounted) _fitToView();
                      });
                    }
                  }
                  return Stack(
                    children: [
                      // Pinch = the SAME zoom the buttons do (pivot on the
                      // tree's centre line and the fingers' row), fingers'
                      // travel = pan. Our own gesture math, so the tree
                      // never slides sideways on its own. The canvas grows
                      // past the viewport when the mesh is crowded — pan to
                      // reach the rest.
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onScaleStart: _onScaleStart,
                          onScaleUpdate: _onScaleUpdate,
                          child: ClipRect(
                            child: OverflowBox(
                              alignment: Alignment.topLeft,
                              minWidth: 0,
                              minHeight: 0,
                              maxWidth: double.infinity,
                              maxHeight: double.infinity,
                              child: ValueListenableBuilder<Matrix4>(
                                valueListenable: _transform,
                                builder: (_, m, child) => Transform(
                                  transform: m,
                                  alignment: Alignment.topLeft,
                                  child: child,
                                ),
                                child: SizedBox(
                                  width: layout.canvas.width,
                                  height: layout.canvas.height,
                                  child: Stack(
                                    children: [
                                      Positioned.fill(
                                        child: CustomPaint(
                                          painter: _MeshGraphPainter(
                                            nodes: nodes,
                                            layout: layout,
                                            dots: _dots,
                                            repaint: _ticker,
                                            isDark: context.isDark,
                                            boardMac: boardMac,
                                            rootMac: election.rootMac,
                                            candidates: election.electing
                                                ? election.candidates
                                                : const {},
                                          ),
                                        ),
                                      ),
                                      _CentralChip(
                                          position:
                                              layout.positions[_centralKey]!,
                                          board: board),
                                      for (final node in nodes)
                                        if (layout.positions
                                            .containsKey(node.mac))
                                          _NodeChip(
                                            node: node,
                                            position:
                                                layout.positions[node.mac]!,
                                            isRoot: node.online &&
                                                node.mac == election.rootMac,
                                            isCandidate: election.electing &&
                                                election.candidates
                                                    .contains(node.mac),
                                            onTap: () => _showNodeSheet(node),
                                          ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Lane labels live in screen space: pinned to the
                      // left edge whatever the pan/zoom, following only
                      // the rows' vertical position.
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _LaneLabelsPainter(
                              layout: layout,
                              transform: _transform,
                              isDark: context.isDark,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: _ZoomControls(
                          onZoomIn: () => _zoomBy(1.3),
                          onZoomOut: () => _zoomBy(1 / 1.3),
                          onReset: _fitToView,
                        ),
                      ),
                    ],
                  );
                }),
        ),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        title: const Text('Rede Mesh'),
        backgroundColor: context.bgColor,
        elevation: 0,
      ),
      body: body,
    );
  }

  /// Wipes the device registry so the map stops showing units from old
  /// sessions or installations. Live devices reappear on their next heartbeat.
  Future<void> _clearRegistry() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ressincronizar com a placa'),
        content: const Text(
            'Limpa o mapa da rede e pede à placa a tabela de dispositivos de '
            'novo. Os que estiverem ativos reaparecem no próximo heartbeat; '
            'o histórico de logs é mantido.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ressincronizar'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(appDatabaseProvider).clearMeshDevices();
      await ref.read(safrDownlinkProvider).sendGetInstallation();
      await ref.read(safrDownlinkProvider).sendGetDeviceTable();
    }
  }

  /// The sheet is taller than the default half-screen budget (facts + three
  /// commands + feedback), so it is scroll-controlled, capped at 90 % of the
  /// viewport and scrolls inside; on wide screens it stays a readable column.
  void _showNodeSheet(TopologyNode node) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.9,
        ),
        child: SingleChildScrollView(
          child: _NodeDetailSheet(node: node),
        ),
      ),
    );
  }
}

// ── Status bar ───────────────────────────────────────────────────────────────

class _MeshStatusBar extends StatelessWidget {
  const _MeshStatusBar({
    required this.nodes,
    required this.election,
    required this.onClear,
  });
  final List<TopologyNode> nodes;
  final RootElectionState election;

  /// "Limpar dispositivos" lives here, not floating over the canvas, so it
  /// can never collide with the zoom controls on a short landscape screen.
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final online = nodes.where((n) => n.online && !n.sleeping).length;
    final sleeping = nodes.where((n) => n.sleeping).length;
    final offline = nodes.where((n) => !n.online).length;
    DateTime? lastSeen;
    for (final n in nodes) {
      if (lastSeen == null || n.lastSeenAt.isAfter(lastSeen)) {
        lastSeen = n.lastSeenAt;
      }
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderColor.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          // One line always: on a narrow phone the counts scale down a
          // little instead of wrapping and doubling the strip's height.
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (election.electing) ...[
                    _ElectionPill(election: election),
                    const SizedBox(width: 14),
                  ],
                  _StatusCount(
                      color: AppColors.success, label: 'ATIVOS', count: online),
                  const SizedBox(width: 14),
                  _StatusCount(
                      color: context.textSecondary,
                      label: 'DORMINDO',
                      count: sleeping),
                  const SizedBox(width: 14),
                  _StatusCount(
                      color: AppColors.error, label: 'OFFLINE', count: offline),
                ],
              ),
            ),
          ),
          if (lastSeen != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  relativeTime(lastSeen),
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'ÚLTIMO QUADRO',
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 7.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          const SizedBox(width: 10),
          IconButton(
            tooltip: 'Ressincronizar com a placa',
            // M3 pads the tap target to 48 px, which alone made the strip
            // two lines tall; the strip stays one compact line.
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              fixedSize: const Size(30, 30),
              minimumSize: const Size(30, 30),
              padding: EdgeInsets.zero,
              foregroundColor: AppColors.error,
            ),
            icon: const Icon(Icons.delete_sweep_rounded, size: 20),
            onPressed: onClear,
          ),
        ],
      ),
    );
  }
}

/// "The mesh is choosing its root": shown while several units claim level 1
/// or the root was just lost, with the elapsed time so the operator sees it
/// is transient — and as a trouble once it has run past what a failover is
/// allowed to take (root_election_provider).
class _ElectionPill extends StatelessWidget {
  const _ElectionPill({required this.election});
  final RootElectionState election;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toUtc();
    final overdue = election.overdue(now);
    final color = overdue ? AppColors.error : AppColors.warning;
    final secs = election.elapsed(now).inSeconds;
    final label = overdue ? 'SEM ROOT' : 'REORGANIZANDO';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
          ),
          const SizedBox(width: 6),
          Text(
            '$label · ${secs}s',
            style: TextStyle(
              color: color,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCount extends StatelessWidget {
  const _StatusCount({
    required this.color,
    required this.label,
    required this.count,
  });

  final Color color;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: count > 0 ? color : color.withValues(alpha: 0.3),
            shape: BoxShape.circle,
            boxShadow: count > 0
                ? [
                    BoxShadow(
                        color: color.withValues(alpha: 0.5), blurRadius: 5)
                  ]
                : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$count',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 8,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }
}

class _ZoomControls extends StatelessWidget {
  const _ZoomControls({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    Widget button(IconData icon, String tooltip, VoidCallback onTap) {
      return Tooltip(
        message: tooltip,
        child: Material(
          color: context.surfaceColor.withValues(alpha: 0.92),
          shape: const CircleBorder(),
          elevation: 2,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 38,
              height: 38,
              child: Icon(icon, size: 19, color: context.textPrimary),
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        button(Icons.add_rounded, 'Aproximar', onZoomIn),
        const SizedBox(height: 8),
        button(Icons.remove_rounded, 'Afastar', onZoomOut),
        const SizedBox(height: 8),
        button(Icons.crop_free_rounded, 'Ajustar à tela', onReset),
      ],
    );
  }
}

// ── Traveling dot model ──────────────────────────────────────────────────────

class _TrafficDot {
  const _TrafficDot({
    required this.path,
    required this.color,
    required this.startedAt,
    required this.duration,
  });

  final List<String> path;
  final Color color;
  final DateTime startedAt;
  final Duration duration;

  double get progress {
    final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
    return elapsed / duration.inMilliseconds;
  }
}

// ── Painter: background grid, curved glowing links, pulses, dot trails ──────

class _MeshGraphPainter extends CustomPainter {
  _MeshGraphPainter({
    required this.nodes,
    required this.layout,
    required this.dots,
    required Listenable repaint,
    required this.isDark,
    this.boardMac,
    this.rootMac,
    this.candidates = const {},
  }) : super(repaint: repaint);

  final List<TopologyNode> nodes;
  final _MeshLayout layout;
  final List<_TrafficDot> dots;
  final bool isDark;
  final String? boardMac;

  /// The settled root (pulse ring) and, while electing, the contenders
  /// (faster, fainter pulse; dashed link to the central).
  final String? rootMac;
  final Set<String> candidates;

  @override
  void paint(Canvas canvas, Size size) {
    final byMac = {for (final n in nodes) n.mac: n};
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    _paintGrid(canvas, size);

    // Links: curved, two-pass (glow + core).
    for (final n in nodes) {
      final from = layout.positions[n.mac];
      if (from == null) continue;
      final parentKey = (n.parentMac != null && byMac.containsKey(n.parentMac))
          ? n.parentMac!
          : (n.layer <= 1 || n.parentMac == boardMac ? _centralKey : null);
      final to = parentKey != null ? layout.positions[parentKey] : null;
      if (to == null) continue;

      final parentOnline =
          parentKey == _centralKey || (byMac[parentKey]?.online ?? false);
      final healthy = n.online && parentOnline;
      final candidate = candidates.contains(n.mac);
      // Link colour = signal quality (system reference §3.6.2). A sleeping
      // leaf's link keeps its last dBm but wears the sleep colour: the reading
      // is from the last wake and the next one may come through any parent.
      final color = candidate
          ? AppColors.warning
          : healthy
              ? (n.sleeping ? sleepingLinkColor(isDark) : signalColor(n.rssi))
              : AppColors.error.withValues(alpha: 0.8);

      final path = _linkPath(from, to);
      if (candidate) {
        // Contending for root: attached, but not yet the bridge.
        _drawDashedPath(
          canvas,
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3
            ..color = color.withValues(alpha: 0.7),
        );
      } else if (healthy) {
        // Glow pass
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5
            ..color = color.withValues(alpha: 0.10)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
        );
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3
            ..color = color.withValues(alpha: 0.55),
        );
      } else {
        _drawDashedPath(
          canvas,
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.1
            ..color =
                color.withValues(alpha: n.stale ? 0.55 * _staleOpacity : 0.55),
        );
      }

      // Link quality: the child's RSSI to this parent, printed on the line in
      // the link's colour (not for a stale device — that reading is long out
      // of date). A sleeping leaf keeps its last value, in the sleep colour.
      if (n.rssi != null && !n.stale) {
        _linkLabel(
            canvas, path, '${n.rssi} dBm', healthy ? color : AppColors.error);
      }
    }

    // Pulse rings on the central and the settled root; while electing the
    // candidates get a quicker, fainter pulse instead of the root's.
    final phase = (nowMs % 2200) / 2200.0;
    _pulse(
        canvas, layout.positions[_centralKey], AppColors.secondary, phase, 30);
    final fast = (nowMs % 1100) / 1100.0;
    for (final n in nodes) {
      if (!n.online || n.layer == 0) continue;
      if (n.mac == rootMac) {
        _pulse(canvas, layout.positions[n.mac], AppColors.warning,
            (phase + 0.5) % 1.0, 26);
      } else if (candidates.contains(n.mac)) {
        _pulse(canvas, layout.positions[n.mac],
            AppColors.warning.withValues(alpha: 0.6), fast, 22);
      }
    }

    // Traveling packets: a small data packet (rounded body, two data stripes)
    // oriented along the line, with a soft glow and two fainter ghosts behind.
    dots.removeWhere((d) => d.progress >= 1.0);
    for (final dot in dots) {
      for (var k = 2; k >= 0; k--) {
        final t = dot.progress - k * 0.03;
        if (t < 0) continue;
        final tan = _tangentAlong(dot.path, t);
        if (tan == null) continue;
        _drawPacket(canvas, tan.position, tan.angle, dot.color,
            k == 0 ? 1.0 : 0.85 - k * 0.15, k == 0 ? 1.0 : 0.30 - k * 0.10);
      }
    }
  }

  /// Paints the RSSI value on a pill at the middle of a link.
  void _linkLabel(Canvas canvas, Path path, String text, Color color) {
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final m = metrics.first;
    final pos = m.getTangentForOffset(m.length * 0.5)?.position;
    if (pos == null) return;

    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color.withValues(alpha: 0.95),
          fontSize: 8.5,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final rect = Rect.fromCenter(
      center: pos,
      width: tp.width + 10,
      height: tp.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(7)),
      Paint()
        ..color = (isDark ? const Color(0xFF0B0F1A) : Colors.white)
            .withValues(alpha: 0.85),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(7)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = color.withValues(alpha: 0.35),
    );
    tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawDashedPath(Canvas canvas, Path path, Paint paint) {
    const dash = 5.0, gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var covered = 0.0;
      while (covered < metric.length) {
        final end = (covered + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(covered, end), paint);
        covered = end + gap;
      }
    }
  }

  Path _linkPath(Offset from, Offset to) {
    // Gentle vertical S-curve: fans siblings out from their shared parent.
    final mid = Offset.lerp(from, to, 0.5)!;
    final bend = (to.dx - from.dx).abs() * 0.001 + 0.22;
    final c1 = Offset(from.dx, from.dy - (from.dy - mid.dy) * bend * 2);
    final c2 = Offset(to.dx, to.dy + (mid.dy - to.dy) * bend * 2);
    return Path()
      ..moveTo(from.dx, from.dy)
      ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, to.dx, to.dy);
  }

  /// One packet: 12 × 7.5 body with a lighter header band and two data
  /// stripes, rotated to travel along the link. `scale` / `alpha` draw the
  /// motion ghosts.
  void _drawPacket(Canvas canvas, Offset pos, double angle, Color color,
      double scale, double alpha) {
    canvas.save();
    canvas.translate(pos.dx, pos.dy);
    canvas.rotate(angle);
    canvas.scale(scale);
    if (alpha >= 1.0) {
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: 20, height: 13),
        Paint()
          ..color = color.withValues(alpha: 0.28)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    }
    final body = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: 12, height: 7.5),
        const Radius.circular(1.8));
    canvas.drawRRect(body, Paint()..color = color.withValues(alpha: alpha));
    // Header band (leading edge) + two data stripes, in the body's own light.
    final ink = Paint()
      ..color = Colors.white.withValues(alpha: 0.75 * alpha)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(3.6, -2.4), const Offset(3.6, 2.4), ink..strokeWidth = 1.4);
    canvas.drawLine(const Offset(-4.2, -1.2), const Offset(1.4, -1.2), ink..strokeWidth = 0.9);
    canvas.drawLine(const Offset(-4.2, 1.2), const Offset(0.2, 1.2), ink);
    canvas.restore();
  }

  /// Position and heading along the multi-hop path (same curve as the link).
  Tangent? _tangentAlong(List<String> keys, double progress) {
    final points = [
      for (final key in keys)
        if (layout.positions[key] != null) layout.positions[key]!,
    ];
    if (points.length < 2) return null;
    final segments = points.length - 1;
    final t = (progress * segments).clamp(0.0, segments.toDouble());
    final seg = t.floor().clamp(0, segments - 1);
    final local = t - seg;
    final metrics =
        _linkPath(points[seg], points[seg + 1]).computeMetrics().toList();
    if (metrics.isEmpty) return null;
    final m = metrics.first;
    final tan = m.getTangentForOffset(m.length * local);
    if (tan == null) return null;
    // Tangent.angle is measured counter-clockwise; the canvas rotates clockwise.
    return Tangent.fromAngle(tan.position, -tan.angle);
  }

  void _pulse(
    Canvas canvas,
    Offset? center,
    Color color,
    double phase,
    double baseRadius,
  ) {
    if (center == null) return;
    canvas.drawCircle(
      center,
      baseRadius + phase * 16,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = color.withValues(alpha: (1 - phase) * 0.30),
    );
  }

  void _paintGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = (isDark ? Colors.white : Colors.black).withValues(alpha: 0.035);
    const gap = 26.0;
    for (var x = gap; x < size.width; x += gap) {
      for (var y = gap; y < size.height; y += gap) {
        canvas.drawCircle(Offset(x, y), 0.9, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_MeshGraphPainter old) => true;
}

// ── Arena-free tap ───────────────────────────────────────────────────────────

/// Tap detection that stays OUT of the gesture arena. A chip must never
/// compete with the viewer's pinch/pan: with a TapGestureRecognizer on the
/// chip, a pinch that began on a chip (where fingers usually land) lost part
/// of the hand's movement and the map slid away from the fingers. A raw
/// Listener sees every pointer event without claiming any of them, so the
/// viewer keeps the whole gesture; the tap fires only for a short, still,
/// single-finger touch.
class _ArenaFreeTap extends StatefulWidget {
  const _ArenaFreeTap({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_ArenaFreeTap> createState() => _ArenaFreeTapState();
}

class _ArenaFreeTapState extends State<_ArenaFreeTap> {
  Offset? _down;
  int _pointers = 0;
  bool _cancelled = false;

  void _onDown(PointerDownEvent e) {
    _pointers++;
    if (_pointers == 1) {
      _down = e.position;
      _cancelled = false;
    } else {
      _cancelled = true; // second finger: this is a pinch, not a tap
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (_down != null && (e.position - _down!).distance > kTouchSlop) {
      _cancelled = true;
    }
  }

  void _onUp(PointerUpEvent e) {
    _pointers = math.max(0, _pointers - 1);
    if (_pointers > 0) return;
    if (!_cancelled && _down != null) widget.onTap();
    _down = null;
  }

  void _onCancel(PointerCancelEvent e) {
    _pointers = math.max(0, _pointers - 1);
    _cancelled = true;
    if (_pointers == 0) _down = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: widget.child,
    );
  }
}

// ── Lane labels (screen-space gutter) ────────────────────────────────────────

/// CENTRAL / ROOT / CAMADA n, rotated along the left edge of the viewport.
/// Repaints with the transform so each label tracks its row's screen y while
/// its x and size never change — the gutter is fixed, the map moves.
class _LaneLabelsPainter extends CustomPainter {
  _LaneLabelsPainter({
    required this.layout,
    required this.transform,
    required this.isDark,
  }) : super(repaint: transform);

  final _MeshLayout layout;
  final TransformationController transform;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final m = transform.value;
    final scale = _scaleOf(m);
    final ty = m.getTranslation().y;

    void label(String text, double lane) {
      final y = ty + lane * scale;
      if (y < 0 || y > size.height) return; // row scrolled off-screen
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color:
                (isDark ? Colors.white : Colors.black).withValues(alpha: 0.22),
            fontSize: 8,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.save();
      canvas.translate(10, y + tp.width / 2);
      canvas.rotate(-math.pi / 2);
      tp.paint(canvas, Offset.zero);
      canvas.restore();
    }

    label('CENTRAL', layout.centralLane);
    final layers = layout.laneCenters.keys.toList()..sort();
    for (final ly in layers) {
      label(ly == 1 ? 'ROOT' : 'CAMADA ${ly - 1}', layout.laneCenters[ly]!);
    }
  }

  @override
  bool shouldRepaint(_LaneLabelsPainter old) =>
      old.layout != layout || old.isDark != isDark;
}

// ── Layout ───────────────────────────────────────────────────────────────────

/// Where every node sits on the canvas, plus the lanes the painter labels.
///
/// The tree always grows top → bottom: central row on top, one row per
/// layer, siblings spread across the width, rotated labels in a left gutter.
/// The canvas is at least the viewport and grows when a row or a lane would
/// otherwise overlap chips; the screen then zooms out to fit it (landscape)
/// rather than changing the picture.
class _MeshLayout {
  const _MeshLayout({
    required this.positions,
    required this.centralLane,
    required this.laneCenters,
    required this.canvas,
  });

  final Map<String, Offset> positions;

  /// y of the central row.
  final double centralLane;

  /// y of each mesh layer's row.
  final Map<int, double> laneCenters;

  /// Canvas size the chips and painter are laid out in (≥ viewport).
  final Size canvas;

  // Chip footprint: node chip 104 × ~62, central chip 120 × ~95.
  // The same margin on both sides keeps the tree centred; the left one
  // also hosts the rotated lane labels.
  static const _gutter = 36.0;
  static const _edge = 12.0;
  static const _minAcross = 116.0; // node pitch along a row
  static const _minLane = 104.0; // row pitch

  static _MeshLayout compute(List<TopologyNode> nodes, Size viewport) {
    final layers = <int, List<TopologyNode>>{};
    for (final n in nodes) {
      layers.putIfAbsent(n.layer, () => []).add(n);
    }
    final layerKeys = layers.keys.toList()..sort();
    final laneCount = layerKeys.length + 1; // + central row
    var widest = 1;
    for (final l in layers.values) {
      widest = math.max(widest, l.length);
    }

    // Siblings sit at (j+1)/(n+1) of the usable width, so n chips need
    // n+1 pitches for the pitch itself to stay ≥ _minAcross.
    final width =
        math.max(viewport.width, 2 * _gutter + (widest + 1) * _minAcross);
    final height = math.max(viewport.height, 2 * _edge + laneCount * _minLane);
    final rowH = (height - 2 * _edge) / laneCount;
    final usableW = width - 2 * _gutter;
    double laneY(int i) => _edge + rowH * (i + 0.52);

    final positions = <String, Offset>{
      _centralKey: Offset(_gutter + usableW / 2, laneY(0)),
    };
    final laneCenters = <int, double>{};
    for (var i = 0; i < layerKeys.length; i++) {
      final row = layers[layerKeys[i]]!;
      laneCenters[layerKeys[i]] = laneY(i + 1);
      for (var j = 0; j < row.length; j++) {
        positions[row[j].mac] = Offset(
          _gutter + usableW * (j + 1) / (row.length + 1),
          laneY(i + 1),
        );
      }
    }
    return _MeshLayout(
      positions: positions,
      centralLane: laneY(0),
      laneCenters: laneCenters,
      canvas: Size(width, height),
    );
  }
}

// ── Chips ────────────────────────────────────────────────────────────────────

class _CentralChip extends StatelessWidget {
  const _CentralChip({required this.position, this.board});
  final Offset position;
  final TopologyNode? board;

  static const _width = 120.0;
  static const _circle = 54.0;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: position.dx - _CentralChip._width / 2,
      top: position.dy - _CentralChip._circle / 2,
      child: SizedBox(
        width: _CentralChip._width,
        child: Column(
          children: [
            Container(
              width: _CentralChip._circle,
              height: _CentralChip._circle,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.primary, Color(0xFF2E6DA4)],
                ),
                border: Border.all(
                  color: AppColors.secondary.withValues(alpha: 0.7),
                  width: 1.6,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.secondary.withValues(alpha: 0.30),
                    blurRadius: 16,
                  ),
                ],
              ),
              child: const Icon(Icons.tablet_mac_rounded,
                  color: Colors.white, size: 24),
            ),
            const SizedBox(height: 5),
            Text(
              'CENTRAL',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.0,
              ),
            ),
            if (board != null) ...[
              const SizedBox(height: 2),
              Text(
                board!.mac,
                style: TextStyle(
                  color: context.textSecondary.withValues(alpha: 0.8),
                  fontSize: 8,
                  fontFamily: 'monospace',
                ),
              ),
              if (board!.rssi != null)
                Text(
                  '${board!.rssi} dBm',
                  style: TextStyle(
                    color: context.textSecondary.withValues(alpha: 0.7),
                    fontSize: 8,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NodeChip extends StatelessWidget {
  const _NodeChip({
    required this.node,
    required this.position,
    required this.isRoot,
    required this.isCandidate,
    required this.onTap,
  });

  final TopologyNode node;
  final Offset position;

  /// Decided by root_election_provider, not by the unit's own claim: the
  /// ROOT badge goes to the settled root only; while the mesh is still
  /// choosing, the contenders wear CANDIDATO instead.
  final bool isRoot;
  final bool isCandidate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final statusColor = !node.online
        ? AppColors.error
        : node.sleeping
            ? context.textSecondary
            : AppColors.success;
    final icon = switch (node.role) {
      SafrNodeRole.root => Icons.power_rounded,
      SafrNodeRole.node => Icons.cell_tower_rounded,
      _ => node.sleeping ? Icons.dark_mode_rounded : Icons.sensors_rounded,
    };
    final ringColor = isRoot
        ? AppColors.warning
        : isCandidate
            ? AppColors.warning.withValues(alpha: 0.55)
            : node.online
                ? AppColors.secondary.withValues(alpha: 0.6)
                : AppColors.error.withValues(alpha: 0.65);

    return Positioned(
      left: position.dx - 52,
      top: position.dy - 26,
      child: Opacity(
        opacity: node.stale ? _staleOpacity : 1.0,
        child: _ArenaFreeTap(
          onTap: onTap,
          child: SizedBox(
            width: 104,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Outer ring + inner avatar (double-ring look)
                    Container(
                      width: 46,
                      height: 46,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: ringColor, width: isRoot ? 1.8 : 1.1),
                        boxShadow: [
                          BoxShadow(
                            color: (isRoot ? AppColors.warning : ringColor)
                                .withValues(alpha: node.online ? 0.28 : 0.10),
                            blurRadius: 12,
                          ),
                        ],
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: node.online
                              ? Color.alphaBlend(
                                  ringColor.withValues(alpha: 0.10),
                                  context.surfaceColor)
                              : context.surfaceColor,
                        ),
                        child: node.sleeping
                            ? _SleepingMoon(
                                color: context.textPrimary,
                                zColor: context.textSecondary,
                              )
                            : Icon(
                                icon,
                                size: 19,
                                color: node.online
                                    ? context.textPrimary
                                    : context.textSecondary
                                        .withValues(alpha: 0.7),
                              ),
                      ),
                    ),
                    Positioned(
                      right: -1,
                      top: -1,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                          border:
                              Border.all(color: context.bgColor, width: 1.8),
                          boxShadow: node.online && !node.sleeping
                              ? [
                                  BoxShadow(
                                    color: statusColor.withValues(alpha: 0.6),
                                    blurRadius: 5,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ),
                    if (node.alarmLatched)
                      Positioned(
                        right: -10,
                        bottom: -7,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: AppColors.error,
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.error.withValues(alpha: 0.4),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                          child: const Text(
                            'ALARME',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 7.5,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                    if (isRoot || isCandidate)
                      Positioned(
                        left: isCandidate ? -18 : -8,
                        bottom: -7,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: isRoot
                                ? AppColors.warning
                                : AppColors.warning.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(6),
                            border: isRoot
                                ? null
                                : Border.all(
                                    color: AppColors.warning
                                        .withValues(alpha: 0.7)),
                            boxShadow: isRoot
                                ? [
                                    BoxShadow(
                                      color: AppColors.warning
                                          .withValues(alpha: 0.4),
                                      blurRadius: 6,
                                    ),
                                  ]
                                : null,
                          ),
                          child: Text(
                            isRoot ? 'ROOT' : 'CANDIDATO',
                            style: TextStyle(
                              color: isRoot ? Colors.black : AppColors.warning,
                              fontSize: 7.5,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 5),
                // Identification: the device's name when set, otherwise the
                // full MAC address — never a truncated fragment.
                Text(
                  node.name?.isNotEmpty == true ? node.name! : node.mac,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: node.name?.isNotEmpty == true
                        ? context.textPrimary
                        : context.textSecondary,
                    fontSize: node.name?.isNotEmpty == true ? 9.5 : 8,
                    fontWeight: FontWeight.w600,
                    fontFamily:
                        node.name?.isNotEmpty == true ? null : 'monospace',
                    letterSpacing: node.name?.isNotEmpty == true ? 0 : -0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Node detail sheet with downlink commands ─────────────────────────────────

class _NodeDetailSheet extends ConsumerStatefulWidget {
  const _NodeDetailSheet({required this.node});
  final TopologyNode node;

  @override
  ConsumerState<_NodeDetailSheet> createState() => _NodeDetailSheetState();
}

class _NodeDetailSheetState extends ConsumerState<_NodeDetailSheet> {
  SafrCommand? _sending;
  String? _feedback;
  bool _feedbackOk = false;

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final roleLabel = node.layer == 0
        ? 'Placa (gateway para a central)'
        : switch (node.role) {
            SafrNodeRole.root => 'Root da malha (alimentado 24h)',
            SafrNodeRole.node => 'Repetidor',
            SafrNodeRole.leaf => 'Sensor (dorme entre envios)',
            _ => 'Desconhecido',
          };
    final hasName = node.name?.isNotEmpty == true;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  node.online
                      ? Icons.check_circle_rounded
                      : Icons.error_rounded,
                  color: node.online ? AppColors.success : AppColors.error,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hasName ? node.name! : node.mac,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          fontFamily: hasName ? null : 'monospace',
                        ),
                      ),
                      if (hasName)
                        Text(
                          node.mac,
                          style: TextStyle(
                            color: context.textSecondary,
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Dar um nome a este dispositivo',
                  icon: Icon(Icons.edit_rounded,
                      size: 18, color: context.textSecondary),
                  onPressed: () => _rename(context),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _fact(context, 'Papel', roleLabel),
            _fact(context, 'Camada', 'L${node.layer}'),
            if (node.parentMac != null) _fact(context, 'Pai', node.parentMac!),
            if (node.rssi != null)
              _fact(context, 'Sinal', '${node.rssi} dBm',
                  valueColor: signalColor(node.rssi)),
            if (node.isLeaf)
              _fact(
                context,
                'Pais ao alcance',
                node.parentCandidates.isEmpty
                    ? 'nenhum informado ainda'
                    : node.parentCandidates
                        .map((c) => '${c.mac} (${c.rssi} dBm)')
                        .join(' · '),
                valueColor: node.singleParent ? AppColors.warning : null,
              ),
            if (node.isLeaf && node.singleParent && node.online)
              _fact(context, 'Atenção',
                  'só um pai ao alcance — instale um dispositivo AC mais perto',
                  valueColor: AppColors.warning),
            if (node.isLeaf && node.weakLink && node.online)
              _fact(context, 'Atenção', 'sinal fraco com o pai (abaixo de −85 dBm)',
                  valueColor: AppColors.warning),
            if (node.batteryPct != null)
              _fact(context, 'Bateria', '${node.batteryPct}%'),
            if (node.zone?.isNotEmpty == true) _fact(context, 'Zona', node.zone!),
            if (node.boardState != null)
              _fact(
                context,
                'Na placa',
                switch (node.boardState!) {
                  SafrDeviceState.expected => 'esperado (nunca ouvido)',
                  SafrDeviceState.online => 'online',
                  SafrDeviceState.missing => 'sem comunicação',
                  SafrDeviceState.retired => node.heardWhileRetired
                      ? 'aposentado — mas transmitindo'
                      : 'aposentado',
                  _ => '?',
                },
                valueColor: node.retired ? AppColors.trouble : null,
              ),
            if (node.pendingRename)
              _fact(context, 'Pendente', 'novo nome/zona: aplica quando o dispositivo falar',
                  valueColor: AppColors.warning),
            if (node.pendingDecommission)
              _fact(context, 'Pendente', 'apagar da placa: aplica quando o dispositivo falar',
                  valueColor: AppColors.warning),
            _fact(context, 'Última comunicação', relativeTime(node.lastSeenAt)),
            if (node.alarmLatched)
              _fact(
                context,
                'Alarme retido',
                node.alarmLatchedAt != null
                    ? 'desde ${relativeTime(node.alarmLatchedAt!)}'
                    : 'sim',
                valueColor: AppColors.error,
              ),
            _fact(
                context,
                'Estado',
                node.online
                    ? (node.sleeping
                        ? 'Dormindo · último despertar ${relativeTime(node.lastSeenAt)}'
                            '${node.nextWakeInSeconds != null ? ' · próximo em ~${node.nextWakeInSeconds} s' : ' · próximo a qualquer momento'}'
                        : node.isLeaf
                            ? (node.alarmLatched ? 'Acordado — em alarme' : 'Acordado')
                            : 'Online')
                    : node.stale
                        ? 'Sem comunicação há muito tempo (${relativeTime(node.lastSeenAt)})'
                        : 'Sem comunicação (${relativeTime(node.lastSeenAt)})',
                valueColor: !node.online ? AppColors.error : null),
            const SizedBox(height: 16),
            Text(
              'COMANDOS — CENTRAL → DISPOSITIVO',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              node.online
                  ? (node.sleeping
                      ? 'Este sensor está dormindo: o root confirma o '
                          'recebimento e entrega o comando no próximo despertar.'
                      : 'Enviados pela serial ao root, que encaminha ao '
                          'dispositivo e confirma com ACK.')
                  : 'Sem comunicação — comandos indisponíveis até o '
                      'dispositivo voltar.',
              style: TextStyle(color: context.textSecondary, fontSize: 11),
            ),
            const SizedBox(height: 8),
            _cmdRow(
              SafrCommand.identify,
              'Identificar',
              'Pisca o LED do dispositivo para localizá-lo fisicamente',
              Icons.lightbulb_outline_rounded,
              args: const [10],
            ),
            _cmdRow(
              SafrCommand.silence,
              'Silenciar',
              'Desliga a sirene/relé durante um alarme ativo',
              Icons.notifications_off_outlined,
            ),
            _cmdRow(
              SafrCommand.test,
              'Testar',
              'Solicita um autoteste — o resultado aparece em Logs seriais',
              Icons.quiz_outlined,
            ),
            if (node.alarmLatched)
              // The root's ACK is what clears the latch, so this stays
              // available even while the sensor itself is unreachable.
              _cmdRow(
                SafrCommand.reset,
                'Rearmar',
                'Libera o alarme retido deste dispositivo (só após o ACK do root)',
                Icons.restart_alt_rounded,
                requiresOnline: false,
              ),
            const SizedBox(height: 16),
            Text(
              'GERENCIAR — PIN MASTER / NÍVEL 4',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Alterações na tabela de dispositivos da placa '
              '(installation-lifecycle-v1.md §5).',
              style: TextStyle(color: context.textSecondary, fontSize: 11),
            ),
            const SizedBox(height: 8),
            if (node.layer > 0 || node.boardState != null) ...[
              if (!node.retired)
                _manageRow('Aposentar', 'A placa passa a ignorar este dispositivo',
                    Icons.person_off_outlined, _retire),
              if (node.retired)
                _manageRow('Reativar', 'Volta a aceitar este dispositivo',
                    Icons.person_add_alt_1_outlined, _unretire),
              _manageRow('Substituir por…', 'Move nome e zona para um dispositivo novo',
                  Icons.swap_horiz_rounded, _replace),
              _manageRow('Apagar da placa', 'Reset de fábrica remoto (digite o nome para confirmar)',
                  Icons.delete_forever_outlined, _decommission,
                  destructive: true),
              if (node.retired)
                _manageRow('Esquecer', 'Remove o registro aposentado da placa',
                    Icons.playlist_remove_rounded, _forget),
            ],
            // Inline result: never a SnackBar fighting the sheet for space.
            if (_feedback != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: (_feedbackOk ? AppColors.success : AppColors.trouble)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: (_feedbackOk ? AppColors.success : AppColors.trouble)
                        .withValues(alpha: 0.45),
                    width: 0.7,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _feedbackOk
                          ? Icons.done_all_rounded
                          : Icons.error_outline_rounded,
                      size: 16,
                      color:
                          _feedbackOk ? AppColors.success : AppColors.trouble,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _feedback!,
                        style: TextStyle(
                          color: _feedbackOk
                              ? AppColors.success
                              : AppColors.trouble,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<EditorRole?> _gate(String what) => requestEditorRole(
        context,
        subtitle: 'Digite o PIN Master ou o PIN de Nível 4\npara $what.',
      );

  void _show(String message, bool ok) {
    if (!mounted) return;
    setState(() {
      _feedback = message;
      _feedbackOk = ok;
    });
  }

  Future<void> _rename(BuildContext context) async {
    // Lifecycle §5 H: SET_DEVICE to the board (which relays to the unit and
    // keeps it pending while the unit is away). Without a v3.2 board the row
    // is edited on this tablet only.
    final role = await _gate('renomear este dispositivo');
    if (role == null || !context.mounted) return;
    final nameCtrl = TextEditingController(text: widget.node.name ?? '');
    final zoneCtrl = TextEditingController(text: widget.node.zone ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: dialogContext.surfaceColor,
        title: const Text('Nome e zona'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              maxLength: 32,
              decoration: InputDecoration(
                labelText: 'Nome',
                hintText: 'ex.: Sala de máquinas',
                helperText: widget.node.mac,
              ),
            ),
            TextField(
              controller: zoneCtrl,
              maxLength: 16,
              decoration: const InputDecoration(labelText: 'Zona', hintText: 'ex.: Térreo'),
              onSubmitted: (_) => Navigator.pop(dialogContext, true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    final zone = zoneCtrl.text.trim();
    if (name.isEmpty) return;
    final db = ref.read(appDatabaseProvider);
    final result = await ref
        .read(safrDownlinkProvider)
        .sendSetDevice(widget.node.mac, name, zone);
    await (db.update(db.meshDevices)
          ..where((t) => t.mac.equals(widget.node.mac)))
        .write(MeshDevicesCompanion(name: Value(name), zone: Value(zone)));
    await db.addAudit(role.auditName, result.ok ? 'device_rename' : 'device_rename_local',
        {'mac': widget.node.mac, 'name': name, 'zone': zone, 'board_ok': result.ok});
    _show(result.ok
        ? 'Nome enviado à placa.'
        : 'Salvo só neste tablet — ${result.message}', result.ok);
  }

  Future<void> _retire() async {
    final role = await _gate('aposentar este dispositivo');
    if (role == null) return;
    final r = await ref.read(safrDownlinkProvider).sendRetireDevice(widget.node.mac);
    await ref.read(appDatabaseProvider).addAudit(role.auditName, 'device_retire',
        {'mac': widget.node.mac, 'ok': r.ok});
    if (r.ok) ref.read(safrDownlinkProvider).sendGetDeviceTable();
    _show(r.message, r.ok);
  }

  Future<void> _unretire() async {
    final role = await _gate('reativar este dispositivo');
    if (role == null) return;
    final r = await ref.read(safrDownlinkProvider).sendUnretireDevice(widget.node.mac);
    await ref.read(appDatabaseProvider).addAudit(role.auditName, 'device_unretire',
        {'mac': widget.node.mac, 'ok': r.ok});
    if (r.ok) ref.read(safrDownlinkProvider).sendGetDeviceTable();
    _show(r.message, r.ok);
  }

  Future<void> _forget() async {
    final role = await _gate('esquecer este dispositivo');
    if (role == null) return;
    final r = await ref.read(safrDownlinkProvider).sendForgetDevice(widget.node.mac);
    await ref.read(appDatabaseProvider).addAudit(role.auditName, 'device_forget',
        {'mac': widget.node.mac, 'ok': r.ok});
    if (r.ok) {
      final db = ref.read(appDatabaseProvider);
      await (db.delete(db.meshDevices)..where((t) => t.mac.equals(widget.node.mac))).go();
      if (mounted) Navigator.pop(context);
      return;
    }
    _show(r.message, r.ok);
  }

  Future<void> _replace() async {
    final role = await _gate('substituir este dispositivo');
    if (role == null || !mounted) return;
    final candidates = ref
        .read(topologyProvider)
        .where((n) => n.mac != widget.node.mac && !n.retired && n.layer > 0)
        .toList();
    if (!mounted) return;
    final chosen = await showDialog<TopologyNode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: ctx.surfaceColor,
        title: Text('Substituir "${widget.node.name ?? widget.node.mac}" por…'),
        children: candidates.isEmpty
            ? [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'Nenhum dispositivo novo visto ainda. Configure a unidade nova '
                    'pelo telefone e aguarde ela aparecer na rede.',
                    style: TextStyle(color: ctx.textSecondary, fontSize: 13),
                  ),
                ),
              ]
            : [
                for (final c in candidates)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, c),
                    child: Text('${c.name?.isNotEmpty == true ? c.name : c.mac} · '
                        '${c.online ? "online" : "sem comunicação"}'),
                  ),
              ],
      ),
    );
    if (chosen == null) return;
    final r = await ref
        .read(safrDownlinkProvider)
        .sendReplaceDevice(widget.node.mac, chosen.mac);
    await ref.read(appDatabaseProvider).addAudit(role.auditName, 'device_replace',
        {'old': widget.node.mac, 'new': chosen.mac, 'ok': r.ok});
    if (r.ok) ref.read(safrDownlinkProvider).sendGetDeviceTable();
    _show(r.ok ? 'Substituído. O antigo foi aposentado.' : r.message, r.ok);
  }

  Future<void> _decommission() async {
    final role = await _gate('apagar este dispositivo da placa');
    if (role == null || !mounted) return;
    final expected = widget.node.name?.isNotEmpty == true ? widget.node.name! : widget.node.mac;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: const Text('Apagar da placa?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'O dispositivo apaga a própria configuração e volta ao modo de '
              'instalação (LED branco piscando). Para confirmar, digite '
              'exatamente: $expected',
              style: TextStyle(color: ctx.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(controller: ctrl, autofocus: true),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim() == expected),
            child: const Text('Apagar'),
          ),
        ],
      ),
    );
    if (ok != true) {
      if (ok == false && ctrl.text.isNotEmpty) _show('Nome não confere. Nada foi feito.', false);
      return;
    }
    final r = await ref.read(safrDownlinkProvider).sendDecommission(widget.node.mac);
    await ref.read(appDatabaseProvider).addAudit(role.auditName, 'device_decommission',
        {'mac': widget.node.mac, 'ok': r.ok});
    if (r.ok) ref.read(safrDownlinkProvider).sendGetDeviceTable();
    _show(r.ok ? 'Enviado. A unidade será apagada (ou ao acordar).' : r.message, r.ok);
  }

  Widget _manageRow(String label, String hint, IconData icon, Future<void> Function() action,
      {bool destructive = false}) {
    final color = destructive ? AppColors.error : context.textPrimary;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(icon, color: color, size: 20),
      title: Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
      subtitle: Text(hint, style: TextStyle(color: context.textSecondary, fontSize: 11)),
      onTap: action,
    );
  }

  Widget _fact(BuildContext context, String label, String value,
      {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(label,
                style: TextStyle(color: context.textSecondary, fontSize: 12.5)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    color: valueColor ?? context.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _cmdRow(
      SafrCommand cmd, String label, String description, IconData icon,
      {List<int> args = const [], bool requiresOnline = true}) {
    final busy = _sending == cmd;
    final enabled = (widget.node.online || !requiresOnline) && _sending == null;
    final color = enabled
        ? AppColors.secondary
        : context.textSecondary.withValues(alpha: 0.5);

    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: enabled
              ? AppColors.secondary.withValues(alpha: 0.35)
              : context.borderColor.withValues(alpha: 0.5),
          width: 0.7,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: !enabled ? null : () => _send(cmd, label, args),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: enabled
                              ? context.textPrimary
                              : context.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        description,
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
                if (busy)
                  const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(Icons.send_rounded, size: 15, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _send(SafrCommand cmd, String label, List<int> args) async {
    setState(() {
      _sending = cmd;
      _feedback = null;
    });
    final downlink = ref.read(safrDownlinkProvider);
    // RESET goes through sendReset so the latch clears only on the root's ACK.
    final confirmed = cmd == SafrCommand.reset
        ? await downlink.sendReset(widget.node.mac)
        : await downlink.sendCommand(widget.node.mac, cmd, args: args);
    if (!mounted) return;
    setState(() {
      _sending = null;
      _feedbackOk = confirmed;
      _feedback = confirmed
          ? '$label — confirmado pelo root (ACK ✓✓)'
          : '$label — sem confirmação do root, tente novamente';
    });
  }
}

class _EmptyMesh extends StatelessWidget {
  const _EmptyMesh();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hub_outlined,
              size: 52, color: context.textSecondary.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(
            'Nenhum dispositivo na rede',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'A topologia aparecerá aqui assim que o root\ncomeçar a reportar pela serial.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.textSecondary, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

/// The moon of a sleeping leaf with two small "z" drifting up and fading,
/// clipped to the avatar circle so the chip's layout never changes. One
/// controller per sleeping leaf; the frame cost is two tiny texts.
class _SleepingMoon extends StatefulWidget {
  const _SleepingMoon({required this.color, required this.zColor});

  final Color color;
  final Color zColor;

  @override
  State<_SleepingMoon> createState() => _SleepingMoonState();
}

class _SleepingMoonState extends State<_SleepingMoon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// One "z": rises 7 px and fades over its own third of the cycle, staggered
  /// by `delay` (0..1) so the two never move together.
  Widget _z(double t, double delay, double size, double right, double bottom) {
    final u = ((t - delay) % 1.0 + 1.0) % 1.0; // 0..1 within this z's cycle
    final visible = u < 0.55;
    final k = visible ? u / 0.55 : 0.0;
    final opacity = visible ? (k < 0.25 ? k / 0.25 : 1.0 - (k - 0.25) / 0.75) : 0.0;
    return Positioned(
      right: right - k * 1.5,
      bottom: bottom + k * 7,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Text(
          'z',
          style: TextStyle(
            color: widget.zColor,
            fontSize: size,
            fontWeight: FontWeight.w800,
            height: 1,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          return Stack(
            clipBehavior: Clip.hardEdge,
            alignment: Alignment.center,
            children: [
              // The moon breathes very slightly with the first z.
              Transform.translate(
                offset: Offset(-1.5, 1.5 - 1.0 * (0.5 - (t - 0.5).abs())),
                child: Icon(Icons.dark_mode_rounded, size: 18, color: widget.color),
              ),
              _z(t, 0.0, 7.5, 7, 22),
              _z(t, 0.45, 6, 3, 20),
            ],
          );
        },
      ),
    );
  }
}
