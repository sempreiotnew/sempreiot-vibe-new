import 'package:flutter/material.dart';

/// A retro LED dot-matrix readout — the 5×7 dot font of old alarm central
/// message panels. The full dot grid is always faintly visible (unlit LEDs),
/// lit dots glow in the status color, and messages wider than the panel
/// scroll in from the right in whole-column steps, exactly like the real
/// hardware. Accents are stripped ("SEM CONEXÃO" → "SEM CONEXAO"), which is
/// also what the old panels did.
class DotMatrixDisplay extends StatefulWidget {
  const DotMatrixDisplay({
    super.key,
    required this.text,
    required this.color,
    this.height = 24,
  });

  final String text;
  final Color color;
  final double height;

  @override
  State<DotMatrixDisplay> createState() => _DotMatrixDisplayState();
}

class _DotMatrixDisplayState extends State<DotMatrixDisplay>
    with SingleTickerProviderStateMixin {
  static const _colsPerSecond = 12.0;

  late final AnimationController _scroll = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // Start/stop the marquee outside of build.
  void _syncScroll(bool needsScroll, int totalCols) {
    if (needsScroll) {
      final duration =
          Duration(milliseconds: (totalCols / _colsPerSecond * 1000).round());
      _scroll.duration = duration;
      if (!_scroll.isAnimating) _scroll.repeat();
    } else if (_scroll.isAnimating) {
      _scroll.stop();
      _scroll.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _DotMatrixFont.normalize(widget.text);

    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final pitch = widget.height / _DotMatrixFont.rows;
          final textCols = _DotMatrixFont.colsFor(text);
          final viewCols = (constraints.maxWidth / pitch).floor();
          final needsScroll = textCols > viewCols;
          final totalCols = textCols + viewCols; // enter right, exit left

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _syncScroll(needsScroll, totalCols);
          });

          return AnimatedBuilder(
            animation: _scroll,
            builder: (context, _) {
              // Whole-column steps — real panels shift the message one LED
              // column at a time, never smoothly.
              final startCol = needsScroll
                  ? viewCols - (_scroll.value * totalCols).floor()
                  : ((viewCols - textCols) / 2).floor();
              return CustomPaint(
                size: Size(constraints.maxWidth, widget.height),
                painter: _DotMatrixPainter(
                  text: text,
                  color: widget.color,
                  pitch: pitch,
                  startCol: startCol,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _DotMatrixPainter extends CustomPainter {
  const _DotMatrixPainter({
    required this.text,
    required this.color,
    required this.pitch,
    required this.startCol,
  });

  final String text;
  final Color color;
  final double pitch;
  final int startCol;

  @override
  void paint(Canvas canvas, Size size) {
    const rows = _DotMatrixFont.rows;
    final r = pitch * 0.33;
    final gridCols = (size.width / pitch).floor();
    if (gridCols <= 0) return;
    final xInset = (size.width - gridCols * pitch) / 2;

    Offset centerOf(int col, int row) => Offset(
          xInset + col * pitch + pitch / 2,
          row * pitch + pitch / 2,
        );

    final unlit = Paint()..color = color.withValues(alpha: 0.10);
    for (var col = 0; col < gridCols; col++) {
      for (var row = 0; row < rows; row++) {
        canvas.drawCircle(centerOf(col, row), r * 0.9, unlit);
      }
    }

    final glow = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 1.8);
    final lit = Paint()..color = color;

    var col = startCol;
    for (final ch in text.split('')) {
      final glyph = _DotMatrixFont.glyph(ch);
      for (var gc = 0; gc < 5; gc++, col++) {
        if (col < 0 || col >= gridCols) continue;
        for (var row = 0; row < rows; row++) {
          if (((glyph[row] >> (4 - gc)) & 1) != 0) {
            final c = centerOf(col, row);
            canvas.drawCircle(c, r * 1.15, glow);
            canvas.drawCircle(c, r, lit);
          }
        }
      }
      col++; // blank column between characters
    }
  }

  @override
  bool shouldRepaint(_DotMatrixPainter old) =>
      old.text != text ||
      old.color != color ||
      old.pitch != pitch ||
      old.startCol != startCol;
}

/// Classic 5×7 dot-matrix font. Each glyph is 7 rows of 5 bits (MSB left).
class _DotMatrixFont {
  _DotMatrixFont._();

  static const rows = 7;

  /// Total LED columns for [text]: 5 per glyph + 1 blank between glyphs.
  static int colsFor(String text) =>
      text.isEmpty ? 0 : text.length * 6 - 1;

  /// Uppercases and strips accents — old panels had no accented glyphs.
  static String normalize(String input) {
    const map = {
      'Á': 'A', 'À': 'A', 'Â': 'A', 'Ã': 'A',
      'É': 'E', 'Ê': 'E',
      'Í': 'I',
      'Ó': 'O', 'Ô': 'O', 'Õ': 'O',
      'Ú': 'U', 'Ü': 'U',
      'Ç': 'C',
      '…': '...',
    };
    final sb = StringBuffer();
    for (final ch in input.toUpperCase().split('')) {
      sb.write(map[ch] ?? ch);
    }
    return sb.toString();
  }

  static List<int> glyph(String ch) => _glyphs[ch] ?? _glyphs[' ']!;

  static const _glyphs = <String, List<int>>{
    ' ': [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
    'A': [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
    'B': [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
    'C': [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E],
    'D': [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E],
    'E': [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
    'F': [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
    'G': [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F],
    'H': [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
    'I': [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
    'J': [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C],
    'K': [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11],
    'L': [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
    'M': [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11],
    'N': [0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11],
    'O': [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
    'P': [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
    'Q': [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D],
    'R': [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
    'S': [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E],
    'T': [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
    'U': [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
    'V': [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04],
    'W': [0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A],
    'X': [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11],
    'Y': [0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04],
    'Z': [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F],
    '0': [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
    '1': [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
    '2': [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F],
    '3': [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E],
    '4': [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
    '5': [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
    '6': [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E],
    '7': [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
    '8': [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
    '9': [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
    '.': [0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C],
    '-': [0x00, 0x00, 0x00, 0x0E, 0x00, 0x00, 0x00],
    '/': [0x01, 0x02, 0x02, 0x04, 0x08, 0x08, 0x10],
    '!': [0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04],
    '%': [0x18, 0x19, 0x02, 0x04, 0x08, 0x13, 0x03],
  };
}
