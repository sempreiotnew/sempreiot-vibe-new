import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/safr/safr_product.dart';
import 'device_update_state.dart';
import 'ota_push_report.dart' show unitFamily;
import 'topology_provider.dart';

/// What the operator chose on "Atualizar dispositivos": units of ONE family
/// (one firmware image per update), or the board.
class DeviceUpdateSelection {
  const DeviceUpdateSelection({this.family, this.keys = const {}, this.note});

  /// Null while nothing is chosen.
  final SafrProductFamily? family;

  /// MACs, or [deviceUpdateBoardKey].
  final Set<String> keys;

  /// Something to tell about the last tap ("sem comunicação", "a seleção
  /// anterior foi trocada"); null = nothing.
  final String? note;

  bool get isEmpty => keys.isEmpty;
}

/// Tap rules of the selection.
class DeviceUpdateSelectionController
    extends StateNotifier<DeviceUpdateSelection> {
  DeviceUpdateSelectionController() : super(const DeviceUpdateSelection());

  static const switchedNote =
      'Um tipo de firmware por vez: a seleção anterior foi trocada.';

  /// A unit on the map: in or out. A unit of another family replaces the
  /// selection; a silent unit cannot be chosen.
  void tapUnit(TopologyNode node, {required String name}) {
    if (!node.online) {
      state = DeviceUpdateSelection(
        family: state.family,
        keys: state.keys,
        note: '$name está sem comunicação e não pode ser atualizado.',
      );
      return;
    }
    final family = unitFamily(node);
    if (family != SafrProductFamily.node && family != SafrProductFamily.leaf) {
      return;
    }
    _toggle(family, node.mac);
  }

  /// The CENTRAL: the board alone.
  void tapBoard() => _toggle(SafrProductFamily.board, deviceUpdateBoardKey);

  /// "Placa" / "Todos os nós" / "Todos os detectores": those units, or
  /// nothing when they are exactly what is chosen already.
  void pickAll(SafrProductFamily family, Iterable<String> keys) {
    final wanted = keys.toSet();
    final same = state.family == family &&
        state.keys.length == wanted.length &&
        state.keys.containsAll(wanted);
    state = same || wanted.isEmpty
        ? const DeviceUpdateSelection()
        : DeviceUpdateSelection(family: family, keys: wanted);
  }

  void clear() => state = const DeviceUpdateSelection();

  void _toggle(SafrProductFamily family, String key) {
    if (state.family != null && state.family != family && !state.isEmpty) {
      state = DeviceUpdateSelection(
          family: family, keys: {key}, note: switchedNote);
      return;
    }
    final keys = {...state.keys};
    if (!keys.remove(key)) keys.add(key);
    state = keys.isEmpty
        ? const DeviceUpdateSelection()
        : DeviceUpdateSelection(family: family, keys: keys);
  }
}

final deviceUpdateSelectionProvider = StateNotifierProvider.autoDispose<
    DeviceUpdateSelectionController, DeviceUpdateSelection>(
  (ref) => DeviceUpdateSelectionController(),
);
