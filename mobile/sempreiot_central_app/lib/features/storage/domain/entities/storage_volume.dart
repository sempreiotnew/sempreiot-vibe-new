class StorageVolume {
  const StorageVolume({
    required this.label,
    required this.totalBytes,
    required this.availableBytes,
  });

  final String label;
  final int totalBytes;
  final int availableBytes;

  int get usedBytes => totalBytes - availableBytes;

  double get usedFraction =>
      totalBytes > 0 ? (usedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  int get percentUsed => (usedFraction * 100).round();

  String _fmt(int bytes) {
    if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(0)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  String get formattedUsed => _fmt(usedBytes);
  String get formattedAvailable => _fmt(availableBytes);
  String get formattedTotal => _fmt(totalBytes);
}
