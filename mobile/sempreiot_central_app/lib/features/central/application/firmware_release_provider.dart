import 'dart:async';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../iot/domain/entities/mqtt_message_entity.dart';
import '../data/services/release_downloader.dart';
import '../domain/ota/firmware_image.dart';
import '../domain/ota/firmware_release.dart';
import '../domain/safr/safr_product.dart';
import 'alarm_latch_provider.dart';
import 'central_iot_provider.dart';
import 'device_update_controller.dart';
import 'firmware_library_provider.dart';
import 'ota_push_controller.dart';
import 'ota_rollout_controller.dart';

/// Firmware published on the Internet (docs/ota/ota-internet-plan.md §5.1):
/// the catalogs this central hears, and the images it downloads from them
/// into "Firmwares no tablet". The update itself is the same run as Manual.

/// The channel this tablet listens to. `bench` until production
/// (docs/ota/before-production.md item 9).
const otaReleaseChannel =
    String.fromEnvironment('OTA_CHANNEL', defaultValue: 'bench');

/// The catalog for every central, retained (`ota_release.sh`).
String firmwareCatalogTopic(String channel) => 'sempreiot/releases/$channel';

/// The catalog for this central only, retained on its own topic
/// (`ota_release.sh --central <Sub ID>`).
String centralFirmwareCatalogTopic(String identityId) => '$identityId/release';

class FirmwareReleasesState {
  const FirmwareReleasesState({
    this.everyone,
    this.ours,
    this.releases = const [],
    this.downloading = const {},
    this.failures = const {},
  });

  /// The catalog for every central; null until it was heard.
  final FirmwareCatalog? everyone;

  /// The catalog for this central only; null until it was heard.
  final FirmwareCatalog? ours;

  /// Both, merged: what this central may install, newest first.
  final List<FirmwareRelease> releases;

  /// Images being downloaded, as `family-version`.
  final Set<String> downloading;

  /// The last download failure per image (`family-version` → text).
  final Map<String, String> failures;

  /// A catalog was heard at least once.
  bool get known => everyone != null || ours != null;

  /// The highest published version of [family]: the update (D4).
  FirmwareRelease? highest(SafrProductFamily family) =>
      highestRelease(releases, family);

  /// The published version [version] that has an image of [family].
  FirmwareRelease? release(SafrProductFamily family, String version) {
    for (final r in releases) {
      if (r.version == version && r.images.containsKey(family)) return r;
    }
    return null;
  }

  /// [entry] is the published image of its version (same hash): it came
  /// from the Internet, or is byte for byte what was published there.
  FirmwareRelease? publishedAs(FirmwareLibraryEntry entry) {
    final r = release(entry.family, entry.version);
    if (r == null || entry.sha256.isEmpty) return null;
    return r.images[entry.family]!.sha256 == entry.sha256 ? r : null;
  }

  FirmwareReleasesState copyWith({
    FirmwareCatalog? everyone,
    FirmwareCatalog? ours,
    Set<String>? downloading,
    Map<String, String>? failures,
  }) {
    final e = everyone ?? this.everyone, o = ours ?? this.ours;
    return FirmwareReleasesState(
      everyone: e,
      ours: o,
      releases: (everyone != null || ours != null)
          ? mergeFirmwareCatalogs(e, o)
          : releases,
      downloading: downloading ?? this.downloading,
      failures: failures ?? this.failures,
    );
  }
}

String _imageKey(SafrProductFamily family, String version) =>
    '${family.name}-$version';

/// No download while the serial link or the panel has more important work:
/// an update or a push running, the board rolling out, an alarm held.
final otaReleaseDownloadBlockedProvider = Provider<bool>((ref) =>
    ref.watch(activeAlarmProvider) ||
    ref.watch(otaPushProvider).running ||
    ref.watch(otaRolloutProvider).running != null ||
    ref.watch(deviceUpdateProvider)?.running == true);

class FirmwareReleasesController extends StateNotifier<FirmwareReleasesState> {
  FirmwareReleasesController(this._ref) : super(const FirmwareReleasesState());

  final Ref _ref;
  final _inFlight = <String, Future<String?>>{};

  /// A message on one of the catalog topics. [identityId] is this central's.
  void onMessage(MqttMessageEntity msg, String? identityId) {
    final ours = identityId != null &&
        msg.topic == centralFirmwareCatalogTopic(identityId);
    if (!ours && msg.topic != firmwareCatalogTopic(otaReleaseChannel)) return;
    // An empty retained payload clears the topic: nothing published there.
    final catalog = msg.payload.trim().isEmpty
        ? FirmwareCatalog.empty
        : FirmwareCatalog.parse(msg.payload, forThisCentral: ours);
    if (catalog == null) {
      debugPrint('[OTA] catalog on ${msg.topic} is not a catalog: ignored');
      return;
    }
    if (!mounted) return;
    state = ours ? state.copyWith(ours: catalog) : state.copyWith(everyone: catalog);
    debugPrint('[OTA] catalog ${ours ? "for this central" : otaReleaseChannel}: '
        '${catalog.releases.map((r) => r.version).join(', ')}');
    unawaited(syncNewest());
  }

  /// Downloads the highest published version of each family when the
  /// library does not hold it yet (decided 2026-10-05: automatic). Older
  /// versions are fetched only when one is chosen ([ensureImage]).
  Future<void> syncNewest() async {
    if (_ref.read(otaReleaseDownloadBlockedProvider)) return;
    for (final f in SafrProductFamily.values) {
      final r = state.highest(f);
      if (r == null) continue;
      final failed = await ensureImage(f, r.version);
      if (failed != null) debugPrint('[OTA] ${_imageKey(f, r.version)}: $failed');
    }
  }

  /// Makes the published image of [family] at [version] present in the
  /// library and checked. Null when it is there; otherwise the reason, for
  /// the operator.
  Future<String?> ensureImage(SafrProductFamily family, String version) {
    final key = _imageKey(family, version);
    // A block, not `=> _inFlight.remove(key)`: that returns this very future,
    // and whenComplete would wait for itself.
    return _inFlight[key] ??= _ensure(family, version).whenComplete(() {
      _inFlight.remove(key);
    });
  }

  Future<String?> _ensure(SafrProductFamily family, String version) async {
    final release = state.release(family, version);
    if (release == null) return 'A versão $version não está publicada.';
    final library = _ref.read(firmwareLibraryProvider.notifier);
    if (!_ref.read(firmwareLibraryProvider).loaded) await library.load();
    final held = _ref.read(firmwareLibraryProvider).image(family, version);
    if (held != null && state.publishedAs(held) != null) return null;

    final key = _imageKey(family, version);
    _set(downloading: {...state.downloading, key});
    String? failure;
    try {
      final img = release.images[family]!;
      final bytes = await _ref.read(releaseDownloaderProvider).download(
          bucket: release.bucket, region: release.region, key: img.key);
      failure = _check(bytes, family, version, img);
      if (failure == null) {
        await library.savePublished(family, version, bytes);
        debugPrint('[OTA] $key downloaded (${bytes.length} B)');
      }
    } on ReleaseDownloadException catch (e) {
      failure = e.message;
    } catch (e) {
      failure = 'Falha ao baixar o firmware: $e';
    }
    if (mounted) {
      _set(
        downloading: {...state.downloading}..remove(key),
        failures: {...state.failures}..remove(key),
      );
      if (failure != null) _set(failures: {...state.failures, key: failure});
    }
    return failure;
  }

  /// What the catalog promised, checked on the bytes (§7 rule 5): size,
  /// hash, and the image's own header. The unit checks the signature.
  static String? _check(Uint8List bytes, SafrProductFamily family,
      String version, FirmwareReleaseImage img) {
    if (bytes.length != img.size) {
      return 'O firmware baixado tem ${bytes.length} bytes, e não ${img.size}.';
    }
    if (crypto.sha256.convert(bytes).toString() != img.sha256) {
      return 'O firmware baixado não confere com o publicado (SHA-256).';
    }
    final FirmwareImageHeader header;
    try {
      header = FirmwareImageHeader.parse(bytes);
    } on FirmwareImageException catch (e) {
      return e.message;
    }
    if (header.family != family || header.version != version) {
      return 'O firmware baixado é ${header.projectName} ${header.version}, '
          'não o publicado.';
    }
    return null;
  }

  void _set({Set<String>? downloading, Map<String, String>? failures}) {
    if (!mounted) return;
    state = state.copyWith(downloading: downloading, failures: failures);
  }
}

final firmwareReleasesProvider =
    StateNotifierProvider<FirmwareReleasesController, FirmwareReleasesState>(
  (ref) => FirmwareReleasesController(ref),
);

/// Central mode only: feeds the catalogs from MQTT into
/// [firmwareReleasesProvider] and downloads again when the panel is free.
/// Must stay watched while the app runs (MainScreen watches it).
final firmwareReleaseSyncProvider = Provider<void>((ref) {
  if (!AppConfig.isCentral) return;
  final releases = ref.read(firmwareReleasesProvider.notifier);
  // The notifier's own stream, not the StreamProvider over it: a retained
  // catalog arrives at every connect, and each one must count.
  final sub = ref
      .watch(centralIotConnectionProvider.notifier)
      .messages
      .listen((msg) => releases.onMessage(
          msg, ref.read(centralMqttRepositoryProvider).identityId));
  ref.listen<bool>(otaReleaseDownloadBlockedProvider, (prev, blocked) {
    if (prev == true && !blocked) unawaited(releases.syncNewest());
  });
  ref.onDispose(sub.cancel);
});
