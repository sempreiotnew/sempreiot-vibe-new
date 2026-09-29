import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_product.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

/// SAFR v3.5: product code, hardware revision and firmware version on the
/// wire (NAME_ANNOUNCE §7.11, DEVICE_TABLE §7.12, GET_DEVICE_TABLE 0x18).
void main() {
  group('product catalogue', () {
    test('known codes: model, family and pt-BR label', () {
      final siren = SafrProduct.fromCode(0x0201)!;
      expect(siren.isKnown, isTrue);
      expect(siren.model, 'SIOT-SIREN-01');
      expect(siren.label, 'Sirene');
      expect(siren.family, SafrProductFamily.node);
      expect(siren.display, 'Sirene · SIOT-SIREN-01');

      final board = SafrProduct.fromCode(0x0100)!;
      expect(board.model, 'SIOT-BOARD-01');
      expect(board.family, SafrProductFamily.board);
      expect(board.label, 'Central (placa)');

      final smoke = SafrProduct.fromCode(0x0301)!;
      expect(smoke.model, 'SIOT-SMOKE-01');
      expect(smoke.family, SafrProductFamily.leaf);
      expect(smoke.label, 'Detector de fumaça (bateria)');
    });

    test('the whole catalogue, code by code (a contract: never renumbered)',
        () {
      const expected = {
        0x0100: 'SIOT-BOARD-01',
        0x0201: 'SIOT-SIREN-01',
        0x0202: 'SIOT-PBS-01',
        0x0203: 'SIOT-IO-01',
        0x0204: 'SIOT-REPEATER-01',
        0x0205: 'SIOT-SMOKE-AC-01',
        0x02FF: 'SIOT-NODE-01',
        0x0301: 'SIOT-SMOKE-01',
        0x0302: 'SIOT-HEAT-01',
        0x03FF: 'SIOT-LEAF-01',
      };
      expect(
        {for (final p in SafrProduct.catalogue) p.code: p.model},
        expected,
      );
      for (final p in SafrProduct.catalogue) {
        expect(SafrProduct.fromCode(p.code), p);
        expect(p.family.wire, p.code >> 8);
        expect(p.label, isNotEmpty);
      }
    });

    test('unknown code is kept and shown, family from the high byte', () {
      final p = SafrProduct.fromCode(0x0206)!;
      expect(p.isKnown, isFalse);
      expect(p.code, 0x0206);
      expect(p.model, isNull);
      expect(p.label, 'Produto desconhecido 0x0206');
      expect(p.family, SafrProductFamily.node);
      expect(p.display, 'Produto desconhecido 0x0206 · rede elétrica');

      final alien = SafrProduct.fromCode(0x7A01)!;
      expect(alien.family, SafrProductFamily.unknown);
      expect(alien.label, 'Produto desconhecido 0x7A01');
      expect(alien.display, 'Produto desconhecido 0x7A01');

      // High byte 0x00 with a non-zero low byte is not a family either.
      expect(SafrProduct.fromCode(0x0001)!.family, SafrProductFamily.unknown);
    });

    test('0x0000 and null = not reported', () {
      expect(SafrProduct.fromCode(0), isNull);
      expect(SafrProduct.fromCode(null), isNull);
    });
  });

  group('NAME_ANNOUNCE (spec §7.11)', () {
    test('with the v3.5 extension', () {
      final bytes = SafrNameAnnouncePayload.build(
        name: 'Sirene 1',
        zone: 'Térreo',
        role: SafrNodeRole.node,
        productCode: 0x0201,
        hwRev: 2,
        fwVersion: '0.1.0-dev',
      );
      // The extension sits right after ROLE, big-endian.
      final ext = bytes.sublist(bytes.length - (4 + 9));
      expect(ext.sublist(0, 4), [0x02, 0x01, 0x02, 9]);
      expect(String.fromCharCodes(ext.sublist(4)), '0.1.0-dev');

      final p = SafrNameAnnouncePayload.parse(bytes)!;
      expect(p.name, 'Sirene 1');
      expect(p.zone, 'Térreo');
      expect(p.role, SafrNodeRole.node);
      expect(p.hasProductFields, isTrue);
      expect(p.productCode, 0x0201);
      expect(p.hwRev, 2);
      expect(p.fwVersion, '0.1.0-dev');
    });

    test('without it (v3.2 with ROLE, v3.1 without ROLE)', () {
      final v32 = SafrNameAnnouncePayload.parse(SafrNameAnnouncePayload.build(
          name: 'Sirene', zone: 'T', role: SafrNodeRole.leaf))!;
      expect(v32.role, SafrNodeRole.leaf);
      expect(v32.hasProductFields, isFalse);
      expect(v32.productCode, isNull);
      expect(v32.hwRev, isNull);
      expect(v32.fwVersion, isNull);

      final v31 = SafrNameAnnouncePayload.parse(
          SafrNameAnnouncePayload.build(name: 'Sirene', zone: 'T'))!;
      expect(v31.name, 'Sirene');
      expect(v31.role, SafrNodeRole.unknown);
      expect(v31.productCode, isNull);
      expect(v31.fwVersion, isNull);
    });

    test('extension with nothing stated: product 0, hw 0, empty version', () {
      final p = SafrNameAnnouncePayload.parse(SafrNameAnnouncePayload.build(
          name: 'X', zone: '', role: SafrNodeRole.node, productCode: 0))!;
      expect(p.hasProductFields, isTrue);
      expect(p.productCode, 0);
      expect(p.hwRev, 0);
      expect(p.fwVersion, '');
    });

    test('truncated extension is ignored, name/zone/role still accepted', () {
      final full = SafrNameAnnouncePayload.build(
        name: 'Sirene 1',
        zone: 'Térreo',
        role: SafrNodeRole.node,
        productCode: 0x0201,
        hwRev: 2,
        fwVersion: '0.1.0-dev',
      );
      const extLen = 4 + 9;
      // Every cut inside the extension: 1..12 of its 13 bytes present.
      for (var keep = 1; keep < extLen; keep++) {
        final cut = Uint8List.sublistView(
            full, 0, full.length - extLen + keep);
        final p = SafrNameAnnouncePayload.parse(cut);
        expect(p, isNotNull, reason: 'keep=$keep');
        expect(p!.name, 'Sirene 1', reason: 'keep=$keep');
        expect(p.zone, 'Térreo', reason: 'keep=$keep');
        expect(p.role, SafrNodeRole.node, reason: 'keep=$keep');
        expect(p.productCode, isNull, reason: 'keep=$keep');
        expect(p.hwRev, isNull, reason: 'keep=$keep');
        expect(p.fwVersion, isNull, reason: 'keep=$keep');
      }
    });

    test('FW_LEN > 24 is ignored, name/zone/role still accepted', () {
      final head = SafrNameAnnouncePayload.build(
          name: 'Sirene', zone: 'T', role: SafrNodeRole.node);
      final bad = Uint8List.fromList([
        ...head,
        0x02, 0x01, 0x01, 25, // FW_LEN 25
        ...List.filled(25, 0x31),
      ]);
      final p = SafrNameAnnouncePayload.parse(bad)!;
      expect(p.name, 'Sirene');
      expect(p.role, SafrNodeRole.node);
      expect(p.productCode, isNull);
      expect(p.fwVersion, isNull);
    });

    test('FW_LEN of exactly 24 is accepted; bytes after FW are tolerated', () {
      const v24 = '1.22.333-rc.4+abcdef0123'; // 24 chars
      expect(v24.length, 24);
      final bytes = SafrNameAnnouncePayload.build(
        name: 'Sirene',
        zone: 'T',
        role: SafrNodeRole.node,
        productCode: 0x0205,
        hwRev: 1,
        fwVersion: v24,
      );
      expect(SafrNameAnnouncePayload.parse(bytes)!.fwVersion, v24);
      // A later revision may append more: still readable.
      final longer = Uint8List.fromList([...bytes, 0xAA, 0xBB]);
      final p = SafrNameAnnouncePayload.parse(longer)!;
      expect(p.productCode, 0x0205);
      expect(p.fwVersion, v24);

      expect(
        () => SafrNameAnnouncePayload.build(
            name: 'S',
            zone: '',
            role: SafrNodeRole.node,
            productCode: 0x0201,
            fwVersion: '${v24}x'),
        throwsArgumentError,
      );
    });

    test('non-printable bytes in FW never reach the screen', () {
      final head = SafrNameAnnouncePayload.build(
          name: 'S', zone: '', role: SafrNodeRole.node);
      final p = SafrNameAnnouncePayload.parse(Uint8List.fromList([
        ...head,
        0x02, 0x01, 0x00, 6,
        0x31, 0x2E, 0x07, 0xC3, 0x00, 0x39, // "1." BEL 0xC3 NUL "9"
      ]))!;
      expect(p.productCode, 0x0201);
      expect(p.fwVersion, '1.??');
    });
  });

  group('DEVICE_TABLE (spec §7.12)', () {
    const a = SafrDeviceTableEntry(
      mac: '5A:46:52:00:00:02',
      role: SafrNodeRole.node,
      state: SafrDeviceState.online,
      flags: SafrDeviceFlags.seenEver,
      lastSeenAgeS: 5,
      name: 'Sirene 1',
      zone: 'Térreo',
      productCode: 0x0201,
      hwRev: 3,
      fwVersion: '0.1.0-dev',
    );
    const b = SafrDeviceTableEntry(
      mac: '5A:46:52:00:00:03',
      role: SafrNodeRole.leaf,
      state: SafrDeviceState.expected,
      flags: 0,
      lastSeenAgeS: null,
      name: 'Detector 2',
      zone: '1º andar',
      // the board does not know yet
    );

    test('bit 7 set: entries carry product, hw revision and version', () {
      final bytes = SafrDeviceTablePayload.build(
          page: 1,
          pageCount: 2,
          total: 41,
          entries: const [a, b],
          productFields: true);
      expect(bytes[4], 0x80 | 2);

      final back = SafrDeviceTablePayload.parse(bytes)!;
      expect(back.hasProductFields, isTrue);
      expect(back.page, 1);
      expect(back.pageCount, 2);
      expect(back.total, 41);
      expect(back.entries, hasLength(2));
      final ea = back.entries[0];
      expect(ea.mac, a.mac);
      expect(ea.name, 'Sirene 1');
      expect(ea.zone, 'Térreo');
      expect(ea.productCode, 0x0201);
      expect(ea.hwRev, 3);
      expect(ea.fwVersion, '0.1.0-dev');
      final eb = back.entries[1];
      expect(eb.mac, b.mac);
      expect(eb.role, SafrNodeRole.leaf);
      expect(eb.lastSeenAgeS, isNull);
      expect(eb.name, 'Detector 2');
      expect(eb.productCode, 0);
      expect(eb.hwRev, 0);
      expect(eb.fwVersion, '');
    });

    test('bit 7 clear: exactly the v3.2 layout', () {
      final bytes = SafrDeviceTablePayload.build(
          page: 1, pageCount: 1, total: 2, entries: const [a, b]);
      expect(bytes[4], 2);
      // v3.2 entry = 6 + 1 + 1 + 1 + 2 + (1+len) + (1+len), nothing else.
      final v35 = SafrDeviceTablePayload.build(
          page: 1,
          pageCount: 1,
          total: 2,
          entries: const [a, b],
          productFields: true);
      expect(v35.length - bytes.length, (4 + 9) + 4);

      final back = SafrDeviceTablePayload.parse(bytes)!;
      expect(back.hasProductFields, isFalse);
      expect(back.entries, hasLength(2));
      expect(back.entries[0].name, 'Sirene 1');
      expect(back.entries[0].productCode, 0);
      expect(back.entries[0].fwVersion, '');
      expect(back.entries[1].zone, '1º andar');
    });

    test('an empty v3.5 page (COUNT = 0x80)', () {
      final back = SafrDeviceTablePayload.parse(
          Uint8List.fromList([1, 1, 0, 0, 0x80]))!;
      expect(back.hasProductFields, isTrue);
      expect(back.entries, isEmpty);
    });

    test('truncated or oversized product fields reject the page', () {
      final bytes = SafrDeviceTablePayload.build(
          page: 1,
          pageCount: 1,
          total: 1,
          entries: const [a],
          productFields: true);
      expect(
          SafrDeviceTablePayload.parse(
              Uint8List.sublistView(bytes, 0, bytes.length - 3)),
          isNull);
      final bad = Uint8List.fromList(bytes);
      bad[bytes.length - 9 - 1] = 25; // FW_LEN
      expect(SafrDeviceTablePayload.parse(bad), isNull);
    });
  });

  group('GET_DEVICE_TABLE args (CMD 0x18)', () {
    test('always page + format 1', () {
      expect(SafrGetDeviceTableArgs.build(), [0, 1]);
      expect(SafrGetDeviceTableArgs.build(page: 3), [3, 1]);
      final cmd = SafrCommandPayload.build(
          cmd: SafrCommand.getDeviceTable,
          args: SafrGetDeviceTableArgs.build());
      expect(cmd, [0x18, 2, 0, 1]);
    });

    test('a request without the format byte reads as the v3.2 layout', () {
      expect(SafrGetDeviceTableArgs.parse(Uint8List.fromList([2])),
          (page: 2, format: 0));
      expect(SafrGetDeviceTableArgs.parse(Uint8List.fromList([0, 1])),
          (page: 0, format: 1));
      expect(SafrGetDeviceTableArgs.parse(Uint8List(0)), isNull);
    });
  });
}
