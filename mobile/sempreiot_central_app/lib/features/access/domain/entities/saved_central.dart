import 'access_level.dart';

/// A central the user has requested access to or been granted access.
class SavedCentral {
  final String subId;
  final String identityId;
  final String name;
  final String status; // 'PENDING' | 'ACCEPTED' | 'REJECTED' | 'BLOCKED'
  final AccessLevel? level; // only set when status == 'ACCEPTED'
  final DateTime addedAt;

  const SavedCentral({
    required this.subId,
    required this.identityId,
    required this.name,
    required this.status,
    this.level,
    required this.addedAt,
  });

  SavedCentral copyWith({
    String? name,
    String? status,
    AccessLevel? level,
    bool clearLevel = false,
  }) =>
      SavedCentral(
        subId: subId,
        identityId: identityId,
        name: name ?? this.name,
        status: status ?? this.status,
        level: clearLevel ? null : (level ?? this.level),
        addedAt: addedAt,
      );

  Map<String, dynamic> toMap() => {
        'subId': subId,
        'identityId': identityId,
        'name': name,
        'status': status,
        if (level != null) 'level': level!.wireValue,
        'addedAt': addedAt.toIso8601String(),
      };

  factory SavedCentral.fromMap(Map<String, dynamic> map) => SavedCentral(
        subId: map['subId'] as String? ?? '',
        identityId: map['identityId'] as String? ?? '',
        name: map['name'] as String? ?? '',
        status: map['status'] as String? ?? 'PENDING',
        level: AccessLevel.fromWire(map['level'] as String?),
        addedAt: DateTime.tryParse(map['addedAt'] as String? ?? '') ?? DateTime.now(),
      );
}
