import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A file the operator chose, as bytes.
class PickedFirmware {
  const PickedFirmware({required this.name, required this.bytes});
  final String name;
  final Uint8List bytes;
}

/// The file could not be read; [message] says why, in pt-BR.
class FirmwarePickException implements Exception {
  const FirmwarePickException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Lets the operator choose the firmware file (a `.bin`) on the tablet.
abstract class FirmwareFilePicker {
  /// Null = the operator gave up.
  Future<PickedFirmware?> pick();
}

/// The system file chooser. Any file can be chosen: what decides whether it
/// is a firmware is its content, not its name.
class SystemFirmwareFilePicker implements FirmwareFilePicker {
  const SystemFirmwareFilePicker();

  @override
  Future<PickedFirmware?> pick() async {
    final FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        dialogTitle: 'Escolher firmware',
        type: FileType.any,
        withData: true,
      );
    } catch (_) {
      throw const FirmwarePickException(
          'Não foi possível abrir o seletor de arquivos.');
    }
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      throw const FirmwarePickException('Não foi possível ler o arquivo.');
    }
    return PickedFirmware(name: file.name, bytes: bytes);
  }
}

final firmwareFilePickerProvider = Provider<FirmwareFilePicker>(
  (ref) => const SystemFirmwareFilePicker(),
);
