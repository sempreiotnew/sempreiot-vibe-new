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
  const DeviceTempSection({super.key, required this.node});

  final TopologyNode node;

  static const keyTemp = ValueKey('device-temp-value');
  static const keyHumidity = ValueKey('device-humidity-value');
  static const keyAge = ValueKey('device-reading-age');
  static const keyChart = ValueKey('device-temp-chart');

  @override
  ConsumerState<DeviceTempSection> createState() => _DeviceTempSectionState();
}

class _DeviceTempSectionState extends ConsumerState<DeviceTempSection> {
  Timer? _tick;

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
        : ref.watch(deviceChartProvider(node.mac)).valueOrNull ??
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
                      Text(
                        'Temperatura na última hora',
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TempChart(
                        key: DeviceTempSection.keyChart,
                        points: points,
                        now: now,
                        muted: offline,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Só as leituras que chegaram: onde não há linha, '
                        'nenhuma chegou.',
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

/// Where the points of a chart go, and which of them a line joins — the
/// rule apart from the paint, so it can be checked: only the points of the
/// last [tempChartWindow], and a line only between two consecutive points
/// no more than [tempChartGap] apart.
class TempChartGeometry {
  TempChartGeometry({
    required List<TempPoint> points,
    required this.now,
  }) : points = [
          for (final p in points)
            if (!p.at.isBefore(now.subtract(tempChartWindow)) &&
                !p.at.isAfter(now))
              p,
        ] {
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
  }

  final DateTime now;

  /// The points drawn, oldest first.
  final List<TempPoint> points;
  late final int minTenths;
  late final int maxTenths;

  /// Index pairs (i, i + 1) a line is drawn between.
  List<(int, int)> get segments => [
        for (var i = 0; i + 1 < points.length; i++)
          if (points[i + 1].at.difference(points[i].at) <= tempChartGap)
            (i, i + 1),
      ];

  /// 0 at one hour ago, 1 at [now].
  double xOf(DateTime at) =>
      1 - now.difference(at).inMilliseconds / tempChartWindow.inMilliseconds;

  /// 0 at the bottom, 1 at the top.
  double yOf(int tenths) => (tenths - minTenths) / (maxTenths - minTenths);
}

/// The last hour of a unit's temperature: its points, a line between two
/// that followed each other, a gap where none arrived, and the 57 °C line.
/// No smoothing, no value between two points.
class TempChart extends StatelessWidget {
  const TempChart({
    super.key,
    required this.points,
    required this.now,
    this.muted = false,
  });

  final List<TempPoint> points;
  final DateTime now;

  /// The unit is not heard: drawn grey.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final geometry = TempChartGeometry(points: points, now: now);
    final line = muted
        ? context.textSecondary.withValues(alpha: 0.6)
        : AppColors.secondary;
    return Semantics(
      label: geometry.points.isEmpty
          ? 'Gráfico de temperatura: nenhuma leitura na última hora'
          : 'Gráfico de temperatura da última hora, '
              '${geometry.points.length} leituras, última '
              '${tempText(geometry.points.last.tenths)}',
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
                    line: line,
                    grid: context.borderColor.withValues(alpha: 0.6),
                    label: context.textSecondary,
                    limit: AppColors.error,
                  ),
                ),
              ),
              if (geometry.points.isEmpty)
                Center(
                  child: Text(
                    'Nenhuma leitura na última hora.',
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

class _TempChartPainter extends CustomPainter {
  _TempChartPainter({
    required this.geometry,
    required this.line,
    required this.grid,
    required this.label,
    required this.limit,
  });

  final TempChartGeometry geometry;
  final Color line;
  final Color grid;
  final Color label;
  final Color limit;

  static const _left = 34.0;
  static const _bottom = 18.0;
  static const _top = 6.0;
  static const _right = 6.0;

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

  @override
  void paint(Canvas canvas, Size size) {
    final plot =
        Rect.fromLTRB(_left, _top, size.width - _right, size.height - _bottom);
    if (plot.width <= 0 || plot.height <= 0) return;
    final g = geometry;
    Offset at(double x, double y) =>
        Offset(plot.left + x * plot.width, plot.bottom - y * plot.height);

    // Horizontal grid: every 10 °C (every 20 when the range is tall).
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 0.6;
    final span = g.maxTenths - g.minTenths;
    final step = span > 600 ? 200 : 100;
    for (var t = g.minTenths; t <= g.maxTenths; t += step) {
      final y = at(0, g.yOf(t)).dy;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      _text(canvas, '${t ~/ 10}°', Offset(plot.left - 5, y - 5), label,
          right: true);
    }
    // Time: one hour ago … now.
    for (final (x, text) in const [
      (0.0, '-60 min'),
      (0.5, '-30 min'),
      (1.0, 'agora'),
    ]) {
      final px = plot.left + x * plot.width;
      canvas.drawLine(
          Offset(px, plot.bottom), Offset(px, plot.bottom + 3), gridPaint);
      _text(canvas, text, Offset(px, plot.bottom + 6), label,
          right: x == 1.0, centre: x == 0.5);
    }

    // The fixed-temperature alarm: 57 °C, dashed (short lines — never a
    // Path: Flutter web leaks on drawPath in this project's version).
    final limitPaint = Paint()
      ..color = limit.withValues(alpha: 0.85)
      ..strokeWidth = 1.2;
    final ly = at(0, g.yOf(safrHeatAlarmTenths)).dy;
    for (var x = plot.left; x < plot.right; x += 9) {
      final end = x + 5 > plot.right ? plot.right : x + 5;
      canvas.drawLine(Offset(x, ly), Offset(end, ly), limitPaint);
    }
    _text(canvas, '57 °C', Offset(plot.right - 2, ly - 13), limit, right: true);

    // The readings: a line between two that followed each other, a dot on
    // every one — a lone point between two gaps is still seen.
    final linePaint = Paint()
      ..color = line
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    final where = [
      for (final p in g.points) at(g.xOf(p.at), g.yOf(p.tenths)),
    ];
    for (final (a, b) in g.segments) {
      canvas.drawLine(where[a], where[b], linePaint);
    }
    canvas.drawPoints(
      PointMode.points,
      where,
      Paint()
        ..color = line
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_TempChartPainter old) =>
      old.geometry.points.length != geometry.points.length ||
      old.geometry.now != geometry.now ||
      old.line != line ||
      old.grid != grid ||
      old.label != label;
}
