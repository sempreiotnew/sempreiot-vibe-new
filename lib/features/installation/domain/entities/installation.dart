/// A device already provisioned into an installation — tracked locally so
/// that, when the board is provisioned, its sticker can be sent the
/// `/enroll` list (POC-BRIEF.md §5/§6.2: `[{mac, id, name, zone}]`).
class ProvisionedDevice {
  const ProvisionedDevice({
    required this.mac,
    required this.id,
    required this.name,
    required this.zone,
  });

  final String mac;
  final String id;
  final String name;
  final String zone;

  Map<String, dynamic> toJson() =>
      {'mac': mac, 'id': id, 'name': name, 'zone': zone};

  factory ProvisionedDevice.fromJson(Map<String, dynamic> json) =>
      ProvisionedDevice(
        mac: json['mac'] as String,
        id: json['id'] as String,
        name: json['name'] as String,
        zone: json['zone'] as String,
      );
}

/// An installation code (POC-BRIEF.md §6.1): the SoftAP/mesh identity the
/// phone hands to every device provisioned into this installation via
/// POST /provision's `code_json` (POC-BRIEF §5).
class Installation {
  const Installation({
    required this.localId,
    required this.displayName,
    required this.systemId,
    required this.netSsid,
    required this.netPsk,
    required this.safrPskHex,
    required this.channel,
    required this.meshId,
    required this.zones,
    required this.createdAt,
    this.devices = const [],
  });

  /// Local identifier for this installation on this phone only — never sent
  /// over the wire (not to be confused with SYSTEM_ID).
  final String localId;

  /// Operator-facing nickname, e.g. "Galpão 2".
  final String displayName;

  final int systemId;
  final String netSsid;
  final String netPsk;

  /// 32 lowercase hex chars (16 bytes) — matches `code_json.safr_psk_hex`.
  final String safrPskHex;

  final int channel;
  final int meshId;
  final List<String> zones;
  final DateTime createdAt;

  /// Devices already provisioned into this installation (nodes provisioned
  /// before the board, per POC-BRIEF §7 step 2's order).
  final List<ProvisionedDevice> devices;

  Installation copyWith({
    String? displayName,
    List<String>? zones,
    List<ProvisionedDevice>? devices,
  }) =>
      Installation(
        localId: localId,
        displayName: displayName ?? this.displayName,
        systemId: systemId,
        netSsid: netSsid,
        netPsk: netPsk,
        safrPskHex: safrPskHex,
        channel: channel,
        meshId: meshId,
        zones: zones ?? this.zones,
        createdAt: createdAt,
        devices: devices ?? this.devices,
      );

  /// `code_json` for POST /provision's envelope (POC-BRIEF §5).
  Map<String, dynamic> toCodeJson() => {
        'system_id': systemId,
        'net_ssid': netSsid,
        'net_psk': netPsk,
        'safr_psk_hex': safrPskHex,
        'channel': channel,
        'mesh_id': meshId,
      };

  Map<String, dynamic> toJson() => {
        'localId': localId,
        'displayName': displayName,
        'systemId': systemId,
        'netSsid': netSsid,
        'netPsk': netPsk,
        'safrPskHex': safrPskHex,
        'channel': channel,
        'meshId': meshId,
        'zones': zones,
        'createdAt': createdAt.toIso8601String(),
        'devices': devices.map((d) => d.toJson()).toList(),
      };

  factory Installation.fromJson(Map<String, dynamic> json) => Installation(
        localId: json['localId'] as String,
        displayName: json['displayName'] as String,
        systemId: json['systemId'] as int,
        netSsid: json['netSsid'] as String,
        netPsk: json['netPsk'] as String,
        safrPskHex: json['safrPskHex'] as String,
        channel: json['channel'] as int,
        meshId: json['meshId'] as int,
        zones: (json['zones'] as List<dynamic>).cast<String>(),
        createdAt: DateTime.parse(json['createdAt'] as String),
        devices: (json['devices'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>()
            .map(ProvisionedDevice.fromJson)
            .toList(),
      );
}
