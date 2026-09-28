import 'access_level.dart';

/// The relationship between one user and one central — a single row per
/// (centralIdentityId, userSubId) pair, mirroring the backend's
/// `CentralAccess` table. Replaces the old per-request `AccessRequest`
/// entity: a second request from the same user updates this same relation
/// instead of creating a new one.
class AccessRelation {
  final String centralIdentityId;
  final String userSubId;
  final String userIdentityId;
  final String status; // PENDING | ACCEPTED | REJECTED | BLOCKED
  final AccessLevel? level; // only set when status == ACCEPTED
  final String requestId;
  final DateTime requestedAt;
  final DateTime? resolvedAt;
  final DateTime updatedAt;

  const AccessRelation({
    required this.centralIdentityId,
    required this.userSubId,
    required this.userIdentityId,
    required this.status,
    required this.level,
    required this.requestId,
    required this.requestedAt,
    required this.resolvedAt,
    required this.updatedAt,
  });

  bool get isPending => status == 'PENDING';
  bool get isAccepted => status == 'ACCEPTED';
  bool get isRejected => status == 'REJECTED';
  bool get isBlocked => status == 'BLOCKED';

  factory AccessRelation.fromMap(Map<String, dynamic> map) => AccessRelation(
        centralIdentityId: map['centralIdentityId'] as String? ?? '',
        userSubId: map['userSubId'] as String? ?? '',
        userIdentityId: map['userIdentityId'] as String? ?? '',
        status: map['status'] as String? ?? 'PENDING',
        level: AccessLevel.fromWire(map['level'] as String?),
        requestId: map['requestId'] as String? ?? '',
        requestedAt: _parseDate(map['requestedAt']) ?? DateTime.now(),
        resolvedAt: _parseDate(map['resolvedAt']),
        updatedAt: _parseDate(map['updatedAt']) ?? DateTime.now(),
      );

  Map<String, dynamic> toMap() => {
        'centralIdentityId': centralIdentityId,
        'userSubId': userSubId,
        'userIdentityId': userIdentityId,
        'status': status,
        if (level != null) 'level': level!.wireValue,
        'requestId': requestId,
        'requestedAt': requestedAt.toIso8601String(),
        if (resolvedAt != null) 'resolvedAt': resolvedAt!.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  AccessRelation copyWith({
    String? status,
    AccessLevel? level,
    bool clearLevel = false,
    DateTime? resolvedAt,
    DateTime? updatedAt,
  }) =>
      AccessRelation(
        centralIdentityId: centralIdentityId,
        userSubId: userSubId,
        userIdentityId: userIdentityId,
        status: status ?? this.status,
        level: clearLevel ? null : (level ?? this.level),
        requestId: requestId,
        requestedAt: requestedAt,
        resolvedAt: resolvedAt ?? this.resolvedAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  static DateTime? _parseDate(dynamic value) =>
      value is String ? DateTime.tryParse(value) : null;
}
