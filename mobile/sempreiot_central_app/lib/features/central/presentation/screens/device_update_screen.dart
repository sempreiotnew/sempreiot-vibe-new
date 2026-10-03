import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/theme_ext.dart';
import '../../application/device_update_controller.dart';
import '../../application/device_update_selection.dart';
import '../../application/device_update_state.dart';
import '../../application/firmware_library_provider.dart';
import '../../application/ota_push_report.dart';
import '../../application/ota_rollout_controller.dart';
import '../../application/ota_rollout_report.dart';
import '../../application/root_election_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/safr/safr_product.dart';
import '../../domain/safr/safr_v2_payloads.dart';
import '../widgets/device_avatar.dart' show deviceDisplayName;
import '../widgets/device_update_widgets.dart';
import '../widgets/mesh_map.dart';
import '../widgets/mesh_status_bar.dart';

/// "Atualizar dispositivos": the Rede map, and on it the firmware update —
/// choose units with a tap (or Placa / Todos os nós / Todos os detectores),
/// "Atualizar", pick the firmware; or "Atualizar tudo" (board, nodes,
/// detectors, in that order). Everything is watched on the same map: the
/// tablet and its cable while the image goes to the board, a ring and the
/// phase on the unit being updated, the image's packets along the tree.
class DeviceUpdateScreen extends ConsumerStatefulWidget {
  const DeviceUpdateScreen({super.key});

  @override
  ConsumerState<DeviceUpdateScreen> createState() => _DeviceUpdateScreenState();
}

class _DeviceUpdateScreenState extends ConsumerState<DeviceUpdateScreen> {
  @override
  void initState() {
    super.initState();
    // What the board holds decides whether an image must be sent first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(otaRolloutProvider.notifier).refresh();
      ref.read(firmwareLibraryProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final allNodes = ref.watch(topologyProvider);
    final election = ref.watch(rootElectionProvider);
    final run = ref.watch(deviceUpdateProvider);
    final sel = ref.watch(deviceUpdateSelectionProvider);
    final push = ref.watch(otaPushViewProvider);
    final lib = ref.watch(firmwareLibraryProvider);

    TopologyNode? board;
    final nodes = <TopologyNode>[];
    for (final n in allNodes) {
      if (n.layer == 0) {
        board ??= n;
      } else {
        nodes.add(n);
      }
    }

    final selecting = run == null;
    final family = sel.family;
    final newest = family == null || family == SafrProductFamily.board
        ? null
        : lib.of(family).firstOrNull?.version;

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        title: const Text('Atualizar dispositivos'),
        backgroundColor: context.bgColor,
        elevation: 0,
        actions: [
          IconButton(
            key: const ValueKey('firmware-library'),
            tooltip: 'Firmwares no tablet',
            icon: const Icon(Icons.inventory_2_outlined),
            onPressed: () => showFirmwareLibrarySheet(context),
          ),
          IconButton(
            tooltip: 'Registro',
            icon: const Icon(Icons.receipt_long_rounded),
            onPressed: () => showDeviceUpdateLog(context),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            MeshStatusBar(
              nodes: nodes,
              election: election,
              leading: [
                if (run != null) DeviceUpdatePill(run: run, push: push),
              ],
            ),
            Expanded(
              child: MeshMap(
                nodes: nodes,
                board: board,
                election: election,
                overlay: run == null
                    ? OtaRolloutOverlay.none
                    : _overlay(run, election.rootMac),
                selected: selecting ? sel.keys : const {},
                boardSelected:
                    selecting && sel.keys.contains(deviceUpdateBoardKey),
                focus: run == null ? null : _focus(run, nodes),
                selectionTarget: newest,
                onNodeTap: (node, _) => selecting
                    ? ref
                        .read(deviceUpdateSelectionProvider.notifier)
                        .tapUnit(node, name: deviceDisplayName(node))
                    : (run.units.containsKey(node.mac)
                        ? showDeviceUpdateUnitSheet(context, node.mac)
                        : null),
                onCentralTap: selecting
                    ? ref.read(deviceUpdateSelectionProvider.notifier).tapBoard
                    : null,
              ),
            ),
            DeviceUpdateBar(nodes: allNodes),
          ],
        ),
      ),
    );
  }

  /// What the map draws on the units of the run: the run's own record (the
  /// board's table holds only the rollout it runs now).
  OtaRolloutOverlay _overlay(DeviceUpdateRun run, String? rootMac) {
    String? downloading;
    final units = <String, OtaUnitActivity>{};
    for (final u in run.units.values) {
      if (u.key == deviceUpdateBoardKey) continue;
      if (u.state == SafrOtaUnitState.downloading &&
          run.running &&
          !run.paused) {
        downloading ??= u.key;
      }
      units[u.key] = OtaUnitActivity(
        state: u.state,
        percent: u.percent,
        version: u.version,
        last: u.key == rootMac && u.state == SafrOtaUnitState.waiting,
      );
    }
    return OtaRolloutOverlay(units: units, downloading: downloading);
  }

  /// The units the run touches; the rest is drawn faded.
  Set<String> _focus(DeviceUpdateRun run, List<TopologyNode> nodes) => {
        for (final k in run.units.keys)
          if (k != deviceUpdateBoardKey) k,
      };
}
