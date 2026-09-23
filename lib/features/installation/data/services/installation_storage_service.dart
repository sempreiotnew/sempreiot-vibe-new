import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/entities/installation.dart';

/// Persists Installation codes encrypted at rest (POC-BRIEF.md §6.1:
/// "stored encrypted with flutter_secure_storage") — these carry
/// `net_psk`/`safr_psk`, the same secrets the device itself must never leak.
class InstallationStorageService {
  InstallationStorageService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _indexKey = 'siot_installations_index';
  static const _entryPrefix = 'siot_installation_';

  Future<List<Installation>> loadAll() async {
    final ids = await _loadIndex();
    final result = <Installation>[];
    for (final id in ids) {
      final raw = await _storage.read(key: '$_entryPrefix$id');
      if (raw == null) continue;
      try {
        result.add(Installation.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        ));
      } on FormatException {
        continue; // corrupt entry — skip rather than crash the whole list
      }
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  Future<void> save(Installation installation) async {
    await _storage.write(
      key: '$_entryPrefix${installation.localId}',
      value: jsonEncode(installation.toJson()),
    );
    final ids = await _loadIndex();
    if (!ids.contains(installation.localId)) {
      ids.add(installation.localId);
      await _saveIndex(ids);
    }
  }

  Future<void> delete(String localId) async {
    await _storage.delete(key: '$_entryPrefix$localId');
    final ids = await _loadIndex();
    ids.remove(localId);
    await _saveIndex(ids);
  }

  Future<List<String>> _loadIndex() async {
    final raw = await _storage.read(key: _indexKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List<dynamic>).cast<String>();
    } on FormatException {
      return [];
    }
  }

  Future<void> _saveIndex(List<String> ids) =>
      _storage.write(key: _indexKey, value: jsonEncode(ids));
}
