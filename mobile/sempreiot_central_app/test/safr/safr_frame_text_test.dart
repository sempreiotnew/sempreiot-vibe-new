import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_frame.dart';
import 'package:sempreiot_central_app/features/central/domain/safr/safr_v2_payloads.dart';
import 'package:sempreiot_central_app/features/central/presentation/widgets/safr_frame_text.dart';

// The Logs seriais console names frames as docs/safr/protocol-safr-v3.md
// writes them (§7 MSG_TYPE table, §7.6 COMMAND table, §13).
void main() {
  test('MSG_TYPE names follow the protocol', () {
    expect(safrMsgTypeName(SafrMsgType.eventLogData, 0x08), 'EVENT_LOG_DATA');
    expect(safrMsgTypeName(SafrMsgType.deviceTable, 0x0B), 'DEVICE_TABLE');
    expect(safrMsgTypeName(SafrMsgType.otaPushResult, 0x12), 'OTA_PUSH_RESULT');
    expect(safrMsgTypeName(SafrMsgType.unknown, 0x2A), 'MSG_TYPE 0x2A');
  });

  test('COMMAND names follow the protocol', () {
    expect(safrCommandName(0x00), 'LINK_CHECK');
    expect(safrCommandName(0x12), 'SET_DEVICE');
    expect(safrCommandName(0x19), 'GET_CODE');
    expect(safrCommandName(0x1D), 'OTA_CONTROL');
    expect(safrCommandName(0x7E), 'CMD 0x7E');
  });

  test('every known MSG_TYPE has a console group other than errors', () {
    for (final t in SafrMsgType.values) {
      if (t == SafrMsgType.unknown) continue;
      expect(safrLogGroup(t), isNot(SafrLogGroup.errors), reason: t.name);
    }
  });

  test('event codes read as the protocol names them', () {
    expect(safrEventCodeName(SafrEventCode.smokeAlarm, 0x01), 'SMOKE_ALARM');
    expect(safrEventCodeName(SafrEventCode.acLost, 0x0A), 'AC_LOST');
    expect(safrEventCodeName(SafrEventCode.unknown, 0x33), 'CODE 0x33');
  });
}
