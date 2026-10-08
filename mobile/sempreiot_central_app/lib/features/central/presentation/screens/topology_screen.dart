import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/theme_ext.dart';
import '../../application/board_sync_provider.dart';
import '../../application/central_mirror_viewer.dart';
import '../../application/root_election_provider.dart';
import '../../application/topology_provider.dart';
import '../widgets/board_sync_banner.dart';
import '../widgets/device_menu.dart';
import '../widgets/mesh_map.dart';
import '../widgets/mesh_status_bar.dart';
import '../widgets/device_update_rede_line.dart';
import '../widgets/root_election_banner.dart';

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
  Widget build(BuildContext context) {
    // The board (layer 0) is folded into the CENTRAL chip, not drawn as its
    // own node; the mesh (layer 1+) hangs off the central directly.
    final allNodes = ref.watch(topologyProvider);
    // Who is root — or that the mesh is still deciding (root_election_provider).
    final election = ref.watch(rootElectionProvider);
    // A user's phone viewing a central: the map and nothing that commands.
    final viewOnly = ref.watch(mirrorViewOnlyProvider);
    final sync = ref.watch(boardSyncProvider);
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
          show3d: true,
          electionPill: false,
        ),
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
