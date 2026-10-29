import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/core/database/app_database.dart';
import 'package:sempreiot_central_app/features/central/application/central_installation_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_downlink_provider.dart';
import 'package:sempreiot_central_app/features/central/application/safr_ingest_provider.dart';
import 'package:sempreiot_central_app/features/central/application/serial_link_provider.dart';
import 'package:sempreiot_central_app/features/central/application/serial_provider.dart';
import 'package:sempreiot_central_app/features/central/application/supervision_provider.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_encoder.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_identity.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';

import '../ota/fake_board.dart';

/// Protocol §9.1 (v3.6, 2026-10-26): a COMMAND into the mesh is retried
/// until the unit's own ACK, not the board's. The board behind the cable
/// ACKs every command at once, as the real one does; what the units say is
/// the test's to decide.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final identity = SafrIdentity(
    systemId: 0x4A17,
    key: Uint8List.fromList([for (var i = 0; i < 16; i++) 0x30 + i]),
  );
  const unit = FakeBoard.unitMac; // a powered node two hops away
  const leaf = '5A:46:52:00:00:09';

  late AppDatabase db;
  late FakeBoard board;
  late ProviderContainer container;

  Future<void> registered(String mac, SafrNodeRole role) async {
    final now = DateTime.now().toUtc();
    await db
        .into(db.meshDevices)
        .insertOnConflictUpdate(MeshDevicesCompanion.insert(
          mac: mac,
          role: Value(role.wire),
          layer: const Value(2),
          firstSeenAt: now,
          lastSeenAt: now,
        ));
    await container.read(supervisionProvider.notifier).evaluate();
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    board = FakeBoard(identity: identity);
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      serialProvider.overrideWith((ref) => board),
      safrIdentityProvider.overrideWithValue(identity),
    ]);
    container.read(safrIngestProvider); // serial → ingest → downlink
    board.plug();
    await _until(
      () => container.read(serialLinkProvider) == SerialLinkStatus.connected,
      what: 'the link to come up',
    );
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    container.dispose();
    await db.close();
  });

  int identifies() => board.commands(SafrCommand.identify);

  test('a powered unit that never answers: three transmissions, then red',
      () async {
    await registered(unit, SafrNodeRole.node);
    final downlink = container.read(safrDownlinkProvider);
    final boardTook = await downlink.sendCommand(unit, SafrCommand.identify);
    expect(boardTook, isTrue, reason: "the board's ACK answers the caller");
    expect(identifies(), 1);
    await _until(() => identifies() == 3,
        what: 'the two retries', within: const Duration(seconds: 7));
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(identifies(), 3, reason: 'no fourth: the retries are spent');
  });

  test("the unit's own ACK ends the retries", () async {
    await registered(unit, SafrNodeRole.node);
    final downlink = container.read(safrDownlinkProvider);
    await downlink.sendCommand(unit, SafrCommand.identify);
    final sent = board.heard.lastWhere((f) =>
        f.payload is SafrCommandPayload &&
        (f.payload as SafrCommandPayload).cmdRaw == SafrCommand.identify.wire);
    // The unit confirms, its ACK relayed up by the board as it is.
    final unitEnc = SafrEncoder(
      srcMac: safrMacToBytes(unit),
      bootCtr: 9,
      systemId: identity.systemId,
      key: identity.key,
    );
    board.relayUp(unitEnc.encode(
      msgType: SafrMsgType.ack,
      payload: SafrAckPayload.build(ackedMsgId: sent.msgId),
      dstMac: safrCentralMacBytes,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(identifies(), 1, reason: 'confirmed before the first retry was due');
  });

  test("a broadcast's retries go only to the units still missing (2026-10-28)",
      () async {
    const other = '5A:46:52:00:00:07';
    await registered(unit, SafrNodeRole.node);
    await registered(other, SafrNodeRole.node);
    final downlink = container.read(safrDownlinkProvider);
    await downlink.sendCommand(safrBroadcastMac, SafrCommand.test);
    List<SafrWireFrame> tests() => board.heard
        .where((f) =>
            f.payload is SafrCommandPayload &&
            (f.payload as SafrCommandPayload).cmdRaw == SafrCommand.test.wire)
        .toList();
    expect(tests(), hasLength(1));
    expect(tests().single.dstMac, safrBroadcastMac);
    // `unit` confirms; `other` never does.
    final unitEnc = SafrEncoder(
      srcMac: safrMacToBytes(unit),
      bootCtr: 9,
      systemId: identity.systemId,
      key: identity.key,
    );
    board.relayUp(unitEnc.encode(
      msgType: SafrMsgType.ack,
      payload: SafrAckPayload.build(ackedMsgId: tests().single.msgId),
      dstMac: safrCentralMacBytes,
    ));
    await _until(() => tests().length == 3,
        what: 'the two retries', within: const Duration(seconds: 7));
    final retries = tests().sublist(1);
    expect(retries.map((f) => f.dstMac), everyElement(other),
        reason: 'addressed to the unit still missing, never broadcast again');
    expect(retries.map((f) => f.msgId).toSet(), {tests().first.msgId},
        reason: 'the same MSG_ID: the unit dedupes, the tablet matches');
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(tests(), hasLength(3), reason: 'no fourth: the retries are spent');
  });

  test("a battery unit's command is not retried: the mailbox has it", () async {
    await registered(leaf, SafrNodeRole.leaf);
    final downlink = container.read(safrDownlinkProvider);
    await downlink.sendCommand(leaf, SafrCommand.identify);
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(identifies(), 1);
  });
}

Future<void> _until(
  FutureOr<bool> Function() test, {
  required String what,
  Duration within = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(within);
  while (!await test()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
