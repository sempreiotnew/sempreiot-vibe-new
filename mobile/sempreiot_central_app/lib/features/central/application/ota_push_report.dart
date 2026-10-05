import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/safr/safr_product.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'central_mirror_viewer.dart';
import 'ota_push_controller.dart';
import 'ota_push_state.dart';
import 'topology_provider.dart';

// What a firmware push means for the screens: the board's activity on the
// map, what waits on the board for a unit.
//
// What a push does (protocol §13.3): send an image to the BOARD. A board
// image is installed by the board itself. A node or leaf image is only
// STORED on the board: no device receives anything in a push. Nothing here
// may read as "the devices were updated" — that is the rollout's to say
// (§13.6, ota_rollout_report.dart).

/// The push as the screens read it. A
/// provider of its own so a widget test can hand a state over without a
/// serial port or a database behind it.
///
/// On a user's phone viewing a central: that central's push, as far as its
/// mirror tells (phase and progress — the image, steps and log stay on the
/// tablet). The phone's own push controller is never started.
final otaPushViewProvider = Provider<OtaPushState>((ref) {
  if (ref.watch(viewedCentralProvider) != null) {
    return ref.watch(centralMirrorProvider.select((v) => v.push));
  }
  return ref.watch(otaPushProvider);
});

/// `43 %`.
String otaPercentText(double progress) =>
    '${(progress.clamp(0.0, 1.0) * 100).floor()} %';

// ── Units and what waits for them on the board ──────────────────────────────

/// The firmware image a unit runs: from its product code when it reported
/// one; otherwise the board is the unit that bridges to the tablet (layer
/// 0, root), a leaf is a battery unit and everything else is mains powered.
SafrProductFamily unitFamily(TopologyNode node) {
  final code = node.productCode;
  if (code != null) {
    final family = SafrProductFamily.ofCode(code);
    if (family != SafrProductFamily.unknown) return family;
  }
  if (node.layer == 0 && node.role == SafrNodeRole.root) {
    return SafrProductFamily.board;
  }
  return node.isLeaf ? SafrProductFamily.leaf : SafrProductFamily.node;
}

/// The version of the image of [node]'s family that the board holds
/// ([storedOnBoard]: `otaHeldOnBoardProvider`) and that the unit does not
/// run; null when there is none. Stored is not delivered: the unit still
/// runs what it ran.
String? pendingFirmwareFor(
  TopologyNode node,
  Map<SafrProductFamily, String> storedOnBoard,
) {
  final stored = storedOnBoard[unitFamily(node)];
  if (stored == null || stored.isEmpty || stored == node.fwVersion) {
    return null;
  }
  return stored;
}

/// "na placa: 0.1.1 (ainda não enviado)".
String otaPendingText(String version) =>
    'na placa: $version (ainda não enviado)';

// ── The board on the Rede map while a push runs ─────────────────────────────

/// What the board is doing with the push, for the overlay on its avatar.
/// This is NOT the board's LED: it is a drawing of the tablet's own.
///
/// Two of them are equal when they read the same on screen, so a map that
/// watches this is rebuilt once per percent, not once per chunk.
class OtaBoardActivity {
  const OtaBoardActivity(this.label, {this.percent});

  /// "Recebendo 43 %", "Verificando", "Reiniciando", "Autoteste".
  final String label;

  /// 0…100 while the image is on its way; null = no number to show.
  final int? percent;

  /// 0…1 for the ring; null = the ring turns.
  double? get progress => percent == null ? null : percent! / 100;

  /// Under the CENTRAL avatar: "Placa: recebendo 43 %".
  String get caption => 'Placa: ${label.toLowerCase()}';

  @override
  bool operator ==(Object other) =>
      other is OtaBoardActivity &&
      other.label == label &&
      other.percent == percent;

  @override
  int get hashCode => Object.hash(label, percent);
}

/// Null when no push runs.
OtaBoardActivity? otaBoardActivity(OtaPushState s) {
  final percent = (s.progress.clamp(0.0, 1.0) * 100).floor();
  switch (s.phase) {
    case OtaPushPhase.switchingSpeed:
      return const OtaBoardActivity('Preparando');
    case OtaPushPhase.sending:
      return s.waitingFor != null
          // The cable is out, or the board is silent: nothing moves.
          ? OtaBoardActivity('Aguardando', percent: percent)
          : OtaBoardActivity(
              'Recebendo ${otaPercentText(s.progress)}',
              percent: percent,
            );
    case OtaPushPhase.verifying:
      return const OtaBoardActivity('Verificando');
    case OtaPushPhase.boardRestarting:
      return OtaBoardActivity(_inSelfTest(s) ? 'Autoteste' : 'Reiniciando');
    case OtaPushPhase.idle ||
          OtaPushPhase.readingFile ||
          OtaPushPhase.confirmed ||
          OtaPushPhase.stored ||
          OtaPushPhase.rolledBack ||
          OtaPushPhase.failed:
      return null;
  }
}

/// Chunks confirmed by the board while the image is on its way; -1 when
/// nothing is being sent. The Rede maps turn its steps into packets.
int otaChunksOnTheWay(OtaPushState s) =>
    s.phase == OtaPushPhase.sending ? s.chunksDone : -1;

/// One packet on the map per [every] chunks, and never two within
/// [minGap]: about ten chunks a second would flood the link.
class OtaPacketThrottle {
  OtaPacketThrottle({
    this.every = 5,
    this.minGap = const Duration(milliseconds: 450),
  });

  final int every;
  final Duration minGap;

  int? _lastChunk;
  DateTime? _lastAt;

  /// True when the step to [chunksDone] is worth a packet. -1 (nothing is
  /// being sent) forgets where the last one was.
  bool take(int chunksDone, DateTime now) {
    if (chunksDone < 0) {
      _lastChunk = null;
      _lastAt = null;
      return false;
    }
    if (chunksDone == 0) return false;
    final lastChunk = _lastChunk;
    final lastAt = _lastAt;
    if (lastChunk != null && chunksDone >= lastChunk) {
      if (chunksDone - lastChunk < every) return false;
      if (lastAt != null && now.difference(lastAt) < minGap) return false;
    }
    _lastChunk = chunksDone;
    _lastAt = now;
    return true;
  }
}

bool _inSelfTest(OtaPushState s) =>
    s.step(OtaStepId.confirm)?.status == OtaStepStatus.running;
