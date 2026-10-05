import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../../../domain/safr/safr_product.dart';
import 'device_models.g.dart';

/// A product's 3D model as the app draws it (Rede 3D, Dispositivos,
/// Dispositivo): pre-rendered in Blender by tool/blender/factory.sh — no 3D
/// engine at runtime. The list is generated: [deviceModelSpecs].
class DeviceModelSpec {
  const DeviceModelSpec({
    required this.slug,
    required this.productCodes,
    required this.familyFallback,
    required this.atlas,
    required this.spin,
    required this.glow,
    required this.spinGlow,
    required this.frames,
    required this.scale,
    required this.alarmSound,
  });

  /// `siren` — the .glb is assets/models/<slug>.glb.
  final String slug;

  /// PRODUCT codes (catalogue, system reference §2.1) drawn with this model.
  final List<int> productCodes;

  /// Also drawn for a unit of this family whose product has no model of its
  /// own or is not reported; null = only [productCodes].
  final SafrProductFamily? familyFallback;

  /// Every turn × tilt of the Rede 3D camera.
  final String atlas;

  /// One turn at a fixed tilt in fine steps (the spinning Dispositivos card).
  final String spin;

  /// The model's alarm lights alone (white), same frames as [atlas] /
  /// [spin]; null = the model has none.
  final String? glow, spinGlow;

  /// Frame data (`<slug>_frames.json`).
  final String frames;

  /// Size nudge on top of the equal visual weight every model gets
  /// ([deviceModelBox]); 1.0 = same weight as every other model.
  final double scale;

  /// In ALARME it rings: sound waves come out of its sides.
  final bool alarmSound;
}

/// Which model draws a unit: its product's own model, else its family's
/// fallback, else none (the unit is a sphere / circle). [isLeaf] gives the
/// family when the unit did not report a product.
DeviceModelSpec? deviceModelFor(int? productCode, {required bool isLeaf}) =>
    deviceModelIn(deviceModelSpecs, productCode, isLeaf: isLeaf);

/// [deviceModelFor] over any list (tests).
DeviceModelSpec? deviceModelIn(List<DeviceModelSpec> specs, int? productCode,
    {required bool isLeaf}) {
  final code = productCode == null ? 0 : productCode & 0xFFFF;
  if (code != safrProductUnknown) {
    for (final s in specs) {
      if (s.productCodes.contains(code)) return s;
    }
  }
  final fromCode = SafrProductFamily.ofCode(code);
  final family = fromCode != SafrProductFamily.unknown
      ? fromCode
      : isLeaf
          ? SafrProductFamily.leaf
          : SafrProductFamily.node;
  for (final s in specs) {
    if (s.familyFallback == family) return s;
  }
  return null;
}

/// How big a model looks, the same for every product: the square root of
/// the area its outline covers is this share of the layout size it is given
/// (the circle's diameter). A tall siren, a round detector and a square push
/// button then weigh the same on a card or the map, whatever their real size
/// or shape. 0.79 = the smoke detector as it was first drawn.
const deviceModelVisualWeight = 0.79;

/// Side of the frame to draw so the model has [deviceModelVisualWeight] at
/// layout size [size] (px).
double deviceModelBox(DeviceModelSpec spec, DeviceModelFrames frames,
        double size) =>
    size *
    deviceModelVisualWeight *
    spec.scale /
    math.sqrt(frames.coverage.clamp(0.01, 1.0));

/// Where a marker (e.g. the LED) sits in one frame: 0..1 in the frame, and
/// whether it faces the camera.
typedef ModelMarker = ({Offset at, bool visible});

List<ModelMarker> _markers(List raw) => [
      for (final f in raw.cast<List>())
        (
          at: Offset((f[0] as num).toDouble(), (f[1] as num).toDouble()),
          visible: (f[2] as num) != 0,
        ),
    ];

Map<String, List<ModelMarker>> _markerMap(Object? raw) => {
      for (final e in ((raw ?? const {}) as Map).entries)
        e.key as String: _markers(e.value as List),
    };

/// The frame data a model's `<slug>_frames.json` holds.
class DeviceModelFrames {
  const DeviceModelFrames({
    required this.size,
    required this.yaws,
    required this.pitches,
    required this.bodyFraction,
    required this.coverage,
    required this.markers,
    required this.spinPitch,
    required this.spinYaws,
    required this.spinCols,
    required this.spinMarkers,
  });

  final int size; // frame side, px
  final List<int> yaws; // degrees, the atlas
  final List<int> pitches; // degrees, the atlas

  /// Fraction of a frame the model's largest side fills.
  final double bodyFraction;

  /// Mean share of a frame the model's outline covers over a full turn
  /// (factory); sizes every model to the same visual weight.
  final double coverage;

  /// Per marker name, one entry per atlas frame (pitch-major, yaw-minor).
  final Map<String, List<ModelMarker>> markers;

  /// The spin strip: one turn at [spinPitch] degrees, [spinCols] per row.
  final int spinPitch;
  final List<int> spinYaws;
  final int spinCols;
  final Map<String, List<ModelMarker>> spinMarkers;

  int get frameCount => yaws.length * pitches.length;

  factory DeviceModelFrames.parse(String source) {
    final j = jsonDecode(source) as Map<String, dynamic>;
    final spin = j['spin'] as Map<String, dynamic>;
    return DeviceModelFrames(
      size: j['size'] as int,
      yaws: (j['yaws'] as List).cast<int>(),
      pitches: (j['pitches'] as List).cast<int>(),
      bodyFraction: (j['bodyFraction'] as num).toDouble(),
      coverage: ((j['coverage'] ?? 0.4) as num).toDouble(),
      markers: _markerMap(j['markers']),
      spinPitch: spin['pitch'] as int,
      spinYaws: (spin['yaws'] as List).cast<int>(),
      spinCols: spin['cols'] as int,
      spinMarkers: _markerMap(spin['markers']),
    );
  }

  /// The atlas frame closest to the camera's turn and tilt (radians).
  /// Angles follow [OrbitCamera]: yaw turns around the vertical, pitch > 0
  /// = camera above; the model faces the viewer at yaw 0, pitch 0.
  int frameFor(double yaw, double pitch) {
    final step = 360 / yaws.length;
    final deg = (yaw * 180 / math.pi) % 360;
    final yi = (deg / step).round() % yaws.length;
    final pd = pitch * 180 / math.pi;
    var pi = 0;
    for (var i = 1; i < pitches.length; i++) {
      if ((pitches[i] - pd).abs() < (pitches[pi] - pd).abs()) pi = i;
    }
    return pi * yaws.length + yi;
  }

  Rect source(int frame) => _cell(frame, yaws.length);

  Rect spinSource(int i) => _cell(i, spinCols);

  Rect _cell(int i, int cols) => Rect.fromLTWH(((i % cols) * size).toDouble(),
      ((i ~/ cols) * size).toDouble(), size.toDouble(), size.toDouble());

  /// The two spin frames around [yaw] (radians) and how far between them.
  ({int a, int b, double t}) spinBetween(double yaw) {
    final n = spinYaws.length;
    final f = ((yaw * 180 / math.pi) % 360) / (360 / n);
    final a = f.floor() % n;
    return (a: a, b: (a + 1) % n, t: f - f.floor());
  }
}

/// What to draw for one view of a model: a frame (and, while it turns, the
/// next one to blend in by [t]), the alarm lights of those frames, and the
/// LED there.
class ModelPose {
  const ModelPose({
    required this.image,
    required this.glow,
    required this.a,
    this.b,
    this.t = 0,
    required this.led,
  });

  final ui.Image image;
  final ui.Image? glow;
  final Rect a;
  final Rect? b;
  final double t;
  final ModelMarker? led;

  @override
  bool operator ==(Object other) =>
      other is ModelPose &&
      other.image == image &&
      other.a == a &&
      other.b == b &&
      other.t == t &&
      other.led == led;

  @override
  int get hashCode => Object.hash(image, a, b, t, led);
}

/// A model loaded: its sheets and frame data.
class DeviceModelSprites {
  DeviceModelSprites._(
      this.spec, this.atlas, this.spin, this.glow, this.spinGlow, this.frames);

  final DeviceModelSpec spec;
  final ui.Image atlas, spin;

  /// Alarm lights; null when the model has none.
  final ui.Image? glow, spinGlow;
  final DeviceModelFrames frames;

  bool get hasAlarmLights => glow != null;

  /// Frame side for layout size [size] — see [deviceModelBox].
  double frameBox(double size) => deviceModelBox(spec, frames, size);

  /// The Rede 3D view: the nearest atlas frame for the camera.
  ModelPose mapPose(double yaw, double pitch) {
    final f = frames.frameFor(yaw, pitch);
    return ModelPose(
      image: atlas,
      glow: glow,
      a: frames.source(f),
      led: frames.markers['led']?[f],
    );
  }

  /// The spinning / turned view at the spin tilt: two neighbouring frames
  /// blended, the LED between their two positions.
  ModelPose spinPose(double yaw) {
    final s = frames.spinBetween(yaw);
    final leds = frames.spinMarkers['led'];
    ModelMarker? led;
    if (leds != null) {
      final la = leds[s.a], lb = leds[s.b];
      led = (
        at: Offset.lerp(la.at, lb.at, s.t)!,
        visible: s.t < 0.5 ? la.visible : lb.visible,
      );
    }
    return ModelPose(
      image: spin,
      glow: spinGlow,
      a: frames.spinSource(s.a),
      b: s.t > 0.001 ? frames.spinSource(s.b) : null,
      t: s.t,
      led: led,
    );
  }

  static final _cache = <String, Future<DeviceModelSprites>>{};

  /// Loaded once per model.
  static Future<DeviceModelSprites> load(DeviceModelSpec spec) =>
      _cache[spec.slug] ??= _load(spec);

  static Future<DeviceModelSprites> _load(DeviceModelSpec spec) async {
    Future<ui.Image> image(String path) async {
      final data = await rootBundle.load(path);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      return (await codec.getNextFrame()).image;
    }

    return DeviceModelSprites._(
      spec,
      await image(spec.atlas),
      await image(spec.spin),
      spec.glow == null ? null : await image(spec.glow!),
      spec.spinGlow == null ? null : await image(spec.spinGlow!),
      DeviceModelFrames.parse(await rootBundle.loadString(spec.frames)),
    );
  }
}
