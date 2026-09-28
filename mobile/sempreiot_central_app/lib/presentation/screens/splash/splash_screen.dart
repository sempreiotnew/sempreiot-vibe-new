import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../features/app/application/app_init_provider.dart';
import '../main/main_screen.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _logoController;
  late final AnimationController _pulseController;
  late final AnimationController _dotsController;

  late final Animation<double> _logoScale;
  late final Animation<double> _logoOpacity;

  @override
  void initState() {
    super.initState();

    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );

    _dotsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _logoScale = CurvedAnimation(
      parent: _logoController,
      curve: Curves.elasticOut,
    );

    _logoOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const Interval(0, 0.4, curve: Curves.easeIn),
      ),
    );

    _logoController.forward().then((_) {
      _pulseController.repeat();
      _dotsController.repeat();
    });
  }

  @override
  void dispose() {
    _logoController.dispose();
    _pulseController.dispose();
    _dotsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appInitProvider, (_, next) {
      if (next.valueOrNull != true) return;
      // Use addPostFrameCallback so navigation fires after the current build
      // frame, avoiding conflicts with in-progress widget rebuilds.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const MainScreen()),
          (_) => false,
        );
      });
    });

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      body: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (_, __) => CustomPaint(
              size: Size.infinite,
              painter: _PulseRingsPainter(progress: _pulseController.value),
            ),
          ),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ScaleTransition(
                scale: _logoScale,
                child: FadeTransition(
                  opacity: _logoOpacity,
                  child: Image.asset(
                    'assets/images/logo_no_shadow.png',
                    width: 160,
                    height: 160,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            bottom: 80,
            child: AnimatedBuilder(
              animation: _dotsController,
              builder: (_, __) => _LoadingDots(progress: _dotsController.value),
            ),
          ),
        ],
      ),
    );
  }
}

class _PulseRingsPainter extends CustomPainter {
  const _PulseRingsPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const maxRadius = 180.0;

    for (int i = 0; i < 3; i++) {
      final offset = i / 3.0;
      final t = (progress + offset) % 1.0;
      final radius = t * maxRadius;
      final opacity = (1 - t) * 0.4;

      final paint = Paint()
        ..color = AppColors.secondary.withValues(alpha: opacity)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      canvas.drawCircle(center, radius, paint);
    }

    final innerPaint = Paint()
      ..color = AppColors.secondary.withValues(alpha: 0.08)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, 100, innerPaint);
  }

  @override
  bool shouldRepaint(_PulseRingsPainter old) => old.progress != progress;
}

class _LoadingDots extends StatelessWidget {
  const _LoadingDots({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        final offset = i / 3.0;
        final t = (progress + offset) % 1.0;
        final scale = 0.5 + 0.5 * sin(t * pi);
        final opacity = 0.3 + 0.7 * sin(t * pi);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Opacity(
            opacity: opacity,
            child: Transform.scale(
              scale: scale,
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: AppColors.secondary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}
