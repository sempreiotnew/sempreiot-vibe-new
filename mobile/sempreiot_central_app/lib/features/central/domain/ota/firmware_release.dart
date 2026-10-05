import 'dart:convert';

import '../safr/safr_product.dart';
import 'firmware_version.dart';

/// Firmware published on the Internet (docs/ota/ota-internet-plan.md): the
/// catalog `firmware/tools/ota_release.sh` writes to S3 and announces,
/// retained, on MQTT — for every central (`sempreiot/releases/<channel>`)
/// or for one central only (`<its Identity ID>/release`).

/// Who published a version: the person (git), the AWS identity, the machine
/// and the source commit, as `ota_release.sh` recorded them.
class FirmwarePublisher {
  const FirmwarePublisher({
    required this.who,
    this.email = '',
    this.aws = '',
    this.host = '',
    this.commit = '',
  });

  final String who;
  final String email;
  final String aws;
  final String host;
  final String commit;

  /// "tallesaugusto · MacBook-Pro · 4706fbb".
  String get label => [who, host, commit].where((s) => s.isNotEmpty).join(' · ');

  static FirmwarePublisher? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final who = raw['who'];
    if (who is! String || who.isEmpty) return null;
    String s(String k) => raw[k] is String ? raw[k] as String : '';
    return FirmwarePublisher(
        who: who, email: s('email'), aws: s('aws'), host: s('host'), commit: s('commit'));
  }

  Map<String, Object?> toJson() =>
      {'who': who, 'email': email, 'aws': aws, 'host': host, 'commit': commit};
}

/// One image of a published version.
class FirmwareReleaseImage {
  const FirmwareReleaseImage({
    required this.key,
    required this.size,
    required this.sha256,
    required this.project,
  });

  /// S3 object key, e.g. `bench/0.3.4/node-0.3.4.bin`.
  final String key;
  final int size;

  /// Lower-case hex SHA-256 of the signed image.
  final String sha256;

  /// `project_name` the image must carry (`sempreiot-node`).
  final String project;

  static FirmwareReleaseImage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'], size = raw['size'], sha = raw['sha256'];
    final project = raw['project'];
    if (key is! String || key.isEmpty || size is! int || size <= 0) return null;
    if (sha is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) return null;
    return FirmwareReleaseImage(
        key: key, size: size, sha256: sha, project: project is String ? project : '');
  }
}

/// One published version: an image per family, its notes, who published it.
class FirmwareRelease {
  const FirmwareRelease({
    required this.version,
    required this.images,
    required this.bucket,
    required this.region,
    this.published,
    this.publishedBy,
    this.notes = '',
    this.forThisCentral = false,
  });

  final String version;
  final Map<SafrProductFamily, FirmwareReleaseImage> images;

  /// Where the images are (from the catalog).
  final String bucket;
  final String region;
  final DateTime? published;
  final FirmwarePublisher? publishedBy;
  final String notes;

  /// Published for this central only (`ota_release.sh --central`).
  final bool forThisCentral;

  FirmwareReleaseImage? image(SafrProductFamily family) => images[family];
}

/// A catalog as announced: every published version, newest first.
class FirmwareCatalog {
  const FirmwareCatalog({
    required this.channel,
    required this.releases,
    this.updated,
  });

  final String channel;
  final List<FirmwareRelease> releases;
  final DateTime? updated;

  static const empty = FirmwareCatalog(channel: '', releases: []);

  /// Reads an announced catalog. Never throws: a payload that is not a
  /// catalog is null, and a version or an image that is malformed is left
  /// out (the rest still counts). [forThisCentral] marks the catalog that
  /// came on this central's own topic.
  static FirmwareCatalog? parse(String payload, {bool forThisCentral = false}) {
    final Object? raw;
    try {
      raw = jsonDecode(payload);
    } catch (_) {
      return null;
    }
    if (raw is! Map || raw['releases'] is! List) return null;
    final bucket = raw['bucket'], region = raw['region'];
    if (bucket is! String || bucket.isEmpty || region is! String || region.isEmpty) {
      return null;
    }
    final releases = <FirmwareRelease>[];
    for (final r in raw['releases'] as List) {
      if (r is! Map) continue;
      final version = r['version'];
      final imgs = r['images'];
      if (version is! String || version.isEmpty || imgs is! Map) continue;
      final images = <SafrProductFamily, FirmwareReleaseImage>{};
      for (final f in SafrProductFamily.values) {
        final img = FirmwareReleaseImage.fromJson(imgs[f.name]);
        if (img != null) images[f] = img;
      }
      if (images.isEmpty) continue;
      releases.add(FirmwareRelease(
        version: version,
        images: images,
        bucket: bucket,
        region: region,
        published: DateTime.tryParse(r['published'] as String? ?? ''),
        publishedBy: FirmwarePublisher.fromJson(r['published_by']),
        notes: r['notes'] is String ? r['notes'] as String : '',
        forThisCentral: forThisCentral,
      ));
    }
    releases.sort((a, b) => compareFirmwareVersions(b.version, a.version));
    return FirmwareCatalog(
      channel: raw['channel'] is String ? raw['channel'] as String : '',
      releases: releases,
      updated: DateTime.tryParse(raw['updated'] as String? ?? ''),
    );
  }
}

/// What this central may install from the Internet: the catalog for every
/// central and the one for this central only, merged. A version in both
/// is this central's (it was made for it). Newest first.
List<FirmwareRelease> mergeFirmwareCatalogs(
    FirmwareCatalog? everyone, FirmwareCatalog? ours) {
  final byVersion = <String, FirmwareRelease>{
    for (final r in everyone?.releases ?? const <FirmwareRelease>[]) r.version: r,
    for (final r in ours?.releases ?? const <FirmwareRelease>[]) r.version: r,
  };
  return byVersion.values.toList()
    ..sort((a, b) => compareFirmwareVersions(b.version, a.version));
}

/// The published versions that have an image of [family], newest first.
List<FirmwareRelease> releasesOf(
        List<FirmwareRelease> releases, SafrProductFamily family) =>
    [for (final r in releases) if (r.images.containsKey(family)) r];

/// The highest published version of [family] — the only one that is ever
/// called an update (D4) — or null when nothing of it is published.
FirmwareRelease? highestRelease(
        List<FirmwareRelease> releases, SafrProductFamily family) =>
    releasesOf(releases, family).firstOrNull;

/// The units that run less than the highest published version of their
/// family (plan D4) — what the round badge on "Atualizar dispositivos"
/// counts.
class UpdatesAvailable {
  const UpdatesAvailable({this.units = const {}, this.versions = const {}});

  /// Per family, the units (MACs; the board's key) that have an update.
  final Map<SafrProductFamily, List<String>> units;

  /// Per family with an update, the version it would go to.
  final Map<SafrProductFamily, String> versions;

  static const none = UpdatesAvailable();

  int get count => units.values.fold(0, (n, u) => n + u.length);
  bool get any => count > 0;

  /// "3 dispositivos" / "1 dispositivo".
  String get countText => count == 1 ? '1 dispositivo' : '$count dispositivos';
}
