import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';

/// Reads the "info" metadata row and exposes it as a typed map.
/// Returns an empty map when the row is absent or unparseable.
final deviceInfoProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  final raw = await db.getMeta('info');
  if (raw == null || raw.isEmpty) return {};
  try {
    return jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return {};
  }
});
