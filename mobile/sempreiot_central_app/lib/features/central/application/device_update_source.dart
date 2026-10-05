import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/database/app_database.dart';
import '../../access/application/user_access_provider.dart';
import '../../access/domain/entities/access_level.dart';
import '../domain/ota/firmware_release.dart';
import '../domain/ota/firmware_version.dart';
import '../domain/safr/safr_product.dart';
import 'central_mirror_viewer.dart';
import 'device_update_controller.dart';
import 'device_update_state.dart';
import 'firmware_release_provider.dart';
import 'ota_push_report.dart' show unitFamily;
import 'topology_provider.dart';

/// "Atualizar dispositivos": Internet | Manual (docs/ota/ota-internet-plan.md
/// §5.3). The tablet remembers the last choice; a user's phone has only
/// Internet (§6).
class DeviceUpdateSourceController extends StateNotifier<DeviceUpdateSource> {
  DeviceUpdateSourceController(this._db) : super(DeviceUpdateSource.internet) {
    unawaited(_restore());
  }

  final AppDatabase? _db;
  static const _metaKey = 'ota_update_source';

  Future<void> _restore() async {
    try {
      final saved = await _db?.getMeta(_metaKey);
      final source = DeviceUpdateSource.values
          .where((s) => s.name == saved)
          .firstOrNull;
      if (source != null && mounted) state = source;
    } catch (e) {
      debugPrint('[OTA] update source not read: $e');
    }
  }

  void choose(DeviceUpdateSource source) {
    state = source;
    unawaited(_db
        ?.setMeta(_metaKey, source.name)
        .catchError((Object e) => debugPrint('[OTA] update source not kept: $e')));
  }
}

/// This app is the central (the tablet), not a user's phone or the web.
/// A provider so tests can play the tablet.
final appIsCentralProvider = Provider<bool>((_) => AppConfig.isCentral);

final _deviceUpdateSourceChoiceProvider =
    StateNotifierProvider<DeviceUpdateSourceController, DeviceUpdateSource>(
  // Only the tablet has the local database (none on the web or a phone).
  (ref) => DeviceUpdateSourceController(
      ref.read(appIsCentralProvider) ? ref.read(appDatabaseProvider) : null),
);

/// The source the screen uses: the tablet's choice, Internet on a phone.
final deviceUpdateSourceProvider = Provider<DeviceUpdateSource>((ref) =>
    ref.watch(mirrorViewOnlyProvider)
        ? DeviceUpdateSource.internet
        : ref.watch(_deviceUpdateSourceChoiceProvider));

/// Switches the tablet between Internet and Manual.
void chooseDeviceUpdateSource(WidgetRef ref, DeviceUpdateSource source) =>
    ref.read(_deviceUpdateSourceChoiceProvider.notifier).choose(source);

/// What has an update: the units the tablet hears now (the same ones
/// "Atualizar tudo" takes) that run a version lower than the highest
/// published one of their family, or never said which one they run. A
/// published version lower than what a unit runs is never an update.
UpdatesAvailable computeUpdatesAvailable(
    List<TopologyNode> nodes, List<FirmwareRelease> releases) {
  final units = <SafrProductFamily, List<String>>{};
  final versions = <SafrProductFamily, String>{};
  for (final f in const [
    SafrProductFamily.board,
    SafrProductFamily.node,
    SafrProductFamily.leaf,
  ]) {
    final top = highestRelease(releases, f);
    if (top == null) continue;
    final behind = <String>[
      for (final n in nodes)
        if (unitFamily(n) == f &&
            (f == SafrProductFamily.board || (n.layer > 0 && n.online)) &&
            !n.retired &&
            ((n.fwVersion ?? '').isEmpty ||
                compareFirmwareVersions(top.version, n.fwVersion!) > 0))
          f == SafrProductFamily.board ? deviceUpdateBoardKey : n.mac,
    ];
    if (behind.isNotEmpty) {
      units[f] = behind;
      versions[f] = top.version;
    }
  }
  return UpdatesAvailable(units: units, versions: versions);
}

/// The badge's count. Nothing while an update runs: the run line already
/// says what happens (plan §5.2). On a phone: what the viewed central's own
/// badge counts, through the mirror.
final updatesAvailableProvider = Provider<UpdatesAvailable>((ref) {
  if (ref.watch(mirrorViewOnlyProvider)) {
    return ref.watch(centralMirrorProvider.select((v) => v.updates));
  }
  // The app (phone, web) with no central open has no units of its own —
  // and no local database to read them from: nothing to count.
  if (!ref.watch(appIsCentralProvider)) return UpdatesAvailable.none;
  if (ref.watch(deviceUpdateRunProvider)?.running == true) {
    return UpdatesAvailable.none;
  }
  return computeUpdatesAvailable(
    ref.watch(topologyProvider),
    ref.watch(firmwareReleasesProvider).releases,
  );
});

/// What the screens show of the published versions.
class FirmwareReleasesView {
  const FirmwareReleasesView({required this.known, required this.releases});

  /// A catalog was heard (on a phone: the central said what it has).
  final bool known;

  /// Newest first.
  final List<FirmwareRelease> releases;

  FirmwareRelease? highest(SafrProductFamily family) =>
      highestRelease(releases, family);
}

/// The tablet's own catalogs; on a phone, the viewed central's.
final firmwareReleasesViewProvider = Provider<FirmwareReleasesView>((ref) {
  if (ref.watch(mirrorViewOnlyProvider)) {
    final releases = ref.watch(centralMirrorProvider.select((v) => v.releases));
    return FirmwareReleasesView(
        known: releases != null, releases: releases ?? const []);
  }
  if (!ref.watch(appIsCentralProvider)) {
    return const FirmwareReleasesView(known: false, releases: []);
  }
  final state = ref.watch(firmwareReleasesProvider);
  return FirmwareReleasesView(known: state.known, releases: state.releases);
});

/// A phone viewing a central whose user may start an Internet update there:
/// an accepted Administrador or Master (decided 2026-10-05). The central
/// checks it again on its side, from who AWS says published the request.
final mirrorCanUpdateProvider = Provider<bool>((ref) {
  final id = ref.watch(viewedCentralProvider);
  if (id == null) return false;
  for (final c in ref.watch(savedCentralsProvider)) {
    if (c.identityId == id) {
      return c.status == 'ACCEPTED' &&
          (c.level == AccessLevel.level4 || c.level == AccessLevel.master);
    }
  }
  return false;
});

