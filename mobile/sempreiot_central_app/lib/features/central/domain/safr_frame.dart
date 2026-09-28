import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

// ── SAFR constants (must match ESP32 firmware) ───────────────────

const _sof = 0xA5;
const _aadLen = 21;
const _nonceWireLen = 4;
const _nonceMbedLen = 7; // mbedTLS pads to 7 bytes
const _tagLen = 16;

// Header FLAGS byte
const _fSensors = 0x01;
const _fFault = 0x02;
const _fEnc = 0x04;

// Event types
const _evtOk = 0x01;
const _evtAlert = 0x02;
const _evtAlarm = 0x03;
const _evtTrouble = 0x04;

// Power flags
const _pwrAcOk = 0x01;
const _pwrBoost = 0x02;
const _pwrChg = 0x04;
const _pwrTamper = 0x08;

// Fault flags
const _fltSmoke = 0x01;
const _fltTemp = 0x02;
const _fltBatt = 0x04;

// Pre-shared key (AES-128) — must match firmware PSK[]
final _psk = Uint8List.fromList(const [
  0x2B,
  0x7E,
  0x15,
  0x16,
  0x28,
  0xAE,
  0xD2,
  0xA6,
  0xAB,
  0xF7,
  0x15,
  0x88,
  0x09,
  0xCF,
  0x4F,
  0x3C,
]);

// ── Domain types ─────────────────────────────────────────────────

enum SafrEvent { ok, alert, alarm, trouble, unknown }

class SafrPayload {
  const SafrPayload({
    required this.event,
    required this.eventRaw,
    required this.timestamp,
    required this.pwrAcOk,
    required this.pwrBoost,
    required this.pwrCharging,
    required this.pwrTamper,
    required this.batteryRaw,
    this.smokeRaw,
    this.tempTenths,
    this.humidity,
    this.faultSmoke,
    this.faultTemp,
    this.faultBatt,
    this.faultCode,
    required this.meshFlagsRaw,
    required this.rssiDbm,
    required this.parentMac,
    required this.childCount,
    required this.children,
  });

  final SafrEvent event;
  final int eventRaw;
  final DateTime timestamp;
  final bool pwrAcOk;
  final bool pwrBoost;
  final bool pwrCharging;
  final bool pwrTamper;
  final int batteryRaw; // raw 8-bit ADC value (range ~140–168)

  // Present when F_SENSORS
  final int? smokeRaw; // ADU
  final int? tempTenths; // °C × 10 (e.g. 325 = 32.5 °C)
  final int? humidity; // %

  // Present when F_FAULT
  final bool? faultSmoke;
  final bool? faultTemp;
  final bool? faultBatt;
  final int? faultCode;

  // Mesh
  final int meshFlagsRaw;
  final int rssiDbm;
  final String parentMac;
  final int childCount;
  final List<String> children;
}

class SafrFrame {
  const SafrFrame({
    required this.validSof,
    required this.version,
    required this.totalLengthField,
    required this.actualLength,
    required this.msgId,
    required this.srcMac,
    required this.dstMac,
    required this.ttl,
    required this.hops,
    required this.hasSensors,
    required this.hasFault,
    required this.isEncrypted,
    required this.nonceHex,
    required this.ptLen,
    required this.decryptionAttempted,
    required this.decryptionSuccess,
    this.payload,
    this.parseError,
  });

  final bool validSof;
  final int version;
  final int totalLengthField; // LEN field from header
  final int actualLength; // bytes.length
  final int msgId;
  final String srcMac;
  final String dstMac;
  final int ttl;
  final int hops;
  final bool hasSensors;
  final bool hasFault;
  final bool isEncrypted;
  final String nonceHex; // 4 wire bytes as hex string
  final int ptLen;
  final bool decryptionAttempted;
  final bool decryptionSuccess;
  final SafrPayload? payload;
  final String? parseError;

  bool get isDstBroadcast => dstMac == 'FF:FF:FF:FF:FF:FF';
}

// ── Parser ────────────────────────────────────────────────────────

SafrFrame parseSafrFrame(Uint8List bytes) {
  const minLen = _aadLen + _nonceWireLen + _tagLen + 1;
  if (bytes.length < minLen) {
    return SafrFrame(
      validSof: false,
      version: 0,
      totalLengthField: 0,
      actualLength: bytes.length,
      msgId: 0,
      srcMac: '',
      dstMac: '',
      ttl: 0,
      hops: 0,
      hasSensors: false,
      hasFault: false,
      isEncrypted: false,
      nonceHex: '',
      ptLen: 0,
      decryptionAttempted: false,
      decryptionSuccess: false,
      parseError: 'Frame too short (${bytes.length} bytes, min $minLen)',
    );
  }

  if (bytes[0] != _sof) {
    return SafrFrame(
      validSof: false,
      version: 0,
      totalLengthField: 0,
      actualLength: bytes.length,
      msgId: 0,
      srcMac: '',
      dstMac: '',
      ttl: 0,
      hops: 0,
      hasSensors: false,
      hasFault: false,
      isEncrypted: false,
      nonceHex: '',
      ptLen: 0,
      decryptionAttempted: false,
      decryptionSuccess: false,
      parseError:
          'Invalid SOF byte: 0x${bytes[0].toRadixString(16).padLeft(2, '0')} (expected 0xA5)',
    );
  }

  final version = bytes[1];
  final totalLenField = (bytes[2] << 8) | bytes[3];
  final msgId = (bytes[4] << 8) | bytes[5];
  final srcMac = _macStr(bytes.sublist(6, 12));
  final dstMac = _macStr(bytes.sublist(12, 18));
  final ttl = bytes[18];
  final hops = bytes[19];
  final flags = bytes[20];

  final hasSensors = (flags & _fSensors) != 0;
  final hasFault = (flags & _fFault) != 0;
  final isEncrypted = (flags & _fEnc) != 0;

  final nonceBytes = bytes.sublist(21, 25);
  final nonceHex = nonceBytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');

  final ptLen = bytes.length - _aadLen - _nonceWireLen - _tagLen;

  SafrPayload? payload;
  bool decryptionAttempted = false;
  bool decryptionSuccess = false;

  if (ptLen > 0) {
    if (isEncrypted) {
      decryptionAttempted = true;
      final plain = _decryptCcm(bytes, ptLen);
      if (plain != null) {
        decryptionSuccess = true;
        payload = _parsePayload(plain, hasSensors, hasFault);
      }
    } else {
      final plain = bytes.sublist(25, 25 + ptLen);
      payload = _parsePayload(plain, hasSensors, hasFault);
      decryptionSuccess = true;
    }
  }

  return SafrFrame(
    validSof: true,
    version: version,
    totalLengthField: totalLenField,
    actualLength: bytes.length,
    msgId: msgId,
    srcMac: srcMac,
    dstMac: dstMac,
    ttl: ttl,
    hops: hops,
    hasSensors: hasSensors,
    hasFault: hasFault,
    isEncrypted: isEncrypted,
    nonceHex: nonceHex,
    ptLen: ptLen,
    decryptionAttempted: decryptionAttempted,
    decryptionSuccess: decryptionSuccess,
    payload: payload,
  );
}

// ── AES-128-CCM decryption ────────────────────────────────────────

Uint8List? _decryptCcm(Uint8List frame, int ptLen) {
  try {
    // 7-byte nonce: wire 4 bytes + 3 zero bytes (matches mbedTLS behaviour)
    final nonce = Uint8List(_nonceMbedLen);
    nonce.setRange(0, _nonceWireLen, frame.sublist(21, 25));

    final aad = frame.sublist(0, _aadLen);

    // pointycastle CCM expects ciphertext || tag
    final cipherWithTag = Uint8List(ptLen + _tagLen);
    cipherWithTag.setRange(0, ptLen, frame.sublist(25, 25 + ptLen));
    cipherWithTag.setRange(ptLen, ptLen + _tagLen,
        frame.sublist(25 + ptLen, 25 + ptLen + _tagLen));

    final params = AEADParameters(
      KeyParameter(_psk),
      _tagLen * 8, // tag length in bits
      nonce,
      aad,
    );

    final ccm = CCMBlockCipher(AESEngine())..init(false, params);
    final outLen = ccm.getOutputSize(cipherWithTag.length);
    final out = Uint8List(outLen);
    var len = ccm.processBytes(cipherWithTag, 0, cipherWithTag.length, out, 0);
    len += ccm.doFinal(out, len);
    return out.sublist(0, len);
  } catch (e, st) {
    debugPrint('[SAFR] decrypt failed: $e\n$st');
    return null;
  }
}

// ── Payload parser ────────────────────────────────────────────────

SafrPayload? _parsePayload(Uint8List p, bool hasSensors, bool hasFault) {
  if (p.length < 7) return null;

  int o = 0;
  final evtRaw = p[o++];
  final tsRaw = (p[o] << 24) | (p[o + 1] << 16) | (p[o + 2] << 8) | p[o + 3];
  o += 4;
  final pwr = p[o++];
  final battRaw = p[o++];

  int? smokeRaw, tempTenths, humidity;
  if (hasSensors) {
    if (o + 4 >= p.length) return null;
    smokeRaw = (p[o] << 8) | p[o + 1];
    o += 2;
    int t = (p[o] << 8) | p[o + 1];
    if (t >= 0x8000) t -= 0x10000; // sign-extend int16
    tempTenths = t;
    o += 2;
    humidity = p[o++];
  }

  bool? fltSmoke, fltTemp, fltBatt;
  int? faultCode;
  if (hasFault) {
    if (o + 1 >= p.length) return null;
    final ff = p[o++];
    faultCode = p[o++];
    fltSmoke = (ff & _fltSmoke) != 0;
    fltTemp = (ff & _fltTemp) != 0;
    fltBatt = (ff & _fltBatt) != 0;
  }

  if (o + 8 >= p.length) return null; // need 9 more bytes minimum
  final meshFlags = p[o++];
  final rssiRaw = p[o++];
  final rssiDbm = rssiRaw - 128;

  final parentMac = _macStr(p.sublist(o, o + 6));
  o += 6;
  final childCount = p[o++];
  final children = <String>[];
  for (var i = 0; i < childCount && o + 5 < p.length; i++) {
    children.add(_macStr(p.sublist(o, o + 6)));
    o += 6;
  }

  return SafrPayload(
    event: _toEvent(evtRaw),
    eventRaw: evtRaw,
    timestamp: DateTime.fromMillisecondsSinceEpoch(tsRaw * 1000, isUtc: true),
    pwrAcOk: (pwr & _pwrAcOk) != 0,
    pwrBoost: (pwr & _pwrBoost) != 0,
    pwrCharging: (pwr & _pwrChg) != 0,
    pwrTamper: (pwr & _pwrTamper) != 0,
    batteryRaw: battRaw,
    smokeRaw: smokeRaw,
    tempTenths: tempTenths,
    humidity: humidity,
    faultSmoke: fltSmoke,
    faultTemp: fltTemp,
    faultBatt: fltBatt,
    faultCode: faultCode,
    meshFlagsRaw: meshFlags,
    rssiDbm: rssiDbm,
    parentMac: parentMac,
    childCount: childCount,
    children: children,
  );
}

// ── Helpers ───────────────────────────────────────────────────────

String _macStr(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');

SafrEvent _toEvent(int raw) => switch (raw) {
      _evtOk => SafrEvent.ok,
      _evtAlert => SafrEvent.alert,
      _evtAlarm => SafrEvent.alarm,
      _evtTrouble => SafrEvent.trouble,
      _ => SafrEvent.unknown,
    };
