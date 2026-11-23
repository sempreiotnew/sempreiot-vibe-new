import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../../../features/central/application/central_mirror_codec.dart';
import '../../../../features/central/application/panel_provider.dart';
import '../../../../features/central/presentation/screens/event_history_screen.dart';
import '../../../../features/central/presentation/widgets/latched_alarm_banner.dart';
import '../../../../features/central/presentation/widgets/remote_alarm_banner.dart';
import '../../../../features/iot/application/presence_provider.dart';
import 'panel_objects.dart';

// Principal, redesigned (2026-11-19): one block that says the system's
// state, then the central's links, its battery and temperature, and the
// last events. The same widgets on the tablet ([centralId] null: its own
// data) and on a user's phone (the viewed central's, from the cloud).

/// The colour of an event's severity (DeviceEvents.severity):
/// 0 ok · 1 trouble · 2 alert · 3 alarm.
Color panelSeverityColor(int severity) => switch (severity) {
      3 => AppColors.error,
      2 => AppColors.trouble,
      1 => AppColors.warning,
      _ => AppColors.success,
    };

String panelSeverityLabel(int severity) => switch (severity) {
      3 => 'ALARME',
      2 => 'ALERTA',
      1 => 'PROBLEMA',
      _ => 'OK',
    };

/// A card of Principal: the theme's surface, a thin border, a small
/// caption on top.
class PanelCard extends StatelessWidget {
  const PanelCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.minHeight = 0,
  });

  final String title;
  final Widget child;
  final Widget? trailing;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(minHeight: minHeight),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: context.borderColor.withValues(alpha: 0.7),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// Principal's layout: the state block, then Comunicação and Energia —
/// side by side on a wide screen (the tablet, the web), one under the
/// other on a phone — then the last events. Always scrollable: a short
/// landscape screen shows the top and scrolls to the rest.
class PrincipalBody extends StatelessWidget {
  const PrincipalBody({
    super.key,
    required this.commBuilder,
    this.centralId,
    this.header,
    this.dim,
  });

  /// Null on the tablet; the viewed central on a user's phone.
  final String? centralId;

  /// Shown above the state block (the tablet's "another installation"
  /// warning).
  final Widget? header;

  /// The Comunicação card, at least as tall as asked.
  final Widget Function(double minHeight) commBuilder;

  /// Wraps what is below the state block (a phone greys it out while the
  /// central is offline).
  final Widget Function(Widget child)? dim;

  /// The tablet's own battery and temperature are not read yet: these are
  /// the placeholders the screen always showed.
  static const batteryPercent = 78;
  static const celsius = 32.0;

  /// Comunicação and Energia side by side stand as tall as each other.
  static const _pairHeight = 196.0;

  /// From this width the two cards share a row.
  static const wideFrom = 900.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= wideFrom;
      final comm = commBuilder(wide ? _pairHeight : 0);
      final energy = EnergyCard(
        batteryPercent: batteryPercent,
        celsius: celsius,
        minHeight: wide ? _pairHeight : 0,
      );
      const gap = SizedBox(height: 12, width: 12);
      final rest = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: comm),
                gap,
                Expanded(flex: 2, child: energy),
              ],
            )
          else ...[comm, gap, energy],
          gap,
          PanelEventsCard(centralId: centralId, rows: wide ? 4 : 3),
        ],
      );

      return SingleChildScrollView(
        padding: EdgeInsets.all(wide ? 16 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (header != null) header!,
            // The system's state — and, in alarm, the devices held: the
            // tablet reads its own latches (with Rearmar); a user's phone
            // the central's retained list (no reset from a phone).
            SystemStatusBlock(centralId: centralId),
            gap,
            dim?.call(rest) ?? rest,
          ],
        ),
      );
    });
  }
}

enum _SystemState { unknown, offline, normal, trouble, alarm }

/// "Estado do sistema": the one answer to "is everything fine?" — normal
/// (green), units that need attention (amber) or alarm (red) — with the
/// three counts, and in alarm the devices held and their Rearmar (the
/// alarm-hold banner, inside the block).
class SystemStatusBlock extends ConsumerWidget {
  const SystemStatusBlock({super.key, this.centralId});

  /// Null on the tablet; the viewed central on a user's phone.
  final String? centralId;

  static const keyTitle = ValueKey('system-state-title');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(panelViewProvider(centralId));
    final presence = centralId == null
        ? PresenceStatus.online
        : ref.watch(presenceStatusProvider(centralId!));

    // An alarm held is said first, even with the central out of reach: the
    // retained list still says what it held.
    final state = view.alarms > 0
        ? _SystemState.alarm
        : presence == PresenceStatus.offline
            ? _SystemState.offline
            : !view.known || presence == PresenceStatus.unknown
                ? _SystemState.unknown
                : view.troubles > 0
                    ? _SystemState.trouble
                    : _SystemState.normal;

    final muted = context.textSecondary;
    final (Color tone, IconData icon, String title, String sub) =
        switch (state) {
      _SystemState.alarm => (
          AppColors.error,
          Icons.local_fire_department_rounded,
          view.alarms == 1
              ? 'ALARME — 1 dispositivo'
              : 'ALARME — ${view.alarms} dispositivos',
          presence == PresenceStatus.offline
              ? 'A central está sem conexão: esta é a última informação '
                  'que ela enviou.'
              : '',
        ),
      _SystemState.offline => (
          muted,
          Icons.cloud_off_rounded,
          'Central sem conexão',
          'O que aparece abaixo é a última informação que ela enviou.',
        ),
      _SystemState.unknown => (
          muted,
          Icons.hourglass_empty_rounded,
          'Verificando…',
          'Aguardando a informação da central.',
        ),
      _SystemState.trouble => (
          AppColors.warning,
          Icons.warning_amber_rounded,
          view.troubles == 1 ? '1 problema' : '${view.troubles} problemas',
          view.troubles == 1
              ? 'Há um dispositivo que precisa de atenção.'
              : 'Há dispositivos que precisam de atenção.',
        ),
      _SystemState.normal => (
          AppColors.success,
          Icons.check_rounded,
          'Sistema normal',
          // A central that sends its alarms only (its app is older): the
          // number of units is not known — never "none installed".
          !view.eventsKnown
              ? 'Nenhum alarme retido na central.'
              : view.total == 0
                  ? 'Nenhum dispositivo instalado ainda.'
                  : view.ok == 1
                      ? 'Nenhum alarme, nenhum problema. 1 dispositivo '
                          'respondendo.'
                      : 'Nenhum alarme, nenhum problema. ${view.ok} '
                          'dispositivos respondendo.',
        ),
    };

    final dark = context.isDark;
    final headline = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: tone, width: 2),
          ),
          child: Icon(icon, color: tone, size: 30),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'ESTADO DO SISTEMA',
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                title,
                key: keyTitle,
                style: TextStyle(
                  color: tone,
                  fontSize: 26,
                  height: 1.1,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (sub.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  sub,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    // A central whose app publishes its alarms only: no numbers to show.
    final counters = !view.known || !view.eventsKnown
        ? null
        : _Counters(alarms: view.alarms, troubles: view.troubles, ok: view.ok);

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
            tone.withValues(alpha: dark ? 0.10 : 0.06), context.surfaceColor),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tone.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          LayoutBuilder(builder: (context, c) {
            // Wide (the tablet): the counts beside the headline. Narrow
            // (a phone): under it, across the block.
            if (counters == null) return headline;
            if (c.maxWidth >= 720) {
              return Row(
                children: [
                  Expanded(child: headline),
                  const SizedBox(width: 16),
                  SizedBox(width: 330, child: counters),
                ],
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [headline, const SizedBox(height: 14), counters],
            );
          }),
          if (state == _SystemState.trouble && view.troubleList.isNotEmpty) ...[
            const SizedBox(height: 12),
            _TroubleChips(troubles: view.troubleList, total: view.troubles),
          ],
          if (state == _SystemState.alarm) ...[
            const SizedBox(height: 14),
            if (centralId == null)
              const LatchedAlarmBanner(embedded: true)
            else
              RemoteAlarmBanner(identityId: centralId!, embedded: true),
          ],
        ],
      ),
    );
  }
}

class _Counters extends StatelessWidget {
  const _Counters(
      {required this.alarms, required this.troubles, required this.ok});

  final int alarms;
  final int troubles;
  final int ok;

  @override
  Widget build(BuildContext context) {
    Widget tile(int value, String label, Color color) => Expanded(
          child: Semantics(
            label: '$value $label',
            excludeSemantics: true,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: context.bgColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: context.borderColor.withValues(alpha: 0.8)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$value',
                    style: TextStyle(
                      color: color,
                      fontSize: 26,
                      height: 1.1,
                      fontWeight: FontWeight.w900,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      maxLines: 1,
                      style:
                          TextStyle(color: context.textPrimary, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

    return Row(
      children: [
        tile(alarms, 'Alarmes', AppColors.error),
        const SizedBox(width: 8),
        tile(troubles, 'Problemas', AppColors.warning),
        const SizedBox(width: 8),
        tile(ok, 'OK', AppColors.success),
      ],
    );
  }
}

/// The units that need attention, by name and why.
class _TroubleChips extends StatelessWidget {
  const _TroubleChips({required this.troubles, required this.total});

  final List<MirrorTrouble> troubles;
  final int total;

  static const _shown = 6;

  @override
  Widget build(BuildContext context) {
    final more = total - troubles.take(_shown).length;
    Widget chip(String name, String? why) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: context.bgColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (why != null) ...[
                const SizedBox(width: 8),
                Text(
                  why,
                  style: TextStyle(color: context.textSecondary, fontSize: 12),
                ),
              ],
            ],
          ),
        );

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final t in troubles.take(_shown))
          chip(
            t.name,
            t.why == MirrorTrouble.battery
                ? 'bateria baixa'
                : 'sem comunicação',
          ),
        if (more > 0) chip('+ $more', null),
      ],
    );
  }
}

/// "Energia e temperatura da central": its battery and its thermometer as
/// objects, the number beside each.
class EnergyCard extends StatelessWidget {
  const EnergyCard({
    super.key,
    required this.batteryPercent,
    required this.celsius,
    this.minHeight = 0,
  });

  final int batteryPercent;
  final double celsius;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final batteryColor = batteryPercent > 50
        ? AppColors.success
        : batteryPercent > 20
            ? AppColors.warning
            : AppColors.error;
    final heatColor = celsius < 30
        ? AppColors.success
        : celsius < 50
            ? AppColors.warning
            : AppColors.error;

    Widget gadget(Widget object, String value, String unit) => Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              object,
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        value,
                        maxLines: 1,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 30,
                          height: 1,
                          fontWeight: FontWeight.w900,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      unit,
                      style:
                          TextStyle(color: context.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

    return PanelCard(
      title: 'ENERGIA E TEMPERATURA DA CENTRAL',
      minHeight: minHeight,
      child: ConstrainedBox(
        // Beside Comunicação (a wide screen) the two stand in the middle
        // of the card's height.
        constraints:
            BoxConstraints(minHeight: minHeight > 0 ? minHeight - 62 : 0),
        child: Row(
          children: [
            gadget(
              PanelObject(
                kind: PanelObjectKind.battery,
                accent: batteryColor,
                level: batteryPercent / 100,
                width: minHeight > 0 ? 72 : 60,
                semanticLabel: 'Bateria',
              ),
              '$batteryPercent%',
              'bateria',
            ),
            const SizedBox(width: 8),
            gadget(
              PanelObject(
                kind: PanelObjectKind.thermometer,
                accent: heatColor,
                // 0–80 °C over the column.
                level: celsius / 80,
                width: minHeight > 0 ? 54 : 46,
                semanticLabel: 'Temperatura',
              ),
              '${celsius.round()}°',
              'celsius',
            ),
          ],
        ),
      ),
    );
  }
}

/// One event: its severity as a dot (and a word where there is room),
/// what happened, how long ago.
class PanelEventRow extends StatelessWidget {
  const PanelEventRow({
    super.key,
    required this.event,
    this.showKind = true,
    this.exactTime = false,
  });

  final MirrorPanelEvent event;

  /// The severity's word beside the dot (wide layouts).
  final bool showKind;

  /// The day and time instead of "há 2 min" (the history screen).
  final bool exactTime;

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String exact(DateTime utc) {
    final t = utc.toLocal();
    return '${_two(t.day)}/${_two(t.month)} '
        '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final color = panelSeverityColor(event.severity);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 10),
          if (showKind)
            SizedBox(
              width: 84,
              child: Text(
                panelSeverityLabel(event.severity),
                style: TextStyle(
                  color: color,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          Expanded(
            child: Text(
              event.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.textPrimary, fontSize: 13.5),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            exactTime ? exact(event.at) : relativeTime(event.at),
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Últimos eventos": the newest few, and "Ver todos" for the history.
class PanelEventsCard extends ConsumerWidget {
  const PanelEventsCard({super.key, this.centralId, this.rows = 4});

  final String? centralId;

  /// How many events the card shows.
  final int rows;

  static const keySeeAll = ValueKey('events-see-all');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(panelViewProvider(centralId));
    final events = view.events.take(rows).toList();

    return PanelCard(
      title: 'ÚLTIMOS EVENTOS',
      trailing: !view.eventsKnown
          ? null
          : TextButton(
              key: keySeeAll,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => EventHistoryScreen(centralId: centralId),
                ),
              ),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.secondary,
                minimumSize: const Size(44, 44),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Ver todos',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
      child: LayoutBuilder(builder: (context, c) {
        if (!view.eventsKnown) {
          return _EventsNote(view.known
              ? 'A central ainda não envia os eventos: atualize o app da '
                  'central.'
              : 'Aguardando a informação da central.');
        }
        if (events.isEmpty) {
          return const _EventsNote('Nenhum evento registrado ainda.');
        }
        final wide = c.maxWidth >= 560;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in events) ...[
              Divider(
                  height: 1,
                  thickness: 0.8,
                  color: context.borderColor.withValues(alpha: 0.7)),
              PanelEventRow(event: e, showKind: wide),
            ],
          ],
        );
      }),
    );
  }
}

class _EventsNote extends StatelessWidget {
  const _EventsNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(
          text,
          style: TextStyle(color: context.textSecondary, fontSize: 13),
        ),
      );
}
