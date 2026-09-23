import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/services/installation_storage_service.dart';
import '../domain/entities/installation.dart';
import '../domain/services/installation_generator.dart';

final installationStorageProvider = Provider<InstallationStorageService>(
  (ref) => InstallationStorageService(),
);

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

  Future<void> addZone(String installationLocalId, String zone) async {
    final current = state.valueOrNull ?? [];
    final target = current.firstWhere((i) => i.localId == installationLocalId);
    if (target.zones.contains(zone)) return;
    final updated = target.copyWith(zones: [...target.zones, zone]);
    await _storage.save(updated);
    await _load();
  }

  Future<void> addProvisionedDevice(
    String installationLocalId,
    ProvisionedDevice device,
  ) async {
    final current = state.valueOrNull ?? [];
    final target = current.firstWhere((i) => i.localId == installationLocalId);
    // One entry per unit: re-provisioning the same MAC (new name/zone, or a
    // retry) replaces the old row instead of stacking duplicates that would
    // all be sent to the board's /enroll list.
    final mac = device.mac.toUpperCase();
    final kept = target.devices
        .where((d) => d.mac.toUpperCase() != mac)
        .toList();
    final updated = target.copyWith(devices: [...kept, device]);
    await _storage.save(updated);
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

/// The installation currently selected for the provisioning wizard.
final selectedInstallationProvider = StateProvider<Installation?>((_) => null);
