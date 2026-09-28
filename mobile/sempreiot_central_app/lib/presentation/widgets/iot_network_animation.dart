import 'dart:math';
import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

class IoTNetworkAnimation extends StatefulWidget {
  const IoTNetworkAnimation({super.key});

  @override
  State<IoTNetworkAnimation> createState() => _IoTNetworkAnimationState();
}

class _IoTNetworkAnimationState extends State<IoTNetworkAnimation>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final AnimationController _packetController;
  late final AnimationController _driftController;
  late final Listenable _animationListenable;
  late final _NetworkPainter _painter;

  final List<_Node> _nodes = [];
  final Random _random = Random(42);

  @override
  void initState() {
    super.initState();

    for (int i = 0; i < 14; i++) {
      _nodes.add(_Node(
        x: _random.nextDouble(),
        y: _random.nextDouble(),
        size: 3.0 + _random.nextDouble() * 3,
        phase: _random.nextDouble() * 2 * pi,
        driftX: (_random.nextDouble() - 0.5) * 0.04,
        driftY: (_random.nextDouble() - 0.5) * 0.04,
      ));
    }

    _painter = _NetworkPainter(nodes: _nodes);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _packetController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _driftController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat(reverse: true);

    _animationListenable = Listenable.merge([
      _pulseController,
      _packetController,
      _driftController,
    ]);
    _animationListenable.addListener(_onAnimationTick);
  }

  void _onAnimationTick() {
    _painter.update(
      pulse: _pulseController.value,
      packet: _packetController.value,
      drift: _driftController.value,
    );
  }

  @override
  void dispose() {
    _animationListenable.removeListener(_onAnimationTick);
    _pulseController.dispose();
    _packetController.dispose();
    _driftController.dispose();
    _painter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _painter, size: Size.infinite);
  }
}

class _Node {
  final double x;
  final double y;
  final double size;
  final double phase;
  final double driftX;
  final double driftY;

  const _Node({
    required this.x,
    required this.y,
    required this.size,
    required this.phase,
    required this.driftX,
    required this.driftY,
  });

  Offset position(Size size, double driftProgress) {
    final dx = x + driftX * sin(driftProgress * pi);
    final dy = y + driftY * cos(driftProgress * pi);
    return Offset(dx * size.width, dy * size.height);
  }
}

// Extends CustomPainter with ChangeNotifier so it lives as a single long-lived
// instance. The render object subscribes to notifyListeners() for repaints
// instead of receiving a freshly constructed painter every frame.
class _NetworkPainter extends CustomPainter with ChangeNotifier {
  _NetworkPainter({required this.nodes}) : super() {
    for (int i = 0; i < nodes.length; i++) {
      _glowPaints.add(Paint()..style = PaintingStyle.fill);
    }
  }

  final List<_Node> nodes;

  double _pulseProgress = 0;
  double _packetProgress = 0;
  double _driftProgress = 0;

  // Cached paints — created once, properties mutated each frame.
  final _glowPaints = <Paint>[];
  final _ringPaint = Paint()
    ..strokeWidth = 1
    ..style = PaintingStyle.stroke;
  final _corePaint = Paint()..style = PaintingStyle.fill;
  final _linePaint = Paint()
    ..strokeWidth = 1
    ..style = PaintingStyle.stroke;
  final _packetPaint = Paint()..style = PaintingStyle.fill;

  static const _connectionThreshold = 0.38;
  static const _nodeColor = AppColors.secondary;
  static const _lineColor = AppColors.secondary;

  // Gradient colors are constant; only the shader rect changes per frame.
  // 0x59 = round(0.35 * 255) for AppColors.secondary (0xFF5DADE2).
  static const _glowGradient = RadialGradient(
    colors: [Color(0x595DADE2), Color(0x005DADE2)],
  );

  void update({
    required double pulse,
    required double packet,
    required double drift,
  }) {
    _pulseProgress = pulse;
    _packetProgress = packet;
    _driftProgress = drift;
    notifyListeners();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final positions =
        nodes.map((n) => n.position(size, _driftProgress)).toList();
    _drawConnections(canvas, size, positions);
    _drawNodes(canvas, positions);
  }

  void _drawConnections(Canvas canvas, Size size, List<Offset> positions) {
    for (int i = 0; i < positions.length; i++) {
      for (int j = i + 1; j < positions.length; j++) {
        final a = positions[i];
        final b = positions[j];
        final dist = (a - b).distance;
        final maxDist = size.width * _connectionThreshold;

        if (dist < maxDist) {
          final strength = 1 - (dist / maxDist);

          _linePaint.color = _lineColor.withValues(alpha: strength * 0.25);
          canvas.drawLine(a, b, _linePaint);

          _drawPacket(canvas, a, b, i, j, strength);
        }
      }
    }
  }

  void _drawPacket(
      Canvas canvas, Offset a, Offset b, int i, int j, double strength) {
    final offset = ((i * 7 + j * 13) % 100) / 100.0;
    final t = (_packetProgress + offset) % 1.0;
    final pos = Offset.lerp(a, b, t)!;

    _packetPaint.color = _lineColor.withValues(alpha: strength * 0.8);
    canvas.drawCircle(pos, 2.0, _packetPaint);
  }

  void _drawNodes(Canvas canvas, List<Offset> positions) {
    for (int i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final pos = positions[i];
      final pulse = sin(_pulseProgress * 2 * pi + node.phase);
      final glowRadius = node.size + 6 + pulse * 4;

      _glowPaints[i].shader = _glowGradient
          .createShader(Rect.fromCircle(center: pos, radius: glowRadius));
      canvas.drawCircle(pos, glowRadius, _glowPaints[i]);

      _ringPaint.color = _nodeColor.withValues(alpha: 0.5 + pulse * 0.2);
      canvas.drawCircle(pos, node.size + 3, _ringPaint);

      _corePaint.color = _nodeColor.withValues(alpha: 0.85 + pulse * 0.15);
      canvas.drawCircle(pos, node.size, _corePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _NetworkPainter old) => false;
}
