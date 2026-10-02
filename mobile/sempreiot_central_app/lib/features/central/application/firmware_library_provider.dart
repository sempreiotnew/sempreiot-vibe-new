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
  });

  /// Name inside the library (`node-0.1.1.bin`).
  final String fileName;
  final SafrProductFamily family;
  final String version;
  final int size;
  final DateTime addedAt;

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

  /// Versions the tablet has the three images of (board, node, leaf) —
  /// what "Atualizar tudo" can send — newest first.
  List<String> get completeVersions {
    final versions = {for (final e in entries) e.version};
    final out = [
      for (final v in versions)
        if (_families.every((f) => image(f, v) != null)) v,
    ]..sort((a, b) => compareFirmwareVersions(b, a));
    return out;
  }

  static const _families = [
    SafrProductFamily.board,
    SafrProductFamily.node,
    SafrProductFamily.leaf,
  ];

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
          final header = FirmwareImageHeader.parse(await _store.read(f.name));
          entries.add(FirmwareLibraryEntry(
            fileName: f.name,
            family: header.family,
            version: header.version,
            size: f.size,
            addedAt: f.modified,
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
