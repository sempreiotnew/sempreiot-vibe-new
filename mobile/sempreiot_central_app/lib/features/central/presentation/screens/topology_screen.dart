import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/theme_ext.dart';
import '../../application/board_sync_provider.dart';
import '../../application/central_mirror_viewer.dart';
import '../../application/rede_view_prefs.dart';
import '../../application/root_election_provider.dart';
import '../../application/system_test_provider.dart';
import '../../application/topology_provider.dart';
import '../widgets/board_sync_banner.dart';
import '../widgets/device_menu.dart';
import '../widgets/mesh_map.dart';
import '../widgets/mesh_status_bar.dart';
import '../widgets/device_update_rede_line.dart';
import '../widgets/link_down_banner.dart';
import '../widgets/network_3d/device_model_sprites.dart';
import '../widgets/root_election_banner.dart';
import '../widgets/system_test_sheets.dart';

/// Rede — live map of the fire-alarm mesh (the map itself: [MeshMap]),
/// with the status strip on top, under it the root election and the board
/// sync while they happen, and the device popover on a tap.
class TopologyScreen extends ConsumerStatefulWidget {
  const TopologyScreen({super.key, this.embedded = false});

  /// True when hosted inside the Rede tab (no own Scaffold/AppBar).
  final bool embedded;

  @override
  ConsumerState<TopologyScreen> createState() => _TopologyScreenState();
}

class _TopologyScreenState extends ConsumerState<TopologyScreen> {
  @override
  void initState() {
    super.initState();
    // Every product's model, loaded once: a unit is drawn as its model
    // from its first frame on, not as a circle for a second or two.
    DeviceModelSprites.preloadAll();
  }

  @override
  Widget build(BuildContext context) {
    // A test that was running ended: its report opens by itself, on the
    // tablet and on a phone that was watching alike.
    ref.listen<SystemTestsState>(systemTestsViewProvider, (prev, next) {
      final was = prev?.running;
      if (was == null || next.running != null) return;
      final ended = next.recent.where((r) => r.id == was.id).firstOrNull;
      if (ended != null && mounted) showSystemTestReport(context, ended);
    });
    // The board (layer 0) is folded into the CENTRAL chip, not drawn as its
    // own node; the mesh (layer 1+) hangs off the central directly.
    final allNodes = ref.watch(topologyProvider);
    // Who is root — or that the mesh is still deciding (root_election_provider).
    final election = ref.watch(rootElectionProvider);
    // A user's phone viewing a central: the map and nothing that commands.
    final viewOnly = ref.watch(mirrorViewOnlyProvider);
    final sync = ref.watch(boardSyncProvider);
    // The firmware pills, on or off from the strip (kept on this device).
    final showVersions = ref.watch(redeShowVersionsProvider);
    TopologyNode? board;
    final nodes = <TopologyNode>[];
    for (final n in allNodes) {
      if (n.layer == 0) {
        board ??= n;
      } else {
        nodes.add(n);
      }
    }

    final body = Column(
      children: [
        const DeviceUpdateRedeLine(),
        MeshStatusBar(
          nodes: nodes,
          election: election,
          onSync: viewOnly
              ? null
              : () => ref.read(boardSyncProvider.notifier).start(),
          syncing: sync.phase == BoardSyncPhase.syncing,
          electionPill: false,
          versionsShown: showVersions,
          onToggleVersions: () =>
              ref.read(redeShowVersionsProvider.notifier).toggle(),
        ),
        // The board's link is down: said here, in words, before anything
        // on the map is read as live.
        const LinkDownBanner(),
        RootElectionBanner(election: election, nodes: nodes),
        if (!viewOnly)
          BoardSyncBanner(
            sync: sync,
            awaiting: nodes.where((n) => n.awaitingSignal).length,
          ),
        Expanded(
          child: MeshMap(
            nodes: nodes,
            board: board,
            election: election,
            onNodeTap: _showNodeMenu,
            onCentralMenu: (anchor) => showCentralMenu(
              context: context,
              ref: ref,
              board: board,
              anchor: anchor,
            ),
            // Rede is the alarm view: the update is drawn on "Atualizar
            // dispositivos" only.
            showOta: false,
            showVersions: showVersions,
          ),
        ),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        title: const Text('Rede Mesh'),
        backgroundColor: context.bgColor,
        elevation: 0,
      ),
      body: body,
    );
  }

  /// A tap on a device opens its popover (facts, commands, Dispositivo)
  /// pointing at the chip.
  void _showNodeMenu(TopologyNode node, Rect anchor) => showDeviceMenu(
        context: context,
        ref: ref,
        node: node,
        anchor: anchor,
      );
}
