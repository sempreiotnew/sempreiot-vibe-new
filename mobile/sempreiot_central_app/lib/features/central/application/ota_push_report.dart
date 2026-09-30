import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/safr/safr_product.dart';
import '../domain/safr/safr_v2_payloads.dart';
import 'ota_push_controller.dart';
import 'ota_push_state.dart';
import 'topology_provider.dart';

// What a firmware push means, in plain words: what was sent, who received
// it, what changed. One place, so the update screen, the Rede banner and the
// device menu say the same thing.
//
// What a push does (protocol §13.3): send an image to the BOARD. A board
// image is installed by the board itself. A node or leaf image is only
// STORED on the board: no device receives anything in a push. Nothing here
// may read as "the devices were updated" — that is the rollout's to say
// (§13.6, ota_rollout_report.dart).

/// The push as every screen but "Atualização de firmware" reads it. A
/// provider of its own so a widget test can hand a state over without a
/// serial port or a database behind it.
final otaPushViewProvider =
    Provider<OtaPushState>((ref) => ref.watch(otaPushProvider));

/// `startedAt` of the push whose outcome the operator closed on the Rede
/// banner. The banner of another push shows again.
final otaBannerDismissedProvider = StateProvider<DateTime?>((_) => null);

// ── Names ────────────────────────────────────────────────────────────────────

/// "firmware da placa", "firmware das unidades de rede elétrica",
/// "firmware das unidades a bateria".
String otaFirmwareName(SafrProductFamily family) => switch (family) {
      SafrProductFamily.board => 'firmware da placa',
      SafrProductFamily.node => 'firmware das unidades de rede elétrica',
      SafrProductFamily.leaf => 'firmware das unidades a bateria',
      SafrProductFamily.unknown => 'firmware',
    };

/// The short form, for one line: "firmware de rede elétrica".
String otaFirmwareShortName(SafrProductFamily family) => switch (family) {
      SafrProductFamily.board => 'firmware da placa',
      SafrProductFamily.node => 'firmware de rede elétrica',
      SafrProductFamily.leaf => 'firmware de bateria',
      SafrProductFamily.unknown => 'firmware',
    };

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

/// The units of the "Versões em execução" list: the board, then the mains
/// powered units, then the battery units, each by name.
class OtaUnitGroups {
  const OtaUnitGroups(
      {this.board, this.mains = const [], this.battery = const []});

  final TopologyNode? board;
  final List<TopologyNode> mains;
  final List<TopologyNode> battery;

  bool get isEmpty => board == null && mains.isEmpty && battery.isEmpty;

  factory OtaUnitGroups.of(List<TopologyNode> nodes) {
    TopologyNode? board;
    final mains = <TopologyNode>[];
    final battery = <TopologyNode>[];
    for (final n in nodes) {
      switch (unitFamily(n)) {
        case SafrProductFamily.board:
          if (board == null) {
            board = n;
          } else {
            mains.add(n);
          }
        case SafrProductFamily.leaf:
          battery.add(n);
        case SafrProductFamily.node || SafrProductFamily.unknown:
          mains.add(n);
      }
    }
    int byName(TopologyNode a, TopologyNode b) {
      final an = a.name?.isNotEmpty == true ? a.name! : a.mac;
      final bn = b.name?.isNotEmpty == true ? b.name! : b.mac;
      return an.toLowerCase().compareTo(bn.toLowerCase());
    }

    return OtaUnitGroups(
      board: board,
      mains: mains..sort(byName),
      battery: battery..sort(byName),
    );
  }
}

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

/// What a Rede map draws of a push: the board's activity and what waits on
/// the board for the units.
typedef OtaMapOverlay = (
  OtaBoardActivity? activity,
  Map<SafrProductFamily, String> storedOnBoard,
);

OtaMapOverlay otaMapOverlay(OtaPushState s) =>
    (otaBoardActivity(s), s.storedOnBoard);

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

// ── The report ───────────────────────────────────────────────────────────────

enum OtaReportKind {
  sending,
  verifying,
  boardRestarting,
  stored,
  boardUpdated,
  boardRolledBack,
  failed,
}

/// How the report looks. [neutral] is for an image that was only stored:
/// informative, never the look of a site that was updated.
enum OtaReportTone { progress, neutral, good, warning, bad }

class OtaPushReport {
  const OtaPushReport({
    required this.kind,
    required this.tone,
    required this.title,
    required this.sent,
    required this.receiver,
    required this.changed,
    required this.line,
    this.lineTail,
    this.versionChange,
    this.reason,
  });

  final OtaReportKind kind;
  final OtaReportTone tone;
  final String title;

  /// What was sent.
  final String sent;

  /// Who received it.
  final String receiver;

  /// What changed.
  final String changed;

  /// The same, in one line, for the Rede banner. While the push runs:
  /// what is going where; how far it is comes in [lineTail].
  final String line;

  /// How far a push that runs is: "43 %", "verificando", "reiniciando",
  /// "autoteste". Apart from [line] so a narrow screen never cuts it off.
  final String? lineTail;

  /// [line] and [lineTail] as one sentence.
  String get fullLine => lineTail == null ? line : '$line · $lineTail';

  /// "0.1.0-dev → 0.1.1": a board that changed version.
  final String? versionChange;

  /// A push that did not end well: why, in plain words.
  final String? reason;

  bool get running =>
      kind == OtaReportKind.sending ||
      kind == OtaReportKind.verifying ||
      kind == OtaReportKind.boardRestarting;
}

/// What the push of [s] means. Null when there is nothing to say: no file,
/// or a file that was not sent yet.
OtaPushReport? otaPushReport(OtaPushState s) {
  final file = s.file;
  if (file == null) return null;
  final family = file.family;
  final isBoard = family == SafrProductFamily.board;
  final version = file.version;
  final sent = '${_capital(otaFirmwareName(family))} $version';
  final short = '${otaFirmwareShortName(family)} $version';
  final before = s.boardVersionBefore;
  final going = 'Atualização: placa ← $short'
      '${isBoard ? '' : ' (será guardado na placa)'}';

  switch (s.phase) {
    case OtaPushPhase.idle || OtaPushPhase.readingFile:
      return null;

    case OtaPushPhase.switchingSpeed || OtaPushPhase.sending:
      final percent = otaPercentText(s.progress);
      return OtaPushReport(
        kind: OtaReportKind.sending,
        tone: OtaReportTone.progress,
        title: 'Enviando para a placa',
        sent: sent,
        receiver: isBoard
            ? 'A placa, pelo cabo USB.'
            : 'Só a placa, pelo cabo USB. Nenhum dispositivo recebe nada '
                'neste envio.',
        changed: isBoard
            ? 'Nada ainda. A placa só troca de versão depois de receber '
                'tudo, verificar a imagem e reiniciar.'
            : 'Nada ainda. A imagem será guardada na placa; nenhum '
                'dispositivo será atualizado.',
        line: going,
        lineTail: percent,
      );

    case OtaPushPhase.verifying:
      return OtaPushReport(
        kind: OtaReportKind.verifying,
        tone: OtaReportTone.progress,
        title: 'A placa está verificando a imagem',
        sent: sent,
        receiver: isBoard
            ? 'A placa recebeu a imagem inteira.'
            : 'Só a placa recebeu a imagem inteira. Nenhum dispositivo '
                'recebe nada neste envio.',
        changed: isBoard
            ? 'Nada ainda. Se a imagem for aprovada, a placa reinicia com '
                'ela.'
            : 'Nada ainda. Se a imagem for aprovada, ela fica guardada na '
                'placa; nenhum dispositivo será atualizado.',
        line: going,
        lineTail: 'verificando',
      );

    case OtaPushPhase.boardRestarting:
      final selfTest = _inSelfTest(s);
      return OtaPushReport(
        kind: OtaReportKind.boardRestarting,
        tone: OtaReportTone.progress,
        title:
            selfTest ? 'A placa está em autoteste' : 'A placa está reiniciando',
        sent: sent,
        receiver: 'A placa. Ela aprovou a imagem.',
        changed: 'Ainda não confirmado. A placa reinicia com a versão '
            '$version e testa a si mesma; a instalação fica sem supervisão '
            'até ela voltar.'
            '${before == null ? '' : ' Antes do envio ela estava com a versão $before.'}',
        line: going,
        lineTail: selfTest ? 'autoteste' : 'reiniciando',
      );

    case OtaPushPhase.stored:
      return OtaPushReport(
        kind: OtaReportKind.stored,
        tone: OtaReportTone.neutral,
        title: 'Imagem guardada na placa',
        sent: sent,
        receiver: 'Só a placa. Ela guardou o ${otaFirmwareName(family)} '
            '$version.',
        changed: family == SafrProductFamily.leaf
            ? 'Nenhum dispositivo foi atualizado. Os detectores a bateria '
                'continuam com o firmware que já tinham: eles serão '
                'atualizados em uma etapa futura.'
            : 'Nenhum dispositivo foi atualizado. Os dispositivos '
                'continuam com o firmware que já tinham até você usar '
                '"Enviar aos dispositivos" na tela Atualização de firmware.',
        line: 'Guardado na placa: $short · nenhum dispositivo foi '
            'atualizado',
      );

    case OtaPushPhase.confirmed:
      final runs = _known(s.boardVersion) ?? version;
      final same = before != null && before == runs;
      return OtaPushReport(
        kind: OtaReportKind.boardUpdated,
        tone: OtaReportTone.good,
        title: 'Placa atualizada',
        sent: sent,
        receiver: 'A placa. Ela reiniciou e passou no autoteste.',
        changed: before == null
            ? 'A placa está com a versão $runs. A versão que ela tinha '
                'antes não era conhecida. Nenhum outro dispositivo foi '
                'alterado.'
            : same
                ? 'A placa instalou de novo a versão $runs. Nenhum outro '
                    'dispositivo foi alterado.'
                : 'A placa trocou da versão $before para a versão $runs. '
                    'Nenhum outro dispositivo foi alterado.',
        versionChange: before == null ? null : '$before → $runs',
        line: before == null
            ? 'Placa atualizada: agora na versão $runs'
            : 'Placa atualizada: $before → $runs',
      );

    case OtaPushPhase.rolledBack:
      final runs = _known(s.boardVersion) ?? before;
      final back = runs == null
          ? 'voltou para a versão que tinha antes'
          : 'voltou para a versão $runs';
      final reason = s.reason;
      final selfTest = reason == null || reason == SafrOtaReason.selftestFail;
      final why = selfTest
          ? 'A placa testou a versão $version e não passou no autoteste.'
          : 'A placa não ficou com a versão $version: '
              '${_lower(_sentence(reason.label))}';
      return OtaPushReport(
        kind: OtaReportKind.boardRolledBack,
        tone: OtaReportTone.warning,
        title: 'A placa voltou à versão anterior',
        sent: sent,
        receiver: 'A placa. Ela experimentou a imagem e a descartou.',
        reason: why,
        changed: 'Nada mudou: a placa $back. Nenhum outro dispositivo foi '
            'alterado.',
        line: selfTest
            ? 'A placa testou $version, falhou no autoteste e $back'
            : 'A placa não ficou com $version e $back',
      );

    case OtaPushPhase.failed:
      final reason = _sentence(_known(s.message) ??
          s.reason?.label ??
          'A atualização parou sem dizer o motivo.');
      if (s.boardRestarted) {
        // The board took the image and restarted: only it knows what it
        // runs now. Never "nothing changed" here.
        return OtaPushReport(
          kind: OtaReportKind.failed,
          tone: OtaReportTone.bad,
          title: 'A atualização não foi confirmada',
          sent: sent,
          receiver: 'A placa. Ela aprovou a imagem e reiniciou.',
          reason: reason,
          changed: 'Não se sabe. A placa não disse com que versão ficou. '
              'Confira a versão dela em "Versões em execução" quando ela '
              'voltar a responder.',
          line: 'Atualização não confirmada: não se sabe com que versão a '
              'placa ficou',
        );
      }
      return OtaPushReport(
        kind: OtaReportKind.failed,
        tone: OtaReportTone.bad,
        title: 'A atualização não foi concluída',
        sent: sent,
        receiver: 'Ninguém. A placa não ficou com esta imagem.',
        reason: reason,
        changed: isBoard
            ? 'Nada mudou na placa.'
                '${before == null ? '' : ' Ela continua com a versão $before.'}'
            : 'Nada mudou na placa e nenhum dispositivo foi atualizado.',
        line: 'Atualização não concluída: ${_lower(reason)} Nada mudou na '
            'placa.',
      );
  }
}

String? _known(String? text) => text == null || text.isEmpty ? null : text;

String _capital(String text) =>
    text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

/// First letter in lower case, unless the text opens with an acronym.
String _lower(String text) {
  if (text.length < 2) return text.toLowerCase();
  final second = text[1];
  final acronym = second == second.toUpperCase() && second != ' ';
  return acronym ? text : '${text[0].toLowerCase()}${text.substring(1)}';
}

/// Ends with a full stop.
String _sentence(String text) {
  final t = text.trim();
  if (t.isEmpty) return t;
  return RegExp(r'[.!?]$').hasMatch(t) ? t : '$t.';
}
