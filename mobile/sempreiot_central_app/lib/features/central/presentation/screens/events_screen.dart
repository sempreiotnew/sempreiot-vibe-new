import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../application/central_mirror_codec.dart';
import '../../application/event_groups.dart';
import '../../application/events_view_prefs.dart';
import '../../application/panel_provider.dart';
import '../../application/topology_provider.dart';
import '../widgets/device_menu.dart';
import '../widgets/event_group_tiles.dart';

// Eventos (2026-11-23): its own tab, where Principal's "Últimos eventos"
// card and its "Ver todos" screen used to be. Everything the central
// listed, newest first, by day and to the second; filtered by kind and by
// what is typed; a line about a unit opens that unit.
//
// Two views (2026-11-24), a switch beside the filters: "Agrupado" — the
// lines of one network incident in one tile, a unit's silence and its
// return in one line (event_groups.dart, event_group_tiles.dart) — and
// "Linhas", every line of the table by itself.
//
// On the tablet ([EventsScreen.centralId] null): its own event table, a
// page at a time. On a user's phone: the events the central keeps on the
// cloud — its last 20 — and a line saying the rest is at the central.

/// The word, the colour and the icon an event's kind is listed with.
extension PanelEventKindStyle on PanelEventKind {
  String get label => switch (this) {
        PanelEventKind.alarm => 'ALARME',
        PanelEventKind.alert => 'ALERTA',
        PanelEventKind.trouble => 'PROBLEMA',
        PanelEventKind.info => 'AVISO',
        PanelEventKind.ok => 'OK',
      };

  /// The filter's word (plural).
  String get filterLabel => switch (this) {
        PanelEventKind.alarm => 'Alarmes',
        PanelEventKind.alert => 'Alertas',
        PanelEventKind.trouble => 'Problemas',
        PanelEventKind.info => 'Avisos',
        PanelEventKind.ok => 'OK',
      };

  Color get color => switch (this) {
        PanelEventKind.alarm => AppColors.error,
        PanelEventKind.alert => AppColors.trouble,
        PanelEventKind.trouble => AppColors.warning,
        PanelEventKind.info => AppColors.info,
        PanelEventKind.ok => AppColors.success,
      };

  IconData get icon => switch (this) {
        PanelEventKind.alarm => Icons.local_fire_department_rounded,
        PanelEventKind.alert => Icons.warning_amber_rounded,
        PanelEventKind.trouble => Icons.error_outline_rounded,
        PanelEventKind.info => Icons.info_outline_rounded,
        PanelEventKind.ok => Icons.check_circle_outline_rounded,
      };
}

/// The filters, most serious first.
const _filterOrder = [
  PanelEventKind.alarm,
  PanelEventKind.alert,
  PanelEventKind.trouble,
  PanelEventKind.info,
  PanelEventKind.ok,
];

String _two(int v) => v.toString().padLeft(2, '0');

/// `14:03:27`, the tablet's clock.
String eventClock(DateTime utc) {
  final t = utc.toLocal();
  return '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
}

/// `Hoje`, `Ontem` or `23/11/2026`.
String eventDay(DateTime utc, DateTime now) {
  final t = utc.toLocal();
  final n = now.toLocal();
  final days = DateTime(n.year, n.month, n.day)
      .difference(DateTime(t.year, t.month, t.day))
      .inDays;
  final date = '${_two(t.day)}/${_two(t.month)}/${t.year}';
  return switch (days) {
    0 => 'Hoje · $date',
    1 => 'Ontem · $date',
    _ => date,
  };
}

class EventsScreen extends ConsumerStatefulWidget {
  const EventsScreen({super.key, this.centralId});

  /// Null on the tablet; the viewed central on a user's phone.
  final String? centralId;

  static const keySearch = ValueKey('events-search');
  static const keyClear = ValueKey('events-clear');
  static const keyShowAll = ValueKey('events-show-all');
  static const keyMore = ValueKey('events-more');
  static const keyGrouped = ValueKey('events-view-grouped');
  static const keyLines = ValueKey('events-view-lines');
  static ValueKey<String> keyFilter(PanelEventKind? k) =>
      ValueKey('events-filter-${k?.name ?? 'all'}');

  @override
  ConsumerState<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends ConsumerState<EventsScreen> {
  final _search = TextEditingController();
  String _query = '';
  PanelEventKind? _filter;
  int _limit = eventsPageSize;

  /// Under this height the toolbar scrolls with the list.
  static const shortBelow = 480.0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final centralId = widget.centralId;
    final remote = centralId != null;
    final view = remote ? ref.watch(panelViewProvider(centralId)) : null;
    final loaded =
        remote ? view!.events : ref.watch(localPanelEventsProvider(_limit));
    final clearedAt = ref.watch(eventsClearedAtProvider(centralId));
    final grouped = ref.watch(eventsGroupedProvider);

    // A phone before the central's message, or a central whose app does
    // not send its events.
    if (view != null && !view.eventsKnown) {
      return _Empty(
        icon: Icons.hourglass_empty_rounded,
        title: view.known ? 'Sem eventos da central' : 'Verificando…',
        subtitle: view.known
            ? 'A central ainda não envia os eventos: atualize o app da '
                'central.'
            : 'Aguardando a informação da central.',
      );
    }

    // The network re-forming on purpose is news, in both views and in
    // the filters' counts (event_groups.dart).
    final listed = listReorganisationsAsNews(clearedAt == null
        ? loaded
        : [
            for (final e in loaded)
              if (e.at.isAfter(clearedAt)) e
          ]);
    final counts = <PanelEventKind, int>{};
    for (final e in listed) {
      counts[e.kind] = (counts[e.kind] ?? 0) + 1;
    }
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final e in listed)
        if ((_filter == null || e.kind == _filter) &&
            (q.isEmpty ||
                e.text.toLowerCase().contains(q) ||
                (e.zone?.toLowerCase().contains(q) ?? false) ||
                (e.address?.toLowerCase().contains(q) ?? false)))
          e
    ];
    // The table may hold more than was read (the tablet only).
    final more = !remote && loaded.length >= _limit;

    final top = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Toolbar(
          controller: _search,
          onQuery: (v) => setState(() => _query = v),
          filter: _filter,
          total: listed.length,
          counts: counts,
          onFilter: (k) => setState(() => _filter = k),
          grouped: grouped,
          onGrouped: (v) => ref.read(eventsGroupedProvider.notifier).set(v),
          canClear: listed.isNotEmpty,
          onClear: () =>
              ref.read(eventsClearedAtProvider(centralId).notifier).clear(),
        ),
        if (clearedAt != null)
          _ClearedLine(
            at: clearedAt,
            onShowAll: () =>
                ref.read(eventsClearedAtProvider(centralId).notifier).showAll(),
          ),
      ],
    );
    final empty = shown.isNotEmpty
        ? null
        : _EmptyContent(
            icon: listed.isEmpty
                ? Icons.receipt_long_rounded
                : Icons.search_off_rounded,
            title: listed.isEmpty
                ? (clearedAt != null
                    ? 'Nenhum evento desde a limpeza'
                    : 'Nenhum evento registrado ainda')
                : 'Nada encontrado',
            subtitle: listed.isEmpty
                ? 'O que acontecer na instalação aparece aqui, na hora.'
                : 'Nenhum evento neste filtro.',
          );
    final footer = _Footer(
      remote: remote,
      more: more,
      onMore: () => setState(() => _limit += eventsPageSize),
    );

    return LayoutBuilder(builder: (context, c) {
      // A short screen (a phone on its side, between the app's bars): the
      // search and the filters scroll away with the list, which keeps the
      // whole height. Anywhere else they stay on top.
      if (c.maxHeight < shortBelow) {
        return empty != null
            ? ListView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  top,
                  Padding(padding: const EdgeInsets.all(24), child: empty),
                ],
              )
            : _EventList(
                events: shown, grouped: grouped, header: top, footer: footer);
      }
      return Column(
        children: [
          top,
          Expanded(
            child: empty != null
                ? Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: empty,
                    ),
                  )
                : _EventList(events: shown, grouped: grouped, footer: footer),
          ),
        ],
      );
    });
  }
}

// ── Search, filters, clear ───────────────────────────────────────────────────

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.onQuery,
    required this.filter,
    required this.total,
    required this.counts,
    required this.onFilter,
    required this.grouped,
    required this.onGrouped,
    required this.canClear,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onQuery;
  final PanelEventKind? filter;
  final int total;
  final Map<PanelEventKind, int> counts;
  final ValueChanged<PanelEventKind?> onFilter;
  final bool grouped;
  final ValueChanged<bool> onGrouped;
  final bool canClear;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final field = SizedBox(
      height: 44,
      child: TextField(
        key: EventsScreen.keySearch,
        controller: controller,
        onChanged: onQuery,
        textInputAction: TextInputAction.search,
        style: TextStyle(color: context.textPrimary, fontSize: 14),
        decoration: InputDecoration(
          hintText: 'Buscar por dispositivo, zona, endereçamento ou texto',
          hintStyle: TextStyle(color: context.textSecondary, fontSize: 14),
          prefixIcon: Icon(Icons.search_rounded,
              size: 20, color: context.textSecondary),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Apagar a busca',
                  icon: Icon(Icons.close_rounded,
                      size: 18, color: context.textSecondary),
                  onPressed: () {
                    controller.clear();
                    onQuery('');
                  },
                ),
          isDense: true,
          filled: true,
          fillColor: context.surfaceColor,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide:
                BorderSide(color: context.borderColor.withValues(alpha: 0.7)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.secondary),
          ),
        ),
      ),
    );

    final clear = Tooltip(
      message: 'Começar a lista do zero. Nada é apagado.',
      child: OutlinedButton.icon(
        key: EventsScreen.keyClear,
        onPressed: canClear ? onClear : null,
        icon: const Icon(Icons.cleaning_services_rounded, size: 18),
        label: const Text('Limpar'),
        style: OutlinedButton.styleFrom(
          foregroundColor: context.textPrimary,
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          side: BorderSide(color: context.borderColor.withValues(alpha: 0.9)),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: field),
                  const SizedBox(width: 8),
                  clear,
                ],
              ),
              const SizedBox(height: 8),
              // One line that scrolls sideways: a short landscape screen
              // keeps its height for the list.
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _ViewSwitch(grouped: grouped, onChanged: onGrouped),
                    const SizedBox(width: 12),
                    _FilterChip(
                      key: EventsScreen.keyFilter(null),
                      label: 'Todos',
                      count: total,
                      color: AppColors.secondary,
                      selected: filter == null,
                      onTap: () => onFilter(null),
                    ),
                    for (final k in _filterOrder) ...[
                      const SizedBox(width: 8),
                      _FilterChip(
                        key: EventsScreen.keyFilter(k),
                        label: k.filterLabel,
                        count: counts[k] ?? 0,
                        color: k.color,
                        selected: filter == k,
                        onTap: () => onFilter(filter == k ? null : k),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Agrupado | Linhas": how the list is shown.
class _ViewSwitch extends StatelessWidget {
  const _ViewSwitch({required this.grouped, required this.onChanged});

  final bool grouped;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget side(Key key, bool value, IconData icon, String label, String tip) {
      final on = grouped == value;
      return Tooltip(
        message: tip,
        child: Semantics(
          button: true,
          selected: on,
          label: label,
          excludeSemantics: true,
          child: InkWell(
            key: key,
            onTap: on ? null : () => onChanged(value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              constraints: const BoxConstraints(minHeight: 40, minWidth: 44),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              color: on
                  ? AppColors.secondary
                      .withValues(alpha: context.isDark ? 0.22 : 0.14)
                  : Colors.transparent,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon,
                      size: 17,
                      color: on ? AppColors.secondary : context.textSecondary),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: on ? context.textPrimary : context.textSecondary,
                      fontSize: 13,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: context.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: context.borderColor.withValues(alpha: 0.7)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          side(EventsScreen.keyGrouped, true, Icons.hub_rounded, 'Agrupado',
              'O que aconteceu junto, em um só bloco'),
          side(EventsScreen.keyLines, false, Icons.view_headline_rounded,
              'Linhas', 'Cada linha do registro, uma a uma'),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    super.key,
    required this.label,
    required this.count,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(20);
    return Semantics(
      button: true,
      selected: selected,
      label: '$label, $count',
      excludeSemantics: true,
      child: Material(
        color: selected
            ? color.withValues(alpha: context.isDark ? 0.18 : 0.12)
            : context.surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected
                ? color.withValues(alpha: 0.8)
                : context.borderColor.withValues(alpha: 0.7),
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration:
                        BoxDecoration(shape: BoxShape.circle, color: color),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$count',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 12,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Lista limpa às 14:03 — Mostrar anteriores".
class _ClearedLine extends StatelessWidget {
  const _ClearedLine({required this.at, required this.onShowAll});

  final DateTime at;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
            children: [
              Icon(Icons.cleaning_services_rounded,
                  size: 14, color: context.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Lista limpa às ${eventClock(at)} de '
                  '${eventDay(at, DateTime.now()).toLowerCase()}. '
                  'Os eventos anteriores continuam guardados.',
                  style: TextStyle(color: context.textSecondary, fontSize: 12),
                ),
              ),
              TextButton(
                key: EventsScreen.keyShowAll,
                onPressed: onShowAll,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.secondary,
                  minimumSize: const Size(44, 44),
                ),
                child: const Text(
                  'Mostrar anteriores',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── The list ─────────────────────────────────────────────────────────────────

class _EventList extends StatelessWidget {
  const _EventList({
    required this.events,
    required this.grouped,
    required this.footer,
    this.header,
  });

  final List<MirrorPanelEvent> events;

  /// One tile per incident, or every line by itself.
  final bool grouped;

  /// Scrolls away with the list (a short screen).
  final Widget? header;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    // The rows, a day's header before the first event of each day.
    final items = <Object>[];
    String? day;
    final List<EventGroup> groups = grouped
        ? groupEvents(events)
        : [for (final e in events) SingleEvent(e)];
    for (final g in groups) {
      final d = eventDay(g.at, now);
      if (d != day) {
        items.add(d);
        day = d;
      }
      items.add(g);
    }
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 640;
      // Zona and Endereçamento as columns of their own, with their titles
      // (the "Linhas" view), where the screen has the width for them.
      final columns = c.maxWidth >= EventRow.columnsFrom;
      final titles = columns && !grouped;
      final lead = (header == null ? 0 : 1) + (titles ? 1 : 0);
      Widget framed(Widget child) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: child,
              ),
            ),
          );
      return ListView.builder(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        itemCount: lead + items.length + 1,
        itemBuilder: (context, index) {
          if (index < lead) {
            return header != null && index == 0
                ? header!
                : framed(const _ColumnTitles());
          }
          final i = index - lead;
          if (i == items.length) return framed(footer);
          final item = items[i];
          if (item is String) return framed(_DayHeader(item));
          return framed(Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: switch (item as EventGroup) {
              NetworkIncident g =>
                IncidentTile(incident: g, wide: wide, columns: columns),
              CommGap g => CommGapRow(gap: g, wide: wide, columns: columns),
              // The grouped view draws the unit itself beside its line.
              SingleEvent g => EventRow(
                  event: g.event,
                  wide: wide,
                  columns: columns,
                  avatar: grouped,
                ),
            },
          ));
        },
      );
    });
  }
}

/// The columns' titles, over the lines (a wide screen, the "Linhas" view).
class _ColumnTitles extends StatelessWidget {
  const _ColumnTitles();

  @override
  Widget build(BuildContext context) {
    Widget t(String text) => Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          ),
        );
    return Padding(
      // The rows' own insets: the coloured edge and their padding.
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          SizedBox(width: EventRow.clockWidth, child: t('HORA')),
          SizedBox(width: EventRow.kindWidth, child: t('TIPO')),
          SizedBox(width: EventRow.zoneWidth, child: t('ZONA')),
          SizedBox(width: EventRow.addressWidth, child: t('ENDEREÇAMENTO')),
          Expanded(child: t('EVENTO')),
        ],
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
      );
}

/// The kind's word on its colour.
class EventKindBadge extends StatelessWidget {
  const EventKindBadge(this.kind, {super.key});
  final PanelEventKind kind;

  @override
  Widget build(BuildContext context) {
    final color = kind.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: context.isDark ? 0.16 : 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(kind.icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            kind.label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// One event: when (to the second), its kind, what happened — all of it,
/// never cut — and, for a unit this screen knows, the way to that unit.
class EventRow extends ConsumerWidget {
  const EventRow({
    super.key,
    required this.event,
    required this.wide,
    this.columns = false,
    this.avatar = false,
    this.inset = false,
  });

  /// From this width the unit's zona and endereçamento are columns.
  static const columnsFrom = 900.0;
  static const clockWidth = 72.0;
  static const kindWidth = 124.0;
  static const zoneWidth = 130.0;
  static const addressWidth = 170.0;

  final MirrorPanelEvent event;

  /// One line (a tablet, the web) or the text under the kind (a phone).
  final bool wide;

  /// Zona and Endereçamento in columns of their own ([wide] only);
  /// otherwise they are a small line under what happened.
  final bool columns;

  /// The unit itself, as Rede draws it, before what is said of it.
  final bool avatar;

  /// A line inside an incident's tile: on the page's colour, so it reads
  /// as part of the tile.
  final bool inset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = event.kind;
    final mac = event.mac;
    final clock = Text(
      eventClock(event.at),
      style: TextStyle(
        color: context.textPrimary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final ago = Text(
      relativeTime(event.at),
      style: TextStyle(color: context.textSecondary, fontSize: 12),
    );
    final zone = event.zone?.isNotEmpty == true ? event.zone : null;
    final address = event.address?.isNotEmpty == true ? event.address : null;
    final inColumns = wide && columns;
    final line = Text(
      event.text,
      style: TextStyle(color: context.textPrimary, fontSize: 14, height: 1.3),
    );
    // Where the unit is, under the line, when it has no columns for it.
    final words = inColumns || (zone == null && address == null)
        ? line
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              line,
              const SizedBox(height: 2),
              Text(
                [if (zone != null) zone, if (address != null) address]
                    .join(' · '),
                style: TextStyle(color: context.textSecondary, fontSize: 12),
              ),
            ],
          );
    Widget cell(String? value, double width) => SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              value ?? '—',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color:
                    value == null ? context.textSecondary : context.textPrimary,
                fontSize: 13,
              ),
            ),
          ),
        );
    final Widget text = !avatar || mac == null
        ? words
        : Row(
            children: [
              EventUnitAvatar(
                  mac: mac, name: event.who, size: 34, tappable: false),
              const SizedBox(width: 10),
              Expanded(child: words),
            ],
          );
    // The way to the unit, when this screen knows it (the tablet; a phone
    // that follows the central's map).
    final known = mac != null &&
        ref.watch(
            topologyProvider.select((nodes) => nodes.any((n) => n.mac == mac)));
    final go = !known
        ? null
        : Icon(Icons.chevron_right_rounded,
            size: 20, color: context.textSecondary);

    final content = wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(width: clockWidth, child: clock),
              SizedBox(
                width: kindWidth,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  // A large system font: the word shrinks, never overflows.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: EventKindBadge(kind),
                  ),
                ),
              ),
              if (inColumns) ...[
                cell(zone, zoneWidth),
                cell(address, addressWidth),
              ],
              Expanded(child: text),
              const SizedBox(width: 12),
              ago,
              SizedBox(width: 24, child: go),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  // The time to the second is what a narrow row has room
                  // for; "há 2 min" is the wide row's.
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: EventKindBadge(kind),
                    ),
                  ),
                  const SizedBox(width: 8),
                  clock,
                  if (go != null) go,
                ],
              ),
              const SizedBox(height: 6),
              text,
            ],
          );

    final radius = BorderRadius.circular(12);
    return Material(
      color: inset ? context.bgColor : context.surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
            color: context.borderColor.withValues(alpha: 0.6), width: 0.8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Builder(builder: (rowContext) {
        return InkWell(
          onTap: !known ? null : () => showDeviceMenuFor(rowContext, ref, mac),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 4, color: kind.color),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                    child: content,
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.remote,
    required this.more,
    required this.onMore,
  });

  final bool remote;
  final bool more;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    if (more) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: OutlinedButton.icon(
            key: EventsScreen.keyMore,
            onPressed: onMore,
            icon: const Icon(Icons.expand_more_rounded, size: 20),
            label: const Text('Carregar mais antigos'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.secondary,
              minimumSize: const Size(44, 44),
              side:
                  BorderSide(color: AppColors.secondary.withValues(alpha: 0.6)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(
        remote
            ? 'Estes são os eventos mais recentes da central. O histórico '
                'completo fica na central.'
            : 'Fim da lista.',
        textAlign: TextAlign.center,
        style: TextStyle(color: context.textSecondary, fontSize: 12),
      ),
    );
  }
}

/// A screen with nothing but a note.
class _Empty extends StatelessWidget {
  const _Empty(
      {required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Center(
        // Scrollable: a short landscape screen.
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _EmptyContent(icon: icon, title: title, subtitle: subtitle),
        ),
      );
}

class _EmptyContent extends StatelessWidget {
  const _EmptyContent(
      {required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 40, color: context.textSecondary),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.textSecondary, fontSize: 13),
        ),
      ],
    );
  }
}
