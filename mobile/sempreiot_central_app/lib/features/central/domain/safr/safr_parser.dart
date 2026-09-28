import 'dart:typed_data';

import '../safr_frame.dart' as v1;
import 'safr_v2_frame.dart';

/// Version-dispatching facade: stored packets may be v1 (old captures in the
/// Drift DB), v2 (pre-compliance protocol, decode-only) or v3 (current).
/// UI and ingest go through here so all render correctly.
sealed class SafrParseResult {
  const SafrParseResult();
}

class SafrV1Result extends SafrParseResult {
  const SafrV1Result(this.frame);
  final v1.SafrFrame frame;
}

/// A v2 or v3 frame — check `frame.ver`.
class SafrWireResult extends SafrParseResult {
  const SafrWireResult(this.frame);
  final SafrWireFrame frame;
}

class SafrInvalidResult extends SafrParseResult {
  const SafrInvalidResult(this.message);
  final String message;
}

SafrParseResult parseSafr(
  Uint8List bytes, {
  Uint8List? key,
  int? expectedSystemId,
}) {
  if (bytes.length < 2 || bytes[0] != safrSof) {
    return const SafrInvalidResult('Not a SAFR frame (bad SOF)');
  }
  return switch (bytes[1]) {
    safrVer3 || safrVer2 => SafrWireResult(parseSafrWireFrame(
        bytes,
        key: key,
        expectedSystemId: expectedSystemId,
      )),
    safrVer1 => SafrV1Result(v1.parseSafrFrame(bytes)),
    _ => SafrInvalidResult(
        'Unsupported SAFR version 0x${bytes[1].toRadixString(16)}'),
  };
}
