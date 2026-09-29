/// A device this phone provisioned into an installation — a **work log**
/// entry (lifecycle §1 principle 3), never the roster. Used for the board's
/// `/enroll` hints (`[{mac, id, name, zone}]`, POC-BRIEF §5) and for the
/// installer's own list on the detail screen.
class ProvisionedDevice {
  const ProvisionedDevice({
    required this.mac,
    required this.id,
    required this.name,
    required this.zone,
    this.provisionedAt,
    this.model,
    this.productCode,
    this.fw,
  });

  final String mac;
  final String id;
  final String name;
  final String zone;

  /// When this phone provisioned it (UTC). Null for entries written before
  /// lifecycle Phase 1.
  final DateTime? provisionedAt;

  /// What the unit said it is on its setup network (`/info`): model string,
  /// PRODUCT code (reference §2.1) and firmware version at provisioning
  /// time. Null for entries written before 2026-09-29.
  final String? model;
  final int? productCode;
  final String? fw;

  Map<String, dynamic> toJson() => {
        'mac': mac,
        'id': id,
        'name': name,
        'zone': zone,
        if (provisionedAt != null)
          'provisionedAt': provisionedAt!.toIso8601String(),
        if (model != null && model!.isNotEmpty) 'model': model,
        if (productCode != null) 'productCode': productCode,
        if (fw != null && fw!.isNotEmpty) 'fw': fw,
      };

  factory ProvisionedDevice.fromJson(Map<String, dynamic> json) =>
      ProvisionedDevice(
        mac: json['mac'] as String,
        id: json['id'] as String,
        name: json['name'] as String,
        zone: json['zone'] as String,
        provisionedAt: json['provisionedAt'] is String
            ? DateTime.tryParse(json['provisionedAt'] as String)
            : null,
        model: json['model'] as String?,
        productCode: (json['productCode'] as num?)?.toInt(),
        fw: json['fw'] as String?,
      );
}

/// An installation code (blueprint §0): the SoftAP/mesh identity the
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
    this.formatVersion = currentFormatVersion,
  });

  /// JSON format of [toJson]. 1 = pre-lifecycle (no version field);
  /// 2 = lifecycle Phase 1 (optional `provisionedAt` per device).
  static const currentFormatVersion = 2;

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

  /// Devices this phone provisioned into this installation (work log).
  final List<ProvisionedDevice> devices;

  final int formatVersion;

  Installation copyWith({
    String? localId,
    String? displayName,
    List<String>? zones,
    List<ProvisionedDevice>? devices,
  }) =>
      Installation(
        localId: localId ?? this.localId,
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

  /// Full local record (secrets included). Never shown or exported in clear:
  /// backups go through `InstallationBackupCodec`.
  Map<String, dynamic> toJson() => {
        'v': currentFormatVersion,
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

  /// What another phone or the tablet receives when the installation is
  /// shared: the code, the name and the zones — never this phone's work log.
  Map<String, dynamic> toShareJson() => {
        'v': currentFormatVersion,
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
        'devices': const <Map<String, dynamic>>[],
      };

  /// Accepts both format 1 (no `v`) and 2.
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
        formatVersion: json['v'] is int ? json['v'] as int : 1,
      );
}
