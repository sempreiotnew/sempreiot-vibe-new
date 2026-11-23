import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../application/central_mirror_codec.dart';
import '../../application/event_groups.dart';
import '../../application/root_election_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_v2_payloads.dart';
import '../screens/events_screen.dart';
import 'device_avatar.dart';
import 'device_menu.dart';
import 'device_state_tile.dart';

// Eventos' grouped view (2026-11-24): what event_groups.dart put together,
// drawn. A network incident is ONE tile — when, how long, how many units,
// where it began — with the units themselves on it, as Rede draws them; it
// opens into each unit's part on a common time line and the lines of the
// table it was made of. A unit that went silent and came back is one line.

/// A unit of an event, drawn as Rede draws it: its product's model in the
/// state it is in now. A tap opens the unit's card when this screen has
/// the map; a unit the map does not have is drawn from its name alone.
class EventUnitAvatar extends ConsumerWidget {
  const EventUnitAvatar({
    super.key,
    required this.mac,
    this.name,
    this.size = 36,
    this.tappable = true,
  });

  final String mac;
  final String? name;
  final double size;

  /// False inside something that is itself tapped (a line that opens the
  /// unit).
  final bool tappable;

  static ValueKey<String> keyOf(String mac) => ValueKey('event-unit-$mac');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(topologyProvider
        .select((nodes) => nodes.where((n) => n.mac == mac).firstOrNull));
    final node = live ??
        DeviceStateTile.describe(
            mac: mac, name: name == mac ? null : name, online: true);
    final isRoot = live != null &&
        live.online &&
        ref.watch(rootElectionProvider.select((e) => e.isRoot(mac)));
    final avatar = SizedBox(
      key: keyOf(mac),
      width: size,
      height: size,
      child: DeviceModelAvatar(
          node: node, isRoot: isRoot, size: size, typeIcon: false),
    );
    if (!tappable || live == null) {
      return Tooltip(message: deviceDisplayName(node), child: avatar);
    }
    return Tooltip(
      message: deviceDisplayName(node),
      child: Builder(builder: (avatarContext) {
        return InkResponse(
          radius: size * 0.7,
          onTap: () => showDeviceMenuFor(avatarContext, ref, mac),
          child: avatar,
        );
      }),
    );
  }
}

String _plural(int n, String one, String many) => n == 1 ? one : many;

String _names(List<IncidentUnit> units) {
  final names = [for (final u in units) u.name];
  if (names.length <= 1) return names.join();
  return '${names.sublist(0, names.length - 1).join(', ')} e ${names.last}';
}

/// What the tile says under its title.
List<String> incidentFacts(NetworkIncident g) {
  if (g.units.length == 1) {
    return g.units.single.words;
  }
  final origins = g.origins;
  final restarted = g.restarted;
  final roots = g.backAsRoot;
  return [
    if (origins.isNotEmpty && !g.originsAreAll) 'começou em ${_names(origins)}',
    if (restarted == g.units.length)
      'todos reiniciaram sozinhos'
    else if (restarted > 0)
      '$restarted ${_plural(restarted, 'reiniciou sozinho', 'reiniciaram sozinhos')}',
    if (roots.isNotEmpty) '${_names(roots)} voltou como raiz',
  ];
}

String incidentTitle(NetworkIncident g) => g.reorganisation
    ? (g.units.length == 1
        ? '${g.units.single.name} — procurou um sinal melhor · '
            '${SafrOutageReportPayload.span(g.duration)} sem caminho até a '
            'central'
        : 'A rede se reorganizou para um sinal melhor · '
            '${g.units.length} dispositivos · '
            '${SafrOutageReportPayload.span(g.duration)}')
    : g.units.length == 1
        ? '${g.units.single.name} — ficou '
            '${SafrOutageReportPayload.span(g.duration)} sem caminho até a central'
        : '${g.units.length} dispositivos ficaram '
            '${SafrOutageReportPayload.span(g.duration)} sem caminho até a central';

/// A network incident: one tile, opening into its units and its lines.
class IncidentTile extends StatefulWidget {
  const IncidentTile({
    super.key,
    required this.incident,
    required this.wide,
    this.columns = false,
  });

  final NetworkIncident incident;

  /// One line (a tablet, the web) or stacked (a phone).
  final bool wide;

  /// Its lines show Zona and Endereçamento in columns.
  final bool columns;

  static ValueKey<String> keyOf(NetworkIncident g) =>
      ValueKey('incident-${g.from.millisecondsSinceEpoch}');
  static ValueKey<String> keyToggle(NetworkIncident g) =>
      ValueKey('incident-toggle-${g.from.millisecondsSinceEpoch}');

  /// How many units the closed tile draws before "+ N".
  static const maxAvatars = 6;

  @override
  State<IncidentTile> createState() => _IncidentTileState();
}

class _IncidentTileState extends State<IncidentTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final g = widget.incident;
    final wide = widget.wide;
    // Re-forming on purpose is news; a unit lost is a trouble.
    final kind =
        g.reorganisation ? PanelEventKind.info : PanelEventKind.trouble;
    final facts = incidentFacts(g);

    final clockStyle = TextStyle(
      color: context.textPrimary,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final untilStyle = TextStyle(
      color: context.textSecondary,
      fontSize: 12,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final title = Text(
      incidentTitle(g),
      style: TextStyle(
        color: context.textPrimary,
        fontSize: 14.5,
        fontWeight: FontWeight.w700,
        height: 1.3,
      ),
    );
    final sub = facts.isEmpty
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              facts.join(' · '),
              style: TextStyle(
                  color: context.textSecondary, fontSize: 13, height: 1.3),
            ),
          );
    final shown = g.units.reversed.take(IncidentTile.maxAvatars).toList();
    final hidden = g.units.length - shown.length;
    final avatars = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final u in shown)
          if (u.mac != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: EventUnitAvatar(mac: u.mac!, name: u.name, size: 38),
            ),
        if (hidden > 0)
          Text(
            '+ $hidden',
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
      ],
    );
    final chevron = AnimatedRotation(
      turns: _open ? 0.5 : 0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: Icon(Icons.expand_more_rounded,
          size: 22, color: context.textSecondary),
    );
    final badge = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: EventKindBadge(kind),
    );

    final head = wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 64,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(eventClock(g.from), style: clockStyle),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text('até ${eventClock(g.to)}', style: untilStyle),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 124,
                child: Padding(
                    padding: const EdgeInsets.only(right: 12), child: badge),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [title, if (sub != null) sub],
                ),
              ),
              const SizedBox(width: 12),
              avatars,
              const SizedBox(width: 6),
              Text(
                relativeTime(g.at),
                style: TextStyle(color: context.textSecondary, fontSize: 12),
              ),
              SizedBox(width: 28, child: chevron),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(child: badge),
                  const SizedBox(width: 8),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${eventClock(g.from)} – ${eventClock(g.to)}',
                        style: clockStyle,
                      ),
                    ),
                  ),
                  chevron,
                ],
              ),
              const SizedBox(height: 6),
              title,
              if (sub != null) sub,
              const SizedBox(height: 8),
              SingleChildScrollView(
                  scrollDirection: Axis.horizontal, child: avatars),
            ],
          );

    final radius = BorderRadius.circular(12);
    return Material(
      key: IncidentTile.keyOf(g),
      color: context.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: kind.color.withValues(alpha: _open ? 0.55 : 0.35),
          width: 0.8,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      // The kind's colour down the left edge (no IntrinsicHeight: the
      // open tile lays its bars out by the width it gets).
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: kind.color, width: 4)),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                button: true,
                expanded: _open,
                child: InkWell(
                  key: IncidentTile.keyToggle(g),
                  onTap: () => setState(() => _open = !_open),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                    child: head,
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: !_open
                    ? const SizedBox(width: double.infinity)
                    : _IncidentBody(
                        incident: g, wide: wide, columns: widget.columns),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          color: context.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        ),
      );
}

/// The open tile: each unit's part on one time line, then the lines.
class _IncidentBody extends StatelessWidget {
  const _IncidentBody({
    required this.incident,
    required this.wide,
    required this.columns,
  });

  final NetworkIncident incident;
  final bool wide;
  final bool columns;

  @override
  Widget build(BuildContext context) {
    final g = incident;
    // The first to lose the path on top.
    final units = [...g.units]..sort((a, b) => a.from.compareTo(b.from));
    final lines = g.lines;
    final clock = TextStyle(
      color: context.textSecondary,
      fontSize: 11.5,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(height: 1, color: context.borderColor.withValues(alpha: 0.6)),
          const SizedBox(height: 10),
          Row(
            children: [
              const Expanded(child: _Caption('SEM CAMINHO ATÉ A CENTRAL')),
              Text('${eventClock(g.from)} – ${eventClock(g.to)}', style: clock),
            ],
          ),
          const SizedBox(height: 8),
          for (final u in units)
            _UnitPart(
              unit: u,
              from: g.from,
              to: g.to,
              origin: u.origin && !g.originsAreAll,
              color: g.reorganisation ? AppColors.info : AppColors.warning,
              wide: wide,
            ),
          const SizedBox(height: 6),
          _Caption('LINHAS DO REGISTRO · ${lines.length}'),
          const SizedBox(height: 8),
          for (final e in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child:
                  EventRow(event: e, wide: wide, columns: columns, inset: true),
            ),
        ],
      ),
    );
  }
}

/// One unit of an incident: the unit, its bar on the incident's time line,
/// how long, and what it says happened.
class _UnitPart extends StatelessWidget {
  const _UnitPart({
    required this.unit,
    required this.from,
    required this.to,
    required this.origin,
    required this.color,
    required this.wide,
  });

  /// The incident's colour: a trouble's, or news'.
  final Color color;

  final IncidentUnit unit;
  final DateTime from;
  final DateTime to;
  final bool origin;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final r = unit.report;
    final total = to.difference(from).inMilliseconds;
    final start =
        total <= 0 ? 0.0 : unit.from.difference(from).inMilliseconds / total;
    final end =
        total <= 0 ? 1.0 : unit.to.difference(from).inMilliseconds / total;

    final name = Text(
      unit.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: context.textPrimary,
        fontSize: 13.5,
        fontWeight: FontWeight.w700,
      ),
    );
    final originChip = !origin
        ? null
        : Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: context.isDark ? 0.18 : 0.14),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'ONDE COMEÇOU',
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
          );
    final span = Text(
      SafrOutageReportPayload.span(r.duration),
      style: TextStyle(
        color: context.textPrimary,
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final bar = LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final left = (w * start).clamp(0.0, w);
      final width =
          (w * (end - start)).clamp(4.0, w - left < 4 ? 4.0 : w - left);
      return SizedBox(
        height: 10,
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: context.borderColor.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
            Positioned(
              left: left,
              width: width,
              top: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color.withValues(alpha: origin ? 1 : 0.7),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
          ],
        ),
      );
    });
    final words = Text(
      unit.words.join(' · '),
      style:
          TextStyle(color: context.textSecondary, fontSize: 12.5, height: 1.3),
    );
    final mac = unit.mac;
    final zone = unit.event.zone, address = unit.event.address;
    final place = [
      if (zone?.isNotEmpty == true) zone!,
      if (address?.isNotEmpty == true) address!,
    ].join(' · ');
    final who = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(child: name),
            if (originChip != null)
              Flexible(
                child: FittedBox(fit: BoxFit.scaleDown, child: originChip),
              ),
          ],
        ),
        // Where the unit is: its zona and its endereçamento.
        if (place.isNotEmpty)
          Text(
            place,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: context.textSecondary, fontSize: 12),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (mac != null)
            Padding(
              padding: const EdgeInsets.only(right: 10, top: 2),
              child: EventUnitAvatar(mac: mac, name: unit.name, size: 44),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    // Wide: the name and the time each keep a column of
                    // their own, so every unit's bar is on the same time
                    // line. Narrow: the bar has the line under them.
                    if (wide)
                      SizedBox(width: 230, child: who)
                    else
                      Expanded(child: who),
                    const SizedBox(width: 8),
                    if (wide) ...[
                      Expanded(child: bar),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 84,
                        child: Align(
                            alignment: Alignment.centerRight, child: span),
                      ),
                    ] else
                      span,
                  ],
                ),
                if (!wide) ...[const SizedBox(height: 6), bar],
                const SizedBox(height: 4),
                words,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A unit that went silent and was heard again: one line, how long.
class CommGapRow extends ConsumerWidget {
  const CommGapRow({
    super.key,
    required this.gap,
    required this.wide,
    this.columns = false,
  });

  final CommGap gap;
  final bool wide;
  final bool columns;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final who = gap.restored.who ?? gap.restored.mac ?? 'Dispositivo';
    return EventRow(
      wide: wide,
      columns: columns,
      avatar: true,
      event: MirrorPanelEvent(
        at: gap.restored.at,
        severity: 1,
        // Inside a reorganisation both lines are news already.
        kind: gap.missing.kind == PanelEventKind.info
            ? PanelEventKind.info
            : PanelEventKind.trouble,
        mac: gap.restored.mac,
        zone: gap.restored.zone,
        address: gap.restored.address,
        text: '$who — ficou ${SafrOutageReportPayload.span(gap.duration)} '
            'sem comunicação · das ${eventClock(gap.missing.at)} às '
            '${eventClock(gap.restored.at)} · voltou a comunicar',
      ),
    );
  }
}
