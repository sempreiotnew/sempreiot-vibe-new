import 'dart:async';

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
  // The back camera is tried first. A central tablet often has only a front
  // camera: asking for a back camera then fails with "unsupported / no camera",
  // so on that error the scanner is started again on the front camera before
  // anything is shown to the installer.
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );
  bool _hasScanned = false;
  bool _triedFrontCamera = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final error = _controller.value.error;
    if (error == null ||
        error.errorCode != MobileScannerErrorCode.unsupported ||
        _triedFrontCamera) {
      return;
    }
    _triedFrontCamera = true;
    // A successful start clears the error; a second failure keeps it and the
    // error builder below shows the message.
    unawaited(_controller.start(cameraDirection: CameraFacing.front));
  }

  Widget _buildError(BuildContext context, MobileScannerException error) {
    // Still switching to the front camera: keep the black preview.
    if (error.errorCode == MobileScannerErrorCode.unsupported &&
        !_triedFrontCamera) {
      return const ColoredBox(color: Colors.black);
    }
    final message = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        'Permita o acesso à câmera nas configurações do aparelho para '
            'escanear o QR Code.',
      MobileScannerErrorCode.unsupported =>
        'Nenhuma câmera disponível neste aparelho.',
      _ => 'Não foi possível abrir a câmera.',
    };
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_rounded,
                  color: Colors.white, size: 40),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onDetect(BarcodeCapture capture) {
    if (_hasScanned) return;
    final value =
        capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
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
            errorBuilder: _buildError,
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
                // A front camera has no flash: hide the button instead of
                // offering a torch that never lights.
                ValueListenableBuilder<MobileScannerState>(
                  valueListenable: _controller,
                  builder: (context, state, _) {
                    if (state.torchState == TorchState.unavailable) {
                      return const SizedBox.shrink();
                    }
                    return IconButton(
                      icon: const Icon(Icons.flash_on_rounded),
                      onPressed: () => _controller.toggleTorch(),
                      tooltip: 'Lanterna',
                    );
                  },
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
