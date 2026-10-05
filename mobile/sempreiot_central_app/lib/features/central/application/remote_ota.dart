import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../access/application/central_access_provider.dart';
import '../../access/domain/entities/access_level.dart';
import '../../access/domain/entities/access_relation.dart';
import '../domain/safr/safr_product.dart';
import 'central_mirror_codec.dart';
import 'device_update_controller.dart';
import 'device_update_state.dart';
import 'firmware_library_provider.dart';
import 'firmware_release_provider.dart';
import 'ota_push_report.dart' show unitFamily;
import 'topology_provider.dart';

/// A phone's Internet update, carried out on the tablet
/// (docs/ota/ota-internet-plan.md §5.4, §7). The same run as the tablet's
/// own "Atualizar" — only the checks before it are the phone's:
///
/// 1. who asked is the Identity ID in the command's topic (AWS lets a user
///    publish only under its own), and that user must be an accepted
///    **Administrador** (or Master) of this central (decided 2026-10-05);
/// 2. only a version **published** for this central, never a file chosen on
///    the tablet (Manual stays on site);
/// 3. the controller's own blockers: a run, a push, a rollout, a held alarm.
///
/// Every start, cancel and refusal goes into the audit trail with who
/// asked.
class RemoteOta {
  RemoteOta(this._ref);
  final Ref _ref;

  /// Null = done; otherwise why not, in words for the phone.
  Future<String?> handle(String userIdentityId, MirrorRemoteOta command) async {
    final user = _userOf(userIdentityId);
    final by = 'remote:${command.name ?? user?.userSubId ?? userIdentityId}';
    final refused = user == null
        ? 'Só um Administrador desta central pode atualizar pela internet.'
        : command.cancel
            ? await _cancel()
            : await _start(command, by);
    _audit(
      by,
      refused == null
          ? (command.cancel ? 'ota_remote_cancelled' : 'ota_remote_started')
          : 'ota_remote_refused',
      {
        'user': userIdentityId,
        if (command.cancel) 'cancel': true,
        if (command.all) 'all': true,
        if (command.family != null) 'family': command.family!.name,
        if (command.version != null) 'version': command.version,
        if (refused != null) 'reason': refused,
      },
    );
    return refused;
  }

  /// The accepted Administrador or Master relation of [userIdentityId].
  AccessRelation? _userOf(String userIdentityId) {
    for (final r in _ref.read(centralAccessRelationsProvider)) {
      if (r.userIdentityId == userIdentityId &&
          r.isAccepted &&
          (r.level == AccessLevel.level4 || r.level == AccessLevel.master)) {
        return r;
      }
    }
    return null;
  }

  Future<String?> _cancel() async {
    final run = _ref.read(deviceUpdateProvider);
    if (run == null || !run.running) return 'Nenhuma atualização em andamento.';
    await _ref.read(deviceUpdateProvider.notifier).abort();
    return null;
  }

  Future<String?> _start(MirrorRemoteOta command, String by) async {
    final update = _ref.read(deviceUpdateProvider.notifier);
    if (command.all) {
      return update.startAll(by: by, source: DeviceUpdateSource.internet);
    }
    final family = command.family!;
    final version = command.version!;
    if (_ref.read(firmwareReleasesProvider).release(family, version) == null) {
      return 'A versão $version não está publicada para esta central.';
    }
    final List<String> keys;
    if (family == SafrProductFamily.board) {
      keys = const [deviceUpdateBoardKey];
    } else {
      final known = {
        for (final n in _ref.read(topologyProvider))
          if (n.layer > 0 && unitFamily(n) == family) n.mac: n,
      };
      if (command.units.isEmpty) return 'Escolha ao menos um dispositivo.';
      final unknown = command.units.where((k) => !known.containsKey(k));
      if (unknown.isNotEmpty) {
        return 'A central não conhece ${unknown.join(', ')} '
            '(ou não é deste tipo).';
      }
      keys = command.units;
    }
    final failed = await _ref
        .read(firmwareReleasesProvider.notifier)
        .ensureImage(family, version);
    if (failed != null) return failed;
    final image = _ref.read(firmwareLibraryProvider).image(family, version);
    if (image == null) return 'O firmware baixado não está no tablet.';
    // Every unit chosen already runs it: chosen on purpose ("Reinstalar").
    final runs = {
      for (final n in _ref.read(topologyProvider)) n.mac: n.fwVersion ?? '',
    };
    final reinstall = family != SafrProductFamily.board &&
        keys.every((k) => runs[k] == version);
    return update.start(
      family: family,
      keys: keys,
      image: image,
      reinstall: reinstall,
      by: by,
      source: DeviceUpdateSource.internet,
    );
  }

  void _audit(String by, String action, Map<String, Object?> detail) {
    _ref
        .read(appDatabaseProvider)
        .addAudit(by, action, detail)
        .catchError((Object e) => debugPrint('[OTA] audit not written: $e'));
  }
}

final remoteOtaProvider = Provider<RemoteOta>((ref) => RemoteOta(ref));
