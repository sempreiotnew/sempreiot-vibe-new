import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/storage_repository_impl.dart';
import '../domain/entities/storage_volume.dart';
import '../domain/repositories/i_storage_repository.dart';

final storageRepositoryProvider = Provider<IStorageRepository>(
  (_) => StorageRepositoryImpl(),
);

final storageProvider =
    AsyncNotifierProvider<StorageNotifier, StorageVolume>(StorageNotifier.new);

class StorageNotifier extends AsyncNotifier<StorageVolume> {
  static const _pollInterval = Duration(seconds: 30);
  Timer? _timer;

  @override
  Future<StorageVolume> build() async {
    ref.onDispose(() => _timer?.cancel());
    _startPolling();
    return ref.read(storageRepositoryProvider).getInternalStorage();
  }

  void _startPolling() {
    _timer = Timer.periodic(_pollInterval, (_) async {
      state = await AsyncValue.guard(
        () => ref.read(storageRepositoryProvider).getInternalStorage(),
      );
    });
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(storageRepositoryProvider).getInternalStorage(),
    );
  }
}
