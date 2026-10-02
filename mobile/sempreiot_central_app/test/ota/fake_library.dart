import 'dart:typed_data';

import 'package:sempreiot_central_app/features/central/data/services/firmware_library_store.dart';

/// The tablet's firmware library, in memory.
class MemoryFirmwareStore implements FirmwareLibraryStore {
  MemoryFirmwareStore([Map<String, Uint8List>? files]) : files = files ?? {};
  final Map<String, Uint8List> files;

  @override
  Future<List<StoredFirmwareFile>> list() async => [
        for (final e in files.entries)
          StoredFirmwareFile(
              name: e.key, size: e.value.length, modified: DateTime(2026)),
      ];

  @override
  Future<Uint8List> read(String name) async => files[name]!;

  @override
  Future<StoredFirmwareFile> save(String name, Uint8List bytes) async {
    files[name] = bytes;
    return StoredFirmwareFile(
        name: name, size: bytes.length, modified: DateTime(2026));
  }

  @override
  Future<void> delete(String name) async => files.remove(name);
}
