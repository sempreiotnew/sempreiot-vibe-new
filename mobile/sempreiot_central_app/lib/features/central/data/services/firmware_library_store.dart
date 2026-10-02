import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// One file in the tablet's firmware library.
class StoredFirmwareFile {
  const StoredFirmwareFile({
    required this.name,
    required this.size,
    required this.modified,
  });

  /// File name inside the library: `<family>-<version>.bin`.
  final String name;
  final int size;
  final DateTime modified;
}

/// Where the firmware images the tablet can send are kept. Only files: what
/// an image is (family, version) is read from its own header, never from a
/// database. Today the images come from the file chooser; a download from
/// the cloud (brief step 5) is one more way to fill the same folder.
abstract class FirmwareLibraryStore {
  Future<List<StoredFirmwareFile>> list();
  Future<Uint8List> read(String name);

  /// Writes [bytes] as [name], replacing a file with that name.
  Future<StoredFirmwareFile> save(String name, Uint8List bytes);
  Future<void> delete(String name);
}

/// The library as a folder of `.bin` files.
class DirectoryFirmwareLibraryStore implements FirmwareLibraryStore {
  DirectoryFirmwareLibraryStore(this._directory);

  final Future<Directory> Function() _directory;

  Future<Directory> _dir() async {
    final dir = await _directory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<List<StoredFirmwareFile>> list() async {
    final dir = await _dir();
    final out = <StoredFirmwareFile>[];
    await for (final e in dir.list()) {
      if (e is! File || !e.path.endsWith('.bin')) continue;
      final stat = await e.stat();
      out.add(StoredFirmwareFile(
        name: e.uri.pathSegments.last,
        size: stat.size,
        modified: stat.modified,
      ));
    }
    return out;
  }

  @override
  Future<Uint8List> read(String name) async =>
      File('${(await _dir()).path}/$name').readAsBytes();

  @override
  Future<StoredFirmwareFile> save(String name, Uint8List bytes) async {
    final file = File('${(await _dir()).path}/$name');
    // Written aside and renamed: a library never holds half an image.
    final part = File('${file.path}.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(file.path);
    final stat = await file.stat();
    return StoredFirmwareFile(
        name: name, size: stat.size, modified: stat.modified);
  }

  @override
  Future<void> delete(String name) async {
    final file = File('${(await _dir()).path}/$name');
    if (await file.exists()) await file.delete();
  }
}

final firmwareLibraryStoreProvider = Provider<FirmwareLibraryStore>(
  (ref) => DirectoryFirmwareLibraryStore(() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/firmware');
  }),
);
