import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../../core/theme/app_colors.dart';

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({
    super.key,
    this.hint = 'Aponte para o QR Code da central',
  });

  final String hint;

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _hasScanned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_hasScanned) return;
    final value = capture.barcodes.isNotEmpty
        ? capture.barcodes.first.rawValue
        : null;
    if (value == null || value.isEmpty) return;
    _hasScanned = true;
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Camera feed ───────────────────────────────────────────────────
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),

          // ── Dark overlay with transparent hole ────────────────────────────
          CustomPaint(
            painter: _OverlayPainter(),
            child: const SizedBox.expand(),
          ),

          // ── AppBar overlay ────────────────────────────────────────────────
          SafeArea(
            child: AppBar(
              backgroundColor: Colors.transparent,
              foregroundColor: Colors.white,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.pop(context),
              ),
              title: const Text(
                'Escanear QR Code',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.flash_on_rounded),
                  onPressed: () => _controller.toggleTorch(),
                  tooltip: 'Lanterna',
                ),
              ],
            ),
          ),

          // ── Hint text ─────────────────────────────────────────────────────
          Positioned(
            bottom: 72,
            left: 0,
            right: 0,
            child: Text(
              widget.hint,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Overlay painter ────────────────────────────────────────────────────────────

class _OverlayPainter extends CustomPainter {
  static const _scanSize = 240.0;
  static const _cornerRadius = 16.0;
  static const _bracketLen = 28.0;
  static const _bracketWidth = 3.5;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final rect = Rect.fromCenter(
      center: Offset(cx, cy),
      width: _scanSize,
      height: _scanSize,
    );
    final rrect = RRect.fromRectAndRadius(
      rect,
      const Radius.circular(_cornerRadius),
    );

    // Dimmed background with hole
    final dimPaint = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final fullPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final holePath = Path()..addRRect(rrect);
    canvas.drawPath(
      Path.combine(PathOperation.difference, fullPath, holePath),
      dimPaint,
    );

    // Corner brackets
    final bp = Paint()
      ..color = AppColors.secondary
      ..strokeWidth = _bracketWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final l = rect.left;
    final r = rect.right;
    final t = rect.top;
    final b = rect.bottom;
    const cr = _cornerRadius;
    const bl = _bracketLen;

    // Top-left
    canvas.drawLine(Offset(l, t + cr), Offset(l, t + bl), bp);
    canvas.drawLine(Offset(l + cr, t), Offset(l + bl, t), bp);
    // Top-right
    canvas.drawLine(Offset(r, t + cr), Offset(r, t + bl), bp);
    canvas.drawLine(Offset(r - cr, t), Offset(r - bl, t), bp);
    // Bottom-left
    canvas.drawLine(Offset(l, b - cr), Offset(l, b - bl), bp);
    canvas.drawLine(Offset(l + cr, b), Offset(l + bl, b), bp);
    // Bottom-right
    canvas.drawLine(Offset(r, b - cr), Offset(r, b - bl), bp);
    canvas.drawLine(Offset(r - cr, b), Offset(r - bl, b), bp);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
