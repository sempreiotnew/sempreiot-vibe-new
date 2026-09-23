// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $SerialPacketsTable extends SerialPackets
    with TableInfo<$SerialPacketsTable, SerialPacket> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SerialPacketsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _receivedAtMeta =
      const VerificationMeta('receivedAt');
  @override
  late final GeneratedColumn<DateTime> receivedAt = GeneratedColumn<DateTime>(
      'received_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _deviceIdMeta =
      const VerificationMeta('deviceId');
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
      'device_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _rawBytesMeta =
      const VerificationMeta('rawBytes');
  @override
  late final GeneratedColumn<Uint8List> rawBytes = GeneratedColumn<Uint8List>(
      'raw_bytes', aliasedName, false,
      type: DriftSqlType.blob, requiredDuringInsert: true);
  static const VerificationMeta _byteLengthMeta =
      const VerificationMeta('byteLength');
  @override
  late final GeneratedColumn<int> byteLength = GeneratedColumn<int>(
      'byte_length', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _hexPreviewMeta =
      const VerificationMeta('hexPreview');
  @override
  late final GeneratedColumn<String> hexPreview = GeneratedColumn<String>(
      'hex_preview', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, receivedAt, deviceId, rawBytes, byteLength, hexPreview];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'serial_packets';
  @override
  VerificationContext validateIntegrity(Insertable<SerialPacket> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('received_at')) {
      context.handle(
          _receivedAtMeta,
          receivedAt.isAcceptableOrUnknown(
              data['received_at']!, _receivedAtMeta));
    } else if (isInserting) {
      context.missing(_receivedAtMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(_deviceIdMeta,
          deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta));
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('raw_bytes')) {
      context.handle(_rawBytesMeta,
          rawBytes.isAcceptableOrUnknown(data['raw_bytes']!, _rawBytesMeta));
    } else if (isInserting) {
      context.missing(_rawBytesMeta);
    }
    if (data.containsKey('byte_length')) {
      context.handle(
          _byteLengthMeta,
          byteLength.isAcceptableOrUnknown(
              data['byte_length']!, _byteLengthMeta));
    } else if (isInserting) {
      context.missing(_byteLengthMeta);
    }
    if (data.containsKey('hex_preview')) {
      context.handle(
          _hexPreviewMeta,
          hexPreview.isAcceptableOrUnknown(
              data['hex_preview']!, _hexPreviewMeta));
    } else if (isInserting) {
      context.missing(_hexPreviewMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SerialPacket map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SerialPacket(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      receivedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}received_at'])!,
      deviceId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}device_id'])!,
      rawBytes: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}raw_bytes'])!,
      byteLength: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}byte_length'])!,
      hexPreview: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}hex_preview'])!,
    );
  }

  @override
  $SerialPacketsTable createAlias(String alias) {
    return $SerialPacketsTable(attachedDatabase, alias);
  }
}

class SerialPacket extends DataClass implements Insertable<SerialPacket> {
  final int id;
  final DateTime receivedAt;
  final String deviceId;
  final Uint8List rawBytes;
  final int byteLength;
  final String hexPreview;
  const SerialPacket(
      {required this.id,
      required this.receivedAt,
      required this.deviceId,
      required this.rawBytes,
      required this.byteLength,
      required this.hexPreview});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['received_at'] = Variable<DateTime>(receivedAt);
    map['device_id'] = Variable<String>(deviceId);
    map['raw_bytes'] = Variable<Uint8List>(rawBytes);
    map['byte_length'] = Variable<int>(byteLength);
    map['hex_preview'] = Variable<String>(hexPreview);
    return map;
  }

  SerialPacketsCompanion toCompanion(bool nullToAbsent) {
    return SerialPacketsCompanion(
      id: Value(id),
      receivedAt: Value(receivedAt),
      deviceId: Value(deviceId),
      rawBytes: Value(rawBytes),
      byteLength: Value(byteLength),
      hexPreview: Value(hexPreview),
    );
  }

  factory SerialPacket.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SerialPacket(
      id: serializer.fromJson<int>(json['id']),
      receivedAt: serializer.fromJson<DateTime>(json['receivedAt']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      rawBytes: serializer.fromJson<Uint8List>(json['rawBytes']),
      byteLength: serializer.fromJson<int>(json['byteLength']),
      hexPreview: serializer.fromJson<String>(json['hexPreview']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'receivedAt': serializer.toJson<DateTime>(receivedAt),
      'deviceId': serializer.toJson<String>(deviceId),
      'rawBytes': serializer.toJson<Uint8List>(rawBytes),
      'byteLength': serializer.toJson<int>(byteLength),
      'hexPreview': serializer.toJson<String>(hexPreview),
    };
  }

  SerialPacket copyWith(
          {int? id,
          DateTime? receivedAt,
          String? deviceId,
          Uint8List? rawBytes,
          int? byteLength,
          String? hexPreview}) =>
      SerialPacket(
        id: id ?? this.id,
        receivedAt: receivedAt ?? this.receivedAt,
        deviceId: deviceId ?? this.deviceId,
        rawBytes: rawBytes ?? this.rawBytes,
        byteLength: byteLength ?? this.byteLength,
        hexPreview: hexPreview ?? this.hexPreview,
      );
  SerialPacket copyWithCompanion(SerialPacketsCompanion data) {
    return SerialPacket(
      id: data.id.present ? data.id.value : this.id,
      receivedAt:
          data.receivedAt.present ? data.receivedAt.value : this.receivedAt,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      rawBytes: data.rawBytes.present ? data.rawBytes.value : this.rawBytes,
      byteLength:
          data.byteLength.present ? data.byteLength.value : this.byteLength,
      hexPreview:
          data.hexPreview.present ? data.hexPreview.value : this.hexPreview,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SerialPacket(')
          ..write('id: $id, ')
          ..write('receivedAt: $receivedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('rawBytes: $rawBytes, ')
          ..write('byteLength: $byteLength, ')
          ..write('hexPreview: $hexPreview')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, receivedAt, deviceId,
      $driftBlobEquality.hash(rawBytes), byteLength, hexPreview);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SerialPacket &&
          other.id == this.id &&
          other.receivedAt == this.receivedAt &&
          other.deviceId == this.deviceId &&
          $driftBlobEquality.equals(other.rawBytes, this.rawBytes) &&
          other.byteLength == this.byteLength &&
          other.hexPreview == this.hexPreview);
}

class SerialPacketsCompanion extends UpdateCompanion<SerialPacket> {
  final Value<int> id;
  final Value<DateTime> receivedAt;
  final Value<String> deviceId;
  final Value<Uint8List> rawBytes;
  final Value<int> byteLength;
  final Value<String> hexPreview;
  const SerialPacketsCompanion({
    this.id = const Value.absent(),
    this.receivedAt = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.rawBytes = const Value.absent(),
    this.byteLength = const Value.absent(),
    this.hexPreview = const Value.absent(),
  });
  SerialPacketsCompanion.insert({
    this.id = const Value.absent(),
    required DateTime receivedAt,
    required String deviceId,
    required Uint8List rawBytes,
    required int byteLength,
    required String hexPreview,
  })  : receivedAt = Value(receivedAt),
        deviceId = Value(deviceId),
        rawBytes = Value(rawBytes),
        byteLength = Value(byteLength),
        hexPreview = Value(hexPreview);
  static Insertable<SerialPacket> custom({
    Expression<int>? id,
    Expression<DateTime>? receivedAt,
    Expression<String>? deviceId,
    Expression<Uint8List>? rawBytes,
    Expression<int>? byteLength,
    Expression<String>? hexPreview,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (receivedAt != null) 'received_at': receivedAt,
      if (deviceId != null) 'device_id': deviceId,
      if (rawBytes != null) 'raw_bytes': rawBytes,
      if (byteLength != null) 'byte_length': byteLength,
      if (hexPreview != null) 'hex_preview': hexPreview,
    });
  }

  SerialPacketsCompanion copyWith(
      {Value<int>? id,
      Value<DateTime>? receivedAt,
      Value<String>? deviceId,
      Value<Uint8List>? rawBytes,
      Value<int>? byteLength,
      Value<String>? hexPreview}) {
    return SerialPacketsCompanion(
      id: id ?? this.id,
      receivedAt: receivedAt ?? this.receivedAt,
      deviceId: deviceId ?? this.deviceId,
      rawBytes: rawBytes ?? this.rawBytes,
      byteLength: byteLength ?? this.byteLength,
      hexPreview: hexPreview ?? this.hexPreview,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (receivedAt.present) {
      map['received_at'] = Variable<DateTime>(receivedAt.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (rawBytes.present) {
      map['raw_bytes'] = Variable<Uint8List>(rawBytes.value);
    }
    if (byteLength.present) {
      map['byte_length'] = Variable<int>(byteLength.value);
    }
    if (hexPreview.present) {
      map['hex_preview'] = Variable<String>(hexPreview.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SerialPacketsCompanion(')
          ..write('id: $id, ')
          ..write('receivedAt: $receivedAt, ')
          ..write('deviceId: $deviceId, ')
          ..write('rawBytes: $rawBytes, ')
          ..write('byteLength: $byteLength, ')
          ..write('hexPreview: $hexPreview')
          ..write(')'))
        .toString();
  }
}

class $DeviceMetadataTable extends DeviceMetadata
    with TableInfo<$DeviceMetadataTable, DeviceMetadataData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DeviceMetadataTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
      'value', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'device_metadata';
  @override
  VerificationContext validateIntegrity(Insertable<DeviceMetadataData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
          _valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  DeviceMetadataData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DeviceMetadataData(
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      value: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}value'])!,
    );
  }

  @override
  $DeviceMetadataTable createAlias(String alias) {
    return $DeviceMetadataTable(attachedDatabase, alias);
  }
}

class DeviceMetadataData extends DataClass
    implements Insertable<DeviceMetadataData> {
  final String key;
  final String value;
  const DeviceMetadataData({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  DeviceMetadataCompanion toCompanion(bool nullToAbsent) {
    return DeviceMetadataCompanion(
      key: Value(key),
      value: Value(value),
    );
  }

  factory DeviceMetadataData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DeviceMetadataData(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  DeviceMetadataData copyWith({String? key, String? value}) =>
      DeviceMetadataData(
        key: key ?? this.key,
        value: value ?? this.value,
      );
  DeviceMetadataData copyWithCompanion(DeviceMetadataCompanion data) {
    return DeviceMetadataData(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DeviceMetadataData(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DeviceMetadataData &&
          other.key == this.key &&
          other.value == this.value);
}

class DeviceMetadataCompanion extends UpdateCompanion<DeviceMetadataData> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const DeviceMetadataCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DeviceMetadataCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  })  : key = Value(key),
        value = Value(value);
  static Insertable<DeviceMetadataData> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DeviceMetadataCompanion copyWith(
      {Value<String>? key, Value<String>? value, Value<int>? rowid}) {
    return DeviceMetadataCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DeviceMetadataCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AuditEventsTable extends AuditEvents
    with TableInfo<$AuditEventsTable, AuditEvent> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AuditEventsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _atMeta = const VerificationMeta('at');
  @override
  late final GeneratedColumn<DateTime> at = GeneratedColumn<DateTime>(
      'at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _actorMeta = const VerificationMeta('actor');
  @override
  late final GeneratedColumn<String> actor = GeneratedColumn<String>(
      'actor', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _actionMeta = const VerificationMeta('action');
  @override
  late final GeneratedColumn<String> action = GeneratedColumn<String>(
      'action', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _detailMeta = const VerificationMeta('detail');
  @override
  late final GeneratedColumn<String> detail = GeneratedColumn<String>(
      'detail', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, at, actor, action, detail];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'audit_events';
  @override
  VerificationContext validateIntegrity(Insertable<AuditEvent> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('at')) {
      context.handle(_atMeta, at.isAcceptableOrUnknown(data['at']!, _atMeta));
    } else if (isInserting) {
      context.missing(_atMeta);
    }
    if (data.containsKey('actor')) {
      context.handle(
          _actorMeta, actor.isAcceptableOrUnknown(data['actor']!, _actorMeta));
    } else if (isInserting) {
      context.missing(_actorMeta);
    }
    if (data.containsKey('action')) {
      context.handle(_actionMeta,
          action.isAcceptableOrUnknown(data['action']!, _actionMeta));
    } else if (isInserting) {
      context.missing(_actionMeta);
    }
    if (data.containsKey('detail')) {
      context.handle(_detailMeta,
          detail.isAcceptableOrUnknown(data['detail']!, _detailMeta));
    } else if (isInserting) {
      context.missing(_detailMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AuditEvent map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AuditEvent(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      at: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}at'])!,
      actor: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}actor'])!,
      action: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}action'])!,
      detail: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}detail'])!,
    );
  }

  @override
  $AuditEventsTable createAlias(String alias) {
    return $AuditEventsTable(attachedDatabase, alias);
  }
}

class AuditEvent extends DataClass implements Insertable<AuditEvent> {
  final int id;
  final DateTime at;
  final String actor;
  final String action;
  final String detail;
  const AuditEvent(
      {required this.id,
      required this.at,
      required this.actor,
      required this.action,
      required this.detail});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['at'] = Variable<DateTime>(at);
    map['actor'] = Variable<String>(actor);
    map['action'] = Variable<String>(action);
    map['detail'] = Variable<String>(detail);
    return map;
  }

  AuditEventsCompanion toCompanion(bool nullToAbsent) {
    return AuditEventsCompanion(
      id: Value(id),
      at: Value(at),
      actor: Value(actor),
      action: Value(action),
      detail: Value(detail),
    );
  }

  factory AuditEvent.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AuditEvent(
      id: serializer.fromJson<int>(json['id']),
      at: serializer.fromJson<DateTime>(json['at']),
      actor: serializer.fromJson<String>(json['actor']),
      action: serializer.fromJson<String>(json['action']),
      detail: serializer.fromJson<String>(json['detail']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'at': serializer.toJson<DateTime>(at),
      'actor': serializer.toJson<String>(actor),
      'action': serializer.toJson<String>(action),
      'detail': serializer.toJson<String>(detail),
    };
  }

  AuditEvent copyWith(
          {int? id,
          DateTime? at,
          String? actor,
          String? action,
          String? detail}) =>
      AuditEvent(
        id: id ?? this.id,
        at: at ?? this.at,
        actor: actor ?? this.actor,
        action: action ?? this.action,
        detail: detail ?? this.detail,
      );
  AuditEvent copyWithCompanion(AuditEventsCompanion data) {
    return AuditEvent(
      id: data.id.present ? data.id.value : this.id,
      at: data.at.present ? data.at.value : this.at,
      actor: data.actor.present ? data.actor.value : this.actor,
      action: data.action.present ? data.action.value : this.action,
      detail: data.detail.present ? data.detail.value : this.detail,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AuditEvent(')
          ..write('id: $id, ')
          ..write('at: $at, ')
          ..write('actor: $actor, ')
          ..write('action: $action, ')
          ..write('detail: $detail')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, at, actor, action, detail);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AuditEvent &&
          other.id == this.id &&
          other.at == this.at &&
          other.actor == this.actor &&
          other.action == this.action &&
          other.detail == this.detail);
}

class AuditEventsCompanion extends UpdateCompanion<AuditEvent> {
  final Value<int> id;
  final Value<DateTime> at;
  final Value<String> actor;
  final Value<String> action;
  final Value<String> detail;
  const AuditEventsCompanion({
    this.id = const Value.absent(),
    this.at = const Value.absent(),
    this.actor = const Value.absent(),
    this.action = const Value.absent(),
    this.detail = const Value.absent(),
  });
  AuditEventsCompanion.insert({
    this.id = const Value.absent(),
    required DateTime at,
    required String actor,
    required String action,
    required String detail,
  })  : at = Value(at),
        actor = Value(actor),
        action = Value(action),
        detail = Value(detail);
  static Insertable<AuditEvent> custom({
    Expression<int>? id,
    Expression<DateTime>? at,
    Expression<String>? actor,
    Expression<String>? action,
    Expression<String>? detail,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (at != null) 'at': at,
      if (actor != null) 'actor': actor,
      if (action != null) 'action': action,
      if (detail != null) 'detail': detail,
    });
  }

  AuditEventsCompanion copyWith(
      {Value<int>? id,
      Value<DateTime>? at,
      Value<String>? actor,
      Value<String>? action,
      Value<String>? detail}) {
    return AuditEventsCompanion(
      id: id ?? this.id,
      at: at ?? this.at,
      actor: actor ?? this.actor,
      action: action ?? this.action,
      detail: detail ?? this.detail,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (at.present) {
      map['at'] = Variable<DateTime>(at.value);
    }
    if (actor.present) {
      map['actor'] = Variable<String>(actor.value);
    }
    if (action.present) {
      map['action'] = Variable<String>(action.value);
    }
    if (detail.present) {
      map['detail'] = Variable<String>(detail.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AuditEventsCompanion(')
          ..write('id: $id, ')
          ..write('at: $at, ')
          ..write('actor: $actor, ')
          ..write('action: $action, ')
          ..write('detail: $detail')
          ..write(')'))
        .toString();
  }
}

class $MeshDevicesTable extends MeshDevices
    with TableInfo<$MeshDevicesTable, MeshDevice> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MeshDevicesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _macMeta = const VerificationMeta('mac');
  @override
  late final GeneratedColumn<String> mac = GeneratedColumn<String>(
      'mac', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<int> role = GeneratedColumn<int>(
      'role', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(255));
  static const VerificationMeta _layerMeta = const VerificationMeta('layer');
  @override
  late final GeneratedColumn<int> layer = GeneratedColumn<int>(
      'layer', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _parentMacMeta =
      const VerificationMeta('parentMac');
  @override
  late final GeneratedColumn<String> parentMac = GeneratedColumn<String>(
      'parent_mac', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _lastRssiMeta =
      const VerificationMeta('lastRssi');
  @override
  late final GeneratedColumn<int> lastRssi = GeneratedColumn<int>(
      'last_rssi', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _batteryPctMeta =
      const VerificationMeta('batteryPct');
  @override
  late final GeneratedColumn<int> batteryPct = GeneratedColumn<int>(
      'battery_pct', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _firstSeenAtMeta =
      const VerificationMeta('firstSeenAt');
  @override
  late final GeneratedColumn<DateTime> firstSeenAt = GeneratedColumn<DateTime>(
      'first_seen_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _lastSeenAtMeta =
      const VerificationMeta('lastSeenAt');
  @override
  late final GeneratedColumn<DateTime> lastSeenAt = GeneratedColumn<DateTime>(
      'last_seen_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _lastHeartbeatAtMeta =
      const VerificationMeta('lastHeartbeatAt');
  @override
  late final GeneratedColumn<DateTime> lastHeartbeatAt =
      GeneratedColumn<DateTime>('last_heartbeat_at', aliasedName, true,
          type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _lastBootCtrMeta =
      const VerificationMeta('lastBootCtr');
  @override
  late final GeneratedColumn<int> lastBootCtr = GeneratedColumn<int>(
      'last_boot_ctr', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastMsgCtrMeta =
      const VerificationMeta('lastMsgCtr');
  @override
  late final GeneratedColumn<int> lastMsgCtr = GeneratedColumn<int>(
      'last_msg_ctr', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _supervisionStateMeta =
      const VerificationMeta('supervisionState');
  @override
  late final GeneratedColumn<int> supervisionState = GeneratedColumn<int>(
      'supervision_state', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _zoneMeta = const VerificationMeta('zone');
  @override
  late final GeneratedColumn<String> zone = GeneratedColumn<String>(
      'zone', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _registryStateMeta =
      const VerificationMeta('registryState');
  @override
  late final GeneratedColumn<String> registryState = GeneratedColumn<String>(
      'registry_state', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _lastDevSeqMeta =
      const VerificationMeta('lastDevSeq');
  @override
  late final GeneratedColumn<int> lastDevSeq = GeneratedColumn<int>(
      'last_dev_seq', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _alarmLatchedMeta =
      const VerificationMeta('alarmLatched');
  @override
  late final GeneratedColumn<int> alarmLatched = GeneratedColumn<int>(
      'alarm_latched', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _alarmLatchedAtMeta =
      const VerificationMeta('alarmLatchedAt');
  @override
  late final GeneratedColumn<DateTime> alarmLatchedAt =
      GeneratedColumn<DateTime>('alarm_latched_at', aliasedName, true,
          type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        mac,
        role,
        layer,
        parentMac,
        lastRssi,
        batteryPct,
        firstSeenAt,
        lastSeenAt,
        lastHeartbeatAt,
        lastBootCtr,
        lastMsgCtr,
        supervisionState,
        name,
        zone,
        registryState,
        lastDevSeq,
        alarmLatched,
        alarmLatchedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'mesh_devices';
  @override
  VerificationContext validateIntegrity(Insertable<MeshDevice> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('mac')) {
      context.handle(
          _macMeta, mac.isAcceptableOrUnknown(data['mac']!, _macMeta));
    } else if (isInserting) {
      context.missing(_macMeta);
    }
    if (data.containsKey('role')) {
      context.handle(
          _roleMeta, role.isAcceptableOrUnknown(data['role']!, _roleMeta));
    }
    if (data.containsKey('layer')) {
      context.handle(
          _layerMeta, layer.isAcceptableOrUnknown(data['layer']!, _layerMeta));
    }
    if (data.containsKey('parent_mac')) {
      context.handle(_parentMacMeta,
          parentMac.isAcceptableOrUnknown(data['parent_mac']!, _parentMacMeta));
    }
    if (data.containsKey('last_rssi')) {
      context.handle(_lastRssiMeta,
          lastRssi.isAcceptableOrUnknown(data['last_rssi']!, _lastRssiMeta));
    }
    if (data.containsKey('battery_pct')) {
      context.handle(
          _batteryPctMeta,
          batteryPct.isAcceptableOrUnknown(
              data['battery_pct']!, _batteryPctMeta));
    }
    if (data.containsKey('first_seen_at')) {
      context.handle(
          _firstSeenAtMeta,
          firstSeenAt.isAcceptableOrUnknown(
              data['first_seen_at']!, _firstSeenAtMeta));
    } else if (isInserting) {
      context.missing(_firstSeenAtMeta);
    }
    if (data.containsKey('last_seen_at')) {
      context.handle(
          _lastSeenAtMeta,
          lastSeenAt.isAcceptableOrUnknown(
              data['last_seen_at']!, _lastSeenAtMeta));
    } else if (isInserting) {
      context.missing(_lastSeenAtMeta);
    }
    if (data.containsKey('last_heartbeat_at')) {
      context.handle(
          _lastHeartbeatAtMeta,
          lastHeartbeatAt.isAcceptableOrUnknown(
              data['last_heartbeat_at']!, _lastHeartbeatAtMeta));
    }
    if (data.containsKey('last_boot_ctr')) {
      context.handle(
          _lastBootCtrMeta,
          lastBootCtr.isAcceptableOrUnknown(
              data['last_boot_ctr']!, _lastBootCtrMeta));
    }
    if (data.containsKey('last_msg_ctr')) {
      context.handle(
          _lastMsgCtrMeta,
          lastMsgCtr.isAcceptableOrUnknown(
              data['last_msg_ctr']!, _lastMsgCtrMeta));
    }
    if (data.containsKey('supervision_state')) {
      context.handle(
          _supervisionStateMeta,
          supervisionState.isAcceptableOrUnknown(
              data['supervision_state']!, _supervisionStateMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    }
    if (data.containsKey('zone')) {
      context.handle(
          _zoneMeta, zone.isAcceptableOrUnknown(data['zone']!, _zoneMeta));
    }
    if (data.containsKey('registry_state')) {
      context.handle(
          _registryStateMeta,
          registryState.isAcceptableOrUnknown(
              data['registry_state']!, _registryStateMeta));
    }
    if (data.containsKey('last_dev_seq')) {
      context.handle(
          _lastDevSeqMeta,
          lastDevSeq.isAcceptableOrUnknown(
              data['last_dev_seq']!, _lastDevSeqMeta));
    }
    if (data.containsKey('alarm_latched')) {
      context.handle(
          _alarmLatchedMeta,
          alarmLatched.isAcceptableOrUnknown(
              data['alarm_latched']!, _alarmLatchedMeta));
    }
    if (data.containsKey('alarm_latched_at')) {
      context.handle(
          _alarmLatchedAtMeta,
          alarmLatchedAt.isAcceptableOrUnknown(
              data['alarm_latched_at']!, _alarmLatchedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {mac};
  @override
  MeshDevice map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MeshDevice(
      mac: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}mac'])!,
      role: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}role'])!,
      layer: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}layer'])!,
      parentMac: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}parent_mac']),
      lastRssi: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_rssi']),
      batteryPct: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}battery_pct']),
      firstSeenAt: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime, data['${effectivePrefix}first_seen_at'])!,
      lastSeenAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}last_seen_at'])!,
      lastHeartbeatAt: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime, data['${effectivePrefix}last_heartbeat_at']),
      lastBootCtr: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_boot_ctr'])!,
      lastMsgCtr: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_msg_ctr'])!,
      supervisionState: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}supervision_state'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name']),
      zone: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}zone']),
      registryState: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}registry_state']),
      lastDevSeq: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_dev_seq'])!,
      alarmLatched: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}alarm_latched'])!,
      alarmLatchedAt: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime, data['${effectivePrefix}alarm_latched_at']),
    );
  }

  @override
  $MeshDevicesTable createAlias(String alias) {
    return $MeshDevicesTable(attachedDatabase, alias);
  }
}

class MeshDevice extends DataClass implements Insertable<MeshDevice> {
  final String mac;
  final int role;
  final int layer;
  final String? parentMac;
  final int? lastRssi;
  final int? batteryPct;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final DateTime? lastHeartbeatAt;
  final int lastBootCtr;
  final int lastMsgCtr;
  final int supervisionState;
  final String? name;
  final String? zone;
  final String? registryState;
  final int lastDevSeq;
  final int alarmLatched;
  final DateTime? alarmLatchedAt;
  const MeshDevice(
      {required this.mac,
      required this.role,
      required this.layer,
      this.parentMac,
      this.lastRssi,
      this.batteryPct,
      required this.firstSeenAt,
      required this.lastSeenAt,
      this.lastHeartbeatAt,
      required this.lastBootCtr,
      required this.lastMsgCtr,
      required this.supervisionState,
      this.name,
      this.zone,
      this.registryState,
      required this.lastDevSeq,
      required this.alarmLatched,
      this.alarmLatchedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['mac'] = Variable<String>(mac);
    map['role'] = Variable<int>(role);
    map['layer'] = Variable<int>(layer);
    if (!nullToAbsent || parentMac != null) {
      map['parent_mac'] = Variable<String>(parentMac);
    }
    if (!nullToAbsent || lastRssi != null) {
      map['last_rssi'] = Variable<int>(lastRssi);
    }
    if (!nullToAbsent || batteryPct != null) {
      map['battery_pct'] = Variable<int>(batteryPct);
    }
    map['first_seen_at'] = Variable<DateTime>(firstSeenAt);
    map['last_seen_at'] = Variable<DateTime>(lastSeenAt);
    if (!nullToAbsent || lastHeartbeatAt != null) {
      map['last_heartbeat_at'] = Variable<DateTime>(lastHeartbeatAt);
    }
    map['last_boot_ctr'] = Variable<int>(lastBootCtr);
    map['last_msg_ctr'] = Variable<int>(lastMsgCtr);
    map['supervision_state'] = Variable<int>(supervisionState);
    if (!nullToAbsent || name != null) {
      map['name'] = Variable<String>(name);
    }
    if (!nullToAbsent || zone != null) {
      map['zone'] = Variable<String>(zone);
    }
    if (!nullToAbsent || registryState != null) {
      map['registry_state'] = Variable<String>(registryState);
    }
    map['last_dev_seq'] = Variable<int>(lastDevSeq);
    map['alarm_latched'] = Variable<int>(alarmLatched);
    if (!nullToAbsent || alarmLatchedAt != null) {
      map['alarm_latched_at'] = Variable<DateTime>(alarmLatchedAt);
    }
    return map;
  }

  MeshDevicesCompanion toCompanion(bool nullToAbsent) {
    return MeshDevicesCompanion(
      mac: Value(mac),
      role: Value(role),
      layer: Value(layer),
      parentMac: parentMac == null && nullToAbsent
          ? const Value.absent()
          : Value(parentMac),
      lastRssi: lastRssi == null && nullToAbsent
          ? const Value.absent()
          : Value(lastRssi),
      batteryPct: batteryPct == null && nullToAbsent
          ? const Value.absent()
          : Value(batteryPct),
      firstSeenAt: Value(firstSeenAt),
      lastSeenAt: Value(lastSeenAt),
      lastHeartbeatAt: lastHeartbeatAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastHeartbeatAt),
      lastBootCtr: Value(lastBootCtr),
      lastMsgCtr: Value(lastMsgCtr),
      supervisionState: Value(supervisionState),
      name: name == null && nullToAbsent ? const Value.absent() : Value(name),
      zone: zone == null && nullToAbsent ? const Value.absent() : Value(zone),
      registryState: registryState == null && nullToAbsent
          ? const Value.absent()
          : Value(registryState),
      lastDevSeq: Value(lastDevSeq),
      alarmLatched: Value(alarmLatched),
      alarmLatchedAt: alarmLatchedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(alarmLatchedAt),
    );
  }

  factory MeshDevice.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MeshDevice(
      mac: serializer.fromJson<String>(json['mac']),
      role: serializer.fromJson<int>(json['role']),
      layer: serializer.fromJson<int>(json['layer']),
      parentMac: serializer.fromJson<String?>(json['parentMac']),
      lastRssi: serializer.fromJson<int?>(json['lastRssi']),
      batteryPct: serializer.fromJson<int?>(json['batteryPct']),
      firstSeenAt: serializer.fromJson<DateTime>(json['firstSeenAt']),
      lastSeenAt: serializer.fromJson<DateTime>(json['lastSeenAt']),
      lastHeartbeatAt: serializer.fromJson<DateTime?>(json['lastHeartbeatAt']),
      lastBootCtr: serializer.fromJson<int>(json['lastBootCtr']),
      lastMsgCtr: serializer.fromJson<int>(json['lastMsgCtr']),
      supervisionState: serializer.fromJson<int>(json['supervisionState']),
      name: serializer.fromJson<String?>(json['name']),
      zone: serializer.fromJson<String?>(json['zone']),
      registryState: serializer.fromJson<String?>(json['registryState']),
      lastDevSeq: serializer.fromJson<int>(json['lastDevSeq']),
      alarmLatched: serializer.fromJson<int>(json['alarmLatched']),
      alarmLatchedAt: serializer.fromJson<DateTime?>(json['alarmLatchedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'mac': serializer.toJson<String>(mac),
      'role': serializer.toJson<int>(role),
      'layer': serializer.toJson<int>(layer),
      'parentMac': serializer.toJson<String?>(parentMac),
      'lastRssi': serializer.toJson<int?>(lastRssi),
      'batteryPct': serializer.toJson<int?>(batteryPct),
      'firstSeenAt': serializer.toJson<DateTime>(firstSeenAt),
      'lastSeenAt': serializer.toJson<DateTime>(lastSeenAt),
      'lastHeartbeatAt': serializer.toJson<DateTime?>(lastHeartbeatAt),
      'lastBootCtr': serializer.toJson<int>(lastBootCtr),
      'lastMsgCtr': serializer.toJson<int>(lastMsgCtr),
      'supervisionState': serializer.toJson<int>(supervisionState),
      'name': serializer.toJson<String?>(name),
      'zone': serializer.toJson<String?>(zone),
      'registryState': serializer.toJson<String?>(registryState),
      'lastDevSeq': serializer.toJson<int>(lastDevSeq),
      'alarmLatched': serializer.toJson<int>(alarmLatched),
      'alarmLatchedAt': serializer.toJson<DateTime?>(alarmLatchedAt),
    };
  }

  MeshDevice copyWith(
          {String? mac,
          int? role,
          int? layer,
          Value<String?> parentMac = const Value.absent(),
          Value<int?> lastRssi = const Value.absent(),
          Value<int?> batteryPct = const Value.absent(),
          DateTime? firstSeenAt,
          DateTime? lastSeenAt,
          Value<DateTime?> lastHeartbeatAt = const Value.absent(),
          int? lastBootCtr,
          int? lastMsgCtr,
          int? supervisionState,
          Value<String?> name = const Value.absent(),
          Value<String?> zone = const Value.absent(),
          Value<String?> registryState = const Value.absent(),
          int? lastDevSeq,
          int? alarmLatched,
          Value<DateTime?> alarmLatchedAt = const Value.absent()}) =>
      MeshDevice(
        mac: mac ?? this.mac,
        role: role ?? this.role,
        layer: layer ?? this.layer,
        parentMac: parentMac.present ? parentMac.value : this.parentMac,
        lastRssi: lastRssi.present ? lastRssi.value : this.lastRssi,
        batteryPct: batteryPct.present ? batteryPct.value : this.batteryPct,
        firstSeenAt: firstSeenAt ?? this.firstSeenAt,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        lastHeartbeatAt: lastHeartbeatAt.present
            ? lastHeartbeatAt.value
            : this.lastHeartbeatAt,
        lastBootCtr: lastBootCtr ?? this.lastBootCtr,
        lastMsgCtr: lastMsgCtr ?? this.lastMsgCtr,
        supervisionState: supervisionState ?? this.supervisionState,
        name: name.present ? name.value : this.name,
        zone: zone.present ? zone.value : this.zone,
        registryState:
            registryState.present ? registryState.value : this.registryState,
        lastDevSeq: lastDevSeq ?? this.lastDevSeq,
        alarmLatched: alarmLatched ?? this.alarmLatched,
        alarmLatchedAt:
            alarmLatchedAt.present ? alarmLatchedAt.value : this.alarmLatchedAt,
      );
  MeshDevice copyWithCompanion(MeshDevicesCompanion data) {
    return MeshDevice(
      mac: data.mac.present ? data.mac.value : this.mac,
      role: data.role.present ? data.role.value : this.role,
      layer: data.layer.present ? data.layer.value : this.layer,
      parentMac: data.parentMac.present ? data.parentMac.value : this.parentMac,
      lastRssi: data.lastRssi.present ? data.lastRssi.value : this.lastRssi,
      batteryPct:
          data.batteryPct.present ? data.batteryPct.value : this.batteryPct,
      firstSeenAt:
          data.firstSeenAt.present ? data.firstSeenAt.value : this.firstSeenAt,
      lastSeenAt:
          data.lastSeenAt.present ? data.lastSeenAt.value : this.lastSeenAt,
      lastHeartbeatAt: data.lastHeartbeatAt.present
          ? data.lastHeartbeatAt.value
          : this.lastHeartbeatAt,
      lastBootCtr:
          data.lastBootCtr.present ? data.lastBootCtr.value : this.lastBootCtr,
      lastMsgCtr:
          data.lastMsgCtr.present ? data.lastMsgCtr.value : this.lastMsgCtr,
      supervisionState: data.supervisionState.present
          ? data.supervisionState.value
          : this.supervisionState,
      name: data.name.present ? data.name.value : this.name,
      zone: data.zone.present ? data.zone.value : this.zone,
      registryState: data.registryState.present
          ? data.registryState.value
          : this.registryState,
      lastDevSeq:
          data.lastDevSeq.present ? data.lastDevSeq.value : this.lastDevSeq,
      alarmLatched: data.alarmLatched.present
          ? data.alarmLatched.value
          : this.alarmLatched,
      alarmLatchedAt: data.alarmLatchedAt.present
          ? data.alarmLatchedAt.value
          : this.alarmLatchedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MeshDevice(')
          ..write('mac: $mac, ')
          ..write('role: $role, ')
          ..write('layer: $layer, ')
          ..write('parentMac: $parentMac, ')
          ..write('lastRssi: $lastRssi, ')
          ..write('batteryPct: $batteryPct, ')
          ..write('firstSeenAt: $firstSeenAt, ')
          ..write('lastSeenAt: $lastSeenAt, ')
          ..write('lastHeartbeatAt: $lastHeartbeatAt, ')
          ..write('lastBootCtr: $lastBootCtr, ')
          ..write('lastMsgCtr: $lastMsgCtr, ')
          ..write('supervisionState: $supervisionState, ')
          ..write('name: $name, ')
          ..write('zone: $zone, ')
          ..write('registryState: $registryState, ')
          ..write('lastDevSeq: $lastDevSeq, ')
          ..write('alarmLatched: $alarmLatched, ')
          ..write('alarmLatchedAt: $alarmLatchedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      mac,
      role,
      layer,
      parentMac,
      lastRssi,
      batteryPct,
      firstSeenAt,
      lastSeenAt,
      lastHeartbeatAt,
      lastBootCtr,
      lastMsgCtr,
      supervisionState,
      name,
      zone,
      registryState,
      lastDevSeq,
      alarmLatched,
      alarmLatchedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MeshDevice &&
          other.mac == this.mac &&
          other.role == this.role &&
          other.layer == this.layer &&
          other.parentMac == this.parentMac &&
          other.lastRssi == this.lastRssi &&
          other.batteryPct == this.batteryPct &&
          other.firstSeenAt == this.firstSeenAt &&
          other.lastSeenAt == this.lastSeenAt &&
          other.lastHeartbeatAt == this.lastHeartbeatAt &&
          other.lastBootCtr == this.lastBootCtr &&
          other.lastMsgCtr == this.lastMsgCtr &&
          other.supervisionState == this.supervisionState &&
          other.name == this.name &&
          other.zone == this.zone &&
          other.registryState == this.registryState &&
          other.lastDevSeq == this.lastDevSeq &&
          other.alarmLatched == this.alarmLatched &&
          other.alarmLatchedAt == this.alarmLatchedAt);
}

class MeshDevicesCompanion extends UpdateCompanion<MeshDevice> {
  final Value<String> mac;
  final Value<int> role;
  final Value<int> layer;
  final Value<String?> parentMac;
  final Value<int?> lastRssi;
  final Value<int?> batteryPct;
  final Value<DateTime> firstSeenAt;
  final Value<DateTime> lastSeenAt;
  final Value<DateTime?> lastHeartbeatAt;
  final Value<int> lastBootCtr;
  final Value<int> lastMsgCtr;
  final Value<int> supervisionState;
  final Value<String?> name;
  final Value<String?> zone;
  final Value<String?> registryState;
  final Value<int> lastDevSeq;
  final Value<int> alarmLatched;
  final Value<DateTime?> alarmLatchedAt;
  final Value<int> rowid;
  const MeshDevicesCompanion({
    this.mac = const Value.absent(),
    this.role = const Value.absent(),
    this.layer = const Value.absent(),
    this.parentMac = const Value.absent(),
    this.lastRssi = const Value.absent(),
    this.batteryPct = const Value.absent(),
    this.firstSeenAt = const Value.absent(),
    this.lastSeenAt = const Value.absent(),
    this.lastHeartbeatAt = const Value.absent(),
    this.lastBootCtr = const Value.absent(),
    this.lastMsgCtr = const Value.absent(),
    this.supervisionState = const Value.absent(),
    this.name = const Value.absent(),
    this.zone = const Value.absent(),
    this.registryState = const Value.absent(),
    this.lastDevSeq = const Value.absent(),
    this.alarmLatched = const Value.absent(),
    this.alarmLatchedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MeshDevicesCompanion.insert({
    required String mac,
    this.role = const Value.absent(),
    this.layer = const Value.absent(),
    this.parentMac = const Value.absent(),
    this.lastRssi = const Value.absent(),
    this.batteryPct = const Value.absent(),
    required DateTime firstSeenAt,
    required DateTime lastSeenAt,
    this.lastHeartbeatAt = const Value.absent(),
    this.lastBootCtr = const Value.absent(),
    this.lastMsgCtr = const Value.absent(),
    this.supervisionState = const Value.absent(),
    this.name = const Value.absent(),
    this.zone = const Value.absent(),
    this.registryState = const Value.absent(),
    this.lastDevSeq = const Value.absent(),
    this.alarmLatched = const Value.absent(),
    this.alarmLatchedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : mac = Value(mac),
        firstSeenAt = Value(firstSeenAt),
        lastSeenAt = Value(lastSeenAt);
  static Insertable<MeshDevice> custom({
    Expression<String>? mac,
    Expression<int>? role,
    Expression<int>? layer,
    Expression<String>? parentMac,
    Expression<int>? lastRssi,
    Expression<int>? batteryPct,
    Expression<DateTime>? firstSeenAt,
    Expression<DateTime>? lastSeenAt,
    Expression<DateTime>? lastHeartbeatAt,
    Expression<int>? lastBootCtr,
    Expression<int>? lastMsgCtr,
    Expression<int>? supervisionState,
    Expression<String>? name,
    Expression<String>? zone,
    Expression<String>? registryState,
    Expression<int>? lastDevSeq,
    Expression<int>? alarmLatched,
    Expression<DateTime>? alarmLatchedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (mac != null) 'mac': mac,
      if (role != null) 'role': role,
      if (layer != null) 'layer': layer,
      if (parentMac != null) 'parent_mac': parentMac,
      if (lastRssi != null) 'last_rssi': lastRssi,
      if (batteryPct != null) 'battery_pct': batteryPct,
      if (firstSeenAt != null) 'first_seen_at': firstSeenAt,
      if (lastSeenAt != null) 'last_seen_at': lastSeenAt,
      if (lastHeartbeatAt != null) 'last_heartbeat_at': lastHeartbeatAt,
      if (lastBootCtr != null) 'last_boot_ctr': lastBootCtr,
      if (lastMsgCtr != null) 'last_msg_ctr': lastMsgCtr,
      if (supervisionState != null) 'supervision_state': supervisionState,
      if (name != null) 'name': name,
      if (zone != null) 'zone': zone,
      if (registryState != null) 'registry_state': registryState,
      if (lastDevSeq != null) 'last_dev_seq': lastDevSeq,
      if (alarmLatched != null) 'alarm_latched': alarmLatched,
      if (alarmLatchedAt != null) 'alarm_latched_at': alarmLatchedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MeshDevicesCompanion copyWith(
      {Value<String>? mac,
      Value<int>? role,
      Value<int>? layer,
      Value<String?>? parentMac,
      Value<int?>? lastRssi,
      Value<int?>? batteryPct,
      Value<DateTime>? firstSeenAt,
      Value<DateTime>? lastSeenAt,
      Value<DateTime?>? lastHeartbeatAt,
      Value<int>? lastBootCtr,
      Value<int>? lastMsgCtr,
      Value<int>? supervisionState,
      Value<String?>? name,
      Value<String?>? zone,
      Value<String?>? registryState,
      Value<int>? lastDevSeq,
      Value<int>? alarmLatched,
      Value<DateTime?>? alarmLatchedAt,
      Value<int>? rowid}) {
    return MeshDevicesCompanion(
      mac: mac ?? this.mac,
      role: role ?? this.role,
      layer: layer ?? this.layer,
      parentMac: parentMac ?? this.parentMac,
      lastRssi: lastRssi ?? this.lastRssi,
      batteryPct: batteryPct ?? this.batteryPct,
      firstSeenAt: firstSeenAt ?? this.firstSeenAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      lastHeartbeatAt: lastHeartbeatAt ?? this.lastHeartbeatAt,
      lastBootCtr: lastBootCtr ?? this.lastBootCtr,
      lastMsgCtr: lastMsgCtr ?? this.lastMsgCtr,
      supervisionState: supervisionState ?? this.supervisionState,
      name: name ?? this.name,
      zone: zone ?? this.zone,
      registryState: registryState ?? this.registryState,
      lastDevSeq: lastDevSeq ?? this.lastDevSeq,
      alarmLatched: alarmLatched ?? this.alarmLatched,
      alarmLatchedAt: alarmLatchedAt ?? this.alarmLatchedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (mac.present) {
      map['mac'] = Variable<String>(mac.value);
    }
    if (role.present) {
      map['role'] = Variable<int>(role.value);
    }
    if (layer.present) {
      map['layer'] = Variable<int>(layer.value);
    }
    if (parentMac.present) {
      map['parent_mac'] = Variable<String>(parentMac.value);
    }
    if (lastRssi.present) {
      map['last_rssi'] = Variable<int>(lastRssi.value);
    }
    if (batteryPct.present) {
      map['battery_pct'] = Variable<int>(batteryPct.value);
    }
    if (firstSeenAt.present) {
      map['first_seen_at'] = Variable<DateTime>(firstSeenAt.value);
    }
    if (lastSeenAt.present) {
      map['last_seen_at'] = Variable<DateTime>(lastSeenAt.value);
    }
    if (lastHeartbeatAt.present) {
      map['last_heartbeat_at'] = Variable<DateTime>(lastHeartbeatAt.value);
    }
    if (lastBootCtr.present) {
      map['last_boot_ctr'] = Variable<int>(lastBootCtr.value);
    }
    if (lastMsgCtr.present) {
      map['last_msg_ctr'] = Variable<int>(lastMsgCtr.value);
    }
    if (supervisionState.present) {
      map['supervision_state'] = Variable<int>(supervisionState.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (zone.present) {
      map['zone'] = Variable<String>(zone.value);
    }
    if (registryState.present) {
      map['registry_state'] = Variable<String>(registryState.value);
    }
    if (lastDevSeq.present) {
      map['last_dev_seq'] = Variable<int>(lastDevSeq.value);
    }
    if (alarmLatched.present) {
      map['alarm_latched'] = Variable<int>(alarmLatched.value);
    }
    if (alarmLatchedAt.present) {
      map['alarm_latched_at'] = Variable<DateTime>(alarmLatchedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MeshDevicesCompanion(')
          ..write('mac: $mac, ')
          ..write('role: $role, ')
          ..write('layer: $layer, ')
          ..write('parentMac: $parentMac, ')
          ..write('lastRssi: $lastRssi, ')
          ..write('batteryPct: $batteryPct, ')
          ..write('firstSeenAt: $firstSeenAt, ')
          ..write('lastSeenAt: $lastSeenAt, ')
          ..write('lastHeartbeatAt: $lastHeartbeatAt, ')
          ..write('lastBootCtr: $lastBootCtr, ')
          ..write('lastMsgCtr: $lastMsgCtr, ')
          ..write('supervisionState: $supervisionState, ')
          ..write('name: $name, ')
          ..write('zone: $zone, ')
          ..write('registryState: $registryState, ')
          ..write('lastDevSeq: $lastDevSeq, ')
          ..write('alarmLatched: $alarmLatched, ')
          ..write('alarmLatchedAt: $alarmLatchedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DeviceEventsTable extends DeviceEvents
    with TableInfo<$DeviceEventsTable, DeviceEvent> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DeviceEventsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _receivedAtMeta =
      const VerificationMeta('receivedAt');
  @override
  late final GeneratedColumn<DateTime> receivedAt = GeneratedColumn<DateTime>(
      'received_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _deviceMacMeta =
      const VerificationMeta('deviceMac');
  @override
  late final GeneratedColumn<String> deviceMac = GeneratedColumn<String>(
      'device_mac', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _msgTypeMeta =
      const VerificationMeta('msgType');
  @override
  late final GeneratedColumn<int> msgType = GeneratedColumn<int>(
      'msg_type', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _eventTypeMeta =
      const VerificationMeta('eventType');
  @override
  late final GeneratedColumn<int> eventType = GeneratedColumn<int>(
      'event_type', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _eventCodeMeta =
      const VerificationMeta('eventCode');
  @override
  late final GeneratedColumn<int> eventCode = GeneratedColumn<int>(
      'event_code', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _severityMeta =
      const VerificationMeta('severity');
  @override
  late final GeneratedColumn<int> severity = GeneratedColumn<int>(
      'severity', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _detailJsonMeta =
      const VerificationMeta('detailJson');
  @override
  late final GeneratedColumn<String> detailJson = GeneratedColumn<String>(
      'detail_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _packetIdMeta =
      const VerificationMeta('packetId');
  @override
  late final GeneratedColumn<int> packetId = GeneratedColumn<int>(
      'packet_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _errorKindMeta =
      const VerificationMeta('errorKind');
  @override
  late final GeneratedColumn<String> errorKind = GeneratedColumn<String>(
      'error_kind', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _ackedAtMeta =
      const VerificationMeta('ackedAt');
  @override
  late final GeneratedColumn<DateTime> ackedAt = GeneratedColumn<DateTime>(
      'acked_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _devSeqMeta = const VerificationMeta('devSeq');
  @override
  late final GeneratedColumn<int> devSeq = GeneratedColumn<int>(
      'dev_seq', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        receivedAt,
        deviceMac,
        msgType,
        eventType,
        eventCode,
        severity,
        detailJson,
        packetId,
        errorKind,
        ackedAt,
        devSeq
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'device_events';
  @override
  VerificationContext validateIntegrity(Insertable<DeviceEvent> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('received_at')) {
      context.handle(
          _receivedAtMeta,
          receivedAt.isAcceptableOrUnknown(
              data['received_at']!, _receivedAtMeta));
    } else if (isInserting) {
      context.missing(_receivedAtMeta);
    }
    if (data.containsKey('device_mac')) {
      context.handle(_deviceMacMeta,
          deviceMac.isAcceptableOrUnknown(data['device_mac']!, _deviceMacMeta));
    } else if (isInserting) {
      context.missing(_deviceMacMeta);
    }
    if (data.containsKey('msg_type')) {
      context.handle(_msgTypeMeta,
          msgType.isAcceptableOrUnknown(data['msg_type']!, _msgTypeMeta));
    } else if (isInserting) {
      context.missing(_msgTypeMeta);
    }
    if (data.containsKey('event_type')) {
      context.handle(_eventTypeMeta,
          eventType.isAcceptableOrUnknown(data['event_type']!, _eventTypeMeta));
    }
    if (data.containsKey('event_code')) {
      context.handle(_eventCodeMeta,
          eventCode.isAcceptableOrUnknown(data['event_code']!, _eventCodeMeta));
    }
    if (data.containsKey('severity')) {
      context.handle(_severityMeta,
          severity.isAcceptableOrUnknown(data['severity']!, _severityMeta));
    } else if (isInserting) {
      context.missing(_severityMeta);
    }
    if (data.containsKey('detail_json')) {
      context.handle(
          _detailJsonMeta,
          detailJson.isAcceptableOrUnknown(
              data['detail_json']!, _detailJsonMeta));
    } else if (isInserting) {
      context.missing(_detailJsonMeta);
    }
    if (data.containsKey('packet_id')) {
      context.handle(_packetIdMeta,
          packetId.isAcceptableOrUnknown(data['packet_id']!, _packetIdMeta));
    }
    if (data.containsKey('error_kind')) {
      context.handle(_errorKindMeta,
          errorKind.isAcceptableOrUnknown(data['error_kind']!, _errorKindMeta));
    }
    if (data.containsKey('acked_at')) {
      context.handle(_ackedAtMeta,
          ackedAt.isAcceptableOrUnknown(data['acked_at']!, _ackedAtMeta));
    }
    if (data.containsKey('dev_seq')) {
      context.handle(_devSeqMeta,
          devSeq.isAcceptableOrUnknown(data['dev_seq']!, _devSeqMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DeviceEvent map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DeviceEvent(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      receivedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}received_at'])!,
      deviceMac: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}device_mac'])!,
      msgType: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}msg_type'])!,
      eventType: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}event_type']),
      eventCode: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}event_code']),
      severity: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}severity'])!,
      detailJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}detail_json'])!,
      packetId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}packet_id']),
      errorKind: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}error_kind']),
      ackedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}acked_at']),
      devSeq: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}dev_seq']),
    );
  }

  @override
  $DeviceEventsTable createAlias(String alias) {
    return $DeviceEventsTable(attachedDatabase, alias);
  }
}

class DeviceEvent extends DataClass implements Insertable<DeviceEvent> {
  final int id;
  final DateTime receivedAt;
  final String deviceMac;
  final int msgType;
  final int? eventType;
  final int? eventCode;
  final int severity;
  final String detailJson;
  final int? packetId;
  final String? errorKind;
  final DateTime? ackedAt;
  final int? devSeq;
  const DeviceEvent(
      {required this.id,
      required this.receivedAt,
      required this.deviceMac,
      required this.msgType,
      this.eventType,
      this.eventCode,
      required this.severity,
      required this.detailJson,
      this.packetId,
      this.errorKind,
      this.ackedAt,
      this.devSeq});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['received_at'] = Variable<DateTime>(receivedAt);
    map['device_mac'] = Variable<String>(deviceMac);
    map['msg_type'] = Variable<int>(msgType);
    if (!nullToAbsent || eventType != null) {
      map['event_type'] = Variable<int>(eventType);
    }
    if (!nullToAbsent || eventCode != null) {
      map['event_code'] = Variable<int>(eventCode);
    }
    map['severity'] = Variable<int>(severity);
    map['detail_json'] = Variable<String>(detailJson);
    if (!nullToAbsent || packetId != null) {
      map['packet_id'] = Variable<int>(packetId);
    }
    if (!nullToAbsent || errorKind != null) {
      map['error_kind'] = Variable<String>(errorKind);
    }
    if (!nullToAbsent || ackedAt != null) {
      map['acked_at'] = Variable<DateTime>(ackedAt);
    }
    if (!nullToAbsent || devSeq != null) {
      map['dev_seq'] = Variable<int>(devSeq);
    }
    return map;
  }

  DeviceEventsCompanion toCompanion(bool nullToAbsent) {
    return DeviceEventsCompanion(
      id: Value(id),
      receivedAt: Value(receivedAt),
      deviceMac: Value(deviceMac),
      msgType: Value(msgType),
      eventType: eventType == null && nullToAbsent
          ? const Value.absent()
          : Value(eventType),
      eventCode: eventCode == null && nullToAbsent
          ? const Value.absent()
          : Value(eventCode),
      severity: Value(severity),
      detailJson: Value(detailJson),
      packetId: packetId == null && nullToAbsent
          ? const Value.absent()
          : Value(packetId),
      errorKind: errorKind == null && nullToAbsent
          ? const Value.absent()
          : Value(errorKind),
      ackedAt: ackedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(ackedAt),
      devSeq:
          devSeq == null && nullToAbsent ? const Value.absent() : Value(devSeq),
    );
  }

  factory DeviceEvent.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DeviceEvent(
      id: serializer.fromJson<int>(json['id']),
      receivedAt: serializer.fromJson<DateTime>(json['receivedAt']),
      deviceMac: serializer.fromJson<String>(json['deviceMac']),
      msgType: serializer.fromJson<int>(json['msgType']),
      eventType: serializer.fromJson<int?>(json['eventType']),
      eventCode: serializer.fromJson<int?>(json['eventCode']),
      severity: serializer.fromJson<int>(json['severity']),
      detailJson: serializer.fromJson<String>(json['detailJson']),
      packetId: serializer.fromJson<int?>(json['packetId']),
      errorKind: serializer.fromJson<String?>(json['errorKind']),
      ackedAt: serializer.fromJson<DateTime?>(json['ackedAt']),
      devSeq: serializer.fromJson<int?>(json['devSeq']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'receivedAt': serializer.toJson<DateTime>(receivedAt),
      'deviceMac': serializer.toJson<String>(deviceMac),
      'msgType': serializer.toJson<int>(msgType),
      'eventType': serializer.toJson<int?>(eventType),
      'eventCode': serializer.toJson<int?>(eventCode),
      'severity': serializer.toJson<int>(severity),
      'detailJson': serializer.toJson<String>(detailJson),
      'packetId': serializer.toJson<int?>(packetId),
      'errorKind': serializer.toJson<String?>(errorKind),
      'ackedAt': serializer.toJson<DateTime?>(ackedAt),
      'devSeq': serializer.toJson<int?>(devSeq),
    };
  }

  DeviceEvent copyWith(
          {int? id,
          DateTime? receivedAt,
          String? deviceMac,
          int? msgType,
          Value<int?> eventType = const Value.absent(),
          Value<int?> eventCode = const Value.absent(),
          int? severity,
          String? detailJson,
          Value<int?> packetId = const Value.absent(),
          Value<String?> errorKind = const Value.absent(),
          Value<DateTime?> ackedAt = const Value.absent(),
          Value<int?> devSeq = const Value.absent()}) =>
      DeviceEvent(
        id: id ?? this.id,
        receivedAt: receivedAt ?? this.receivedAt,
        deviceMac: deviceMac ?? this.deviceMac,
        msgType: msgType ?? this.msgType,
        eventType: eventType.present ? eventType.value : this.eventType,
        eventCode: eventCode.present ? eventCode.value : this.eventCode,
        severity: severity ?? this.severity,
        detailJson: detailJson ?? this.detailJson,
        packetId: packetId.present ? packetId.value : this.packetId,
        errorKind: errorKind.present ? errorKind.value : this.errorKind,
        ackedAt: ackedAt.present ? ackedAt.value : this.ackedAt,
        devSeq: devSeq.present ? devSeq.value : this.devSeq,
      );
  DeviceEvent copyWithCompanion(DeviceEventsCompanion data) {
    return DeviceEvent(
      id: data.id.present ? data.id.value : this.id,
      receivedAt:
          data.receivedAt.present ? data.receivedAt.value : this.receivedAt,
      deviceMac: data.deviceMac.present ? data.deviceMac.value : this.deviceMac,
      msgType: data.msgType.present ? data.msgType.value : this.msgType,
      eventType: data.eventType.present ? data.eventType.value : this.eventType,
      eventCode: data.eventCode.present ? data.eventCode.value : this.eventCode,
      severity: data.severity.present ? data.severity.value : this.severity,
      detailJson:
          data.detailJson.present ? data.detailJson.value : this.detailJson,
      packetId: data.packetId.present ? data.packetId.value : this.packetId,
      errorKind: data.errorKind.present ? data.errorKind.value : this.errorKind,
      ackedAt: data.ackedAt.present ? data.ackedAt.value : this.ackedAt,
      devSeq: data.devSeq.present ? data.devSeq.value : this.devSeq,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DeviceEvent(')
          ..write('id: $id, ')
          ..write('receivedAt: $receivedAt, ')
          ..write('deviceMac: $deviceMac, ')
          ..write('msgType: $msgType, ')
          ..write('eventType: $eventType, ')
          ..write('eventCode: $eventCode, ')
          ..write('severity: $severity, ')
          ..write('detailJson: $detailJson, ')
          ..write('packetId: $packetId, ')
          ..write('errorKind: $errorKind, ')
          ..write('ackedAt: $ackedAt, ')
          ..write('devSeq: $devSeq')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, receivedAt, deviceMac, msgType, eventType,
      eventCode, severity, detailJson, packetId, errorKind, ackedAt, devSeq);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DeviceEvent &&
          other.id == this.id &&
          other.receivedAt == this.receivedAt &&
          other.deviceMac == this.deviceMac &&
          other.msgType == this.msgType &&
          other.eventType == this.eventType &&
          other.eventCode == this.eventCode &&
          other.severity == this.severity &&
          other.detailJson == this.detailJson &&
          other.packetId == this.packetId &&
          other.errorKind == this.errorKind &&
          other.ackedAt == this.ackedAt &&
          other.devSeq == this.devSeq);
}

class DeviceEventsCompanion extends UpdateCompanion<DeviceEvent> {
  final Value<int> id;
  final Value<DateTime> receivedAt;
  final Value<String> deviceMac;
  final Value<int> msgType;
  final Value<int?> eventType;
  final Value<int?> eventCode;
  final Value<int> severity;
  final Value<String> detailJson;
  final Value<int?> packetId;
  final Value<String?> errorKind;
  final Value<DateTime?> ackedAt;
  final Value<int?> devSeq;
  const DeviceEventsCompanion({
    this.id = const Value.absent(),
    this.receivedAt = const Value.absent(),
    this.deviceMac = const Value.absent(),
    this.msgType = const Value.absent(),
    this.eventType = const Value.absent(),
    this.eventCode = const Value.absent(),
    this.severity = const Value.absent(),
    this.detailJson = const Value.absent(),
    this.packetId = const Value.absent(),
    this.errorKind = const Value.absent(),
    this.ackedAt = const Value.absent(),
    this.devSeq = const Value.absent(),
  });
  DeviceEventsCompanion.insert({
    this.id = const Value.absent(),
    required DateTime receivedAt,
    required String deviceMac,
    required int msgType,
    this.eventType = const Value.absent(),
    this.eventCode = const Value.absent(),
    required int severity,
    required String detailJson,
    this.packetId = const Value.absent(),
    this.errorKind = const Value.absent(),
    this.ackedAt = const Value.absent(),
    this.devSeq = const Value.absent(),
  })  : receivedAt = Value(receivedAt),
        deviceMac = Value(deviceMac),
        msgType = Value(msgType),
        severity = Value(severity),
        detailJson = Value(detailJson);
  static Insertable<DeviceEvent> custom({
    Expression<int>? id,
    Expression<DateTime>? receivedAt,
    Expression<String>? deviceMac,
    Expression<int>? msgType,
    Expression<int>? eventType,
    Expression<int>? eventCode,
    Expression<int>? severity,
    Expression<String>? detailJson,
    Expression<int>? packetId,
    Expression<String>? errorKind,
    Expression<DateTime>? ackedAt,
    Expression<int>? devSeq,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (receivedAt != null) 'received_at': receivedAt,
      if (deviceMac != null) 'device_mac': deviceMac,
      if (msgType != null) 'msg_type': msgType,
      if (eventType != null) 'event_type': eventType,
      if (eventCode != null) 'event_code': eventCode,
      if (severity != null) 'severity': severity,
      if (detailJson != null) 'detail_json': detailJson,
      if (packetId != null) 'packet_id': packetId,
      if (errorKind != null) 'error_kind': errorKind,
      if (ackedAt != null) 'acked_at': ackedAt,
      if (devSeq != null) 'dev_seq': devSeq,
    });
  }

  DeviceEventsCompanion copyWith(
      {Value<int>? id,
      Value<DateTime>? receivedAt,
      Value<String>? deviceMac,
      Value<int>? msgType,
      Value<int?>? eventType,
      Value<int?>? eventCode,
      Value<int>? severity,
      Value<String>? detailJson,
      Value<int?>? packetId,
      Value<String?>? errorKind,
      Value<DateTime?>? ackedAt,
      Value<int?>? devSeq}) {
    return DeviceEventsCompanion(
      id: id ?? this.id,
      receivedAt: receivedAt ?? this.receivedAt,
      deviceMac: deviceMac ?? this.deviceMac,
      msgType: msgType ?? this.msgType,
      eventType: eventType ?? this.eventType,
      eventCode: eventCode ?? this.eventCode,
      severity: severity ?? this.severity,
      detailJson: detailJson ?? this.detailJson,
      packetId: packetId ?? this.packetId,
      errorKind: errorKind ?? this.errorKind,
      ackedAt: ackedAt ?? this.ackedAt,
      devSeq: devSeq ?? this.devSeq,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (receivedAt.present) {
      map['received_at'] = Variable<DateTime>(receivedAt.value);
    }
    if (deviceMac.present) {
      map['device_mac'] = Variable<String>(deviceMac.value);
    }
    if (msgType.present) {
      map['msg_type'] = Variable<int>(msgType.value);
    }
    if (eventType.present) {
      map['event_type'] = Variable<int>(eventType.value);
    }
    if (eventCode.present) {
      map['event_code'] = Variable<int>(eventCode.value);
    }
    if (severity.present) {
      map['severity'] = Variable<int>(severity.value);
    }
    if (detailJson.present) {
      map['detail_json'] = Variable<String>(detailJson.value);
    }
    if (packetId.present) {
      map['packet_id'] = Variable<int>(packetId.value);
    }
    if (errorKind.present) {
      map['error_kind'] = Variable<String>(errorKind.value);
    }
    if (ackedAt.present) {
      map['acked_at'] = Variable<DateTime>(ackedAt.value);
    }
    if (devSeq.present) {
      map['dev_seq'] = Variable<int>(devSeq.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DeviceEventsCompanion(')
          ..write('id: $id, ')
          ..write('receivedAt: $receivedAt, ')
          ..write('deviceMac: $deviceMac, ')
          ..write('msgType: $msgType, ')
          ..write('eventType: $eventType, ')
          ..write('eventCode: $eventCode, ')
          ..write('severity: $severity, ')
          ..write('detailJson: $detailJson, ')
          ..write('packetId: $packetId, ')
          ..write('errorKind: $errorKind, ')
          ..write('ackedAt: $ackedAt, ')
          ..write('devSeq: $devSeq')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $SerialPacketsTable serialPackets = $SerialPacketsTable(this);
  late final $DeviceMetadataTable deviceMetadata = $DeviceMetadataTable(this);
  late final $AuditEventsTable auditEvents = $AuditEventsTable(this);
  late final $MeshDevicesTable meshDevices = $MeshDevicesTable(this);
  late final $DeviceEventsTable deviceEvents = $DeviceEventsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities =>
      [serialPackets, deviceMetadata, auditEvents, meshDevices, deviceEvents];
}

typedef $$SerialPacketsTableCreateCompanionBuilder = SerialPacketsCompanion
    Function({
  Value<int> id,
  required DateTime receivedAt,
  required String deviceId,
  required Uint8List rawBytes,
  required int byteLength,
  required String hexPreview,
});
typedef $$SerialPacketsTableUpdateCompanionBuilder = SerialPacketsCompanion
    Function({
  Value<int> id,
  Value<DateTime> receivedAt,
  Value<String> deviceId,
  Value<Uint8List> rawBytes,
  Value<int> byteLength,
  Value<String> hexPreview,
});

class $$SerialPacketsTableFilterComposer
    extends Composer<_$AppDatabase, $SerialPacketsTable> {
  $$SerialPacketsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get receivedAt => $composableBuilder(
      column: $table.receivedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get deviceId => $composableBuilder(
      column: $table.deviceId, builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get rawBytes => $composableBuilder(
      column: $table.rawBytes, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get byteLength => $composableBuilder(
      column: $table.byteLength, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get hexPreview => $composableBuilder(
      column: $table.hexPreview, builder: (column) => ColumnFilters(column));
}

class $$SerialPacketsTableOrderingComposer
    extends Composer<_$AppDatabase, $SerialPacketsTable> {
  $$SerialPacketsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get receivedAt => $composableBuilder(
      column: $table.receivedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get deviceId => $composableBuilder(
      column: $table.deviceId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get rawBytes => $composableBuilder(
      column: $table.rawBytes, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get byteLength => $composableBuilder(
      column: $table.byteLength, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get hexPreview => $composableBuilder(
      column: $table.hexPreview, builder: (column) => ColumnOrderings(column));
}

class $$SerialPacketsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SerialPacketsTable> {
  $$SerialPacketsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<DateTime> get receivedAt => $composableBuilder(
      column: $table.receivedAt, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<Uint8List> get rawBytes =>
      $composableBuilder(column: $table.rawBytes, builder: (column) => column);

  GeneratedColumn<int> get byteLength => $composableBuilder(
      column: $table.byteLength, builder: (column) => column);

  GeneratedColumn<String> get hexPreview => $composableBuilder(
      column: $table.hexPreview, builder: (column) => column);
}

class $$SerialPacketsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $SerialPacketsTable,
    SerialPacket,
    $$SerialPacketsTableFilterComposer,
    $$SerialPacketsTableOrderingComposer,
    $$SerialPacketsTableAnnotationComposer,
    $$SerialPacketsTableCreateCompanionBuilder,
    $$SerialPacketsTableUpdateCompanionBuilder,
    (
      SerialPacket,
      BaseReferences<_$AppDatabase, $SerialPacketsTable, SerialPacket>
    ),
    SerialPacket,
    PrefetchHooks Function()> {
  $$SerialPacketsTableTableManager(_$AppDatabase db, $SerialPacketsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SerialPacketsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SerialPacketsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SerialPacketsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> receivedAt = const Value.absent(),
            Value<String> deviceId = const Value.absent(),
            Value<Uint8List> rawBytes = const Value.absent(),
            Value<int> byteLength = const Value.absent(),
            Value<String> hexPreview = const Value.absent(),
          }) =>
              SerialPacketsCompanion(
            id: id,
            receivedAt: receivedAt,
            deviceId: deviceId,
            rawBytes: rawBytes,
            byteLength: byteLength,
            hexPreview: hexPreview,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required DateTime receivedAt,
            required String deviceId,
            required Uint8List rawBytes,
            required int byteLength,
            required String hexPreview,
          }) =>
              SerialPacketsCompanion.insert(
            id: id,
            receivedAt: receivedAt,
            deviceId: deviceId,
            rawBytes: rawBytes,
            byteLength: byteLength,
            hexPreview: hexPreview,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SerialPacketsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $SerialPacketsTable,
    SerialPacket,
    $$SerialPacketsTableFilterComposer,
    $$SerialPacketsTableOrderingComposer,
    $$SerialPacketsTableAnnotationComposer,
    $$SerialPacketsTableCreateCompanionBuilder,
    $$SerialPacketsTableUpdateCompanionBuilder,
    (
      SerialPacket,
      BaseReferences<_$AppDatabase, $SerialPacketsTable, SerialPacket>
    ),
    SerialPacket,
    PrefetchHooks Function()>;
typedef $$DeviceMetadataTableCreateCompanionBuilder = DeviceMetadataCompanion
    Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$DeviceMetadataTableUpdateCompanionBuilder = DeviceMetadataCompanion
    Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$DeviceMetadataTableFilterComposer
    extends Composer<_$AppDatabase, $DeviceMetadataTable> {
  $$DeviceMetadataTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnFilters(column));
}

class $$DeviceMetadataTableOrderingComposer
    extends Composer<_$AppDatabase, $DeviceMetadataTable> {
  $$DeviceMetadataTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnOrderings(column));
}

class $$DeviceMetadataTableAnnotationComposer
    extends Composer<_$AppDatabase, $DeviceMetadataTable> {
  $$DeviceMetadataTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$DeviceMetadataTableTableManager extends RootTableManager<
    _$AppDatabase,
    $DeviceMetadataTable,
    DeviceMetadataData,
    $$DeviceMetadataTableFilterComposer,
    $$DeviceMetadataTableOrderingComposer,
    $$DeviceMetadataTableAnnotationComposer,
    $$DeviceMetadataTableCreateCompanionBuilder,
    $$DeviceMetadataTableUpdateCompanionBuilder,
    (
      DeviceMetadataData,
      BaseReferences<_$AppDatabase, $DeviceMetadataTable, DeviceMetadataData>
    ),
    DeviceMetadataData,
    PrefetchHooks Function()> {
  $$DeviceMetadataTableTableManager(
      _$AppDatabase db, $DeviceMetadataTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DeviceMetadataTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DeviceMetadataTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DeviceMetadataTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              DeviceMetadataCompanion(
            key: key,
            value: value,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) =>
              DeviceMetadataCompanion.insert(
            key: key,
            value: value,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$DeviceMetadataTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $DeviceMetadataTable,
    DeviceMetadataData,
    $$DeviceMetadataTableFilterComposer,
    $$DeviceMetadataTableOrderingComposer,
    $$DeviceMetadataTableAnnotationComposer,
    $$DeviceMetadataTableCreateCompanionBuilder,
    $$DeviceMetadataTableUpdateCompanionBuilder,
    (
      DeviceMetadataData,
      BaseReferences<_$AppDatabase, $DeviceMetadataTable, DeviceMetadataData>
    ),
    DeviceMetadataData,
    PrefetchHooks Function()>;
typedef $$AuditEventsTableCreateCompanionBuilder = AuditEventsCompanion
    Function({
  Value<int> id,
  required DateTime at,
  required String actor,
  required String action,
  required String detail,
});
typedef $$AuditEventsTableUpdateCompanionBuilder = AuditEventsCompanion
    Function({
  Value<int> id,
  Value<DateTime> at,
  Value<String> actor,
  Value<String> action,
  Value<String> detail,
});

class $$AuditEventsTableFilterComposer
    extends Composer<_$AppDatabase, $AuditEventsTable> {
  $$AuditEventsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get at => $composableBuilder(
      column: $table.at, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get actor => $composableBuilder(
      column: $table.actor, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get action => $composableBuilder(
      column: $table.action, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get detail => $composableBuilder(
      column: $table.detail, builder: (column) => ColumnFilters(column));
}

class $$AuditEventsTableOrderingComposer
    extends Composer<_$AppDatabase, $AuditEventsTable> {
  $$AuditEventsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get at => $composableBuilder(
      column: $table.at, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get actor => $composableBuilder(
      column: $table.actor, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get action => $composableBuilder(
      column: $table.action, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get detail => $composableBuilder(
      column: $table.detail, builder: (column) => ColumnOrderings(column));
}

class $$AuditEventsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AuditEventsTable> {
  $$AuditEventsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<DateTime> get at =>
      $composableBuilder(column: $table.at, builder: (column) => column);

  GeneratedColumn<String> get actor =>
      $composableBuilder(column: $table.actor, builder: (column) => column);

  GeneratedColumn<String> get action =>
      $composableBuilder(column: $table.action, builder: (column) => column);

  GeneratedColumn<String> get detail =>
      $composableBuilder(column: $table.detail, builder: (column) => column);
}

class $$AuditEventsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $AuditEventsTable,
    AuditEvent,
    $$AuditEventsTableFilterComposer,
    $$AuditEventsTableOrderingComposer,
    $$AuditEventsTableAnnotationComposer,
    $$AuditEventsTableCreateCompanionBuilder,
    $$AuditEventsTableUpdateCompanionBuilder,
    (AuditEvent, BaseReferences<_$AppDatabase, $AuditEventsTable, AuditEvent>),
    AuditEvent,
    PrefetchHooks Function()> {
  $$AuditEventsTableTableManager(_$AppDatabase db, $AuditEventsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AuditEventsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AuditEventsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AuditEventsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> at = const Value.absent(),
            Value<String> actor = const Value.absent(),
            Value<String> action = const Value.absent(),
            Value<String> detail = const Value.absent(),
          }) =>
              AuditEventsCompanion(
            id: id,
            at: at,
            actor: actor,
            action: action,
            detail: detail,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required DateTime at,
            required String actor,
            required String action,
            required String detail,
          }) =>
              AuditEventsCompanion.insert(
            id: id,
            at: at,
            actor: actor,
            action: action,
            detail: detail,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$AuditEventsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $AuditEventsTable,
    AuditEvent,
    $$AuditEventsTableFilterComposer,
    $$AuditEventsTableOrderingComposer,
    $$AuditEventsTableAnnotationComposer,
    $$AuditEventsTableCreateCompanionBuilder,
    $$AuditEventsTableUpdateCompanionBuilder,
    (AuditEvent, BaseReferences<_$AppDatabase, $AuditEventsTable, AuditEvent>),
    AuditEvent,
    PrefetchHooks Function()>;
typedef $$MeshDevicesTableCreateCompanionBuilder = MeshDevicesCompanion
    Function({
  required String mac,
  Value<int> role,
  Value<int> layer,
  Value<String?> parentMac,
  Value<int?> lastRssi,
  Value<int?> batteryPct,
  required DateTime firstSeenAt,
  required DateTime lastSeenAt,
  Value<DateTime?> lastHeartbeatAt,
  Value<int> lastBootCtr,
  Value<int> lastMsgCtr,
  Value<int> supervisionState,
  Value<String?> name,
  Value<String?> zone,
  Value<String?> registryState,
  Value<int> lastDevSeq,
  Value<int> alarmLatched,
  Value<DateTime?> alarmLatchedAt,
  Value<int> rowid,
});
typedef $$MeshDevicesTableUpdateCompanionBuilder = MeshDevicesCompanion
    Function({
  Value<String> mac,
  Value<int> role,
  Value<int> layer,
  Value<String?> parentMac,
  Value<int?> lastRssi,
  Value<int?> batteryPct,
  Value<DateTime> firstSeenAt,
  Value<DateTime> lastSeenAt,
  Value<DateTime?> lastHeartbeatAt,
  Value<int> lastBootCtr,
  Value<int> lastMsgCtr,
  Value<int> supervisionState,
  Value<String?> name,
  Value<String?> zone,
  Value<String?> registryState,
  Value<int> lastDevSeq,
  Value<int> alarmLatched,
  Value<DateTime?> alarmLatchedAt,
  Value<int> rowid,
});

class $$MeshDevicesTableFilterComposer
    extends Composer<_$AppDatabase, $MeshDevicesTable> {
  $$MeshDevicesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get mac => $composableBuilder(
      column: $table.mac, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get role => $composableBuilder(
      column: $table.role, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get layer => $composableBuilder(
      column: $table.layer, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get parentMac => $composableBuilder(
      column: $table.parentMac, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastRssi => $composableBuilder(
      column: $table.lastRssi, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get batteryPct => $composableBuilder(
      column: $table.batteryPct, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get firstSeenAt => $composableBuilder(
      column: $table.firstSeenAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get lastSeenAt => $composableBuilder(
      column: $table.lastSeenAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get lastHeartbeatAt => $composableBuilder(
      column: $table.lastHeartbeatAt,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastBootCtr => $composableBuilder(
      column: $table.lastBootCtr, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastMsgCtr => $composableBuilder(
      column: $table.lastMsgCtr, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get supervisionState => $composableBuilder(
      column: $table.supervisionState,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get zone => $composableBuilder(
      column: $table.zone, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get registryState => $composableBuilder(
      column: $table.registryState, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastDevSeq => $composableBuilder(
      column: $table.lastDevSeq, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get alarmLatched => $composableBuilder(
      column: $table.alarmLatched, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get alarmLatchedAt => $composableBuilder(
      column: $table.alarmLatchedAt,
      builder: (column) => ColumnFilters(column));
}

class $$MeshDevicesTableOrderingComposer
    extends Composer<_$AppDatabase, $MeshDevicesTable> {
  $$MeshDevicesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get mac => $composableBuilder(
      column: $table.mac, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get role => $composableBuilder(
      column: $table.role, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get layer => $composableBuilder(
      column: $table.layer, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get parentMac => $composableBuilder(
      column: $table.parentMac, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastRssi => $composableBuilder(
      column: $table.lastRssi, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get batteryPct => $composableBuilder(
      column: $table.batteryPct, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get firstSeenAt => $composableBuilder(
      column: $table.firstSeenAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get lastSeenAt => $composableBuilder(
      column: $table.lastSeenAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get lastHeartbeatAt => $composableBuilder(
      column: $table.lastHeartbeatAt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastBootCtr => $composableBuilder(
      column: $table.lastBootCtr, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastMsgCtr => $composableBuilder(
      column: $table.lastMsgCtr, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get supervisionState => $composableBuilder(
      column: $table.supervisionState,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get zone => $composableBuilder(
      column: $table.zone, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get registryState => $composableBuilder(
      column: $table.registryState,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastDevSeq => $composableBuilder(
      column: $table.lastDevSeq, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get alarmLatched => $composableBuilder(
      column: $table.alarmLatched,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get alarmLatchedAt => $composableBuilder(
      column: $table.alarmLatchedAt,
      builder: (column) => ColumnOrderings(column));
}

class $$MeshDevicesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MeshDevicesTable> {
  $$MeshDevicesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get mac =>
      $composableBuilder(column: $table.mac, builder: (column) => column);

  GeneratedColumn<int> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<int> get layer =>
      $composableBuilder(column: $table.layer, builder: (column) => column);

  GeneratedColumn<String> get parentMac =>
      $composableBuilder(column: $table.parentMac, builder: (column) => column);

  GeneratedColumn<int> get lastRssi =>
      $composableBuilder(column: $table.lastRssi, builder: (column) => column);

  GeneratedColumn<int> get batteryPct => $composableBuilder(
      column: $table.batteryPct, builder: (column) => column);

  GeneratedColumn<DateTime> get firstSeenAt => $composableBuilder(
      column: $table.firstSeenAt, builder: (column) => column);

  GeneratedColumn<DateTime> get lastSeenAt => $composableBuilder(
      column: $table.lastSeenAt, builder: (column) => column);

  GeneratedColumn<DateTime> get lastHeartbeatAt => $composableBuilder(
      column: $table.lastHeartbeatAt, builder: (column) => column);

  GeneratedColumn<int> get lastBootCtr => $composableBuilder(
      column: $table.lastBootCtr, builder: (column) => column);

  GeneratedColumn<int> get lastMsgCtr => $composableBuilder(
      column: $table.lastMsgCtr, builder: (column) => column);

  GeneratedColumn<int> get supervisionState => $composableBuilder(
      column: $table.supervisionState, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get zone =>
      $composableBuilder(column: $table.zone, builder: (column) => column);

  GeneratedColumn<String> get registryState => $composableBuilder(
      column: $table.registryState, builder: (column) => column);

  GeneratedColumn<int> get lastDevSeq => $composableBuilder(
      column: $table.lastDevSeq, builder: (column) => column);

  GeneratedColumn<int> get alarmLatched => $composableBuilder(
      column: $table.alarmLatched, builder: (column) => column);

  GeneratedColumn<DateTime> get alarmLatchedAt => $composableBuilder(
      column: $table.alarmLatchedAt, builder: (column) => column);
}

class $$MeshDevicesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $MeshDevicesTable,
    MeshDevice,
    $$MeshDevicesTableFilterComposer,
    $$MeshDevicesTableOrderingComposer,
    $$MeshDevicesTableAnnotationComposer,
    $$MeshDevicesTableCreateCompanionBuilder,
    $$MeshDevicesTableUpdateCompanionBuilder,
    (MeshDevice, BaseReferences<_$AppDatabase, $MeshDevicesTable, MeshDevice>),
    MeshDevice,
    PrefetchHooks Function()> {
  $$MeshDevicesTableTableManager(_$AppDatabase db, $MeshDevicesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MeshDevicesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MeshDevicesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MeshDevicesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> mac = const Value.absent(),
            Value<int> role = const Value.absent(),
            Value<int> layer = const Value.absent(),
            Value<String?> parentMac = const Value.absent(),
            Value<int?> lastRssi = const Value.absent(),
            Value<int?> batteryPct = const Value.absent(),
            Value<DateTime> firstSeenAt = const Value.absent(),
            Value<DateTime> lastSeenAt = const Value.absent(),
            Value<DateTime?> lastHeartbeatAt = const Value.absent(),
            Value<int> lastBootCtr = const Value.absent(),
            Value<int> lastMsgCtr = const Value.absent(),
            Value<int> supervisionState = const Value.absent(),
            Value<String?> name = const Value.absent(),
            Value<String?> zone = const Value.absent(),
            Value<String?> registryState = const Value.absent(),
            Value<int> lastDevSeq = const Value.absent(),
            Value<int> alarmLatched = const Value.absent(),
            Value<DateTime?> alarmLatchedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MeshDevicesCompanion(
            mac: mac,
            role: role,
            layer: layer,
            parentMac: parentMac,
            lastRssi: lastRssi,
            batteryPct: batteryPct,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            lastHeartbeatAt: lastHeartbeatAt,
            lastBootCtr: lastBootCtr,
            lastMsgCtr: lastMsgCtr,
            supervisionState: supervisionState,
            name: name,
            zone: zone,
            registryState: registryState,
            lastDevSeq: lastDevSeq,
            alarmLatched: alarmLatched,
            alarmLatchedAt: alarmLatchedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String mac,
            Value<int> role = const Value.absent(),
            Value<int> layer = const Value.absent(),
            Value<String?> parentMac = const Value.absent(),
            Value<int?> lastRssi = const Value.absent(),
            Value<int?> batteryPct = const Value.absent(),
            required DateTime firstSeenAt,
            required DateTime lastSeenAt,
            Value<DateTime?> lastHeartbeatAt = const Value.absent(),
            Value<int> lastBootCtr = const Value.absent(),
            Value<int> lastMsgCtr = const Value.absent(),
            Value<int> supervisionState = const Value.absent(),
            Value<String?> name = const Value.absent(),
            Value<String?> zone = const Value.absent(),
            Value<String?> registryState = const Value.absent(),
            Value<int> lastDevSeq = const Value.absent(),
            Value<int> alarmLatched = const Value.absent(),
            Value<DateTime?> alarmLatchedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MeshDevicesCompanion.insert(
            mac: mac,
            role: role,
            layer: layer,
            parentMac: parentMac,
            lastRssi: lastRssi,
            batteryPct: batteryPct,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            lastHeartbeatAt: lastHeartbeatAt,
            lastBootCtr: lastBootCtr,
            lastMsgCtr: lastMsgCtr,
            supervisionState: supervisionState,
            name: name,
            zone: zone,
            registryState: registryState,
            lastDevSeq: lastDevSeq,
            alarmLatched: alarmLatched,
            alarmLatchedAt: alarmLatchedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$MeshDevicesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $MeshDevicesTable,
    MeshDevice,
    $$MeshDevicesTableFilterComposer,
    $$MeshDevicesTableOrderingComposer,
    $$MeshDevicesTableAnnotationComposer,
    $$MeshDevicesTableCreateCompanionBuilder,
    $$MeshDevicesTableUpdateCompanionBuilder,
    (MeshDevice, BaseReferences<_$AppDatabase, $MeshDevicesTable, MeshDevice>),
    MeshDevice,
    PrefetchHooks Function()>;
typedef $$DeviceEventsTableCreateCompanionBuilder = DeviceEventsCompanion
    Function({
  Value<int> id,
  required DateTime receivedAt,
  required String deviceMac,
  required int msgType,
  Value<int?> eventType,
  Value<int?> eventCode,
  required int severity,
  required String detailJson,
  Value<int?> packetId,
  Value<String?> errorKind,
  Value<DateTime?> ackedAt,
  Value<int?> devSeq,
});
typedef $$DeviceEventsTableUpdateCompanionBuilder = DeviceEventsCompanion
    Function({
  Value<int> id,
  Value<DateTime> receivedAt,
  Value<String> deviceMac,
  Value<int> msgType,
  Value<int?> eventType,
  Value<int?> eventCode,
  Value<int> severity,
  Value<String> detailJson,
  Value<int?> packetId,
  Value<String?> errorKind,
  Value<DateTime?> ackedAt,
  Value<int?> devSeq,
});

class $$DeviceEventsTableFilterComposer
    extends Composer<_$AppDatabase, $DeviceEventsTable> {
  $$DeviceEventsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get receivedAt => $composableBuilder(
      column: $table.receivedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get deviceMac => $composableBuilder(
      column: $table.deviceMac, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get msgType => $composableBuilder(
      column: $table.msgType, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get eventType => $composableBuilder(
      column: $table.eventType, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get eventCode => $composableBuilder(
      column: $table.eventCode, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get severity => $composableBuilder(
      column: $table.severity, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get detailJson => $composableBuilder(
      column: $table.detailJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get packetId => $composableBuilder(
      column: $table.packetId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get errorKind => $composableBuilder(
      column: $table.errorKind, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get ackedAt => $composableBuilder(
      column: $table.ackedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get devSeq => $composableBuilder(
      column: $table.devSeq, builder: (column) => ColumnFilters(column));
}

class $$DeviceEventsTableOrderingComposer
    extends Composer<_$AppDatabase, $DeviceEventsTable> {
  $$DeviceEventsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get receivedAt => $composableBuilder(
      column: $table.receivedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get deviceMac => $composableBuilder(
      column: $table.deviceMac, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get msgType => $composableBuilder(
      column: $table.msgType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get eventType => $composableBuilder(
      column: $table.eventType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get eventCode => $composableBuilder(
      column: $table.eventCode, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get severity => $composableBuilder(
      column: $table.severity, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get detailJson => $composableBuilder(
      column: $table.detailJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get packetId => $composableBuilder(
      column: $table.packetId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get errorKind => $composableBuilder(
      column: $table.errorKind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get ackedAt => $composableBuilder(
      column: $table.ackedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get devSeq => $composableBuilder(
      column: $table.devSeq, builder: (column) => ColumnOrderings(column));
}

class $$DeviceEventsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DeviceEventsTable> {
  $$DeviceEventsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<DateTime> get receivedAt => $composableBuilder(
      column: $table.receivedAt, builder: (column) => column);

  GeneratedColumn<String> get deviceMac =>
      $composableBuilder(column: $table.deviceMac, builder: (column) => column);

  GeneratedColumn<int> get msgType =>
      $composableBuilder(column: $table.msgType, builder: (column) => column);

  GeneratedColumn<int> get eventType =>
      $composableBuilder(column: $table.eventType, builder: (column) => column);

  GeneratedColumn<int> get eventCode =>
      $composableBuilder(column: $table.eventCode, builder: (column) => column);

  GeneratedColumn<int> get severity =>
      $composableBuilder(column: $table.severity, builder: (column) => column);

  GeneratedColumn<String> get detailJson => $composableBuilder(
      column: $table.detailJson, builder: (column) => column);

  GeneratedColumn<int> get packetId =>
      $composableBuilder(column: $table.packetId, builder: (column) => column);

  GeneratedColumn<String> get errorKind =>
      $composableBuilder(column: $table.errorKind, builder: (column) => column);

  GeneratedColumn<DateTime> get ackedAt =>
      $composableBuilder(column: $table.ackedAt, builder: (column) => column);

  GeneratedColumn<int> get devSeq =>
      $composableBuilder(column: $table.devSeq, builder: (column) => column);
}

class $$DeviceEventsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $DeviceEventsTable,
    DeviceEvent,
    $$DeviceEventsTableFilterComposer,
    $$DeviceEventsTableOrderingComposer,
    $$DeviceEventsTableAnnotationComposer,
    $$DeviceEventsTableCreateCompanionBuilder,
    $$DeviceEventsTableUpdateCompanionBuilder,
    (
      DeviceEvent,
      BaseReferences<_$AppDatabase, $DeviceEventsTable, DeviceEvent>
    ),
    DeviceEvent,
    PrefetchHooks Function()> {
  $$DeviceEventsTableTableManager(_$AppDatabase db, $DeviceEventsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DeviceEventsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DeviceEventsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DeviceEventsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> receivedAt = const Value.absent(),
            Value<String> deviceMac = const Value.absent(),
            Value<int> msgType = const Value.absent(),
            Value<int?> eventType = const Value.absent(),
            Value<int?> eventCode = const Value.absent(),
            Value<int> severity = const Value.absent(),
            Value<String> detailJson = const Value.absent(),
            Value<int?> packetId = const Value.absent(),
            Value<String?> errorKind = const Value.absent(),
            Value<DateTime?> ackedAt = const Value.absent(),
            Value<int?> devSeq = const Value.absent(),
          }) =>
              DeviceEventsCompanion(
            id: id,
            receivedAt: receivedAt,
            deviceMac: deviceMac,
            msgType: msgType,
            eventType: eventType,
            eventCode: eventCode,
            severity: severity,
            detailJson: detailJson,
            packetId: packetId,
            errorKind: errorKind,
            ackedAt: ackedAt,
            devSeq: devSeq,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required DateTime receivedAt,
            required String deviceMac,
            required int msgType,
            Value<int?> eventType = const Value.absent(),
            Value<int?> eventCode = const Value.absent(),
            required int severity,
            required String detailJson,
            Value<int?> packetId = const Value.absent(),
            Value<String?> errorKind = const Value.absent(),
            Value<DateTime?> ackedAt = const Value.absent(),
            Value<int?> devSeq = const Value.absent(),
          }) =>
              DeviceEventsCompanion.insert(
            id: id,
            receivedAt: receivedAt,
            deviceMac: deviceMac,
            msgType: msgType,
            eventType: eventType,
            eventCode: eventCode,
            severity: severity,
            detailJson: detailJson,
            packetId: packetId,
            errorKind: errorKind,
            ackedAt: ackedAt,
            devSeq: devSeq,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$DeviceEventsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $DeviceEventsTable,
    DeviceEvent,
    $$DeviceEventsTableFilterComposer,
    $$DeviceEventsTableOrderingComposer,
    $$DeviceEventsTableAnnotationComposer,
    $$DeviceEventsTableCreateCompanionBuilder,
    $$DeviceEventsTableUpdateCompanionBuilder,
    (
      DeviceEvent,
      BaseReferences<_$AppDatabase, $DeviceEventsTable, DeviceEvent>
    ),
    DeviceEvent,
    PrefetchHooks Function()>;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$SerialPacketsTableTableManager get serialPackets =>
      $$SerialPacketsTableTableManager(_db, _db.serialPackets);
  $$DeviceMetadataTableTableManager get deviceMetadata =>
      $$DeviceMetadataTableTableManager(_db, _db.deviceMetadata);
  $$AuditEventsTableTableManager get auditEvents =>
      $$AuditEventsTableTableManager(_db, _db.auditEvents);
  $$MeshDevicesTableTableManager get meshDevices =>
      $$MeshDevicesTableTableManager(_db, _db.meshDevices);
  $$DeviceEventsTableTableManager get deviceEvents =>
      $$DeviceEventsTableTableManager(_db, _db.deviceEvents);
}
