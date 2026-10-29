import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

/// SAFR v3.8 (protocol §14.1 / §14.2): the label tables, their commands,
/// a unit's ids in DEVICE_TABLE format 2, and the reserved zone slot.
void main() {
  group('LABEL_TABLE (0x16, §14.2)', () {
    test('page layout: KIND ‖ PAGE ‖ PAGE_COUNT ‖ TOTAL ‖ REV ‖ COUNT ‖ entries',
        () {
      final bytes = SafrLabelTablePayload.build(
        kind: SafrLabelKind.zone,
        page: 1,
        pageCount: 1,
        total: 2,
        rev: 0x0102,
        labels: const [
          SafrLabel(id: 1, name: 'Portões'),
          SafrLabel(id: 7, name: '1º andar'),
        ],
      );
      expect(bytes.sublist(0, 8), [1, 1, 1, 0, 2, 0x01, 0x02, 2]);
      expect(bytes[8], 0);
      expect(bytes[9], 1);
      expect(bytes[10], 8, reason: '"Portões" is 8 bytes of UTF-8');
      final back = SafrLabelTablePayload.parse(bytes)!;
      expect(back.kind, SafrLabelKind.zone);
      expect(back.rev, 0x0102);
      expect(back.total, 2);
      expect(back.isLastPage, isTrue);
      expect(back.labels, const [
        SafrLabel(id: 1, name: 'Portões'),
        SafrLabel(id: 7, name: '1º andar'),
      ]);
    });

    test('an empty table is one page of nothing; a bad kind is rejected', () {
      final empty = SafrLabelTablePayload.parse(
          Uint8List.fromList([2, 1, 1, 0, 0, 0, 0, 0]))!;
      expect(empty.kind, SafrLabelKind.address);
      expect(empty.labels, isEmpty);
      expect(SafrLabelTablePayload.parse(
              Uint8List.fromList([3, 1, 1, 0, 0, 0, 0, 0])),
          isNull);
      expect(SafrLabelTablePayload.parse(
              Uint8List.fromList([1, 1, 1, 0, 1, 0, 0, 1, 0, 1, 40])),
          isNull,
          reason: 'a name longer than 32 bytes');
    });
  });

  group('SET_LABEL / DEL_LABEL / SET_DEVICE_IDS args (§7.6)', () {
    test('SET_LABEL: KIND ‖ ID ‖ NAME_LEN ‖ NAME', () {
      final a = SafrSetLabelArgs.build(
          kind: SafrLabelKind.address, id: 5, name: 'Sala');
      expect(a, [2, 0, 5, 4, 0x53, 0x61, 0x6C, 0x61]);
      final back = SafrSetLabelArgs.parse(a)!;
      expect(back.kind, SafrLabelKind.address);
      expect(back.id, 5);
      expect(back.name, 'Sala');
      expect(SafrSetLabelArgs.parse(Uint8List.fromList([1, 0, 0, 1, 0x78])),
          isNull,
          reason: 'id 0 is "none", never a label');
      expect(
          () => SafrSetLabelArgs.build(
              kind: SafrLabelKind.zone, id: 1, name: 'x' * 33),
          throwsArgumentError);
    });

    test('DEL_LABEL: KIND ‖ ID', () {
      final d = SafrDelLabelArgs.build(kind: SafrLabelKind.zone, id: 0x0100);
      expect(d, [1, 1, 0]);
      expect(SafrDelLabelArgs.parse(d), (kind: SafrLabelKind.zone, id: 0x0100));
      expect(SafrDelLabelArgs.parse(Uint8List.fromList([1, 0, 0])), isNull);
    });

    test('SET_DEVICE_IDS: MAC ‖ ZONE_ID ‖ ADDRESS_ID, board-only', () {
      final a = SafrSetDeviceIdsArgs.build(
          mac: '80:45:6B:72:E3:30', zoneId: 2, addressId: 0);
      expect(a, [0x80, 0x45, 0x6B, 0x72, 0xE3, 0x30, 0, 2, 0, 0]);
      final back = SafrSetDeviceIdsArgs.parse(a)!;
      expect(back.mac, '80:45:6B:72:E3:30');
      expect(back.zoneId, 2);
      expect(back.addressId, 0);
      expect(SafrCommand.setDeviceIds.isBoardOnly, isTrue);
      expect(SafrCommand.setLabel.isBoardOnly, isTrue);
      expect(SafrCommand.delLabel.isBoardOnly, isTrue);
      expect(SafrCommand.getLabels.isBoardOnly, isTrue);
    });

    test('ACK DETAIL 0x07 / 0x08 have words', () {
      expect(SafrAckDetail.fromWire(0x07), SafrAckDetail.unknownId);
      expect(SafrAckDetail.fromWire(0x08), SafrAckDetail.inUse);
      expect(SafrAckDetail.inUse.label, isNotEmpty);
    });
  });

  group('DEVICE_TABLE format 2 (§7.12)', () {
    const a = SafrDeviceTableEntry(
      mac: '5A:46:52:00:00:02',
      role: SafrNodeRole.node,
      state: SafrDeviceState.online,
      flags: SafrDeviceFlags.seenEver,
      lastSeenAgeS: 5,
      name: 'Sirene 1',
      productCode: 0x0201,
      hwRev: 3,
      fwVersion: '0.4.0',
      zoneId: 2,
      addressId: 7,
      linkKind: safrLinkIsland,
    );

    test('COUNT bit 6: every entry ends with ZONE_ID ‖ ADDRESS_ID ‖ LINK', () {
      final bytes = SafrDeviceTablePayload.build(
        page: 1,
        pageCount: 1,
        total: 1,
        entries: const [a],
        productFields: true,
        labelFields: true,
      );
      expect(bytes[4], 0xC0 | 1);
      expect(bytes.sublist(bytes.length - 5), [0, 2, 0, 7, 1]);
      final back = SafrDeviceTablePayload.parse(bytes)!;
      expect(back.hasProductFields, isTrue);
      expect(back.hasLabelFields, isTrue);
      final e = back.entries.single;
      expect(e.zoneId, 2);
      expect(e.addressId, 7);
      expect(e.linkKind, safrLinkIsland);
      expect(e.fwVersion, '0.4.0');
    });

    test('a v3.5 page reads ids as 0 and link as mesh', () {
      final bytes = SafrDeviceTablePayload.build(
          page: 1, pageCount: 1, total: 1, entries: const [a], productFields: true);
      final e = SafrDeviceTablePayload.parse(bytes)!.entries.single;
      expect(e.zoneId, 0);
      expect(e.addressId, 0);
      expect(e.linkKind, safrLinkMesh);
    });

    test('the reserved zone slot is sent empty and skipped on receive', () {
      final bytes = SafrDeviceTablePayload.build(
          page: 1, pageCount: 1, total: 1, entries: const [a]);
      // MAC 6 + role, state, flags 3 + age 2 + name (1 + 8) + zone_len.
      expect(bytes[5 + 6 + 3 + 2 + 1 + 8], 0);
      // A pre-v3.8 board that still puts a string there is parsed the same.
      final legacy = Uint8List.fromList([
        ...bytes.sublist(0, 5 + 6 + 3 + 2 + 1 + 8),
        1, 0x54,
      ]);
      expect(SafrDeviceTablePayload.parse(legacy)!.entries.single.name,
          'Sirene 1');
    });

    test('format byte of GET_DEVICE_TABLE defaults to 2', () {
      expect(SafrGetDeviceTableArgs.build(), [0, 2]);
      expect(SafrGetDeviceTableArgs.parse(Uint8List.fromList([0, 2])),
          (page: 0, format: 2));
    });
  });
}
