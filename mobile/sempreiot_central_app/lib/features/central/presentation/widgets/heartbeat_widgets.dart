import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/heartbeat_log_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_v2_payloads.dart';

/// A small heart that beats once when [mac]'s HEARTBEAT arrives at the
/// tablet (`heartbeatLogProvider`). Over the monitor it is the board's: it
/// beats the moment the board sends its HEARTBEAT down the mesh (protocol
/// §7.3), the beat the unit then reports as heard or lost. Outline at rest,
/// filled while it beats (lub-dub, [beat]). It is not an LED — the LED
/// lens keeps the LED language — and it shows nothing the wire did not
/// carry: one beat per real frame, never on a timer. It was on every unit
/// of the Rede map for a day (2026-10-27) and was taken off: it doubled the
/// blue LED tick there and said nothing the LED did not.
class HeartbeatHeart extends ConsumerStatefulWidget {
  const HeartbeatHeart({super.key, required this.mac, this.size = 12});

  final String mac;
  final double size;

  /// One beat on screen.
  static const beat = Duration(milliseconds: 700);

  static Key keyFor(String mac) => ValueKey('heartbeat-$mac');

  @override
  ConsumerState<HeartbeatHeart> createState() => _HeartbeatHeartState();
}

class _HeartbeatHeartState extends ConsumerState<HeartbeatHeart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl =
      AnimationController(vsync: this, duration: HeartbeatHeart.beat);

  // lub (big) … dub (smaller) … rest.
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.45), weight: 18),
    TweenSequenceItem(tween: Tween(begin: 1.45, end: 1.0), weight: 22),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.25), weight: 16),
    TweenSequenceItem(tween: Tween(begin: 1.25, end: 1.0), weight: 44),
  ]).animate(_ctl);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<DateTime?>(
      heartbeatLogProvider.select((log) => log.lastBeatAt(widget.mac)),
      (prev, next) {
        if (next != null && next != prev) _ctl.forward(from: 0);
      },
    );
    return AnimatedBuilder(
      animation: _ctl,
      builder: (context, _) {
        final beating = _ctl.isAnimating;
        return Transform.scale(
          scale: _scale.value,
          child: Icon(
            beating ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            key: HeartbeatHeart.keyFor(widget.mac),
            size: widget.size,
            color: beating
                ? AppColors.heartbeat
                : AppColors.heartbeat.withValues(alpha: 0.55),
          ),
        );
      },
    );
  }
}

/// The unit's downlink, drawn like a bedside monitor (2026-10-27): black
/// screen, one green trace, the last [span] scrolling with now at the right
/// edge. The beats on it are the BOARD's heartbeats going down the mesh —
/// one every 15 s, each a small tick under the line at the moment the
/// tablet saw the board send it — and for every one of them the unit's own
/// word (protocol v3.7 §7.3 DL_MAP, carried in the unit's next heartbeat):
/// heard = a spike, lost = nothing, the line stays flat over the tick. A
/// beat the unit has not reported yet (the newest, for up to 15 s; or
/// everything after a unit went quiet) is a hollow dot on the line, not a
/// gap: unknown is not lost. A dead downlink is a flat line over a row of
/// ticks; a dead unit is a row of hollow dots and the caption's "sem sinal
/// da unidade".
///
/// Nothing here is inferred: the tablet knows when the board sent each
/// beat (it gets the same frame over the cable), and the unit says which
/// it heard. A unit on firmware before v3.7 sends no map: the monitor then
/// falls back to the unit's own heartbeats as spikes (is it alive?) and the
/// caption says so. The log lives from app start, so a fresh app shows an
/// empty left side until 5 min have gone by.
class HeartbeatMonitor extends ConsumerStatefulWidget {
  const HeartbeatMonitor({
    super.key,
    required this.node,
    required this.boardMac,
    this.height = 74,
  });

  final TopologyNode node;
  final String? boardMac;
  final double height;

  /// What the screen shows.
  static const span = Duration(minutes: 5);

  static const monitorKey = ValueKey('heartbeat-monitor');
  static const captionKey = ValueKey('heartbeat-monitor-caption');

  @override
  ConsumerState<HeartbeatMonitor> createState() => _HeartbeatMonitorState();
}

class _HeartbeatMonitorState extends ConsumerState<HeartbeatMonitor>
    with SingleTickerProviderStateMixin {
  // The trace scrolls: a frame a second is plenty for 15 s beats.
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final log = ref.watch(heartbeatLogProvider);
    final unitBeats = log.recent(widget.node.mac);
    final board = widget.boardMac;
    final boardBeats =
        board == null ? const <HeartbeatBeat>[] : log.recent(board);
    final labelStyle = TextStyle(
      color: context.textSecondary,
      fontSize: 8.5,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.8,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (board != null)
              HeartbeatHeart(mac: board, size: 12)
            else
              Icon(Icons.favorite_border_rounded,
                  size: 12, color: context.textSecondary),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                'BATIMENTOS DA PLACA · ${HeartbeatMonitor.span.inMinutes} MIN',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: labelStyle,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        AnimatedBuilder(
          animation: _clock,
          builder: (context, _) {
            final now = DateTime.now();
            final picture = MonitorPicture.build(
              unitBeats: unitBeats,
              boardBeats: boardBeats,
              now: now,
              span: HeartbeatMonitor.span,
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    height: widget.height,
                    child: CustomPaint(
                      key: HeartbeatMonitor.monitorKey,
                      painter: HeartbeatMonitorPainter(picture: picture),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  picture.caption,
                  key: HeartbeatMonitor.captionKey,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: context.textSecondary, fontSize: 9.5),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

enum SlotState { heard, lost, pending }

/// One of the board's beats on the screen: when the board sent it, and
/// what the unit said of it.
class MonitorSlot {
  const MonitorSlot({required this.at, required this.state});
  final DateTime at;
  final SlotState state;
}

/// Everything the painter draws and the caption says, computed once per
/// frame from the two logs (pure: unit-tested).
class MonitorPicture {
  const MonitorPicture({
    required this.now,
    required this.span,
    required this.slots,
    required this.unitBeats,
    required this.hasMaps,
    required this.caption,
  });

  final DateTime now;
  final Duration span;

  /// The board's beats in the window, oldest first.
  final List<MonitorSlot> slots;

  /// The unit's own heartbeats in the window (the fallback trace).
  final List<HeartbeatBeat> unitBeats;

  /// The unit reports DL_MAP (v3.7): the slots carry its word.
  final bool hasMaps;
  final String caption;

  /// Two board beats closer than this are one beat (the extra one the board
  /// sends on a link-up shares its slot, siot_hbwin.c).
  static const sameSlot = Duration(seconds: 8);

  /// A unit's beat is due every 15 s; past this silence something is wrong.
  static const silence = Duration(seconds: 20);

  static MonitorPicture build({
    required List<HeartbeatBeat> unitBeats,
    required List<HeartbeatBeat> boardBeats,
    required DateTime now,
    Duration span = HeartbeatMonitor.span,
  }) {
    final from = now.subtract(span);
    // The board's beats as slots: a map in the unit's beat covers the 8
    // before it, so keep two minutes more than the screen to fill its left
    // edge, and collapse a link-up double.
    final sent = <DateTime>[];
    for (final b in boardBeats) {
      if (b.at.isBefore(from.subtract(HeartbeatLog.window))) continue;
      if (sent.isNotEmpty && b.at.difference(sent.last) < sameSlot) continue;
      sent.add(b.at);
    }
    final states = List<SlotState>.filled(sent.length, SlotState.pending);
    var hasMaps = false;
    // Newest report first: a later map resolves a slot an earlier one left
    // pending (an overdue beat read as lost, then heard late).
    for (final b in unitBeats.reversed) {
      final map = b.dlMap;
      if (map == null) continue;
      hasMaps = true;
      var j = sent.length - 1;
      while (j >= 0 && !sent[j].isBefore(b.at)) {
        j--;
      }
      for (var i = 0;
          i < SafrHeartbeatPayload.dlHeardExpected && j >= 0;
          i++, j--) {
        if (states[j] != SlotState.pending) continue;
        states[j] = SafrHeartbeatPayload.heardAt(map, i)
            ? SlotState.heard
            : SlotState.lost;
      }
    }
    final slots = <MonitorSlot>[
      for (var j = 0; j < sent.length; j++)
        if (!sent[j].isBefore(from)) MonitorSlot(at: sent[j], state: states[j]),
    ];
    final own = [
      for (final b in unitBeats)
        if (!b.at.isBefore(from)) b,
    ];
    return MonitorPicture(
      now: now,
      span: span,
      slots: slots,
      unitBeats: own,
      hasMaps: hasMaps,
      caption: _caption(slots, own, unitBeats.lastOrNull?.at, hasMaps, now,
          span, boardBeats.isEmpty),
    );
  }

  static String _caption(
    List<MonitorSlot> slots,
    List<HeartbeatBeat> own,
    DateTime? lastUnitBeat,
    bool hasMaps,
    DateTime now,
    Duration span,
    bool noBoard,
  ) {
    final minutes = span.inMinutes;
    String quiet() {
      if (lastUnitBeat == null) return ' · nada da unidade ainda';
      final gap = now.difference(lastUnitBeat);
      return gap > silence
          ? ' · sem sinal da unidade há ${gap.inSeconds} s'
          : '';
    }

    if (noBoard && own.isEmpty) return 'aguardando o primeiro batimento';
    if (hasMaps) {
      final heard = slots.where((s) => s.state == SlotState.heard).length;
      final lost = slots.where((s) => s.state == SlotState.lost).length;
      return '$heard ${heard == 1 ? 'batimento' : 'batimentos'} da placa '
          'ouvido${heard == 1 ? '' : 's'} em $minutes min · $lost '
          'perdido${lost == 1 ? '' : 's'}${quiet()}';
    }
    final n = own.length;
    return '$n ${n == 1 ? 'batimento' : 'batimentos'} da unidade em $minutes '
        'min · firmware sem mapa, mostra só os dela${quiet()}';
  }
}

class HeartbeatMonitorPainter extends CustomPainter {
  const HeartbeatMonitorPainter({required this.picture});

  final MonitorPicture picture;

  /// A monitor's screen and its green.
  static const screen = Color(0xFF050907);
  static const trace = Color(0xFF3CFF7A);
  static const grid = Color(0xFF123B22);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = screen);

    final span = picture.span.inSeconds;
    final pxPerS = size.width / span;
    final baseY = size.height * 0.66;

    // The grid: a line every 15 s (the beat cadence) and three across.
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 0.6;
    for (var s = 15; s < span; s += 15) {
      final x = size.width - s * pxPerS;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (final f in [0.22, 0.44, 0.88]) {
      final y = size.height * f;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // The board's beats: a tick under the line for every one it sent.
    final tickPaint = Paint()
      ..color = trace.withValues(alpha: 0.45)
      ..strokeWidth = 1.2;
    for (final s in picture.slots) {
      final x = _x(s.at, size.width, pxPerS);
      canvas.drawLine(
          Offset(x, size.height - 2), Offset(x, size.height - 8), tickPaint);
    }

    // The baseline, as one green line across the screen.
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = trace.withValues(alpha: 0.22);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = trace;
    final base = Path()
      ..moveTo(0, baseY)
      ..lineTo(size.width, baseY);
    canvas.drawPath(base, glow);
    canvas.drawPath(base, line);

    // One complex per beat heard — a small bump, the sharp spike, the dip,
    // back to the line; nothing for a lost one (the line stays flat over
    // its tick); a hollow dot for one not reported yet.
    final top = size.height * 0.12;
    final dip = baseY + size.height * 0.16;
    final pending = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = trace.withValues(alpha: 0.7);
    void spike(double x) {
      final p = Path()
        ..moveTo(x - 7, baseY)
        ..quadraticBezierTo(x - 5, baseY - size.height * 0.08, x - 3, baseY)
        ..lineTo(x - 1.2, top)
        ..lineTo(x + 1.0, dip)
        ..lineTo(x + 2.2, baseY)
        ..lineTo(x + 6, baseY);
      canvas.drawPath(p, glow);
      canvas.drawPath(p, line);
    }

    if (picture.hasMaps) {
      for (final s in picture.slots) {
        final x = _x(s.at, size.width, pxPerS);
        switch (s.state) {
          case SlotState.heard:
            spike(x);
          case SlotState.lost:
            break;
          case SlotState.pending:
            canvas.drawCircle(Offset(x, baseY), 2.6, Paint()..color = screen);
            canvas.drawCircle(Offset(x, baseY), 2.6, pending);
        }
      }
    } else {
      for (final b in picture.unitBeats) {
        spike(_x(b.at, size.width, pxPerS));
      }
    }

    // The present: a brighter edge at the right, where the trace is born.
    canvas.drawRect(
      Rect.fromLTWH(size.width - 2, 0, 2, size.height),
      Paint()..color = trace.withValues(alpha: 0.35),
    );
  }

  double _x(DateTime at, double width, double pxPerS) =>
      width - picture.now.difference(at).inMilliseconds / 1000 * pxPerS;

  @override
  bool shouldRepaint(HeartbeatMonitorPainter old) => true;
}
