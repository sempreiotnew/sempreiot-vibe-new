import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// Minimal 3D vector for the Rede 3D prototype (no extra package).
class Vec3 {
  const Vec3(this.x, this.y, this.z);
  static const zero = Vec3(0, 0, 0);
  static const up = Vec3(0, 1, 0);

  final double x, y, z;

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double k) => Vec3(x * k, y * k, z * k);

  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;
  Vec3 cross(Vec3 o) =>
      Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get length => math.sqrt(x * x + y * y + z * z);

  Vec3 normalized() {
    final l = length;
    return l < 1e-9 ? const Vec3(0, 0, 1) : Vec3(x / l, y / l, z / l);
  }

  static Vec3 lerp(Vec3 a, Vec3 b, double t) => a + (b - a) * t;

  bool get isFinite => x.isFinite && y.isFinite && z.isFinite;

  @override
  String toString() =>
      'Vec3(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)}, ${z.toStringAsFixed(1)})';
}

/// A point on screen: where, how big (pixels per world unit) and how far.
class Projected {
  const Projected(this.offset, this.scale, this.depth);
  final Offset offset;
  final double scale;
  final double depth;
}

/// Camera orbiting [target] at [distance], turned by [yaw] (around the
/// vertical) and [pitch] (up/down, clamped short of the poles).
class OrbitCamera {
  OrbitCamera({
    this.target = Vec3.zero,
    this.yaw = 0.6,
    this.pitch = 0.35,
    this.distance = 600,
  });

  /// Distance at which chips are drawn at their 2D (Rede) size; set by the
  /// fit. Closer = bigger, farther = smaller.
  double referenceDistance = 600;

  static const minDistance = 25.0;
  static const maxDistance = 5000.0;
  static const maxPitch = 1.2;
  static const minPitch = -0.25;

  Vec3 target;
  double yaw;
  double pitch;
  double distance;

  Vec3 get direction => Vec3(
        math.cos(pitch) * math.sin(yaw),
        math.sin(pitch),
        math.cos(pitch) * math.cos(yaw),
      );

  Vec3 get position => target + direction * distance;

  void clamp() {
    pitch = pitch.clamp(minPitch, maxPitch);
    distance = distance.clamp(minDistance, maxDistance);
  }

  Projector projector(Size size) => Projector(this, size);
}

/// Perspective projection for one frame. The focal length follows the
/// viewport's short side, so the same camera frames the same picture in
/// portrait and landscape.
class Projector {
  Projector(OrbitCamera cam, this.size)
      : eye = cam.position,
        center = Offset(size.width / 2, size.height / 2),
        focal = math.min(size.width, size.height) * 0.9,
        referenceDistance = cam.referenceDistance {
    forward = (cam.target - eye).normalized();
    var r = forward.cross(Vec3.up);
    if (r.length < 1e-6) r = const Vec3(1, 0, 0);
    right = r.normalized();
    up = right.cross(forward).normalized();
  }

  static const near = 6.0;

  final Size size;
  final Vec3 eye;
  final Offset center;
  final double focal;
  final double referenceDistance;
  late final Vec3 forward, right, up;

  /// Pixels per world unit at [referenceDistance]: chip scale 1.0 there.
  double get referenceScale => focal / referenceDistance;

  /// Null when the point is behind (or at) the near plane.
  Projected? project(Vec3 p) {
    final d = p - eye;
    final z = d.dot(forward);
    if (z <= near) return null;
    final k = focal / z;
    return Projected(
      Offset(center.dx + d.dot(right) * k, center.dy - d.dot(up) * k),
      k,
      z,
    );
  }

  /// Screen drag → world motion of the target at [depth] (two-finger pan).
  Vec3 screenDeltaToWorld(Offset delta, double depth) {
    final k = depth / focal;
    return right * (-delta.dx * k) + up * (delta.dy * k);
  }
}
