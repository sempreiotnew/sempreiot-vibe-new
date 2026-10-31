import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

/// A unit cuts a name at its byte slot (32 bytes NAME, 16 bytes ADDRESS,
/// protocol §7.11). Firmware before 2026-10-31 cut inside an accented letter,
/// and the tablet refused the whole frame — the leaf then showed up as a bare
/// MAC, and the DEVICE_TABLE page carrying it was dropped with it. Decoding is
/// lenient now: the bad byte reads as U+FFFD and everything else survives.
void main() {
  // "Sensor escritório administração" is 34 bytes; cut at 32 it ends inside
  // the "ã" (0xC3 0xA3): byte 32 is 0xC3 with no continuation.
  final cut = Uint8List.fromList(
      utf8.encode('Sensor escritório administração').sublist(0, 32));

  test('a name cut inside an accent no longer kills NAME_ANNOUNCE', () {
    expect(cut.length, 32);
    expect(cut.last, 0xC3); // the orphaned lead byte
    final bytes = Uint8List.fromList([
      cut.length,
      ...cut,
      3,
      ...utf8.encode('1ºa').sublist(0, 3), // an endereçamento cut the same way
      SafrNodeRole.leaf.wire,
    ]);
    final p = SafrNameAnnouncePayload.parse(bytes);
    expect(p, isNotNull);
    expect(p!.name, startsWith('Sensor escritório administra'));
    expect(p.name, endsWith('�'));
    expect(p.role, SafrNodeRole.leaf);
  });

  test('a cut name in one entry no longer drops the DEVICE_TABLE page', () {
    // Build the page with a 32-byte placeholder, then put the cut bytes on
    // the wire in its place, exactly as the board sends them.
    final placeholder = 'x' * 32;
    final page = SafrDeviceTablePayload.build(
      page: 1,
      pageCount: 1,
      total: 2,
      entries: [
        SafrDeviceTableEntry(
          mac: '5A:46:52:00:00:03',
          role: SafrNodeRole.leaf,
          state: SafrDeviceState.online,
          flags: SafrDeviceFlags.seenEver,
          lastSeenAgeS: 5,
          name: placeholder,
        ),
        const SafrDeviceTableEntry(
          mac: '5A:46:52:00:00:02',
          role: SafrNodeRole.node,
          state: SafrDeviceState.online,
          flags: SafrDeviceFlags.seenEver,
          lastSeenAgeS: 5,
          name: 'Sirene 1',
        ),
      ],
    );
    final raw = Uint8List.fromList(page);
    final at = _indexOf(raw, ascii.encode(placeholder));
    expect(at, greaterThan(0));
    raw.setRange(at, at + 32, cut);
    final back = SafrDeviceTablePayload.parse(raw);
    expect(back, isNotNull);
    expect(back!.entries, hasLength(2));
    expect(back.entries[0].name, endsWith('\uFFFD'));
    expect(back.entries[1].name, 'Sirene 1');
  });
}

int _indexOf(Uint8List hay, List<int> needle) {
  for (var i = 0; i + needle.length <= hay.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}
