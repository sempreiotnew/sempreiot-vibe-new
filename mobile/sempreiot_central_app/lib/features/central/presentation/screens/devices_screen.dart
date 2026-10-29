import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/signal_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../core/utils/relative_time.dart';
import '../../application/device_labels_provider.dart';
import '../../application/root_election_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_v2_payloads.dart';
import '../widgets/device_avatar.dart';
import '../widgets/device_traffic_ripple.dart';

import 'device_settings_screen.dart';

enum _Filter { all, alarm, offline, sleeping }

/// Dispositivos — every device of this central as a gallery of cards, with
/// search (name, zona, endereçamento, MAC), quick filters and a zona /
/// endereçamento filter (protocol §14.1). A tap opens the device's
/// Dispositivo screen. Hosted inside the main tab (no own Scaffold).
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  final _search = TextEditingController();
  String _query = '';
  _Filter _filter = _Filter.all;

  /// 0 = every zone / endereçamento.
  int _zoneId = 0;
  int _addressId = 0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matchesFilter(TopologyNode n, _Filter f) => switch (f) {
        _Filter.all => true,
        _Filter.alarm => n.alarmLatched,
        _Filter.offline => !n.online,
        _Filter.sleeping => n.sleeping,
      };

  bool _matchesQuery(TopologyNode n) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return (n.name ?? '').toLowerCase().contains(q) ||
        (n.zone ?? '').toLowerCase().contains(q) ||
        (n.address ?? '').toLowerCase().contains(q) ||
        n.mac.toLowerCase().contains(q);
  }

  bool _matchesLabels(TopologyNode n) =>
      (_zoneId == 0 || n.zoneId == _zoneId) &&
      (_addressId == 0 || n.addressId == _addressId);

  /// Alarm first, then silent devices, then by name — what needs a look
  /// comes to the top.
  int _rank(TopologyNode n) => n.alarmLatched ? 0 : (!n.online ? 1 : 2);

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(topologyProvider);
    final election = ref.watch(rootElectionProvider);
    final labels = ref.watch(labelIndexProvider);

    final counts = {
      for (final f in _Filter.values)
        f: all.where((n) => _matchesFilter(n, f) && _matchesLabels(n)).length,
    };
    final shown = all
        .where((n) =>
            _matchesFilter(n, _filter) && _matchesLabels(n) && _matchesQuery(n))
        .toList()
      ..sort((a, b) {
        final r = _rank(a).compareTo(_rank(b));
        if (r != 0) return r;
        return deviceDisplayName(a)
            .toLowerCase()
            .compareTo(deviceDisplayName(b).toLowerCase());
      });

    return Column(
      children: [
        _SearchHeader(
          controller: _search,
          onChanged: (v) => setState(() => _query = v.trim()),
          onClear: () => setState(() {
            _search.clear();
            _query = '';
          }),
          filter: _filter,
          counts: counts,
          onFilter: (f) => setState(() => _filter = f),
          zones: labels.of(SafrLabelKind.zone),
          addresses: labels.of(SafrLabelKind.address),
          zoneId: _zoneId,
          addressId: _addressId,
          onZone: (id) => setState(() => _zoneId = id),
          onAddress: (id) => setState(() => _addressId = id),
        ),
        Expanded(
          child: all.isEmpty
              ? const _Empty(
                  icon: Icons.sensors_off_rounded,
                  title: 'Nenhum dispositivo ainda',
                  subtitle: 'Os dispositivos aparecem aqui assim que a placa\n'
                      'reportar a rede pela serial.',
                )
              : shown.isEmpty
                  ? _Empty(
                      icon: Icons.search_off_rounded,
                      title: 'Nada encontrado',
                      subtitle: _query.isEmpty
                          ? 'Nenhum dispositivo neste filtro.'
                          : 'Nenhum dispositivo com "$_query".',
                    )
                  : GridView.builder(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 180,
                        mainAxisExtent: 204,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final n = shown[i];
                        return _DeviceCard(
                          node: n,
                          isRoot: n.online && election.isRoot(n.mac),
                          isCandidate: election.electing &&
                              election.candidates.contains(n.mac),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => DeviceSettingsScreen(mac: n.mac),
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

// ── Search + filters ─────────────────────────────────────────────────────────

class _SearchHeader extends StatelessWidget {
  const _SearchHeader({
    required this.controller,
    required this.onChanged,
    required this.onClear,
    required this.filter,
    required this.counts,
    required this.onFilter,
    required this.zones,
    required this.addresses,
    required this.zoneId,
    required this.addressId,
    required this.onZone,
    required this.onAddress,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final _Filter filter;
  final Map<_Filter, int> counts;
  final ValueChanged<_Filter> onFilter;
  final List<SafrLabel> zones;
  final List<SafrLabel> addresses;
  final int zoneId;
  final int addressId;
  final ValueChanged<int> onZone;
  final ValueChanged<int> onAddress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        children: [
          TextField(
            controller: controller,
            onChanged: onChanged,
            textInputAction: TextInputAction.search,
            style: TextStyle(color: context.textPrimary, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Buscar por nome, zona, endereçamento ou MAC',
              hintStyle: TextStyle(color: context.textSecondary, fontSize: 14),
              prefixIcon: Icon(Icons.search_rounded,
                  size: 20, color: context.textSecondary),
              suffixIcon: ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (_, v, __) => v.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        tooltip: 'Limpar',
                        onPressed: onClear,
                        icon: Icon(Icons.close_rounded,
                            size: 18, color: context.textSecondary),
                      ),
              ),
              filled: true,
              fillColor: context.surfaceColor,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                    color: context.borderColor.withValues(alpha: 0.6),
                    width: 0.5),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                    color: context.borderColor.withValues(alpha: 0.6),
                    width: 0.5),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:
                    const BorderSide(color: AppColors.secondary, width: 1),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final f in _Filter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _FilterChip(
                      label: switch (f) {
                        _Filter.all => 'Todos',
                        _Filter.alarm => 'Em alarme',
                        _Filter.offline => 'Sem comunicação',
                        _Filter.sleeping => 'Dormindo',
                      },
                      count: counts[f] ?? 0,
                      color: switch (f) {
                        _Filter.all => AppColors.secondary,
                        _Filter.alarm => AppColors.error,
                        _Filter.offline => AppColors.trouble,
                        _Filter.sleeping => context.textSecondary,
                      },
                      selected: filter == f,
                      onTap: () => onFilter(f),
                    ),
                  ),
                if (zones.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _LabelFilter(
                      all: 'Todas as zonas',
                      options: zones,
                      value: zoneId,
                      onChanged: onZone,
                    ),
                  ),
                if (addresses.isNotEmpty)
                  _LabelFilter(
                    all: 'Todos os endereçamentos',
                    options: addresses,
                    value: addressId,
                    onChanged: onAddress,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One label table as a filter chip with a menu; 0 = all.
class _LabelFilter extends StatelessWidget {
  const _LabelFilter({
    required this.all,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final String all;
  final List<SafrLabel> options;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = value != 0;
    const color = AppColors.secondary;
    String name = all;
    for (final l in options) {
      if (l.id == value) name = l.name;
    }
    return PopupMenuButton<int>(
      tooltip: all,
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [
        PopupMenuItem(value: 0, child: Text(all)),
        for (final l in options) PopupMenuItem(value: l.id, child: Text(l.name)),
      ],
      child: Material(
        color: selected ? color.withValues(alpha: 0.16) : context.surfaceColor,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected
                ? color.withValues(alpha: 0.7)
                : context.borderColor.withValues(alpha: 0.6),
            width: selected ? 1 : 0.5,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 6, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                style: TextStyle(
                  color: selected ? color : context.textPrimary,
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              Icon(Icons.arrow_drop_down_rounded,
                  size: 20, color: selected ? color : context.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
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
    return Material(
      color: selected ? color.withValues(alpha: 0.16) : context.surfaceColor,
      shape: StadiumBorder(
        side: BorderSide(
          color: selected
              ? color.withValues(alpha: 0.7)
              : context.borderColor.withValues(alpha: 0.6),
          width: selected ? 1 : 0.5,
        ),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected ? color : context.textPrimary,
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '$count',
                style: TextStyle(
                  color: selected ? color : context.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Card ─────────────────────────────────────────────────────────────────────

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.node,
    required this.isRoot,
    required this.isCandidate,
    required this.onTap,
  });

  final TopologyNode node;
  final bool isRoot;
  final bool isCandidate;
  final VoidCallback onTap;

  String get _kind => node.layer == 0
      ? 'Placa'
      : switch (node.role) {
          SafrNodeRole.root => 'Root',
          SafrNodeRole.node => 'Repetidor',
          SafrNodeRole.leaf => 'Sensor',
          _ => 'Dispositivo',
        };

  @override
  Widget build(BuildContext context) {
    final hasName = node.name?.isNotEmpty == true;
    final accent = node.alarmLatched
        ? AppColors.error
        : !node.online
            ? AppColors.trouble
            : AppColors.secondary;

    return Opacity(
      opacity: node.stale ? 0.55 : 1,
      child: Material(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: node.alarmLatched
                    ? AppColors.error.withValues(alpha: 0.8)
                    : context.borderColor.withValues(alpha: 0.6),
                width: node.alarmLatched ? 1.2 : 0.5,
              ),
              // A soft halo in the device's state colour behind the circle.
              gradient: RadialGradient(
                center: const Alignment(0, -0.45),
                radius: 0.8,
                colors: [
                  accent.withValues(alpha: context.isDark ? 0.14 : 0.10),
                  accent.withValues(alpha: 0),
                ],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 16, 10, 12),
              child: Column(
                children: [
                  // Its product's 3D model, turning on itself, when it has
                  // one (system reference §2.1.1); the circle otherwise.
                  // Tapping opens Dispositivo, where it stands still.
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // A frame of the unit crossing the system — a
                      // detector's wake above all — ripples here as it
                      // does on the Rede map. (Its LED dot is its LED: a
                      // detector's stays dark on a timer wake, §12.8.)
                      DeviceTrafficRipple(node: node, diameter: 64),
                      DeviceModelAvatar(
                        node: node,
                        isRoot: isRoot,
                        isCandidate: isCandidate,
                        size: 64,
                        spin: true,
                      ),
                      // Without communication: said in words, top right —
                      // the same tag as on the Rede map.
                      if (!node.online)
                        const Positioned(
                          right: -22,
                          top: -8,
                          child: DeviceOfflineBadge(),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    deviceDisplayName(node),
                    maxLines: hasName ? 2 : 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          hasName ? context.textPrimary : context.textSecondary,
                      fontSize: hasName ? 13.5 : 10.5,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                      fontFamily: hasName ? null : 'monospace',
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [_kind, node.address, node.zone]
                        .whereType<String>()
                        .join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(color: context.textSecondary, fontSize: 11.5),
                  ),
                  const Spacer(),
                  _CardFooter(node: node),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Signal and battery pills, or how long it has been silent.
class _CardFooter extends StatelessWidget {
  const _CardFooter({required this.node});
  final TopologyNode node;

  @override
  Widget build(BuildContext context) {
    if (!node.online) {
      return _Pill(
        icon: Icons.schedule_rounded,
        text: relativeTime(node.lastSeenAt),
        color: AppColors.trouble,
      );
    }
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 4,
      children: [
        if (node.rssi != null)
          _Pill(
            icon: Icons.network_cell_rounded,
            text: '${node.rssi} dBm',
            color:
                node.sleeping ? context.textSecondary : signalColor(node.rssi),
          ),
        // The "enlace degradado" trouble is up (protocol §9.4): what the
        // unit itself counted of the board's heartbeats.
        if (node.linkDegraded && node.dlLost != null)
          _Pill(
            icon: Icons.network_check_rounded,
            text: 'perde ${node.dlLost} de ${TopologyNode.dlHeardExpected}',
            color: AppColors.trouble,
          ),
        if (node.batteryPct != null)
          _Pill(
            icon: Icons.battery_std_rounded,
            text: '${node.batteryPct}%',
            color: node.batteryPct! < 20
                ? AppColors.warning
                : context.textSecondary,
          ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const SizedBox(height: 24),
          Icon(icon,
              size: 52, color: context.textSecondary.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.textSecondary, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}
