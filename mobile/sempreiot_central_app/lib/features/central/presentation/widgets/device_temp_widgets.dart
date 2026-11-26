import 'dart:async';
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/central_mirror_viewer.dart';
import '../../application/device_readings_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/readings/temp_reading.dart';
import '../../domain/safr/safr_v2_payloads.dart' show safrHeatAlarmTenths;
import 'device_detail_widgets.dart';

// Temperature and humidity on screen (phase 5 brief §8): the pill of a
// Dispositivos card and the "Temperatura e umidade" block of the Dispositivo
// screen. Quiet while normal; every number with its age; the chart draws
// the points that arrived and nothing else. Nothing here is an LED and
// nothing goes on the Rede map.

/// What the temperature pill of a card says.
enum TempPillState {
  /// A reading, nothing to say of it.
  normal,

  /// "Subindo": the central's own points show ≥ 4.0 °C within 60 s.
  rising,

  /// The unit is held in a heat alarm.
  alarm,

  /// The unit is not heard: the number is the last one it sent.
  offline,
}

/// The pill of [node]; null for a unit that never sent a reading (no pill).
TempPillState? tempPillState(TopologyNode node) {
  if (node.tempTenths == null) return null;
  if (!node.online) return TempPillState.offline;
  if (node.heatAlarm) return TempPillState.alarm;
  if (node.tempRising) return TempPillState.rising;
  return TempPillState.normal;
}

Color tempPillColor(BuildContext context, TempPillState state) =>
    switch (state) {
      TempPillState.normal => context.textSecondary,
      TempPillState.rising => AppColors.warning,
      TempPillState.alarm => AppColors.error,
      TempPillState.offline => context.textSecondary.withValues(alpha: 0.55),
    };

IconData tempPillIcon(TempPillState state) => switch (state) {
      TempPillState.rising => Icons.trending_up_rounded,
      TempPillState.alarm => Icons.local_fire_department_rounded,
      _ => Icons.thermostat_rounded,
    };

/// What a screen reader says of the pill beyond the number.
String tempPillSemantics(TopologyNode node, TempPillState state) {
  final value = tempText(node.tempTenths!);
  return switch (state) {
    TempPillState.normal => 'Temperatura $value',
    TempPillState.rising => 'Temperatura $value, subindo',
    TempPillState.alarm => 'Temperatura $value, alarme de calor',
    TempPillState.offline => 'Última temperatura $value, sem comunicação',
  };
}

/// "TEMPERATURA E UMIDADE" on the Dispositivo screen: the last reading
/// with its age (moving by itself), grey when the unit is not heard, and
/// the last hour of temperature with the 57 °C line. Renders nothing for a
/// unit that never sent a reading.
class DeviceTempSection extends ConsumerStatefulWidget {
  const DeviceTempSection({
    super.key,
    required this.node,
    this.zoomable = false,
  });

  final TopologyNode node;

  /// The readings screen: two fingers on the chart choose how much time it
  /// shows (5 min … 24 h) and its scales follow. Off: the last hour.
  final bool zoomable;

  static const keySpan = ValueKey('device-chart-span');

  static const keyTemp = ValueKey('device-temp-value');
  static const keyHumidity = ValueKey('device-humidity-value');
  static const keyAge = ValueKey('device-reading-age');
  static const keyChart = ValueKey('device-temp-chart');

  @override
  ConsumerState<DeviceTempSection> createState() => _DeviceTempSectionState();
}

class _DeviceTempSectionState extends ConsumerState<DeviceTempSection> {
  Timer? _tick;

  /// The readings screen: how much time the chart shows, and where the
  /// pinch in progress began.
  Duration _window = tempChartWindow;
  Duration _pinchFrom = tempChartWindow;

  @override
  void initState() {
    super.initState();
    // The age of the reading counts by itself.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final temp = node.tempTenths;
    final at = node.readingAt;
    if (temp == null || at == null) return const SizedBox.shrink();

    final now = DateTime.now().toUtc();
    final offline = !node.online;
    final viewOnly = ref.watch(mirrorViewOnlyProvider);
    final points = viewOnly
        ? const <TempPoint>[]
        : (widget.zoomable
                    ? ref.watch(deviceChartAllProvider(node.mac))
                    : ref.watch(deviceChartProvider(node.mac)))
                .valueOrNull ??
            const <TempPoint>[];
    final muted = context.textSecondary.withValues(alpha: 0.7);
    final valueColor = offline
        ? muted
        : node.heatAlarm
            ? AppColors.error
            : context.textPrimary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const InfoSectionHeader('TEMPERATURA E UMIDADE'),
        const SizedBox(height: 10),
        InfoCard(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Wrap(
              spacing: 28,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                _Reading(
                  key: DeviceTempSection.keyTemp,
                  icon: Icons.thermostat_rounded,
                  label: 'Temperatura',
                  value: tempText(temp),
                  color: valueColor,
                ),
                _Reading(
                  key: DeviceTempSection.keyHumidity,
                  icon: Icons.water_drop_outlined,
                  label: 'Umidade',
                  value: node.humidityPct == null
                      ? '—'
                      : humidityText(node.humidityPct!),
                  color: offline ? muted : context.textPrimary,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              offline
                  ? 'Última leitura ${readingAgeText(at, now)} · '
                      'sem comunicação'
                  : 'Leitura ${readingAgeText(at, now)}',
              key: DeviceTempSection.keyAge,
              style: TextStyle(
                color: offline ? AppColors.trouble : context.textSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const InfoRowDivider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: viewOnly
                ? Text(
                    'O gráfico da última hora fica na central.',
                    style:
                        TextStyle(color: context.textSecondary, fontSize: 12.5),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 16,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            // how much, and of which day
                            '${widget.zoomable ? _capital(chartWindowText(_window)) : 'Última hora'}'
                            ' · ${chartDateText(now.subtract(widget.zoomable ? _window : tempChartWindow), now)}',
                            key: DeviceTempSection.keySpan,
                            style: TextStyle(
                              color: context.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          TempChartLegend(muted: offline),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (!widget.zoomable)
                        TempChart(
                          key: DeviceTempSection.keyChart,
                          points: points,
                          now: now,
                          muted: offline,
                        )
                      else
                        // Two fingers: apart = closer (less time, finer
                        // scales), together = further. One finger is left
                        // to the screen's own scrolling.
                        GestureDetector(
                          onScaleStart: (_) => _pinchFrom = _window,
                          onScaleUpdate: (d) {
                            if (d.pointerCount < 2) return;
                            final next =
                                pinchedChartWindow(_pinchFrom, d.scale);
                            if (next != _window) {
                              setState(() => _window = next);
                            }
                          },
                          child: TempChart(
                            key: DeviceTempSection.keyChart,
                            points: points,
                            now: now,
                            muted: offline,
                            window: _window,
                          ),
                        ),
                      const SizedBox(height: 6),
                      Text(
                        widget.zoomable
                            ? 'Afaste dois dedos sobre o gráfico para ver '
                                'mais de perto, aproxime para ver mais '
                                'tempo. Só as leituras que chegaram: onde '
                                'não há linha, nenhuma chegou.'
                            : 'Só as leituras que chegaram: onde não há '
                                'linha, nenhuma chegou.',
                        style: TextStyle(color: muted, fontSize: 11.5),
                      ),
                    ],
                  ),
          ),
        ]),
      ],
    );
  }
}

String _capital(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

class _Reading extends StatelessWidget {
  const _Reading({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: context.textSecondary),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(color: context.textSecondary, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 28,
              height: 1.1,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      );
}

/// What the chart draws and where: the readings of its span, the two
/// scales and which neighbours are joined. Pure numbers — tested without a
/// canvas.
///
/// Two ways of choosing the temperature scale:
///  - the last-hour chart of the Dispositivo screen ([fit] false): whole
///    10 °C steps that always contain the 57 °C alarm line;
///  - the readings screen ([fit] true): around the readings in view, the
///    narrower the closer the zoom ([chartMinTempSpanTenths]), so the 57 °C
///    line is drawn only when it is inside what is shown.
/// Humidity has its own scale on the right in both.
class TempChartGeometry {
  TempChartGeometry({
    required List<TempPoint> points,
    required this.now,
    this.window = tempChartWindow,
    this.fit = false,
  }) : points = [
          for (final p in points)
            if (!p.at.isBefore(now.subtract(window)) && !p.at.isAfter(now)) p,
        ] {
    if (fit) {
      _fitTemperature();
    } else {
      var lo = safrHeatAlarmTenths;
      var hi = safrHeatAlarmTenths;
      for (final p in this.points) {
        if (p.tenths < lo) lo = p.tenths;
        if (p.tenths > hi) hi = p.tenths;
      }
      // Whole steps of 10 °C around what is drawn, the 57 °C line included.
      // With nothing to draw: 0 … 60 °C.
      minTenths = this.points.isEmpty ? 0 : (lo / 100).floor() * 100;
      maxTenths = (hi / 100).floor() * 100 + 100;
      tempStepTenths = maxTenths - minTenths > 600 ? 200 : 100;
    }
    _fitHumidity();
  }

  void _fitTemperature() {
    var lo = 200, hi = 300;
    if (points.isNotEmpty) {
      lo = hi = points.first.tenths;
      for (final p in points) {
        if (p.tenths < lo) lo = p.tenths;
        if (p.tenths > hi) hi = p.tenths;
      }
    }
    final least = chartMinTempSpanTenths(window);
    if (hi - lo < least) {
      final mid = (hi + lo) ~/ 2;
      lo = mid - least ~/ 2;
      hi = lo + least;
    }
    // Out to whole steps, with a little air above and below.
    var step = 200;
    for (final (upTo, s) in const [
      (12, 2),
      (30, 5),
      (60, 10),
      (120, 20),
      (300, 50),
      (600, 100),
    ]) {
      if (hi - lo <= upTo) {
        step = s;
        break;
      }
    }
    minTenths = ((lo - step / 4) / step).floor() * step;
    maxTenths = ((hi + step / 4) / step).ceil() * step;
    tempStepTenths = step;
  }

  void _fitHumidity() {
    int? lo, hi;
    for (final p in points) {
      final h = p.humidityPct;
      if (h == null) continue;
      if (lo == null || h < lo) lo = h;
      if (hi == null || h > hi) hi = h;
    }
    hasHumidity = lo != null;
    final least = fit ? chartMinHumiditySpan(window) : 20;
    // Bounds on whole 10 % — on whole 2 % when the zoom allows under 20 %.
    final unit = least >= 20 ? 10 : 2;
    var a = (lo ?? 40) ~/ unit * unit;
    var b = ((hi ?? 60) / unit).ceil() * unit;
    while (b - a < least) {
      a -= unit;
      if (b - a < least) b += unit;
    }
    if (a < 0) {
      b -= a;
      a = 0;
    }
    if (b > 100) {
      a -= b - 100;
      b = 100;
    }
    minHumidity = a < 0 ? 0 : a;
    maxHumidity = b;
  }

  final DateTime now;

  /// How much time is drawn, ending at [now].
  final Duration window;

  /// The scales follow the readings in view (the readings screen).
  final bool fit;

  /// The points drawn, oldest first.
  final List<TempPoint> points;
  late final int minTenths;
  late final int maxTenths;

  /// The distance between two grid lines, °C × 10.
  late final int tempStepTenths;

  /// At least one point carries a humidity.
  late final bool hasHumidity;
  late final int minHumidity;
  late final int maxHumidity;

  /// The 57 °C alarm line is inside the temperature scale.
  bool get showsLimit =>
      safrHeatAlarmTenths >= minTenths && safrHeatAlarmTenths <= maxTenths;

  /// Index pairs (i, i + 1) a temperature line is drawn between.
  List<(int, int)> get segments => [
        for (var i = 0; i + 1 < points.length; i++)
          if (points[i + 1].at.difference(points[i].at) <= tempChartGap)
            (i, i + 1),
      ];

  /// The same for humidity: both ends must carry one.
  List<(int, int)> get humiditySegments => [
        for (final (a, b) in segments)
          if (points[a].humidityPct != null && points[b].humidityPct != null)
            (a, b),
      ];

  /// 0 at the start of the span, 1 at [now].
  double xOf(DateTime at) =>
      1 - now.difference(at).inMilliseconds / window.inMilliseconds;

  /// 0 at the bottom, 1 at the top.
  double yOf(int tenths) => (tenths - minTenths) / (maxTenths - minTenths);

  /// 0 at the bottom, 1 at the top.
  double yOfHumidity(int pct) =>
      (pct - minHumidity) / (maxHumidity - minHumidity);
}

/// A unit's temperature (left scale) and humidity (right scale): the points
/// that arrived, a line between two that followed each other, a gap where
/// none arrived, and the 57 °C alarm line. No smoothing, no value between
/// two points. [window] null = the last hour on the fixed scale of the
/// Dispositivo screen; given = the readings screen's zoom.
class TempChart extends StatelessWidget {
  const TempChart({
    super.key,
    required this.points,
    required this.now,
    this.muted = false,
    this.window,
  });

  final List<TempPoint> points;
  final DateTime now;

  /// The unit is not heard: drawn grey.
  final bool muted;

  /// The readings screen: how much time is drawn; the scales follow.
  final Duration? window;

  /// The colour of the humidity line and of its scale.
  static const humidityColor = AppColors.info;

  /// The colour of the temperature line and of its scale: warm, so it is
  /// never taken for the humidity's blue (the theme's secondary is a blue
  /// too — the two lines could not be told apart).
  static const tempColor = AppColors.warning;

  @override
  Widget build(BuildContext context) {
    final geometry = TempChartGeometry(
      points: points,
      now: now,
      window: window ?? tempChartWindow,
      fit: window != null,
    );
    final grey = context.textSecondary.withValues(alpha: 0.6);
    final span = chartWindowText(geometry.window);
    final last = geometry.points.isEmpty ? null : geometry.points.last;
    return Semantics(
      label: last == null
          ? 'Gráfico de temperatura e umidade: nenhuma leitura, $span'
          : 'Gráfico de temperatura e umidade, $span, '
              '${geometry.points.length} leituras, última '
              '${tempText(last.tenths)}'
              '${last.humidityPct == null ? '' : ', ${humidityText(last.humidityPct!)}'}',
      child: LayoutBuilder(builder: (context, c) {
        // The same picture in both orientations: as wide as the card, a
        // height that follows the width inside limits.
        final height = (c.maxWidth * 0.36).clamp(140.0, 220.0);
        return SizedBox(
          width: double.infinity,
          height: height,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _TempChartPainter(
                    geometry: geometry,
                    line: muted ? grey : tempColor,
                    humidity: muted ? grey : humidityColor,
                    grid: context.borderColor.withValues(alpha: 0.6),
                    label: context.textSecondary,
                    limit: AppColors.error,
                  ),
                ),
              ),
              if (geometry.points.isEmpty)
                Center(
                  child: Text(
                    window == null
                        ? 'Nenhuma leitura na última hora.'
                        : 'Nenhuma leitura neste período.',
                    style:
                        TextStyle(color: context.textSecondary, fontSize: 12.5),
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }
}

/// "● Temperatura  ● Umidade": which line is which.
class TempChartLegend extends StatelessWidget {
  const TempChartLegend({super.key, this.muted = false});
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final grey = context.textSecondary.withValues(alpha: 0.6);
    Widget item(Color color, String text) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(
              text,
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        item(muted ? grey : TempChart.tempColor, 'Temperatura'),
        item(muted ? grey : TempChart.humidityColor, 'Umidade'),
      ],
    );
  }
}

class _TempChartPainter extends CustomPainter {
  _TempChartPainter({
    required this.geometry,
    required this.line,
    required this.humidity,
    required this.grid,
    required this.label,
    required this.limit,
  });

  final TempChartGeometry geometry;
  final Color line;
  final Color humidity;
  final Color grid;
  final Color label;
  final Color limit;

  static const _left = 40.0;
  static const _bottom = 18.0;
  static const _top = 6.0;
  static const _right = 34.0;

  /// More readings than this in view: no dot on each (they would be one
  /// thick band); the line says it.
  static const _dotsUpTo = 240;

  void _text(Canvas canvas, String text, Offset at, Color color,
      {bool right = false, bool centre = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: 10, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = right
        ? at.dx - tp.width
        : centre
            ? at.dx - tp.width / 2
            : at.dx;
    tp.paint(canvas, Offset(dx, at.dy));
  }

  /// One line: a stroke between two readings that followed each other, a
  /// dot on every reading — a lone one between two gaps is still seen.
  void _series(Canvas canvas, List<Offset?> where, List<(int, int)> segments,
      Color color) {
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    for (final (a, b) in segments) {
      canvas.drawLine(where[a]!, where[b]!, linePaint);
    }
    final joined = <int>{
      for (final (a, b) in segments) ...[a, b],
    };
    final dots = [
      for (var i = 0; i < where.length; i++)
        if (where[i] != null &&
            (where.length <= _dotsUpTo || !joined.contains(i)))
          where[i]!,
    ];
    if (dots.isEmpty) return;
    canvas.drawPoints(
      PointMode.points,
      dots,
      Paint()
        ..color = color
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final plot =
        Rect.fromLTRB(_left, _top, size.width - _right, size.height - _bottom);
    if (plot.width <= 0 || plot.height <= 0) return;
    final g = geometry;
    Offset at(double x, double y) =>
        Offset(plot.left + x * plot.width, plot.bottom - y * plot.height);

    // Horizontal grid on the temperature steps; its numbers on the left,
    // with the tenths when the lines are closer than 1 °C.
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 0.6;
    for (var t = g.minTenths; t <= g.maxTenths; t += g.tempStepTenths) {
      final y = at(0, g.yOf(t)).dy;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      final text = g.tempStepTenths < 10
          ? '${(t / 10).toStringAsFixed(1).replaceAll('.', ',')}°'
          : '${t ~/ 10}°';
      _text(canvas, text, Offset(plot.left - 5, y - 5), line, right: true);
    }
    // Humidity on the right, in its colour: bottom, middle, top.
    if (g.hasHumidity) {
      for (final h in {
        g.minHumidity,
        (g.minHumidity + g.maxHumidity) ~/ 2,
        g.maxHumidity,
      }) {
        final y = at(0, g.yOfHumidity(h)).dy;
        _text(canvas, '$h%', Offset(plot.right + 5, y - 5), humidity);
      }
    }
    // Time: the tablet's clock on round times (14:00, 14:15…), the day
    // in place of a midnight. As many marks as fit without touching.
    final start = g.now.subtract(g.window);
    for (final t in chartTimeTicks(start, g.now, (plot.width / 64).floor())) {
      final px = plot.left + g.xOf(t) * plot.width;
      canvas.drawLine(
          Offset(px, plot.bottom), Offset(px, plot.bottom + 3), gridPaint);
      final local = t.toLocal();
      final midnight = local.hour == 0 && local.minute == 0;
      _text(canvas, midnight ? chartDayText(t) : chartClockText(t),
          Offset(px, plot.bottom + 6), label,
          centre: true);
    }

    // The fixed-temperature alarm: 57 °C, dashed (short lines — never a
    // Path: Flutter web leaks on drawPath in this project's version).
    if (g.showsLimit) {
      final limitPaint = Paint()
        ..color = limit.withValues(alpha: 0.85)
        ..strokeWidth = 1.2;
      final ly = at(0, g.yOf(safrHeatAlarmTenths)).dy;
      for (var x = plot.left; x < plot.right; x += 9) {
        final end = x + 5 > plot.right ? plot.right : x + 5;
        canvas.drawLine(Offset(x, ly), Offset(end, ly), limitPaint);
      }
      _text(canvas, '57 °C', Offset(plot.right - 2, ly - 13), limit,
          right: true);
    }

    // Humidity first, the temperature over it.
    if (g.hasHumidity) {
      _series(
        canvas,
        [
          for (final p in g.points)
            p.humidityPct == null
                ? null
                : at(g.xOf(p.at), g.yOfHumidity(p.humidityPct!)),
        ],
        g.humiditySegments,
        humidity,
      );
    }
    _series(
      canvas,
      [for (final p in g.points) at(g.xOf(p.at), g.yOf(p.tenths))],
      g.segments,
      line,
    );
  }

  @override
  bool shouldRepaint(_TempChartPainter old) =>
      old.geometry.points.length != geometry.points.length ||
      old.geometry.now != geometry.now ||
      old.geometry.window != geometry.window ||
      old.line != line ||
      old.humidity != humidity ||
      old.grid != grid ||
      old.label != label;
}
