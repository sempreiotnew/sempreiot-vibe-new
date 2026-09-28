import '../../domain/entities/storage_volume.dart';
import '../../domain/repositories/i_storage_repository.dart';
import '../services/android_storage_service.dart';

class StorageRepositoryImpl implements IStorageRepository {
  StorageRepositoryImpl() : _service = AndroidStorageService();

  final AndroidStorageService _service;

  @override
  Future<StorageVolume> getInternalStorage() => _service.getInternalStorage();
}
