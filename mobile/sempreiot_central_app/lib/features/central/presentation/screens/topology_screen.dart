import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/central_mirror_viewer.dart';
import '../../application/root_election_provider.dart';
import '../../application/safr_downlink_provider.dart';
import '../../application/topology_provider.dart';
import '../widgets/device_menu.dart';
import '../widgets/mesh_map.dart';
import '../widgets/mesh_status_bar.dart';
import '../widgets/device_update_rede_line.dart';

/// Rede — live map of the fire-alarm mesh (the map itself: [MeshMap]),
/// with the status strip on top and the device menu on a tap.
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
          onClear: viewOnly ? null : _clearRegistry,
          show3d: true,
        ),
        Expanded(
          child: MeshMap(
            nodes: nodes,
            board: board,
            election: election,
            onNodeTap: _showNodeMenu,
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

  /// Wipes the device registry so the map stops showing units from old
  /// sessions or installations. Live devices reappear on their next heartbeat.
  Future<void> _clearRegistry() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ressincronizar com a placa'),
        content: const Text(
            'Limpa o mapa da rede e pede à placa a tabela de dispositivos de '
            'novo. Os que estiverem ativos reaparecem no próximo heartbeat; '
            'o histórico de logs é mantido.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ressincronizar'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(appDatabaseProvider).clearMeshDevices();
      await ref.read(safrDownlinkProvider).sendGetInstallation();
      await ref.read(safrDownlinkProvider).sendGetDeviceTable();
    }
  }

  /// A tap on a device drops its menu (basics + Dispositivo, Identificar,
  /// Silenciar, Testar) from the chip.
  void _showNodeMenu(TopologyNode node, Rect anchor) => showDeviceMenu(
        context: context,
        ref: ref,
        node: node,
        anchor: anchor,
      );
}
