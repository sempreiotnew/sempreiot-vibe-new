import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/services/installation_storage_service.dart';
import '../domain/entities/installation.dart';
import '../domain/services/installation_generator.dart';

final installationStorageProvider = Provider<InstallationStorageService>(
  (ref) => InstallationStorageService(),
);

/// Outcome of [InstallationListNotifier.importShared].
enum ImportSharedOutcome {
  /// New on this phone.
  added,

  /// Same SYSTEM_ID already here: name/zones refreshed, work log kept.
  updated,
}

/// All installations known to this phone, newest first.
class InstallationListNotifier
    extends StateNotifier<AsyncValue<List<Installation>>> {
  InstallationListNotifier(this._storage) : super(const AsyncValue.loading()) {
    _load();
  }

  final InstallationStorageService _storage;

  Future<void> _load() async {
    state = const AsyncValue.loading();
    try {
      state = AsyncValue.data(await _storage.loadAll());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Installation _find(String localId) =>
      (state.valueOrNull ?? []).firstWhere((i) => i.localId == localId);

  Future<Installation> create({
    required String displayName,
    List<String> zones = const [],
  }) async {
    final installation =
        InstallationGenerator.generate(displayName: displayName, zones: zones);
    await _storage.save(installation);
    await _load();
    return installation;
  }

  /// A shared installation (decoded from another phone's or the tablet's
  /// encrypted backup) joins this phone's list. Deduplicated by SYSTEM_ID:
  /// the same site never appears twice, and this phone's own work log for it
  /// is kept (lifecycle §5 D).
  Future<(Installation, ImportSharedOutcome)> importShared(
      Installation shared) async {
    final current = state.valueOrNull ?? await _storage.loadAll();
    for (final existing in current) {
      if (existing.systemId == shared.systemId) {
        final merged = existing.copyWith(
          displayName: shared.displayName,
          zones: {...existing.zones, ...shared.zones}.toList(),
        );
        await _storage.save(merged);
        await _load();
        return (merged, ImportSharedOutcome.updated);
      }
    }
    // Fresh local id: localIds are per phone (never on the wire).
    final local = shared.copyWith(
      localId: InstallationGenerator.newLocalId(),
      devices: const [],
    );
    await _storage.save(local);
    await _load();
    return (local, ImportSharedOutcome.added);
  }

  Future<void> rename(String installationLocalId, String displayName) async {
    final target = _find(installationLocalId);
    await _storage.save(target.copyWith(displayName: displayName));
    await _load();
  }

  Future<void> addZone(String installationLocalId, String zone) async {
    final target = _find(installationLocalId);
    if (target.zones.contains(zone)) return;
    final updated = target.copyWith(zones: [...target.zones, zone]);
    await _storage.save(updated);
    await _load();
  }

  Future<void> addProvisionedDevice(
    String installationLocalId,
    ProvisionedDevice device,
  ) async {
    final target = _find(installationLocalId);
    // One entry per unit: re-provisioning the same MAC (new name/zone, or a
    // retry) replaces the old row instead of stacking duplicates that would
    // all be sent to the board's /enroll list.
    final mac = device.mac.toUpperCase();
    final kept = target.devices
        .where((d) => d.mac.toUpperCase() != mac)
        .toList();
    await _storage.save(target.copyWith(devices: [...kept, device]));
    await _load();
  }

  /// Removes a unit from this phone's work log only — the unit itself and
  /// the board are untouched (retire/replace happen on the tablet).
  Future<void> removeProvisionedDevice(
    String installationLocalId,
    String mac,
  ) async {
    final target = _find(installationLocalId);
    final upper = mac.toUpperCase();
    await _storage.save(target.copyWith(
      devices:
          target.devices.where((d) => d.mac.toUpperCase() != upper).toList(),
    ));
    await _load();
  }

  Future<void> delete(String installationLocalId) async {
    await _storage.delete(installationLocalId);
    await _load();
  }

  Future<void> refresh() => _load();
}

final installationListProvider = StateNotifierProvider<
    InstallationListNotifier, AsyncValue<List<Installation>>>(
  (ref) => InstallationListNotifier(ref.watch(installationStorageProvider)),
);
