import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// The smoke detector model (assets/models/smoke_detector.glb) pre-rendered
/// in Blender from every angle: 24 turns × 7 tilts in one atlas, a matching
/// rim mask (tinted with the status colour in the app), and per frame where
/// the LED lens is and whether it faces the camera.
///
/// Angles follow [OrbitCamera]: yaw turns around the vertical, pitch > 0 =
/// camera above. The model faces the viewer at yaw 0, pitch 0.
class DetectorSprites {
  DetectorSprites._(
      this.atlas, this.rim, this.size, this.yaws, this.pitches, this.leds);

  final ui.Image atlas;
  final ui.Image rim;
  final int size; // frame side, px
  final List<int> yaws; // degrees
  final List<int> pitches; // degrees
  final List<({Offset at, bool visible})> leds; // at: 0..1 in the frame

  /// Fraction of a frame the detector's diameter fills (ortho 0.125 m frame,
  /// 0.099 m detector).
  static const bodyFraction = 0.79;

  static Future<DetectorSprites>? _loading;
  static Future<DetectorSprites> load() => _loading ??= _load();

  static Future<DetectorSprites> _load() async {
    Future<ui.Image> image(String path) async {
      final data = await rootBundle.load(path);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      return (await codec.getNextFrame()).image;
    }

    final json = jsonDecode(await rootBundle
        .loadString('assets/models/smoke_detector_frames.json')) as Map;
    final frames = (json['frames'] as List).cast<Map>();
    return DetectorSprites._(
      await image('assets/models/smoke_detector_atlas.png'),
      await image('assets/models/smoke_detector_rim.png'),
      json['size'] as int,
      (json['yaws'] as List).cast<int>(),
      (json['pitches'] as List).cast<int>(),
      [
        for (final f in frames)
          (
            at: Offset((f['led'][0] as num).toDouble(),
                (f['led'][1] as num).toDouble()),
            visible: f['ledVisible'] as bool,
          ),
      ],
    );
  }

  /// The frame closest to the camera's turn and tilt (radians).
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

  Rect source(int frame) {
    final col = frame % yaws.length, row = frame ~/ yaws.length;
    return Rect.fromLTWH((col * size).toDouble(), (row * size).toDouble(),
        size.toDouble(), size.toDouble());
  }
}
