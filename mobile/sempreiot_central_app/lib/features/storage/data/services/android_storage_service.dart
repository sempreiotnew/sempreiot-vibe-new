import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/entities/storage_volume.dart';

class AndroidStorageService {
  static const _channel = MethodChannel('com.sempreiot.central/storage');

  Future<StorageVolume> getInternalStorage() async {
    if (kIsWeb) {
      return const StorageVolume(
        label: 'Armazenamento Interno',
        totalBytes: 0,
        availableBytes: 0,
      );
    }
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>(
        'getInternalStorage',
      );
      return StorageVolume(
        label: 'Armazenamento Interno',
        totalBytes: (data!['totalBytes'] as num).toInt(),
        availableBytes: (data['availableBytes'] as num).toInt(),
      );
    } on PlatformException catch (e) {
      throw Exception('Falha ao ler armazenamento: ${e.message}');
    }
  }
}
