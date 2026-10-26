import 'dart:ui' as ui;
import 'dart:ui' show Tangent;
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart' show safrBroadcastMac;
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/signal_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/central_mirror_viewer.dart';
import '../../application/device_command_provider.dart';
import '../../application/ota_push_report.dart';
import '../../application/ota_rollout_report.dart';
import '../../application/root_election_provider.dart';
import '../../application/safr_traffic_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_product.dart';
import '../../domain/safr/safr_v2_frame.dart' show SafrMsgType;
import 'device_command_widgets.dart';
import 'device_menu.dart' show deviceAnchorOf;
import 'device_avatar.dart';
import 'mesh_legend.dart';
import 'ota_rede_widgets.dart';

/// The 2D map of the fire-alarm mesh, shared by Rede and "Atualizar
/// dispositivos": central on top, root marked, curved glowing links, lane
/// labels, pan / pinch / zoom buttons, and dots with trails travelling along
/// the real path of every frame — visible proof that messages cross the
/// system. The screen around it owns everything else (status strip, menus).
class MeshMap extends ConsumerStatefulWidget {
  const MeshMap({
    super.key,
    required this.nodes,
    required this.board,
    required this.election,
    required this.onNodeTap,
    this.showOta = true,
    this.showVersions = true,
    this.radial = false,
    this.overlay,
    this.selected = const {},
    this.boardSelected = false,
    this.focus,
    this.selectionTarget,
    this.onCentralTap,
    this.onCentralMenu,
  });

  /// The mesh units (layer 1 and below); the board is [board].
  final List<TopologyNode> nodes;

  /// The board (layer 0), folded into the CENTRAL chip; null = not heard.
  final TopologyNode? board;

  /// Who is root, or that the mesh is still deciding.
  final RootElectionState election;

  /// A tap on a unit, with the chip's screen rect (the popover points at it).
  final void Function(TopologyNode node, Rect anchor) onNodeTap;

  /// Firmware push and rollout drawn on the map: the tablet and its cable,
  /// rings, the phase under each unit, the image's packets.
  final bool showOta;

  /// The firmware pill at the bottom right of every unit (and of the
  /// CENTRAL). Rede's strip switches it off for a cleaner map
  /// (`redeShowVersionsProvider`); "Atualizar dispositivos" always shows it.
  final bool showVersions;

  /// The radial picture (`_MeshLayout.balloon`, 2026-10-15): the mesh as
  /// clusters of dots around the hub, for a network too big to read as
  /// rows — Rede's switch. False: the tree.
  final bool radial;

  /// What is drawn on the units of an update; null = the board's own
  /// rollout ("Atualizar dispositivos" passes its run, which outlives the
  /// board's table).
  final OtaRolloutOverlay? overlay;

  /// Units chosen for an update: a ring and a check around the avatar.
  final Set<String> selected;

  /// The board (the CENTRAL) is chosen.
  final bool boardSelected;

  /// While an update runs, the units it does not touch are faded; null =
  /// nothing faded.
  final Set<String>? focus;

  /// Under a chosen unit: "v0.1.0 → [selectionTarget]"; null = its version.
  final String? selectionTarget;

  /// A tap on the CENTRAL chip; null = the chip is not tappable.
  final VoidCallback? onCentralTap;

  /// A tap on the CENTRAL chip with its screen rect (Rede: the Central's
  /// popover points at it). Wins over [onCentralTap] when both are given.
  final void Function(Rect anchor)? onCentralMenu;

  @override
  ConsumerState<MeshMap> createState() => _MeshMapState();
}

/// Pseudo-MAC of the central in the graph (top of the tree).
const _centralKey = '@central';

/// The tablet, beside the central while a firmware push runs: the image
/// goes from it to the board over the USB cable (protocol §13.3).
const _tabletKey = '@tablet';

/// `origin` of the packets of a firmware push (never a MAC).
const _otaOrigin = '@ota';

/// One crossing of the tablet–board link by a packet of a push.
const _otaHop = Duration(milliseconds: 900);

/// `origin` of the packets of a rollout (never a MAC): the image on its way
/// from the board to the unit that downloads it (protocol §13.4).
const _rolloutOrigin = '@rollout';

/// While a unit downloads, a packet leaves the board this often.
const _rolloutPacketEvery = Duration(milliseconds: 1500);

/// A packet leaving or reaching a unit spreads rings from it — a drop on
/// water, the radio's signal going out and being taken in — for this long,
/// in the packet's colour. Every packet, every unit, the central too.
const packetRippleMs = 900;

/// The map's zoom factor. The map is only ever translated and uniformly
/// scaled, so the x-axis entry IS the scale. Never read the "max scale on
/// axis" helper here: it also looks at the z axis, which reads 1.0 whenever
/// the map is zoomed OUT below 1:1 — the landscape opening view — and every
/// zoom, pan clamp and label position then computed with the wrong scale.
double _scaleOf(Matrix4 m) => m.storage[0];

/// Where a unit's link goes — and where a packet of it goes next.
///
/// A unit the central does not hear stays on the map (faded, OFFLINE) but
/// is never a hop: nothing it is said to relay can be true. So an ONLINE
/// unit whose registry parent is offline is linked to its nearest online
/// ancestor — or the central — as a *presumed* link (dashed, no dBm): its
/// frames do arrive, so they come some other way, and its next heartbeat
/// (every 15 s, with the parent it really has) replaces the guess. An
/// OFFLINE unit keeps its last known parent, drawn as a faint ghost line.
/// Null: no link at all (a parent the map does not know).
({String key, bool presumed})? meshLinkTargetOf(
  TopologyNode n,
  Map<String, TopologyNode> byMac,
  String? boardMac,
) {
  final p = n.parentMac;
  final parent = p == null ? null : byMac[p];
  if (parent == null) {
    return n.layer <= 1 || p == boardMac
        ? (key: _centralKey, presumed: false)
        : null;
  }
  if (!n.online || parent.online) return (key: parent.mac, presumed: false);
  var cursor = parent;
  var guard = 0;
  while (guard++ < 8) {
    final upMac = cursor.parentMac;
    final up = upMac == null ? null : byMac[upMac];
    if (up == null) return (key: _centralKey, presumed: true);
    if (up.online) return (key: up.mac, presumed: true);
    cursor = up;
  }
  return (key: _centralKey, presumed: true);
}

class _MeshMapState extends ConsumerState<MeshMap>
    with TickerProviderStateMixin {
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

  /// Chunks of a firmware push, turned into packets a few at a time.
  ProviderSubscription<int>? _otaSub;
  final _otaThrottle = OtaPacketThrottle(
    every: 8,
    minGap: const Duration(milliseconds: 700),
  );

  /// A rollout: the unit that downloads now, and the packets to it.
  ProviderSubscription<String?>? _rolloutSub;
  Timer? _rolloutTimer;
  String? _downloading;

  /// A change of the tree's shape (a node joined, left or moved layer)
  /// re-fits only once the shape has held still for this long, so a
  /// failover does not make the map jump on every intermediate state.
  /// A viewport change (rotation) still re-fits at once.
  static const _refitSettle = Duration(milliseconds: 1500);
  Timer? _refitTimer;

  /// The tree took a new shape (a unit joined, left, or changed parent):
  /// every unit slides from where it was to where the tree puts it now,
  /// in [_moveDuration], so the operator can follow who went where —
  /// links and ticks move with the chips, from the same layout. A unit
  /// new to the map appears in its place.
  static const _moveDuration = Duration(milliseconds: 450);
  late final AnimationController _move;
  _MeshLayout? _target;
  _MeshLayout? _from;

  /// The viewport [_target] was computed for: a change of it (rotation)
  /// re-places everything at once — the screen re-fits, nothing slides.
  Size? _targetViewport;

  @override
  void initState() {
    super.initState();
    // Continuous vsync clock: the painter derives dot positions and pulse
    // phases from wall time, so one controller animates everything.
    _ticker =
        AnimationController(vsync: this, duration: const Duration(days: 1))
          ..repeat();
    _move = AnimationController(vsync: this, duration: _moveDuration);
    _trafficSub = ref.read(safrTrafficProvider).stream.listen(_onTraffic);
    if (!widget.showOta) return;
    _otaSub = ref.listenManual<int>(
      otaPushViewProvider.select(otaChunksOnTheWay),
      (_, chunks) => _onOtaChunks(chunks),
    );
    final given = widget.overlay;
    if (given != null) {
      _onDownloading(given.downloading);
      return;
    }
    _rolloutSub = ref.listenManual<String?>(
      otaRolloutOverlayProvider.select((o) => o.downloading),
      (_, mac) => _onDownloading(mac),
      fireImmediately: true,
    );
  }

  @override
  void didUpdateWidget(MeshMap old) {
    super.didUpdateWidget(old);
    // Tree ↔ radial: the units slide to the other picture, and the
    // screen fits the whole of it once more.
    if (old.radial != widget.radial) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fitToView();
      });
    }
    final given = widget.overlay;
    if (widget.showOta && given != null && given.downloading != _downloading) {
      _onDownloading(given.downloading);
    }
  }

  @override
  void dispose() {
    _refitTimer?.cancel();
    _rolloutTimer?.cancel();
    _rolloutSub?.close();
    _trafficSub?.cancel();
    _otaSub?.close();
    _transform.dispose();
    _move.dispose();
    _ticker.dispose();
    super.dispose();
  }

  /// A new target for the units: starts the slide from wherever they are
  /// drawn right now (mid-slide included). The first layout, and the one
  /// after a rotation, are drawn as they are.
  void _retarget(_MeshLayout target, Size viewport) {
    final prev = _target;
    if (prev == null || viewport != _targetViewport) {
      _move.stop();
      _from = null;
      _target = target;
      _targetViewport = viewport;
      return;
    }
    if (!prev.samePlaces(target)) {
      _from = _shown(prev);
      _target = target;
      _move.forward(from: 0);
    }
  }

  /// What is written on the radial picture, decided in one pass for the
  /// whole map so that nothing ever lands on anything else: each unit's
  /// name (under its halo, else above it — true —, else nowhere), its
  /// firmware pill (bottom right of the halo, as on the tree) and the dBm
  /// pill on its link (at the middle of the line, as on the tree). In
  /// layer-then-MAC order (the hub first), names first, then the pills; a
  /// label is dropped when it would land on a halo or on a label already
  /// placed. All of them appear only once the zoom leaves room
  /// (`radialNameRoom`).
  ({Map<String, bool> names, Map<String, bool> versions, Set<String> dbm})
      _radialLabels(
    _MeshLayout layout,
    List<TopologyNode> nodes,
    String? boardMac, {
    required bool versions,
  }) {
    const nameW = 90.0, nameH = 13.0;
    const pillW = 48.0, pillH = 16.0;
    final byMac = {for (final n in nodes) n.mac: n};
    final halos = <String, Rect>{
      for (final n in nodes)
        if (layout.positions[n.mac] case final p?)
          n.mac: Rect.fromCircle(center: p, radius: radialHaloDiameter(n) / 2),
    };
    final sorted = [...nodes]..sort((a, b) {
        final c = a.layer.compareTo(b.layer);
        return c != 0 ? c : a.mac.compareTo(b.mac);
      });
    final taken = <Rect>[];
    bool clear(String mac, Rect rect, {Rect? own}) {
      if (taken.any((r) => !identical(r, own) && r.overlaps(rect))) {
        return false;
      }
      for (final e in halos.entries) {
        if (e.key != mac && e.value.overlaps(rect)) return false;
      }
      return true;
    }

    final names = <String, bool>{};
    final nameRects = <String, Rect>{};
    for (final n in sorted) {
      final at = layout.positions[n.mac];
      if (at == null) continue;
      final r = radialHaloDiameter(n) / 2;
      final below = Rect.fromCenter(
          center: Offset(at.dx, at.dy + r + radialNameGap + nameH / 2),
          width: nameW,
          height: nameH);
      final above = Rect.fromCenter(
          center: Offset(at.dx, at.dy - r - radialNameGap - nameH / 2),
          width: nameW,
          height: nameH);
      if (clear(n.mac, below)) {
        taken.add(below);
        names[n.mac] = false;
        nameRects[n.mac] = below;
      } else if (clear(n.mac, above)) {
        taken.add(above);
        names[n.mac] = true;
        nameRects[n.mac] = above;
      }
    }
    // The pill sits over the unit's bottom-right, as on the tree's
    // avatar, above the unit's own name (that name is not in its way);
    // mirrored to the bottom-left when a neighbour is in the way.
    final pills = <String, bool>{};
    if (versions) {
      for (final n in sorted) {
        final at = layout.positions[n.mac];
        if (at == null || n.fwVersion?.isNotEmpty != true) continue;
        final r = radialHaloDiameter(n) / 2;
        final top = at.dy + r + radialPillDy - pillH;
        final right = Rect.fromLTWH(at.dx + radialPillDx, top, pillW, pillH);
        final left =
            Rect.fromLTWH(at.dx - radialPillDx - pillW, top, pillW, pillH);
        if (clear(n.mac, right, own: nameRects[n.mac])) {
          taken.add(right);
          pills[n.mac] = false;
        } else if (clear(n.mac, left, own: nameRects[n.mac])) {
          taken.add(left);
          pills[n.mac] = true;
        }
      }
    }
    final dbm = <String>{};
    for (final n in sorted) {
      final at = layout.positions[n.mac];
      if (at == null || !n.online || n.rssi == null) continue;
      final target = meshLinkTargetOf(n, byMac, boardMac);
      if (target == null || target.presumed) continue;
      final to = layout.positions[target.key];
      if (to == null) continue;
      final rect = Rect.fromCenter(
          center: Offset.lerp(at, to, 0.5)!, width: pillW, height: pillH);
      // Its own halo and its parent's are the line's ends: not in the way.
      final blocked = taken.any((r) => r.overlaps(rect)) ||
          halos.entries.any((e) =>
              e.key != n.mac && e.key != target.key && e.value.overlaps(rect));
      if (!blocked) {
        taken.add(rect);
        dbm.add(n.mac);
      }
    }
    return (names: names, versions: pills, dbm: dbm);
  }

  /// The layout drawn this frame: [target] once the units are there, on
  /// their way to it meanwhile.
  _MeshLayout _shown(_MeshLayout target) {
    final from = _from;
    if (from == null || !_move.isAnimating) return target;
    return _MeshLayout.lerp(
        from, target, Curves.easeInOutCubic.transform(_move.value));
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

  /// The radial picture is dots and lines when small, so it goes much
  /// further out: the big picture is the point of it.
  static const _radialFitFloor = 0.1;

  /// Opening/"fit" scale: the whole canvas in the viewport when that stays
  /// readable, else the floor; never above 1:1.
  double get _fitScale {
    if (_viewSize.isEmpty || _canvasSize.isEmpty) return 1.0;
    final fit = math.min(_viewSize.width / _canvasSize.width,
        _viewSize.height / _canvasSize.height);
    return fit.clamp(widget.radial ? _radialFitFloor : _fitFloor, 1.0);
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
    final leafRoutine = tick.severity < 1 &&
        origin.isLeaf &&
        tick.direction == SafrTrafficDirection.uplink;
    // The tablet's ACK going back down is the cyan the unit's LED shows when
    // it arrives: worth a packet for any unit (walk test: blue up, cyan down).
    final ackDown = tick.ack && tick.direction == SafrTrafficDirection.downlink;
    // A COMMAND of the tablet (Identificar, Testar, Silenciar, Rearmar …)
    // going down to its unit, one packet per transmission, and the unit's
    // own ACK of it coming back up (safr_downlink_provider `deliveries`):
    // the operator sees the command reach the unit and the answer return.
    final commandDown = tick.msgType == SafrMsgType.command &&
        tick.direction == SafrTrafficDirection.downlink;
    final unitAckUp = tick.ack && tick.direction == SafrTrafficDirection.uplink;
    if (tick.severity < 1 &&
        !leafRoutine &&
        !ackDown &&
        !commandDown &&
        !unitAckUp) {
      return;
    }

    // Path from the device up to the central, following the links as the
    // map draws them (_linkTargetOf). The first hop is the parent the
    // frame itself named when it did (a leaf that just re-bound: the
    // registry still holds the old parent until this very frame is
    // stored); the rest follows the registry — never through a unit the
    // central does not hear: at the first dead hop the packet goes on to
    // the nearest live ancestor, else straight to the central.
    final boardMac = widget.board?.mac;
    final path = <String>[tick.mac];
    var cursor = origin;
    var named = tick.parentMac;
    var guard = 0;
    while (guard++ < 8) {
      final String? next;
      if (named != null && nodes[named]?.online == true) {
        next = named;
      } else {
        next = meshLinkTargetOf(cursor, nodes, boardMac)?.key;
      }
      named = null;
      if (next == null || next == _centralKey) break;
      final hop = nodes[next];
      if (hop == null || !hop.online) break;
      path.add(next);
      cursor = hop;
    }
    path.add(_centralKey);
    // A sleeping detector's command waits in its parent's mailbox for the
    // next wake (protocol §12.5): the packet stops at the parent.
    if (commandDown && origin.isLeaf && origin.sleeping && path.length > 2) {
      path.removeAt(0);
    }

    final color = switch (tick.severity) {
      3 => AppColors.error,
      1 => AppColors.trouble,
      _ => ackDown ? AppColors.ledCyan : AppColors.ledBlue,
    };
    // One wake = one packet: a unit that sends several frames in a burst
    // (name, topology, heartbeat after a bind; the outbox on reconnection)
    // shows one packet, which takes on the event colour if an event is in
    // the burst — the unit's LED shows one pulse too.
    final now = DateTime.now();
    final uplink = tick.direction == SafrTrafficDirection.uplink;
    for (final d in _dots) {
      if (d.origin == tick.mac &&
          d.uplink == uplink &&
          now.difference(d.startedAt).inMilliseconds < 1200) {
        if (tick.severity > d.severity) {
          d.color = color;
          d.severity = tick.severity;
        }
        // The burst's first frame may not name a parent (NAME_ANNOUNCE) while
        // a later one does (TOPOLOGY after a re-bind): re-route the packet
        // while it is still on its first hop, so it never rides the old line.
        final newPath = uplink ? path : path.reversed.toList();
        final onFirstHop = d.progress * (d.path.length - 1) < 1.0;
        if (tick.parentMac != null &&
            onFirstHop &&
            !_samePath(d.path, newPath)) {
          d.path = newPath;
          d.duration = Duration(
              milliseconds: (leafRoutine || origin.isLeaf ? 700 : 550) *
                  (newPath.length - 1));
        }
        return;
      }
    }

    _dots.add(_TrafficDot(
      origin: tick.mac,
      uplink: tick.direction == SafrTrafficDirection.uplink,
      severity: tick.severity,
      path: tick.direction == SafrTrafficDirection.uplink
          ? path
          : path.reversed.toList(),
      // Colours = the units' LED language (reference §3.7 row 7.7, §3.6.2):
      // red alarm · orange trouble · cyan = the tablet's ACK · blue = a
      // frame sent (heartbeat, test, name, command). No amber: an ALERT such
      // as the walk test is "blue then cyan" on the unit, so here too.
      color: color,
      startedAt: DateTime.now(),
      // A leaf's packet crosses each hop a little slower: one hop more than a
      // node (leaf → parent) and the eye should be able to follow it.
      duration:
          Duration(milliseconds: (leafRoutine ? 700 : 550) * (path.length - 1)),
    ));
    if (_dots.length > 40) _dots.removeRange(0, _dots.length - 40);
  }

  /// A firmware push: the board confirmed chunks. One blue packet goes from
  /// the tablet to the board (a frame sent) and one cyan packet comes back
  /// behind it (the board's ACK) — the LED language's colours, a few
  /// packets for many chunks. Only this link is ever drawn: no node and no
  /// leaf receives anything in a push.
  void _onOtaChunks(int chunks) {
    final now = DateTime.now();
    if (!_otaThrottle.take(chunks, now)) return;
    _dots
      ..add(_TrafficDot(
        origin: _otaOrigin,
        uplink: false,
        severity: 0,
        path: const [_tabletKey, _centralKey],
        color: AppColors.ledBlue,
        startedAt: now,
        duration: _otaHop,
        lane: -4,
      ))
      ..add(_TrafficDot(
        origin: _otaOrigin,
        uplink: true,
        severity: 0,
        path: const [_centralKey, _tabletKey],
        color: AppColors.ledCyan,
        startedAt: now.add(_otaHop),
        duration: _otaHop,
        lane: -4,
      ));
    if (_dots.length > 40) _dots.removeRange(0, _dots.length - 40);
  }

  /// A rollout: a unit started or stopped downloading. While it downloads,
  /// packets leave the board (the CENTRAL chip) and travel the tree to it.
  void _onDownloading(String? mac) {
    if (mac == _downloading) return;
    _downloading = mac;
    _rolloutTimer?.cancel();
    _rolloutTimer = null;
    if (mac == null) {
      _dots.removeWhere((d) => d.origin == _rolloutOrigin);
      return;
    }
    _sendRolloutPacket();
    _rolloutTimer =
        Timer.periodic(_rolloutPacketEvery, (_) => _sendRolloutPacket());
  }

  /// One blue packet (a frame sent, in the LED language's colours) from
  /// the central down the unit's parents to the unit.
  void _sendRolloutPacket() {
    final mac = _downloading;
    if (mac == null || !mounted) return;
    final path = otaDownloadPath(ref.read(topologyProvider), mac, _centralKey);
    if (path == null) return;
    _dots.add(_TrafficDot(
      origin: _rolloutOrigin,
      uplink: false,
      severity: 0,
      path: path,
      color: AppColors.ledBlue,
      startedAt: DateTime.now(),
      duration: Duration(milliseconds: 550 * (path.length - 1)),
      lane: -4,
    ));
    if (_dots.length > 40) _dots.removeRange(0, _dots.length - 40);
  }

  @override
  Widget build(BuildContext context) {
    // A unit this tablet never heard has no level or parent yet: the strip
    // counts it ("aguardando"), the tree places it with its first frame.
    final nodes = [
      for (final n in widget.nodes)
        if (!n.awaitingSignal) n
    ];
    final board = widget.board;
    final election = widget.election;
    final boardMac = board?.mac;
    // A rollout: what is drawn on every unit of it.
    final OtaRolloutOverlay rollout;
    if (!widget.showOta) {
      rollout = OtaRolloutOverlay.none;
    } else {
      rollout = widget.overlay ?? ref.watch(otaRolloutOverlayProvider);
    }
    final held = widget.showOta
        ? ref.watch(otaHeldOnBoardProvider)
        : const <SafrProductFamily, String>{};
    // A firmware push: what the board is doing with it, and what waits on
    // the board for the units (rebuilt once per percent, not per chunk).
    final activity = widget.showOta
        ? ref.watch(otaPushViewProvider.select(otaBoardActivity))
        : null;
    if (activity == null) _dots.removeWhere((d) => d.origin == _otaOrigin);

    // Commands on their way: a pill under the unit, rings when it confirms,
    // a check on the CENTRAL when the board takes it.
    final commands = ref.watch(deviceCommandProvider);
    final viewOnly = ref.watch(mirrorViewOnlyProvider);
    // A broadcast command (Rearmar from the alarm banner) every unit
    // confirmed: a cyan wave down the tree, once, from the moment the last
    // ACK came in.
    final allConfirmed = commands[safrBroadcastMac];
    final waveStartedAt =
        allConfirmed != null && allConfirmed.step == DeviceCommandStep.delivered
            ? allConfirmed.updatedAt
            : null;

    // The central alone is a map: a board the tablet hears (a brand-new
    // central, no unit installed yet) is drawn as the CENTRAL chip with
    // nothing under it — the Rede strip says "0 dispositivos". A push is
    // drawn on the central too, mesh or no mesh. Only with nothing at all
    // heard yet is the empty message shown (2026-10-26).
    if (nodes.isEmpty && activity == null && board == null) {
      return const _EmptyMesh();
    }
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      _viewSize = size;
      final target = widget.radial
          ? _MeshLayout.balloon(nodes, size, boardMac: boardMac)
          : _MeshLayout.compute(nodes, size, boardMac: boardMac);
      _retarget(target, size);
      _canvasSize = target.canvas;
      final key = (size, target.canvas);
      if (_fittedFor != key) {
        final viewportChanged = _fittedFor == null || _fittedFor!.$1 != size;
        _fittedFor = key;
        _refitTimer?.cancel();
        if (viewportChanged) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _fitToView());
        } else {
          _refitTimer = Timer(_refitSettle, () {
            if (mounted) _fitToView();
          });
        }
      }
      // Rebuilt on every frame of a slide (the chips, the links and the
      // ticks from one and the same layout); still between slides.
      return AnimatedBuilder(
          animation: _move,
          builder: (context, _) {
            final layout = _shown(target);
            final labels = layout.radial
                ? _radialLabels(layout, nodes, boardMac,
                    versions: widget.showVersions)
                : null;
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
                                      otaLink: activity != null,
                                      faded: _faded(nodes),
                                      waveStartedAt: waveStartedAt,
                                      transform: _transform,
                                      dbmShown: labels?.dbm ?? const {},
                                    ),
                                  ),
                                ),
                                if (activity != null)
                                  Positioned(
                                    left: layout.positions[_tabletKey]!.dx -
                                        OtaTabletChip.width / 2,
                                    top: layout.positions[_tabletKey]!.dy -
                                        OtaTabletChip.circle / 2,
                                    child: const OtaTabletChip(),
                                  ),
                                _CentralChip(
                                  position: layout.positions[_centralKey]!,
                                  board: board,
                                  activity: activity,
                                  showVersion: widget.showVersions,
                                  selected: widget.boardSelected,
                                  onTap: widget.onCentralTap,
                                  onMenu: widget.onCentralMenu,
                                ),
                                for (final node in nodes)
                                  if (layout.positions.containsKey(node.mac))
                                    if (layout.radial)
                                      _RadialChip(
                                        node: node,
                                        position: layout.positions[node.mac]!,
                                        isRoot: node.online &&
                                            node.mac == election.rootMac,
                                        isCandidate: election.electing &&
                                            election.candidates
                                                .contains(node.mac),
                                        transform: _transform,
                                        pitch: layout.pitch,
                                        nameAbove: labels?.names[node.mac],
                                        pillLeft: labels?.versions[node.mac],
                                        onTap: (anchor) =>
                                            widget.onNodeTap(node, anchor),
                                      )
                                    else
                                      _NodeChip(
                                        node: node,
                                        position: layout.positions[node.mac]!,
                                        isRoot: node.online &&
                                            node.mac == election.rootMac,
                                        isCandidate: election.electing &&
                                            election.candidates
                                                .contains(node.mac),
                                        activity: rollout[node.mac],
                                        pending: pendingFirmwareFor(node, held),
                                        showVersion: widget.showVersions,
                                        selected:
                                            widget.selected.contains(node.mac),
                                        faded: widget.focus != null &&
                                            !widget.focus!.contains(node.mac),
                                        selectionTarget: widget.selectionTarget,
                                        onTap: (anchor) =>
                                            widget.onNodeTap(node, anchor),
                                      ),
                                ..._commandMarks(
                                  commands,
                                  layout,
                                  nodes,
                                  viewOnly: viewOnly,
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
                // the rows' vertical position. The radial picture
                // has no rows.
                if (!layout.radial)
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
                // The numbers, at the bottom left on both pictures
                // (past the tree's label gutter).
                Positioned(
                  left: layout.radial ? 12 : 40,
                  bottom: 12,
                  child: MeshLegend(nodes: widget.nodes),
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
          });
    });
  }
}

extension on _MeshMapState {
  /// What a command in flight draws: the rings on the unit when it
  /// confirms (or red when nothing came back), the ticks under it, and the
  /// ticks under the CENTRAL for what it sent.
  List<Widget> _commandMarks(
    Map<String, DeviceCommandStatus> commands,
    _MeshLayout layout,
    List<TopologyNode> nodes, {
    required bool viewOnly,
  }) {
    if (commands.isEmpty) return const [];
    final marks = <Widget>[];
    final byMac = {for (final n in nodes) n.mac: n};
    DeviceCommandStatus? latestTaken;
    for (final s in commands.values) {
      // The Central's own ticks: the broadcast's while one runs, else the
      // latest command to one unit — never a unit's confirmation of the
      // broadcast (which comes later and would make the Central ✓✓ before
      // the last unit is in).
      final partOfBroadcast = s.mac != safrBroadcastMac &&
          commands[safrBroadcastMac]?.kind == s.kind;
      if (!s.kind.fromUnit &&
          !partOfBroadcast &&
          s.step != DeviceCommandStep.sending &&
          (latestTaken == null ||
              (latestTaken.mac != safrBroadcastMac &&
                  (s.mac == safrBroadcastMac ||
                      s.startedAt.isAfter(latestTaken.startedAt))))) {
        latestTaken = s;
      }
      final at = layout.positions[s.mac];
      if (at == null) continue;
      // The avatar: on the tree the model (46 px, the chip's top 26 above
      // the slot); on the radial picture the dot, centred on the slot.
      final unit = byMac[s.mac];
      final avatar =
          layout.radial && unit != null ? radialHaloDiameter(unit) : 46.0;
      final centre =
          layout.radial ? at : Offset(at.dx, at.dy - 26 + avatar / 2);
      final ripple = CommandRipple.extentFor(avatar);
      if (s.step == DeviceCommandStep.delivered ||
          s.step == DeviceCommandStep.answered ||
          s.step == DeviceCommandStep.failed) {
        marks.add(Positioned(
          key: ValueKey('cmd-ripple-${s.mac}-${s.step.name}-${s.startedAt}'),
          left: centre.dx - ripple / 2,
          top: centre.dy - ripple / 2,
          child:
              CommandRipple(color: commandStepColor(s.step), diameter: avatar),
        ));
      }
      final canRetry = s.step == DeviceCommandStep.failed &&
          (!viewOnly || s.kind == DeviceCommandKind.identify);
      final node = nodes.where((n) => n.mac == s.mac).firstOrNull;
      // The ticks sit beside the avatar, on the right, level with its
      // middle — as the Central's: never over the name, the version pill
      // at the bottom right, the OFFLINE tag at the top right, or a
      // neighbour (the row pitch leaves 35 px clear there).
      marks.add(Positioned(
        key: ValueKey('cmd-tag-${s.mac}'),
        left: at.dx + avatar / 2 + 3,
        top: centre.dy - 9,
        width: 22,
        child: Center(
          child: CommandTicks(
            status: s,
            size: 17,
            onRetry: canRetry
                ? () => ref.read(deviceCommandProvider.notifier).run(
                      s.mac,
                      s.kind,
                      waitsForWake: node?.sleeping ?? false,
                    )
                : null,
          ),
        ),
      ));
    }
    // The Central shows the same ticks for the latest command, as the
    // sender's side of a message: ✓ when the board took it, ✓✓ when the
    // unit confirmed it.
    final taken = latestTaken;
    final central = layout.positions[_centralKey];
    if (taken != null && central != null) {
      marks.add(Positioned(
        key: ValueKey('cmd-central-${taken.mac}'),
        // Beside the disc, on the right: the chip's own lines (CENTRAL,
        // MAC, dBm) stay clear.
        left: central.dx + _CentralChip._circle / 2 + 8,
        top: central.dy - 9,
        width: 40,
        child: Center(
          child: IgnorePointer(child: CommandTicks(status: taken, size: 17)),
        ),
      ));
    }
    return marks;
  }

  /// MACs drawn faded: outside the update that runs.
  Set<String> _faded(List<TopologyNode> nodes) {
    final focus = widget.focus;
    if (focus == null) return const {};
    return {
      for (final n in nodes)
        if (!focus.contains(n.mac)) n.mac,
    };
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

bool _samePath(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _TrafficDot {
  _TrafficDot({
    required this.origin,
    required this.uplink,
    required this.severity,
    required this.path,
    required this.color,
    required this.startedAt,
    required this.duration,
    this.lane = 0,
  });

  final String origin;
  final bool uplink;
  int severity;
  List<String> path;
  Color color;
  final DateTime startedAt;
  Duration duration;

  /// Pixels to the side of the line, to the left of the way it travels:
  /// packets that cross on one link each keep to their side.
  final double lane;

  int get _elapsedMs => DateTime.now().difference(startedAt).inMilliseconds;

  double get progress => _elapsedMs / duration.inMilliseconds;

  /// The departure ripple's phase (0..1), or null when it is over.
  double? get departureRipple {
    final t = _elapsedMs / packetRippleMs;
    return t >= 0 && t < 1 ? t : null;
  }

  /// The arrival ripple's phase (0..1), or null before and after it.
  double? get arrivalRipple {
    final t = (_elapsedMs - duration.inMilliseconds) / packetRippleMs;
    return t >= 0 && t < 1 ? t : null;
  }

  /// Travelled and rippled: nothing left to draw.
  bool get done => _elapsedMs > duration.inMilliseconds + packetRippleMs;
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
    this.otaLink = false,
    this.faded = const {},
    this.waveStartedAt,
    this.transform,
    this.dbmShown = const {},
  }) : super(repaint: repaint);

  /// The map's pan/zoom: on the radial picture the dBm pills are drawn
  /// only once the zoom leaves room for them (the names' rule).
  final TransformationController? transform;

  /// Radial: the units whose dBm pill has a clear place on its link
  /// (`_radialLabels`).
  final Set<String> dbmShown;

  bool get _labelRoom {
    if (!layout.radial) return true;
    final t = transform;
    return t == null || _scaleOf(t.value) * layout.pitch >= radialNameRoom;
  }

  /// Every unit confirmed a broadcast command: a cyan wave from the Central
  /// down the rows, each a little after the one above, for [_waveMs].
  final DateTime? waveStartedAt;
  static const _waveMs = 2200;
  static const _waveRowLagMs = 260;

  final List<TopologyNode> nodes;
  final _MeshLayout layout;
  final List<_TrafficDot> dots;
  final bool isDark;
  final String? boardMac;

  /// A firmware push runs: the USB cable between the tablet and the board
  /// is drawn, in the app's accent colour (it is a cable, not a radio link:
  /// no signal colour, no dBm).
  final bool otaLink;

  /// MACs whose link is drawn faded (outside the update that runs).
  final Set<String> faded;

  /// The settled root (pulse ring) and, while electing, the contenders
  /// (faster, fainter pulse; dashed link to the central).
  final String? rootMac;
  final Set<String> candidates;

  @override
  void paint(Canvas canvas, Size size) {
    final byMac = {for (final n in nodes) n.mac: n};
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    _paintGrid(canvas, size);

    // Links: curved, two-pass (glow + core). Where each one goes is
    // _linkTargetOf's: an online unit never hangs off a dead one.
    for (final n in nodes) {
      final from = layout.positions[n.mac];
      if (from == null) continue;
      final target = meshLinkTargetOf(n, byMac, boardMac);
      if (target == null) continue;
      final to = layout.positions[target.key];
      if (to == null) continue;

      final candidate = candidates.contains(n.mac);
      // Link colour = signal quality (system reference §3.6.2). A sleeping
      // leaf's link keeps its last dBm but wears the sleep colour: the reading
      // is from the last wake and the next one may come through any parent.
      final signal =
          n.sleeping ? sleepingLinkColor(isDark) : signalColor(n.rssi);
      final ghost = (isDark ? Colors.white : Colors.black)
          .withValues(alpha: n.stale ? 0.10 : 0.22);

      final path =
          layout.radial ? _straightPath(from, to) : _linkPath(from, to);
      // Outside the update that runs: the link fades with its unit.
      final fade = faded.contains(n.mac);
      if (fade) {
        canvas.saveLayer(
            null, Paint()..color = Colors.white.withValues(alpha: 0.32));
      }
      if (candidate) {
        // Contending for root: attached, but not yet the bridge.
        _drawDashedPath(
          canvas,
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3
            ..color = AppColors.warning.withValues(alpha: 0.7),
        );
      } else if (!n.online) {
        // Not heard: a ghost of where it hung, so the picture keeps its
        // shape — no colour to read, no dBm, nothing travels on it.
        _drawDashedPath(
          canvas,
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0
            ..color = ghost,
        );
      } else if (target.presumed) {
        // Its registry parent is dead and it is still heard: linked to the
        // nearest live unit above it until it says who its parent is now.
        _drawDashedPath(
          canvas,
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = signal.withValues(alpha: 0.5),
        );
      } else if (layout.radial) {
        // The radial picture's link: a thin line in the signal colour,
        // bright at the parent, fading toward the unit, a soft glow.
        final shader = ui.Gradient.linear(
          to,
          from,
          [signal.withValues(alpha: 0.85), signal.withValues(alpha: 0.28)],
        );
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4
            ..shader = shader
            ..color = signal.withValues(alpha: 0.08)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
        );
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.1
            ..shader = shader,
        );
      } else {
        // Glow pass
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5
            ..color = signal.withValues(alpha: 0.10)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
        );
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3
            ..color = signal.withValues(alpha: 0.55),
        );
      }

      // Link quality: the child's RSSI to this parent, printed on the line
      // in the link's colour — only for a link that is real and live (a
      // dead unit's reading is from before it went; a presumed link's was
      // to another parent). A sleeping leaf keeps its last value, in the
      // sleep colour.
      // The same pill on the radial picture — once there is room for it
      // and its place on the line is clear (text on every short link at
      // once is what made the first cut unreadable).
      if (n.online &&
          !target.presumed &&
          n.rssi != null &&
          (!layout.radial || (_labelRoom && dbmShown.contains(n.mac)))) {
        _linkLabel(canvas, path, '${n.rssi} dBm',
            candidate ? AppColors.warning : signal);
      }
      if (fade) canvas.restore();
    }

    if (otaLink) {
      final from = layout.positions[_tabletKey];
      final to = layout.positions[_centralKey];
      if (from != null && to != null) {
        canvas.drawPath(
          _linkPath(from, to),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..color = AppColors.secondary.withValues(alpha: 0.6),
        );
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
            (phase + 0.5) % 1.0, layout.radial ? 38 : 26);
      } else if (candidates.contains(n.mac)) {
        _pulse(canvas, layout.positions[n.mac],
            AppColors.warning.withValues(alpha: 0.6), fast, 22);
      }
    }

    // Everyone confirmed: the wave.
    final wave = waveStartedAt;
    if (wave != null) {
      final ms = nowMs - wave.millisecondsSinceEpoch;
      if (ms >= 0 && ms < _waveMs) {
        final t0 = ms / packetRippleMs;
        if (t0 < 1) {
          _ripple(canvas, layout.positions[_centralKey], AppColors.ledCyan, t0);
        }
        final rows = layout.laneCenters.keys.toList()..sort();
        for (var i = 0; i < rows.length; i++) {
          final t = (ms - (i + 1) * _waveRowLagMs) / packetRippleMs;
          if (t < 0 || t >= 1) continue;
          for (final n in nodes) {
            if (n.layer == rows[i]) {
              _ripple(canvas, layout.positions[n.mac], AppColors.ledCyan, t);
            }
          }
        }
      }
    }

    // Traveling packets: a small data packet (rounded body, two data stripes)
    // oriented along the line, with a soft glow and two fainter ghosts behind.
    // Where a packet leaves and where it lands, rings spread from the unit.
    dots.removeWhere((d) => d.done);
    for (final dot in dots) {
      final dep = dot.departureRipple;
      if (dep != null) {
        _ripple(canvas, layout.positions[dot.path.first], dot.color, dep);
      }
      final arr = dot.arrivalRipple;
      if (arr != null) {
        _ripple(canvas, layout.positions[dot.path.last], dot.color, arr);
      }
      for (var k = 2; k >= 0; k--) {
        final t = dot.progress - k * 0.03;
        if (t < 0 || t >= 1) continue;
        final tan = _tangentAlong(dot.path, t);
        if (tan == null) continue;
        // `lane` to the left of the heading (the canvas' y grows downward).
        final at = dot.lane == 0
            ? tan.position
            : tan.position + Offset(tan.vector.dy, -tan.vector.dx) * dot.lane;
        _drawPacket(canvas, at, tan.angle, dot.color,
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

  /// The radial picture's link: straight, hub to cluster to unit.
  Path _straightPath(Offset from, Offset to) => Path()
    ..moveTo(from.dx, from.dy)
    ..lineTo(to.dx, to.dy);

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
    canvas.drawLine(const Offset(3.6, -2.4), const Offset(3.6, 2.4),
        ink..strokeWidth = 1.4);
    canvas.drawLine(const Offset(-4.2, -1.2), const Offset(1.4, -1.2),
        ink..strokeWidth = 0.9);
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

  /// Rings spreading from a unit, like a drop on water: three, each a
  /// little behind the one before, thinning and fading as they widen.
  void _ripple(Canvas canvas, Offset? center, Color color, double t) {
    if (center == null) return;
    // A soft flash on the unit itself at the start.
    if (t < 0.4) {
      canvas.drawCircle(
        center,
        22,
        Paint()
          ..color = color.withValues(alpha: 0.18 * (1 - t / 0.4))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }
    for (final lag in const [0.0, 0.2, 0.4]) {
      final k = ((t - lag) / (1 - lag)).clamp(0.0, 1.0);
      if (k <= 0 || k >= 1) continue;
      final eased = Curves.easeOutCubic.transform(k);
      canvas.drawCircle(
        center,
        16 + eased * 34,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2 * (1 - k) + 0.5
          ..color = color.withValues(alpha: 0.65 * (1 - k)),
      );
    }
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

/// The tree the links draw, shared by both layouts: every unit under the
/// unit its link goes to (`meshLinkTargetOf` — a live unit under a dead
/// parent hangs off the nearest live ancestor, as its line does), the
/// roots and the strays under the central. Siblings in a fixed order
/// (layer, then MAC) so the picture holds still between frames; each
/// subtree's width in pitches (a unit without children takes one). Units
/// a stale registry puts in a loop among themselves are never reached
/// from the central: they go under it, and the loop is cut where it
/// closes.
class _MeshTree {
  _MeshTree._(this.children, this.width, this.rowOf, this.layerKeys);

  final Map<String, List<TopologyNode>> children;
  final Map<String, int> width;

  /// Layer → row (1 = the first under the central).
  final Map<int, int> rowOf;
  final List<int> layerKeys;

  int get total => width[_centralKey]!;

  static _MeshTree build(List<TopologyNode> nodes, String? boardMac) {
    final byMac = {for (final n in nodes) n.mac: n};
    final layerKeys = {for (final n in nodes) n.layer}.toList()..sort();
    final rowOf = {
      for (var i = 0; i < layerKeys.length; i++) layerKeys[i]: i + 1,
    };
    final children = <String, List<TopologyNode>>{};
    for (final n in nodes) {
      var target = meshLinkTargetOf(n, byMac, boardMac)?.key ?? _centralKey;
      if (target == n.mac) target = _centralKey;
      children.putIfAbsent(target, () => []).add(n);
    }
    for (final list in children.values) {
      list.sort((a, b) {
        final c = a.layer.compareTo(b.layer);
        return c != 0 ? c : a.mac.compareTo(b.mac);
      });
    }
    final width = <String, int>{};
    final reached = <String>{};
    int measure(String key) {
      var w = 0;
      for (final k in children[key] ?? const <TopologyNode>[]) {
        if (!reached.add(k.mac)) continue;
        w += measure(k.mac);
      }
      return width[key] = math.max(w, 1);
    }

    measure(_centralKey);
    for (final n in nodes) {
      if (reached.add(n.mac)) {
        children.putIfAbsent(_centralKey, () => []).add(n);
        measure(n.mac);
      }
    }
    var total = 0;
    for (final k in children[_centralKey] ?? const <TopologyNode>[]) {
      total += width[k.mac]!;
    }
    width[_centralKey] = math.max(total, 1);
    return _MeshTree._(children, width, rowOf, layerKeys);
  }
}

/// The size a unit's 3D model is drawn at on the radial map: a node a
/// little bigger than a detector.
double radialUnitSize(TopologyNode n) => n.isLeaf ? 30 : 36;

/// The glow round it, in the unit's status colour.
double radialHaloDiameter(TopologyNode n) => radialUnitSize(n) * 1.6;

/// Under this many pixels on screen a model cannot be read: the halo
/// keeps a bright core instead, until the zoom brings the model back.
const radialModelFrom = 14.0;

/// The name's distance from the halo's edge; the firmware pill's place:
/// the tree's — from [radialPillDx] right of the unit's centre, its
/// bottom [radialPillDy] under the halo's edge — or mirrored to the left
/// when a neighbour is in the way on the right.
const radialNameGap = 3.0;
const radialPillDx = 8.0;
const radialPillDy = 2.0;

/// The key of a unit's dot on the radial map (tests).
Key radialChipKey(String mac) => ValueKey('radial-$mac');

/// The room between neighbouring units, on screen, from which the radial
/// map shows their names (and the dBm on the links): zoom in and they
/// come, zoom out and the picture is dots and lines.
const radialNameRoom = 40.0;

/// Where every node sits on the canvas, plus the lanes the painter labels.
///
/// Two pictures of the same tree (`_MeshTree`):
///
/// **Tree** ([compute]): top → bottom, central row on top, one row per
/// layer, rotated labels in a left gutter. Across, it is a tidy tree
/// (2026-10-15): every unit under the unit its link is drawn to, its
/// children side by side beneath it, each subtree in its own span of the
/// width, so no link ever crosses another and a unit that changes parent
/// moves next to the new one.
///
/// **Radial** ([balloon], 2026-10-15, for a mesh too big to read as rows):
/// a balloon tree — every unit's children sit on a small circle around it,
/// each subtree inside its own circle, the circles of siblings side by
/// side on their parent's ring. The mesh root is the hub, with the CENTRAL
/// beside it (every frame goes through the root anyway); with no single
/// root the central is the hub. Links are short and local, clusters are
/// visible at a glance, and nothing crosses: sibling circles are disjoint,
/// a parent's link enters its child's circle through a slot kept free of
/// grandchildren. Concentric rings by layer were tried on paper and
/// dropped: with one root owning the whole circle its links cut straight
/// through the hub.
///
/// The canvas is at least the viewport and grows when the picture needs
/// more; the screen then zooms out to fit it rather than changing it.
class _MeshLayout {
  const _MeshLayout({
    required this.positions,
    required this.centralLane,
    required this.laneCenters,
    required this.canvas,
    this.radial = false,
    this.pitch = 116,
  });

  final Map<String, Offset> positions;

  /// y of the central row (tree).
  final double centralLane;

  /// y of each mesh layer's row (tree); the layers alone (radial).
  final Map<int, double> laneCenters;

  /// Canvas size the chips and painter are laid out in (≥ viewport).
  final Size canvas;

  /// The balloon picture: no lanes, straight links, dots for units.
  final bool radial;

  /// The least distance between two neighbouring units, in canvas pixels
  /// (names are shown when `scale × pitch` leaves room on screen).
  final double pitch;

  // Chip footprint: node chip 104 × ~62, central chip 120 × ~95.
  // The same margin on both sides keeps the tree centred; the left one
  // also hosts the rotated lane labels.
  static const _gutter = 36.0;
  static const _edge = 12.0;
  static const _minAcross = 116.0; // node pitch along a row
  static const _minLane = 104.0; // row pitch
  static const _tabletAside = 112.0; // tablet ↔ central, centre to centre

  static _MeshLayout compute(List<TopologyNode> nodes, Size viewport,
      {String? boardMac}) {
    final tree = _MeshTree.build(nodes, boardMac);
    final total = tree.total;
    final laneCount = tree.layerKeys.length + 1; // + central row

    // A pitch per leaf of the tree, never under _minAcross: two units of
    // one row are in different spans, so they are at least a pitch apart.
    final canvasW = math.max(viewport.width, 2 * _gutter + total * _minAcross);
    final height = math.max(viewport.height, 2 * _edge + laneCount * _minLane);
    final rowH = (height - 2 * _edge) / laneCount;
    final usableW = canvasW - 2 * _gutter;
    final pitch = usableW / total;
    double laneY(int i) => _edge + rowH * (i + 0.52);

    // Every unit in the middle of its subtree's span, its children's
    // spans laid side by side under it, in its own layer's row (a unit
    // linked past a dead parent keeps its row: its line goes up through
    // the column its subtree owns, crossing nobody).
    final positions = <String, Offset>{};
    void place(String key, double from, int row) {
      final w = tree.width[key]!;
      positions[key] = Offset(_gutter + pitch * (from + w / 2), laneY(row));
      var cursor = from;
      for (final k in tree.children[key] ?? const <TopologyNode>[]) {
        if (positions.containsKey(k.mac)) continue; // the loop, cut
        place(k.mac, cursor, tree.rowOf[k.layer]!);
        cursor += tree.width[k.mac]!;
      }
    }

    place(_centralKey, 0, 0);
    // Beside the central, on its row, away from the lane labels; drawn
    // only while a push runs.
    positions[_tabletKey] =
        Offset(positions[_centralKey]!.dx + _tabletAside, laneY(0));

    return _MeshLayout(
      positions: positions,
      centralLane: laneY(0),
      laneCenters: {for (final l in tree.layerKeys) l: laneY(tree.rowOf[l]!)},
      canvas: Size(canvasW, height),
      pitch: pitch,
    );
  }

  // The balloon picture's measures (canvas pixels).
  static const _ballMinRing = 96.0; // a unit's children, at least this far
  static const _ballGap = 16.0; // between neighbouring circles
  static const _ballCentralR = 62.0; // the CENTRAL chip's own circle
  static const _ballCentralAt = 140.0; // hub ↔ central, centre to centre
  static const _ballMargin = 80.0; // round the picture (names, the chip)
  // A small network is spread to use the screen, up to this much.
  static const _ballGrowMax = 2.0;

  /// A unit alone: its halo and a little air.
  static double _ballUnitR(TopologyNode n) => radialHaloDiameter(n) / 2 + 8;

  /// The turn from one circle on a ring of radius [r] to the next, when
  /// the two touch across [_ballGap] (a chord, not an arc: exact).
  static double _step(double a, double b, double r) =>
      2 * math.asin(math.min(1.0, (a + b + _ballGap) / (2 * r)));

  /// The smallest ring on which circles of [radii] sit side by side, in
  /// that order and round the whole turn: each two neighbours apart by
  /// their radii, the turns adding up to one. Measured on chords, so big
  /// circles next to each other get the ring they need.
  static double _ringFor(List<double> radii) {
    var widestPair = 0.0;
    for (var i = 0; i < radii.length; i++) {
      final j = (i + 1) % radii.length;
      widestPair = math.max(widestPair, radii[i] + radii[j] + _ballGap);
    }
    var r = math.max(_ballMinRing, widestPair / 2);
    if (radii.length < 2) return r;
    for (var guard = 0; guard < 80; guard++) {
      var turn = 0.0;
      for (var i = 0; i < radii.length; i++) {
        turn += _step(radii[i], radii[(i + 1) % radii.length], r);
      }
      if (turn <= 2 * math.pi) return r;
      r *= 1.05;
    }
    return r;
  }

  static _MeshLayout balloon(List<TopologyNode> nodes, Size viewport,
      {String? boardMac}) {
    final tree = _MeshTree.build(nodes, boardMac);
    final byMac = {for (final n in nodes) n.mac: n};
    final hubChildren = tree.children[_centralKey] ?? const <TopologyNode>[];
    // One unit under the central (the mesh root): it is the hub and the
    // central sits beside it. Else the central is the hub.
    final hub = hubChildren.length == 1 ? hubChildren.first.mac : _centralKey;

    // Bottom-up: the ring a unit's children sit on, and the circle that
    // holds its whole subtree. On the ring, side by side: one slot
    // ([slot]) kept free for the link from its own parent — the central's
    // chip, for the hub — then the children's circles.
    final ring = <String, double>{};
    final circle = <String, double>{};
    final slots = <String, double>{};
    double measure(String key, double slot) {
      final kids = tree.children[key] ?? const <TopologyNode>[];
      final own = key == _centralKey ? _ballCentralR : _ballUnitR(byMac[key]!);
      slots[key] = slot;
      if (kids.isEmpty) {
        ring[key] = 0;
        return circle[key] = own;
      }
      final radii = <double>[if (slot > 0) slot];
      var widest = 0.0;
      for (final k in kids) {
        if (circle.containsKey(k.mac)) continue; // the loop, cut
        final r = measure(k.mac, _ballUnitR(k));
        radii.add(r);
        widest = math.max(widest, r);
      }
      final rr = _ringFor(radii);
      ring[key] = rr;
      return circle[key] = rr + widest;
    }

    measure(hub, hub == _centralKey ? 0 : _ballCentralR);

    // Top-down: the slot opposite the direction away from the parent
    // (where its link comes in), the children after it round the ring,
    // each the exact turn from the one before, the spare turn split on
    // both sides of the slot so the cluster faces away.
    final positions = <String, Offset>{};
    void place(String key, Offset at, double away) {
      positions[key] = at;
      final kids = [
        for (final k in tree.children[key] ?? const <TopologyNode>[])
          if (!positions.containsKey(k.mac)) k,
      ];
      if (kids.isEmpty) return;
      final rr = ring[key]!;
      final slot = slots[key]!;
      final radii = [
        if (slot > 0) slot,
        for (final k in kids) circle[k.mac]!,
      ];
      final steps = [
        for (var i = 0; i < radii.length; i++)
          _step(radii[i], radii[(i + 1) % radii.length], rr),
      ];
      final spare = 2 * math.pi - steps.fold(0.0, (s, x) => s + x);
      double a;
      if (slot > 0) {
        a = away + math.pi + steps[0] + spare / 2;
        for (var i = 0; i < kids.length; i++) {
          final k = kids[i];
          place(k.mac, at + Offset(math.cos(a), math.sin(a)) * rr, a);
          a += steps[i + 1];
        }
      } else {
        // No slot (the central as hub): the children centred on [away].
        var span = 0.0;
        for (var i = 0; i < kids.length - 1; i++) {
          span += steps[i];
        }
        a = away - span / 2;
        for (var i = 0; i < kids.length; i++) {
          final k = kids[i];
          place(k.mac, at + Offset(math.cos(a), math.sin(a)) * rr, a);
          a += steps[i];
        }
      }
    }

    place(hub, Offset.zero, math.pi / 2);
    if (hub != _centralKey) {
      // The central above the hub, in the slot its children keep free.
      positions[_centralKey] = const Offset(0, -_ballCentralAt);
    }
    // Units a loop kept out of the hub's tree (never from the central):
    // under the central, in a ring of their own.
    for (final n in nodes) {
      if (!positions.containsKey(n.mac)) {
        final rr =
            math.max(circle[_centralKey] ?? 0, _ballCentralR) + _ballMinRing;
        final i = positions.length;
        positions[n.mac] = positions[_centralKey]! +
            Offset(math.cos(i * 0.7), math.sin(i * 0.7)) * rr;
      }
    }

    // The canvas round the picture: at least the viewport, the picture
    // centred in it. A picture smaller than the screen is spread to use
    // it (the models keep their size; the names get their room).
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final p in positions.values) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    final grow = math.min(
      _ballGrowMax,
      math.min(
        (viewport.width - 2 * _ballMargin) / math.max(1, maxX - minX),
        (viewport.height - 2 * _ballMargin) / math.max(1, maxY - minY),
      ),
    );
    if (grow > 1) {
      positions.updateAll((_, p) => p * grow);
      minX *= grow;
      maxX *= grow;
      minY *= grow;
      maxY *= grow;
    }
    final w = math.max(viewport.width, maxX - minX + 2 * _ballMargin);
    final h = math.max(viewport.height, maxY - minY + 2 * _ballMargin);
    final shift = Offset(
      w / 2 - (minX + maxX) / 2,
      h / 2 - (minY + maxY) / 2,
    );
    final placed = {for (final e in positions.entries) e.key: e.value + shift};
    placed[_tabletKey] = placed[_centralKey]! + const Offset(_tabletAside, 0);

    // The least distance between two units: how much room the names have.
    var pitch = double.infinity;
    final units = [
      for (final n in nodes)
        if (placed[n.mac] case final p?) p,
    ];
    for (var i = 0; i < units.length; i++) {
      for (var j = i + 1; j < units.length; j++) {
        pitch = math.min(pitch, (units[i] - units[j]).distance);
      }
    }
    if (!pitch.isFinite) pitch = 2 * _ballMinRing;

    return _MeshLayout(
      positions: placed,
      centralLane: placed[_centralKey]!.dy,
      laneCenters: {for (final l in tree.layerKeys) l: 0},
      canvas: Size(w, h),
      radial: true,
      pitch: pitch,
    );
  }

  /// True when every unit (and the central) sits where it does in [other].
  bool samePlaces(_MeshLayout other) {
    if (positions.length != other.positions.length) return false;
    for (final e in positions.entries) {
      if (other.positions[e.key] != e.value) return false;
    }
    return true;
  }

  /// The picture [t] of the way from [a] to [b]: every unit on the way to
  /// its new place; a unit new to the map already there. The canvas and
  /// the lanes are [b]'s (they are what the screen fits to).
  static _MeshLayout lerp(_MeshLayout a, _MeshLayout b, double t) {
    return _MeshLayout(
      positions: {
        for (final e in b.positions.entries)
          e.key: a.positions[e.key] == null
              ? e.value
              : Offset.lerp(a.positions[e.key], e.value, t)!,
      },
      centralLane: b.centralLane,
      laneCenters: b.laneCenters,
      canvas: b.canvas,
      radial: b.radial,
      pitch: b.pitch,
    );
  }
}

// ── Chips ────────────────────────────────────────────────────────────────────

class _CentralChip extends StatelessWidget {
  const _CentralChip({
    required this.position,
    this.board,
    this.activity,
    this.showVersion = true,
    this.selected = false,
    this.onTap,
    this.onMenu,
  });
  final Offset position;
  final TopologyNode? board;

  /// The firmware pill under the disc (off: Rede's switch).
  final bool showVersion;

  /// Chosen for an update: ring and check around the disc.
  final bool selected;
  final VoidCallback? onTap;

  /// A tap with the chip's rect, for a popover that points at it.
  final void Function(Rect anchor)? onMenu;

  /// A firmware push runs: what the board is doing with it. The avatar
  /// then shows the board (the tablet is drawn beside it), a progress ring
  /// goes around it and the caption says the phase. The LED lens on top is
  /// untouched: it is the board's LED, the ring is not.
  final OtaBoardActivity? activity;

  static const _width = 120.0;
  static const _circle = 54.0;

  Widget _disc() {
    return Container(
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
      child: Icon(
        activity == null
            ? Icons.tablet_mac_rounded
            : Icons.developer_board_rounded,
        color: Colors.white,
        size: 24,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tap = onTap;
    final chip = SizedBox(
      width: _CentralChip._width,
      child: Column(
        children: [
          // The board's LED (magenta flash, a blue pulse per relayed
          // frame) as a small lens at the top of the CENTRAL circle.
          Stack(
            clipBehavior: Clip.none,
            children: [
              if (selected) const _SelectionRing(diameter: _circle),
              _disc(),
              if (selected) const _SelectionCheck(),
              if (activity != null)
                Positioned(
                  left: (_CentralChip._circle -
                          OtaProgressRing.sizeFor(_CentralChip._circle)) /
                      2,
                  top: (_CentralChip._circle -
                          OtaProgressRing.sizeFor(_CentralChip._circle)) /
                      2,
                  child: OtaProgressRing(
                    activity: activity!,
                    diameter: _CentralChip._circle,
                  ),
                ),
              if (board != null)
                Positioned(
                  top: -3,
                  left: (_CentralChip._circle - 11) / 2,
                  child: DeviceLedDot(node: board!, size: 11),
                ),
              // The firmware the board runs: the same pill, in the same
              // place, as on every unit — bottom right of the disc. (Its
              // MAC and the rest are in its popover.)
              if (showVersion &&
                  activity == null &&
                  board?.fwVersion?.isNotEmpty == true)
                Positioned(
                  left: _CentralChip._circle / 2 + 8,
                  bottom: -5,
                  child: FirmwareTag(version: board!.fwVersion),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (activity != null)
            OtaBoardCaption(activity: activity!)
          else
            Text(
              'CENTRAL',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.0,
              ),
            ),
        ],
      ),
    );
    return Positioned(
      left: position.dx - _CentralChip._width / 2,
      top: position.dy - _CentralChip._circle / 2,
      child: onMenu != null
          ? Semantics(
              button: true,
              label: 'Central (placa)',
              child: Builder(
                builder: (chipContext) => _ArenaFreeTap(
                  onTap: () => onMenu!(deviceAnchorOf(chipContext)),
                  child: chip,
                ),
              ),
            )
          : tap == null
              ? chip
              : Semantics(
                  button: true,
                  label: 'Central (placa)',
                  child: _ArenaFreeTap(onTap: tap, child: chip),
                ),
    );
  }
}

/// The ring around a unit chosen for an update.
class _SelectionRing extends StatelessWidget {
  const _SelectionRing({required this.diameter});
  final double diameter;

  @override
  Widget build(BuildContext context) => Positioned(
        left: -6,
        top: -6,
        child: Container(
          key: const ValueKey('update-selected'),
          width: diameter + 12,
          height: diameter + 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.secondary, width: 2),
            boxShadow: [
              BoxShadow(
                color: AppColors.secondary.withValues(alpha: 0.45),
                blurRadius: 14,
              ),
            ],
          ),
        ),
      );
}

/// The check on a unit chosen for an update (top left: the LED is on top,
/// ROOT / ALARME at the bottom).
class _SelectionCheck extends StatelessWidget {
  const _SelectionCheck();

  @override
  Widget build(BuildContext context) => Positioned(
        left: -8,
        top: -6,
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: AppColors.secondary,
            shape: BoxShape.circle,
            border: Border.all(color: context.bgColor, width: 1.8),
          ),
          child: Icon(Icons.check_rounded, size: 12, color: context.bgColor),
        ),
      );
}

class _NodeChip extends StatelessWidget {
  const _NodeChip({
    required this.node,
    required this.position,
    required this.isRoot,
    required this.isCandidate,
    required this.onTap,
    this.pending,
    this.activity,
    this.showVersion = true,
    this.selected = false,
    this.faded = false,
    this.selectionTarget,
  });

  final TopologyNode node;
  final Offset position;

  /// Chosen for an update: ring and check, and "→ [selectionTarget]"
  /// under the name (the pill keeps saying what it runs).
  final bool selected;
  final String? selectionTarget;

  /// The firmware pill at the bottom right (off: Rede's switch).
  final bool showVersion;

  /// Outside the update that runs: drawn faded.
  final bool faded;

  /// A rollout has this unit in it: a progress ring goes around the avatar
  /// while it is being updated and the line under its name says where it
  /// is. The LED lens on top is untouched: it is the unit's LED, the ring
  /// is not.
  final OtaUnitActivity? activity;

  /// The version of an image of this unit's family that is stored on the
  /// board and was not delivered; null = none.
  final String? pending;

  /// Decided by root_election_provider, not by the unit's own claim: the
  /// ROOT badge goes to the settled root only; while the mesh is still
  /// choosing, the contenders wear CANDIDATO instead.
  final bool isRoot;
  final bool isCandidate;

  /// Called with the chip's screen rect: the device popover points at it.
  final ValueChanged<Rect> onTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: position.dx - 52,
      top: position.dy - 26,
      child: Opacity(
        opacity: node.stale || faded ? deviceStaleOpacity : 1.0,
        child: Builder(
          builder: (chipContext) => _ArenaFreeTap(
            onTap: () => onTap(deviceAnchorOf(chipContext)),
            child: SizedBox(
              width: 104,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      if (selected) const _SelectionRing(diameter: 46),
                      // Its product's 3D model, standing still (as on
                      // Dispositivo); the circle when it has none or while
                      // the model loads.
                      DeviceModelAvatar(
                        node: node,
                        isRoot: isRoot,
                        isCandidate: isCandidate,
                        size: 46,
                      ),
                      if (!node.online)
                        const Positioned(
                          right: -24,
                          top: -8,
                          child: DeviceOfflineBadge(),
                        ),
                      if (selected) const _SelectionCheck(),
                      if (activity?.updating == true)
                        Positioned(
                          left: (46 - OtaProgressRing.sizeFor(46)) / 2,
                          top: (46 - OtaProgressRing.sizeFor(46)) / 2,
                          child: OtaUnitRing(activity: activity!, diameter: 46),
                        ),
                      // The firmware it runs, and whether another waits on
                      // the board, as a pill at the bottom right of the
                      // avatar (ALARME is at the bottom left, ROOT on top,
                      // the ticks on the right, OFFLINE top right: nothing
                      // shares a corner). Nothing when the unit never said
                      // its version, or when Rede's switch is off. In a
                      // rollout the line under the name says it instead.
                      if (showVersion && activity == null)
                        Positioned(
                          left: 46 / 2 + 8,
                          bottom: -5,
                          child: FirmwareTag(
                              version: node.fwVersion, pending: pending),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Identification: the device's name when set, otherwise the
                  // full MAC address — never a truncated fragment. The name
                  // is the only line under the unit.
                  Text(
                    node.name?.isNotEmpty == true ? node.name! : node.mac,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: node.name?.isNotEmpty == true
                          ? context.textPrimary
                          : context.textSecondary,
                      fontSize: node.name?.isNotEmpty == true ? 11 : 8.5,
                      fontWeight: FontWeight.w700,
                      fontFamily:
                          node.name?.isNotEmpty == true ? null : 'monospace',
                      letterSpacing: node.name?.isNotEmpty == true ? 0 : -0.2,
                    ),
                  ),
                  // In a rollout: where the unit is in it. Chosen for one:
                  // what it will run (the pill says what it runs now).
                  if (activity != null)
                    OtaUnitTag(activity: activity!, version: node.fwVersion)
                  else if (selected && selectionTarget != null)
                    Text(
                      '→ ${firmwareTagText(selectionTarget!)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.secondary,
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A unit on the radial map (2026-10-15): its 3D model on a flat disc in
/// its status colour (`radialStatusOf`: alarm red, attention amber,
/// sleeping grey, active green — a crisp disc, no glow: the tree draws no
/// shadow either), the LED on the model's own LED marker as everywhere
/// else, the ROOT / CANDIDATO / ALARME badges and the moon as the model
/// draws them, and OFFLINE as the tree's label at the top right over the
/// faded model (no disc then). Zoomed out, under [radialModelFrom] px on
/// screen, the disc alone with a bright core — the same disc, so nothing
/// jumps. The name (and the firmware, as the tree's pill at the bottom
/// right) only once the zoom leaves room and the place is clear
/// ([nameAbove], [pillLeft]: decided for the whole map in one pass,
/// `_radialLabels`). A tap opens the same popover as on the tree.
class _RadialChip extends StatelessWidget {
  const _RadialChip({
    required this.node,
    required this.position,
    required this.isRoot,
    required this.isCandidate,
    required this.transform,
    required this.pitch,
    required this.nameAbove,
    required this.onTap,
    this.pillLeft,
  });

  final TopologyNode node;
  final Offset position;
  final bool isRoot;
  final bool isCandidate;
  final TransformationController transform;
  final double pitch;

  /// The name under the halo (false), above it (true) or nowhere (null).
  final bool? nameAbove;

  /// The firmware pill at the bottom right (false), mirrored to the
  /// bottom left (true) or nowhere (null: the switch off, or no place).
  final bool? pillLeft;
  final ValueChanged<Rect> onTap;

  @override
  Widget build(BuildContext context) {
    final size = radialUnitSize(node);
    final halo = radialHaloDiameter(node);
    final status = radialStatusOf(node);
    final color = radialStatusColor(status, isDark: context.isDark);
    final offline = status == RadialStatus.offline;
    final loud = status == RadialStatus.alarm;
    const label = 96.0;
    final name = deviceDisplayName(node);
    return Positioned(
      left: position.dx - halo / 2,
      top: position.dy - halo / 2,
      child: Builder(
        builder: (chipContext) => _ArenaFreeTap(
          onTap: () => onTap(deviceAnchorOf(chipContext)),
          child: SizedBox(
            width: halo,
            height: halo,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // The disc: the status as a flat colour round the unit;
                // nothing for a unit that is gone (the label says it).
                Container(
                  key: radialChipKey(node.mac),
                  width: halo,
                  height: halo,
                  decoration: offline
                      ? null
                      : BoxDecoration(
                          shape: BoxShape.circle,
                          color: color.withValues(alpha: loud ? 0.34 : 0.18),
                          border: Border.all(
                            color: color.withValues(alpha: loud ? 0.9 : 0.6),
                            width: loud ? 1.6 : 1.1,
                          ),
                        ),
                ),
                Positioned(
                  left: (halo - size) / 2,
                  top: (halo - size) / 2,
                  child: ValueListenableBuilder<Matrix4>(
                    valueListenable: transform,
                    builder: (_, m, __) {
                      if (_scaleOf(m) * size < radialModelFrom) {
                        // Too small for a model to read: the disc's core.
                        return Container(
                          width: size,
                          height: size,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: offline
                                ? context.surfaceColor
                                : Color.lerp(color, Colors.white, 0.2),
                            border: Border.all(
                              color: offline
                                  ? color
                                  : Color.lerp(color, Colors.white, 0.5)!,
                              width: 1.2,
                            ),
                          ),
                        );
                      }
                      return DeviceModelAvatar(
                        node: node,
                        isRoot: isRoot,
                        isCandidate: isCandidate,
                        size: size,
                      );
                    },
                  ),
                ),
                if (offline)
                  const Positioned(
                    right: -22,
                    top: -6,
                    child: DeviceOfflineBadge(),
                  ),
                if (nameAbove != null)
                  Positioned(
                    left: (halo - label) / 2,
                    top: nameAbove! ? null : halo + radialNameGap - 2,
                    bottom: nameAbove! ? halo + radialNameGap - 2 : null,
                    width: label,
                    child: ValueListenableBuilder<Matrix4>(
                      valueListenable: transform,
                      builder: (_, m, __) {
                        if (_scaleOf(m) * pitch < radialNameRoom) {
                          return const SizedBox.shrink();
                        }
                        return Text(
                          name,
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: node.name?.isNotEmpty == true
                                ? context.textPrimary
                                : context.textSecondary,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            fontFamily: node.name?.isNotEmpty == true
                                ? null
                                : 'monospace',
                          ),
                        );
                      },
                    ),
                  ),
                // The firmware it runs: the tree's pill, in the tree's
                // place (bottom right), once the zoom leaves room.
                if (pillLeft != null)
                  Positioned(
                    left: pillLeft! ? null : halo / 2 + radialPillDx,
                    right: pillLeft! ? halo / 2 + radialPillDx : null,
                    top: halo + radialPillDy - FirmwareTag.height,
                    child: ValueListenableBuilder<Matrix4>(
                      valueListenable: transform,
                      builder: (_, m, __) =>
                          _scaleOf(m) * pitch < radialNameRoom
                              ? const SizedBox.shrink()
                              : FirmwareTag(version: node.fwVersion),
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
            'A central e a rede aparecerão aqui assim que a placa\ncomeçar a reportar pela serial.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.textSecondary, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}
