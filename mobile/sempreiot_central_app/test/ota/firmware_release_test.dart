import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/firmware_library_provider.dart';
import 'package:sempreiot_central_app/features/central/application/firmware_release_provider.dart';
import 'package:sempreiot_central_app/features/central/data/services/firmware_library_store.dart';
import 'package:sempreiot_central_app/features/central/data/services/release_downloader.dart';
import 'package:sempreiot_central_app/features/central/domain/ota/firmware_release.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/iot/domain/entities/mqtt_message_entity.dart';

import 'fake_firmware.dart';
import 'fake_library.dart';

/// docs/ota/ota-internet-plan.md §5.1: the catalogs, and the newest images
/// downloaded into the library, checked against what was published.

const _me = 'us-east-1:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const _other = 'us-east-1:11111111-2222-3333-4444-555555555555';

String _sha(Uint8List b) => crypto.sha256.convert(b).toString();

Map<String, Object?> _image(String family, String version, Uint8List bytes,
        {String prefix = 'bench', String? sha}) =>
    {
      'key': '$prefix/$version/$family-$version.bin',
      'size': bytes.length,
      'sha256': sha ?? _sha(bytes),
      'project': 'sempreiot-$family',
    };

String _catalog(List<Map<String, Object?>> releases) => jsonEncode({
      'v': 1,
      'channel': 'bench',
      'bucket': 'sempreiot-releases',
      'region': 'us-east-1',
      'updated': '2026-10-05T16:00:00Z',
      'releases': releases,
    });

Map<String, Object?> _release(String version, Map<String, Object?> images,
        {String notes = ''}) =>
    {
      'version': version,
      'published': '2026-10-05T16:00:00Z',
      'published_by': {
        'who': 'tallesaugusto',
        'email': 't@example.com',
        'aws': 'arn:aws:iam::1:root',
        'host': 'MacBook-Pro',
        'commit': '4706fbb',
      },
      'notes': notes,
      'images': images,
    };

class _FakeDownloader implements ReleaseDownloader {
  final objects = <String, Uint8List>{};
  final asked = <String>[];

  @override
  Future<Uint8List> download(
      {required String bucket,
      required String region,
      required String key}) async {
    asked.add(key);
    final b = objects[key];
    if (b == null) throw const ReleaseDownloadException('404');
    return b;
  }
}

void main() {
  group('catalog', () {
    final node = fakeFirmware(project: 'sempreiot-node', version: '0.3.4');

    test('reads every version, newest first, with who published it', () {
      final c = FirmwareCatalog.parse(_catalog([
        _release('0.3.3', {'node': _image('node', '0.3.3', node)}),
        _release('0.3.10', {'node': _image('node', '0.3.10', node)},
            notes: 'fix'),
        _release('0.4.0-dev', {'node': _image('node', '0.4.0-dev', node)}),
      ]))!;
      expect(c.releases.map((r) => r.version), ['0.4.0-dev', '0.3.10', '0.3.3']);
      expect(c.releases[1].notes, 'fix');
      expect(c.releases[0].publishedBy!.label, 'tallesaugusto · MacBook-Pro · 4706fbb');
      expect(c.releases[0].bucket, 'sempreiot-releases');
    });

    test('a malformed image or version is left out, the rest counts', () {
      final c = FirmwareCatalog.parse(_catalog([
        _release('0.3.4', {
          'node': _image('node', '0.3.4', node),
          'leaf': _image('leaf', '0.3.4', node, sha: 'not-a-hash'),
        }),
        {'version': '', 'images': {}},
        _release('0.3.5', {}),
      ]))!;
      expect(c.releases.map((r) => r.version), ['0.3.4']);
      expect(c.releases.single.images.keys, [SafrProductFamily.node]);
    });

    test('a payload that is not a catalog is null, never an exception', () {
      expect(FirmwareCatalog.parse('nope'), isNull);
      expect(FirmwareCatalog.parse('{"releases": 3}'), isNull);
      expect(FirmwareCatalog.parse('{"releases": []}'), isNull); // no bucket
    });

    test("this central's catalog wins on the same version; highest is the update", () {
      final everyone = FirmwareCatalog.parse(_catalog([
        _release('0.3.4', {'node': _image('node', '0.3.4', node)}),
        _release('0.3.3', {'node': _image('node', '0.3.3', node)}),
      ]))!;
      final ours = FirmwareCatalog.parse(
          _catalog([
            _release('0.3.4', {'node': _image('node', '0.3.4', node, prefix: 'centrals/x/bench')}),
          ]),
          forThisCentral: true)!;
      final merged = mergeFirmwareCatalogs(everyone, ours);
      expect(merged.map((r) => r.version), ['0.3.4', '0.3.3']);
      expect(merged.first.forThisCentral, isTrue);
      expect(highestRelease(merged, SafrProductFamily.node)!.version, '0.3.4');
      expect(highestRelease(merged, SafrProductFamily.leaf), isNull);
    });
  });

  group('downloads', () {
    late MemoryFirmwareStore store;
    late _FakeDownloader s3;
    late bool blocked;
    late ProviderContainer c;

    setUp(() {
      store = MemoryFirmwareStore();
      s3 = _FakeDownloader();
      blocked = false;
      c = ProviderContainer(overrides: [
        firmwareLibraryStoreProvider.overrideWithValue(store),
        releaseDownloaderProvider.overrideWithValue(s3),
        otaReleaseDownloadBlockedProvider.overrideWith((_) => blocked),
      ]);
    });
    tearDown(() => c.dispose());

    Future<void> hear(String topic, String payload) async {
      c.read(firmwareReleasesProvider.notifier).onMessage(
          MqttMessageEntity(topic: topic, payload: payload), _me);
      await c.read(firmwareReleasesProvider.notifier).syncNewest();
    }

    test('the newest image of each family is downloaded, checked and kept', () async {
      final n4 = fakeFirmware(project: 'sempreiot-node', version: '0.3.4');
      final n3 = fakeFirmware(project: 'sempreiot-node', version: '0.3.3');
      s3.objects['bench/0.3.4/node-0.3.4.bin'] = n4;
      s3.objects['bench/0.3.3/node-0.3.3.bin'] = n3;
      await hear(
          firmwareCatalogTopic('bench'),
          _catalog([
            _release('0.3.4', {'node': _image('node', '0.3.4', n4)}),
            _release('0.3.3', {'node': _image('node', '0.3.3', n3)}),
          ]));
      expect(store.files.keys, ['node-0.3.4.bin']); // older ones only on demand
      final lib = c.read(firmwareLibraryProvider);
      final entry = lib.image(SafrProductFamily.node, '0.3.4')!;
      final rel = c.read(firmwareReleasesProvider).publishedAs(entry);
      expect(rel!.version, '0.3.4');
      expect(c.read(firmwareReleasesProvider).failures, isEmpty);

      // Older on demand.
      expect(await c
          .read(firmwareReleasesProvider.notifier)
          .ensureImage(SafrProductFamily.node, '0.3.3'), isNull);
      expect(store.files.keys, containsAll(['node-0.3.4.bin', 'node-0.3.3.bin']));
    });

    test('an image already held with the published hash is not downloaded again', () async {
      final n4 = fakeFirmware(project: 'sempreiot-node', version: '0.3.4');
      store.files['node-0.3.4.bin'] = n4;
      await hear(firmwareCatalogTopic('bench'),
          _catalog([_release('0.3.4', {'node': _image('node', '0.3.4', n4)})]));
      expect(s3.asked, isEmpty);
    });

    test('a file of the same version with another hash is replaced by the published one', () async {
      final published = fakeFirmware(project: 'sempreiot-node', version: '0.3.4');
      final local = fakeFirmware(project: 'sempreiot-node', version: '0.3.4', size: 8192);
      store.files['node-0.3.4.bin'] = local;
      s3.objects['bench/0.3.4/node-0.3.4.bin'] = published;
      await hear(firmwareCatalogTopic('bench'),
          _catalog([_release('0.3.4', {'node': _image('node', '0.3.4', published)})]));
      expect(_sha(store.files['node-0.3.4.bin']!), _sha(published));
    });

    test('bytes that do not match the catalog are refused and nothing is kept', () async {
      final n4 = fakeFirmware(project: 'sempreiot-node', version: '0.3.4');
      final other = fakeFirmware(project: 'sempreiot-node', version: '0.3.4');
      other[200] ^= 0xFF; // same size, another hash
      s3.objects['bench/0.3.4/node-0.3.4.bin'] = other;
      await hear(firmwareCatalogTopic('bench'),
          _catalog([_release('0.3.4', {'node': _image('node', '0.3.4', n4)})]));
      expect(store.files, isEmpty);
      expect(c.read(firmwareReleasesProvider).failures['node-0.3.4'],
          contains('SHA-256'));
    });

    test("an image whose header is another family's is refused", () async {
      final board = fakeFirmware(project: 'sempreiot-board', version: '0.3.4');
      s3.objects['bench/0.3.4/node-0.3.4.bin'] = board;
      await hear(firmwareCatalogTopic('bench'),
          _catalog([_release('0.3.4', {'node': _image('node', '0.3.4', board)})]));
      expect(store.files, isEmpty);
      expect(c.read(firmwareReleasesProvider).failures['node-0.3.4'],
          contains('sempreiot-board'));
    });

    test('nothing is downloaded while the panel is busy (alarm, update)', () async {
      blocked = true;
      final n4 = fakeFirmware(project: 'sempreiot-node', version: '0.3.4');
      s3.objects['bench/0.3.4/node-0.3.4.bin'] = n4;
      await hear(firmwareCatalogTopic('bench'),
          _catalog([_release('0.3.4', {'node': _image('node', '0.3.4', n4)})]));
      expect(s3.asked, isEmpty);
      expect(c.read(firmwareReleasesProvider).highest(SafrProductFamily.node)!.version,
          '0.3.4');
    });

    test("this central's own catalog counts; another central's topic is ignored", () async {
      final n5 = fakeFirmware(project: 'sempreiot-node', version: '0.3.5');
      const prefix = 'centrals/$_me/bench';
      s3.objects['$prefix/0.3.5/node-0.3.5.bin'] = n5;
      await hear(centralFirmwareCatalogTopic(_other),
          _catalog([_release('0.9.0', {'node': _image('node', '0.9.0', n5)})]));
      expect(c.read(firmwareReleasesProvider).known, isFalse);

      await hear(centralFirmwareCatalogTopic(_me),
          _catalog([_release('0.3.5', {'node': _image('node', '0.3.5', n5, prefix: prefix)})]));
      final r = c.read(firmwareReleasesProvider).highest(SafrProductFamily.node)!;
      expect(r.version, '0.3.5');
      expect(r.forThisCentral, isTrue);
      expect(store.files.keys, ['node-0.3.5.bin']);
      expect(s3.asked, ['$prefix/0.3.5/node-0.3.5.bin']);
    });

    test('an empty retained payload means nothing is published there', () async {
      final n4 = fakeFirmware(project: 'sempreiot-node', version: '0.3.4');
      s3.objects['bench/0.3.4/node-0.3.4.bin'] = n4;
      await hear(firmwareCatalogTopic('bench'),
          _catalog([_release('0.3.4', {'node': _image('node', '0.3.4', n4)})]));
      await hear(firmwareCatalogTopic('bench'), '');
      expect(c.read(firmwareReleasesProvider).releases, isEmpty);
    });
  });
}
