import 'dart:math' as math;

import '../../../application/topology_provider.dart';
import 'network_3d_math.dart';

/// Key of the CENTRAL chip (tablet + board).
const graphCentralKey = '@central';

/// How the tree's levels are laid out.
///  * [vertical]: top → bottom, like the Rede map (CENTRAL on top).
///  * [wide]: left → right — the network extending sideways.
enum GraphAxis { vertical, wide }

/// A force-directed 3D graph of the mesh, like Obsidian's graph view:
/// devices repel each other, every link is a spring, and each device is
/// held at its level (the Rede map's rows) along the chosen [GraphAxis].
/// A device can be dragged; the rest reacts and settles again.
///
/// World units are chip pixels at scale 1 (a chip is 104 wide), so keeping
/// devices [minGap] apart keeps their chips from overlapping on screen.
class ForceGraph3d {
  ForceGraph3d({this.axis = GraphAxis.vertical});

  GraphAxis axis;

  final pos = <String, Vec3>{};
  final _vel = <String, Vec3>{};

  /// Device → the key its link goes to (a MAC or [graphCentralKey]); same
  /// rule as the Rede map. Missing = no link (unknown parent).
  Map<String, String> parentOf = const {};

  /// Device → level index (0 = CENTRAL, then one per mesh layer in order).
  Map<String, int> level = const {graphCentralKey: 0};

  /// Level index → mesh layer (for the lane labels).
  Map<int, int> layerOfLevel = const {0: 0};

  /// The device being dragged: follows the finger, not the forces.
  String? dragged;

  /// Simulation heat (d3-style): forces scale with it and it cools down, so
  /// the graph settles and stops moving. Reheated by drags and changes.
  double alpha = 1;

  /// Row pitch: chips are wider than tall, so levels side by side (wide
  /// view) need more room than levels stacked (tree view).
  double get levelGap => axis == GraphAxis.vertical ? 190.0 : 300.0;
  static const linkLength = 170.0;
  static const minGap = 2 * chipRx; // seeding pitch along a level

  int get levels => layerOfLevel.length;

  /// Where a level sits along the axis, centred on the graph.
  double levelCoord(int lvl) {
    final mid = (levels - 1) / 2;
    return axis == GraphAxis.vertical
        ? -(lvl - mid) * levelGap // top → bottom
        : (lvl - mid) * levelGap; // left → right
  }

  double _axisOf(Vec3 p) => axis == GraphAxis.vertical ? p.y : p.x;
  double _spreadOf(Vec3 p) => axis == GraphAxis.vertical ? p.x : p.y;

  Vec3 _compose(double along, double spread, double depth) =>
      axis == GraphAxis.vertical
          ? Vec3(spread, along, depth)
          : Vec3(along, spread, depth);

  /// New device set: keeps where known devices are, seeds new ones next to
  /// their parent (or spread along their level), and reheats.
  void setNodes(List<TopologyNode> nodes, {String? boardMac}) {
    final byMac = {for (final n in nodes) n.mac: n};
    final parents = <String, String>{};
    for (final n in nodes) {
      if (n.parentMac != null &&
          byMac.containsKey(n.parentMac) &&
          n.parentMac != n.mac) {
        parents[n.mac] = n.parentMac!;
      } else if (n.layer <= 1 || n.parentMac == boardMac) {
        parents[n.mac] = graphCentralKey;
      }
    }
    final layers = {for (final n in nodes) n.layer}.toList()..sort();
    final lvl = <String, int>{graphCentralKey: 0};
    final ofLevel = <int, int>{0: 0};
    for (var i = 0; i < layers.length; i++) {
      ofLevel[i + 1] = layers[i];
    }
    for (final n in nodes) {
      lvl[n.mac] = layers.indexOf(n.layer) + 1;
    }
    parentOf = parents;
    level = lvl;
    layerOfLevel = ofLevel;

    pos.removeWhere((k, _) => k != graphCentralKey && !byMac.containsKey(k));
    _vel.removeWhere((k, _) => !pos.containsKey(k));
    pos[graphCentralKey] = _compose(levelCoord(0), 0, 0);

    // Seed the newcomers, parents first so children can start beside them.
    final sorted = nodes.toList()
      ..sort((a, b) {
        final c = lvl[a.mac]!.compareTo(lvl[b.mac]!);
        return c != 0 ? c : a.mac.compareTo(b.mac);
      });
    final perLevel = <int, int>{};
    for (final n in sorted) {
      final l = lvl[n.mac]!;
      final i = perLevel[l] = (perLevel[l] ?? 0) + 1;
      if (pos.containsKey(n.mac)) continue;
      final parent = pos[parents[n.mac]];
      final jitter = (_hash(n.mac) % 1000) / 1000.0 - 0.5;
      final spread = parent != null
          ? _spreadOf(parent) + jitter * minGap * 1.5
          : (i.isEven ? 1 : -1) * (i ~/ 2) * minGap;
      pos[n.mac] = _compose(levelCoord(l), spread, jitter * 60);
      _vel[n.mac] = Vec3.zero;
    }
    alpha = 1;
  }

  /// Turns the graph to the other axis, keeping each device's spread.
  void setAxis(GraphAxis a) {
    if (a == axis) return;
    final old = axis;
    axis = a;
    pos.updateAll((k, p) {
      final spread = old == GraphAxis.vertical ? p.x : p.y;
      return _compose(levelCoord(level[k] ?? 0), spread, p.z);
    });
    alpha = 1;
  }

  /// Runs the simulation until it is almost still (opening, axis switch).
  void settle({int maxSteps = 500}) {
    for (var i = 0; i < maxSteps && alpha > 0.006; i++) {
      step();
    }
  }

  /// Chip footprint in world units seen from the front (x across, y up):
  /// collisions keep these ellipses apart, so chips never cover each other.
  static const chipRx = 66.0; // 104 wide + margin, halved
  static const chipRy = 46.0; // ~62 tall + margin, halved

  /// Half-height of a level's band: a crowded level staggers inside it
  /// instead of stretching into one very long row.
  /// Tree view: two staggered rows fit (chip ~92 tall); wide view: two
  /// staggered columns fit (chip ~132 wide).
  double get levelBand => axis == GraphAxis.vertical ? 38.0 : 72.0;

  /// One tick. Returns false once settled (nothing moved).
  bool step() {
    if (alpha < 0.005 && dragged == null) return false;
    final keys = pos.keys.toList();
    final force = {for (final k in keys) k: Vec3.zero};
    final a = alpha.clamp(0.05, 1.0);

    // Repulsion (charge) in the front plane, strong near, fading far.
    for (var i = 0; i < keys.length; i++) {
      for (var j = i + 1; j < keys.length; j++) {
        final ki = keys[i], kj = keys[j];
        final pi = pos[ki]!, pj = pos[kj]!;
        var dx = pj.x - pi.x, dy = pj.y - pi.y;
        var dist = math.sqrt(dx * dx + dy * dy);
        if (dist < 1e-3) {
          dx = 1 + (i % 5) * 0.2;
          dy = 0.3;
          dist = math.sqrt(dx * dx + dy * dy);
        }
        if (dist > 600) continue;
        final k = 22000 / (dist * dist) * a / dist;
        final f = Vec3(dx * k, dy * k, 0);
        force[ki] = force[ki]! - f;
        force[kj] = force[kj]! + f;
      }
    }

    // Links: springs at [linkLength].
    parentOf.forEach((c, p) {
      final pc = pos[c], pp = pos[p];
      if (pc == null || pp == null) return;
      final d = pp - pc;
      final dist = math.max(d.length, 1e-3);
      final f = d * (1 / dist) * ((dist - linkLength) * 0.04 * a);
      force[c] = force[c]! + f;
      force[p] = force[p]! - f;
    });

    for (final k in keys) {
      final p = pos[k]!;
      // Level band: free inside it, pulled back beyond it.
      final e = levelCoord(level[k] ?? 0) - _axisOf(p);
      final out = e.abs() <= levelBand ? 0.0 : e - e.sign * levelBand;
      // Shallow depth: turning shows perspective, the front stays clear.
      final spread = -_spreadOf(p) * 0.003 * a;
      force[k] = force[k]! + _compose(out * 0.25, spread, -p.z * 0.15);
    }

    var moved = false;
    for (final k in keys) {
      if (k == graphCentralKey) {
        pos[k] = _compose(levelCoord(0), 0, 0);
        continue;
      }
      if (k == dragged) {
        _vel[k] = Vec3.zero;
        continue;
      }
      var v = ((_vel[k] ?? Vec3.zero) + force[k]!) * 0.7;
      if (v.length > 40) v = v.normalized() * 40;
      _vel[k] = v;
      if (v.length > 0.02) moved = true;
      pos[k] = pos[k]! + v;
    }

    // Collisions: chip ellipses never overlap in the front view (hard, not
    // scaled by heat). A few passes so crowded spots untangle in one tick.
    for (var pass = 0; pass < 3; pass++) {
      for (var i = 0; i < keys.length; i++) {
        for (var j = i + 1; j < keys.length; j++) {
          final ki = keys[i], kj = keys[j];
          final pi = pos[ki]!, pj = pos[kj]!;
          final nx = (pj.x - pi.x) / (2 * chipRx);
          final ny = (pj.y - pi.y) / (2 * chipRy);
          final n = math.sqrt(nx * nx + ny * ny);
          if (n >= 1) continue;
          // Push along the normalised direction, back into world units.
          final ux = n < 1e-4 ? 1.0 : nx / n, uy = n < 1e-4 ? 0.0 : ny / n;
          final gap = (1 - n) / 2;
          final push = Vec3(ux * gap * 2 * chipRx, uy * gap * 2 * chipRy, 0);
          final fixI = ki == graphCentralKey || ki == dragged;
          final fixJ = kj == graphCentralKey || kj == dragged;
          if (!fixI) pos[ki] = pi - push * (fixJ ? 2 : 1);
          if (!fixJ) pos[kj] = pj + push * (fixI ? 2 : 1);
          moved = true;
        }
      }
    }

    alpha *= dragged != null ? 1 : 0.985;
    return moved;
  }

  /// Moves the dragged device (world delta), keeping the rest alive.
  void dragBy(String key, Vec3 delta) {
    if (key == graphCentralKey) return;
    final p = pos[key];
    if (p == null) return;
    pos[key] = p + delta;
    alpha = math.max(alpha, 0.35);
  }

  /// Bounding box of the graph (camera fit).
  (Vec3 min, Vec3 max) bounds() {
    var lo = const Vec3(double.infinity, double.infinity, double.infinity);
    var hi = const Vec3(-double.infinity, -double.infinity, -double.infinity);
    for (final p in pos.values) {
      lo = Vec3(math.min(lo.x, p.x), math.min(lo.y, p.y), math.min(lo.z, p.z));
      hi = Vec3(math.max(hi.x, p.x), math.max(hi.y, p.y), math.max(hi.z, p.z));
    }
    return (lo, hi);
  }

  /// Anchor for a level's lane label: just outside the level's first
  /// device, on the side the Rede map puts it (left of a row; above a
  /// column in the wide view).
  Vec3? laneAnchor(int lvl) {
    Vec3? edge;
    pos.forEach((k, p) {
      if (level[k] != lvl) return;
      if (edge == null) {
        edge = p;
      } else if (axis == GraphAxis.vertical ? p.x < edge!.x : p.y > edge!.y) {
        edge = p;
      }
    });
    if (edge == null) return null;
    return axis == GraphAxis.vertical
        ? Vec3(edge!.x - 95, levelCoord(lvl), 0)
        : Vec3(levelCoord(lvl), edge!.y + 70, 0);
  }

  static int _hash(String s) {
    var h = 17;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }
}
