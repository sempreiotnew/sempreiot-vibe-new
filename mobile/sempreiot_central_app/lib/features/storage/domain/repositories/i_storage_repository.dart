import '../entities/storage_volume.dart';

abstract interface class IStorageRepository {
  Future<StorageVolume> getInternalStorage();
}
