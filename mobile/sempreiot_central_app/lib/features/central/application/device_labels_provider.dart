import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../domain/safr/safr_v2_payloads.dart';

/// The board's zone / endereçamento tables as last mirrored (protocol
/// §14.2), live from the database.
final deviceLabelsProvider = StreamProvider<List<DeviceLabel>>(
    (ref) => ref.watch(appDatabaseProvider).watchLabels());

/// Names behind the ids: what every screen shows for a unit's zone and
/// endereçamento. Empty until the board's tables arrive.
class LabelIndex {
  const LabelIndex(this._names);
  const LabelIndex.empty() : _names = const {};

  final Map<(int, int), String> _names;

  /// The label's name; null for 0 (none), an unknown id, or no id yet.
  String? name(SafrLabelKind kind, int? id) =>
      id == null || id == 0 ? null : _names[(kind.wire, id)];

  /// Every label of one kind, by id.
  List<SafrLabel> of(SafrLabelKind kind) => [
        for (final e in _names.entries)
          if (e.key.$1 == kind.wire) SafrLabel(id: e.key.$2, name: e.value),
      ]..sort((a, b) => a.id.compareTo(b.id));

  /// The next id a new label of this kind takes (the tablet chooses it,
  /// protocol §7.6 SET_LABEL).
  int nextId(SafrLabelKind kind) {
    var max = 0;
    for (final k in _names.keys) {
      if (k.$1 == kind.wire && k.$2 > max) max = k.$2;
    }
    return max + 1;
  }
}

final labelIndexProvider = Provider<LabelIndex>((ref) {
  final rows = ref.watch(deviceLabelsProvider).valueOrNull;
  if (rows == null) return const LabelIndex.empty();
  return LabelIndex({for (final r in rows) (r.kind, r.labelId): r.name});
});
