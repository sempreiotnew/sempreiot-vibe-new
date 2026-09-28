class LookupResult {
  final String subId;
  final String identityId;
  final String name;
  final String email;
  final String type; // 'central' | 'user'

  const LookupResult({
    required this.subId,
    required this.identityId,
    required this.name,
    required this.email,
    required this.type,
  });

  factory LookupResult.fromMap(Map<String, dynamic> map) => LookupResult(
        subId: map['subId'] as String? ?? '',
        identityId: map['identityId'] as String? ?? '',
        name: map['name'] as String? ?? '',
        email: map['email'] as String? ?? '',
        type: map['type'] as String? ?? 'user',
      );

  String get displayName => name.isNotEmpty ? name : (email.isNotEmpty ? email : subId);
}
