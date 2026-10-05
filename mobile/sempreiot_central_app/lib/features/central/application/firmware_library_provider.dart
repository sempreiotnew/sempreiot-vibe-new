import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/services/firmware_file_picker.dart';
import '../data/services/firmware_library_store.dart';
import '../domain/ota/firmware_image.dart';
import '../domain/ota/firmware_version.dart';
import '../domain/safr/safr_product.dart';

/// One image the tablet keeps and can send: what it is comes from its own
/// header (`esp_app_desc_t`), never from the file name it had.
class FirmwareLibraryEntry {
  const FirmwareLibraryEntry({
    required this.fileName,
    required this.family,
    required this.version,
    required this.size,
    required this.addedAt,
    this.sha256 = '',
  });

  /// Name inside the library (`node-0.1.1.bin`).
  final String fileName;
  final SafrProductFamily family;
  final String version;
  final int size;
  final DateTime addedAt;

  /// Lower-case hex SHA-256 of the file: an image downloaded from the
  /// Internet is the published one only while this matches the catalog
  /// (firmware_release_provider.dart).
  final String sha256;

  /// Library file name of an image of [family] at [version].
  static String fileNameFor(SafrProductFamily family, String version) =>
      '${family.name}-$version.bin';
}

/// The tablet's firmware library.
class FirmwareLibraryState {
  const FirmwareLibraryState({
    this.entries = const [],
    this.loaded = false,
    this.busy = false,
  });

  final List<FirmwareLibraryEntry> entries;

  /// The folder was read at least once.
  final bool loaded;

  /// Reading or importing.
  final bool busy;

  /// The images of [family], newest first.
  List<FirmwareLibraryEntry> of(SafrProductFamily family) => [
        for (final e in entries)
          if (e.family == family) e
      ]..sort((a, b) => compareFirmwareVersions(b.version, a.version));

  FirmwareLibraryEntry? image(SafrProductFamily family, String version) {
    for (final e in entries) {
      if (e.family == family && e.version == version) return e;
    }
    return null;
  }

  /// The newest image of [family] the tablet has — what "Atualizar tudo"
  /// sends to that family. Null when there is none.
  FirmwareLibraryEntry? newest(SafrProductFamily family) =>
      of(family).firstOrNull;

  FirmwareLibraryState copyWith({
    List<FirmwareLibraryEntry>? entries,
    bool? loaded,
    bool? busy,
  }) =>
      FirmwareLibraryState(
        entries: entries ?? this.entries,
        loaded: loaded ?? this.loaded,
        busy: busy ?? this.busy,
      );
}

/// Fills and reads the library. Importing copies the chosen `.bin` files
/// into it, so an update never depends on where the file came from (a USB
/// stick, a download) still being there.
class FirmwareLibraryController extends StateNotifier<FirmwareLibraryState> {
  FirmwareLibraryController(this._ref) : super(const FirmwareLibraryState());

  final Ref _ref;

  FirmwareLibraryStore get _store => _ref.read(firmwareLibraryStoreProvider);

  /// Reads the folder; a file that is not an image is left out.
  Future<void> load() async {
    state = state.copyWith(busy: true);
    final entries = <FirmwareLibraryEntry>[];
    try {
      for (final f in await _store.list()) {
        try {
          final bytes = await _store.read(f.name);
          final header = FirmwareImageHeader.parse(bytes);
          entries.add(FirmwareLibraryEntry(
            fileName: f.name,
            family: header.family,
            version: header.version,
            size: f.size,
            addedAt: f.modified,
            sha256: crypto.sha256.convert(bytes).toString(),
          ));
        } on FirmwareImageException {
          continue;
        }
      }
    } catch (e) {
      debugPrint('[OTA] firmware library not read: $e');
    }
    if (!mounted) return;
    state = FirmwareLibraryState(entries: entries, loaded: true);
  }

  /// Opens the file chooser and keeps every image chosen. Returns what
  /// happened in one line, or null when the operator gave up.
  Future<String?> importFromTablet() async {
    final List<PickedFirmware> picked;
    try {
      picked = await _ref.read(firmwareFilePickerProvider).pickMany();
    } on FirmwarePickException catch (e) {
      return e.message;
    }
    if (picked.isEmpty) return null;
    return importFiles(picked);
  }

  /// Keeps [files] that are SempreIoT images (an image of the same family
  /// and version replaces the one there). Returns what happened in one line.
  Future<String> importFiles(List<PickedFirmware> files) async {
    state = state.copyWith(busy: true);
    var kept = 0;
    final refused = <String>[];
    for (final f in files) {
      final FirmwareImageHeader header;
      try {
        header = FirmwareImageHeader.parse(f.bytes);
      } on FirmwareImageException {
        refused.add(f.name);
        continue;
      }
      await _store.save(
        FirmwareLibraryEntry.fileNameFor(header.family, header.version),
        f.bytes,
      );
      kept++;
    }
    await load();
    final parts = <String>[
      if (kept > 0)
        kept == 1
            ? '1 firmware guardado no tablet'
            : '$kept firmwares guardados no tablet',
      if (refused.isNotEmpty)
        '${refused.join(', ')}: não é um firmware SempreIoT',
    ];
    return parts.join(' · ');
  }

  /// Keeps an image downloaded from the Internet, already checked against
  /// the catalog (hash, family, version) by the caller.
  Future<void> savePublished(
      SafrProductFamily family, String version, Uint8List bytes) async {
    await _store.save(FirmwareLibraryEntry.fileNameFor(family, version), bytes);
    await load();
  }

  Future<Uint8List> read(FirmwareLibraryEntry entry) =>
      _store.read(entry.fileName);

  Future<void> remove(FirmwareLibraryEntry entry) async {
    await _store.delete(entry.fileName);
    await load();
  }
}

final firmwareLibraryProvider =
    StateNotifierProvider<FirmwareLibraryController, FirmwareLibraryState>(
  (ref) => FirmwareLibraryController(ref)..load(),
);
