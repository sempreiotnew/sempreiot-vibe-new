import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../application/alarm_latch_provider.dart';
import '../../application/ota_board_events_provider.dart';
import '../../application/ota_push_controller.dart';
import '../../application/ota_push_report.dart';
import '../../application/ota_push_state.dart';
import '../../application/ota_rollout_controller.dart';
import '../../application/ota_rollout_report.dart';
import '../../application/ota_rollout_state.dart';
import '../../application/ota_rollout_words.dart';
import '../../application/root_election_provider.dart';
import '../../application/serial_link_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/ota/firmware_image.dart';
import '../../domain/safr/safr_product.dart';
import '../../domain/safr/safr_v2_payloads.dart';
import '../widgets/device_detail_widgets.dart';
import '../widgets/firmware_update_widgets.dart';
import '../widgets/ota_rollout_widgets.dart';

/// "Atualização de firmware": sends a firmware file from the tablet to the
/// board over the USB cable (protocol §13.3), has the board send the image
/// it holds to the units (§13.6), and says plainly what came of both. Top to
/// bottom:
///
///  1. the report card — what was sent, who received it, what changed —
///     while a push runs and after it ended;
///  2. "Versões em execução": what every unit runs NOW, and what waits for
///     it on the board;
///  3. the link and what the board holds;
///  4. the file and the actions;
///  5. "Dispositivos": one card per family the board holds an image of —
///     the form that sends it, and the rollout that runs or ran;
///  6. "Detalhes": the steps, the numbers and the log — of the push and of
///     the rollout — which can be copied. Open while something runs and
///     after something that did not end well.
///
/// One column in both orientations, as wide as reads well; the whole page
/// scrolls.
/// The "instalação forçada" switch (FLAGS bit 0 of OTA_PUSH_BEGIN, protocol
/// §13.2) is for the bench: debug builds, or a build made with
/// `--dart-define=OTA_ALLOW_FORCE=true`.
const kOtaAllowForce =
    kDebugMode || bool.fromEnvironment('OTA_ALLOW_FORCE', defaultValue: false);

class FirmwareUpdateScreen extends ConsumerStatefulWidget {
  const FirmwareUpdateScreen({super.key});

  @override
  ConsumerState<FirmwareUpdateScreen> createState() =>
      _FirmwareUpdateScreenState();
}

class _FirmwareUpdateScreenState extends ConsumerState<FirmwareUpdateScreen> {
  /// Bench only ([kOtaAllowForce]): FLAGS bit 0 of OTA_PUSH_BEGIN.
  bool _force = false;

  /// Moves the seconds on the screen while a push runs.
  Timer? _ticker;
  DateTime _now = DateTime.now();

  /// "Detalhes" as the operator left it, for the push that started at
  /// [_detailsFor]; null = as the push asks.
  bool? _detailsChoice;
  DateTime? _detailsFor;

  bool _detailsOpen(OtaPushState state, OtaRolloutState rollout) {
    if (_detailsFor != state.startedAt) {
      _detailsFor = state.startedAt;
      _detailsChoice = null;
    }
    return _detailsChoice ??
        (state.running ||
            state.phase == OtaPushPhase.failed ||
            state.phase == OtaPushPhase.rolledBack ||
            rollout.running != null);
  }

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!ref.read(otaPushProvider).running &&
          ref.read(otaRolloutProvider).running == null) {
        return;
      }
      setState(() => _now = DateTime.now());
    });
    // What the board holds and where its rollout is: asked every time the
    // screen opens (GET_ROLLOUT).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(otaRolloutProvider.notifier).refresh();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _start(OtaPushState state, String? boardRuns) async {
    final controller = ref.read(otaPushProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final file = state.file;
    if (file == null) return;

    final blocker = await controller.startBlocker();
    if (!mounted) return;
    if (blocker != null) {
      _say(messenger, blocker);
      return;
    }
    if (file.family == SafrProductFamily.board) {
      final go = await _confirmBoardRestart(file, boardRuns);
      if (go != true || !mounted) return;
    }
    final refused = await controller.start(force: _force);
    if (refused != null && mounted) _say(messenger, refused);
  }

  void _say(ScaffoldMessengerState messenger, String text) {
    messenger.showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  // ── The rollout ──────────────────────────────────────────────────────────

  Future<void> _startRollout(
    OtaRolloutRequest request,
    String version,
    String? rootName,
  ) async {
    final controller = ref.read(otaRolloutProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);

    final blocker = await controller.startBlocker(request.family);
    if (!mounted) return;
    if (blocker != null) {
      _say(messenger, blocker);
      return;
    }
    final go = await _confirmRollout(request, version, rootName);
    if (go != true || !mounted) return;
    final refused = await controller.start(
      request.family,
      request.filter,
      expected: request.units.length,
      filterText: request.filterText,
    );
    if (refused != null && mounted) _say(messenger, refused);
  }

  Future<void> _steer(
      Future<String?> Function(OtaRolloutController c) action) async {
    final messenger = ScaffoldMessenger.of(context);
    final refused = await action(ref.read(otaRolloutProvider.notifier));
    if (refused != null && mounted) _say(messenger, refused);
  }

  Future<void> _abortRollout(OtaFamilyRollout rollout) async {
    final waiting = rollout.count(SafrOtaUnitState.waiting);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.warning_amber_rounded,
            color: AppColors.warning, size: 32),
        title: const Text('Cancelar a atualização?'),
        content: Text(
          '${rollout.current == null ? '' : 'O dispositivo que está sendo atualizado agora termina a sua atualização. '}'
          '${waiting == 0 ? 'Nenhum dispositivo está aguardando.' : waiting == 1 ? 'O dispositivo que ainda aguarda não será atualizado.' : 'Os $waiting dispositivos que ainda aguardam não serão atualizados.'}'
          '\n\nOs que já foram atualizados continuam com a versão '
          '${rollout.target}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Continuar atualizando'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancelar a atualização'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await _steer((c) => c.abort(rollout.family));
  }

  /// How many units, and that they restart one at a time: the operator says
  /// yes to that.
  Future<bool?> _confirmRollout(
    OtaRolloutRequest request,
    String version,
    String? rootName,
  ) {
    final n = request.units.length;
    final rootIn = rootName != null;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.system_update_alt_rounded,
            color: AppColors.secondary, size: 32),
        title: Text(n == 1
            ? 'Atualizar 1 dispositivo?'
            : 'Atualizar $n dispositivos?'),
        content: Text(
          'A placa vai enviar o ${otaFirmwareWord(request.family)} $version '
          '${n == 1 ? 'a 1 dispositivo' : 'a $n dispositivos'} '
          '(${request.filterText}).\n\n'
          '${n == 1 ? 'Ele reinicia' : 'Eles reiniciam um de cada vez,'} '
          'com o novo firmware e '
          '${n == 1 ? 'fica' : 'cada um fica'} sem responder enquanto '
          'reinicia.'
          '${rootIn ? ' $rootName é o root da malha e é atualizado por último: a rede se reorganiza enquanto ele reinicia.' : ''}'
          '\n\nSe um alarme acontecer, a atualização pausa sozinha.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(n == 1
                ? 'Atualizar 1 dispositivo'
                : 'Atualizar $n dispositivos'),
          ),
        ],
      ),
    );
  }

  /// Why nothing can be sent to the units now; null = it can.
  static String? _rolloutBlocked({
    required bool linkUp,
    required bool alarm,
    required bool pushRunning,
    required bool otherRunning,
  }) {
    if (!linkUp) return 'A placa não está respondendo. Verifique o cabo USB.';
    if (alarm) {
      return 'Há alarme ativo. Rearme a central antes de atualizar os '
          'dispositivos.';
    }
    if (pushRunning) return 'Aguarde o envio do arquivo à placa terminar.';
    if (otherRunning) return 'Já há uma atualização em andamento.';
    return null;
  }

  /// A board image restarts the board: the operator says yes to the site
  /// being unsupervised while it does.
  Future<bool?> _confirmBoardRestart(FirmwareFile file, String? boardRuns) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.warning_amber_rounded,
            color: AppColors.warning, size: 32),
        title: const Text('Atualizar a placa?'),
        content: Text(
          'A placa vai reiniciar com o novo firmware. Durante cerca de '
          '30 segundos a instalação fica sem supervisão: um alarme nesse '
          'intervalo não chega à central.\n\n'
          '${boardRuns == null || boardRuns.isEmpty ? '' : 'Versão atual: $boardRuns\n'}'
          'Nova versão: ${file.version}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Atualizar a placa'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(otaPushProvider);
    final rollout = ref.watch(otaRolloutProvider);
    final held = ref.watch(otaHeldOnBoardProvider);
    final rootMac = ref.watch(rootElectionProvider.select((e) => e.rootMac));
    final board = ref.watch(boardDeviceProvider).valueOrNull;
    final nodes = ref.watch(topologyProvider);
    final units = OtaUnitGroups.of(nodes);
    final byMac = {for (final n in nodes) n.mac: n};
    final link = ref.watch(serialLinkProvider);
    final alarm = ref.watch(activeAlarmProvider);
    final controller = ref.read(otaPushProvider.notifier);

    final linkUp = link == SerialLinkStatus.connected;
    final file = state.file;
    final blockedByAlarm = alarm && state.isBoardImage;
    final canStart =
        file != null && !state.running && linkUp && !blockedByAlarm;
    final report = otaPushReport(state);
    final detailsOpen = _detailsOpen(state, rollout);
    final log = otaMergedLog(state.log, rollout.log);
    // The families the board holds an image of that goes to units.
    final families = [
      for (final f in const [SafrProductFamily.node, SafrProductFamily.leaf])
        if (held[f]?.isNotEmpty == true) f
    ];

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: context.textPrimary),
        title: Text(
          'Atualização de firmware',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Divider(
            height: 0.5,
            thickness: 0.5,
            color: context.borderColor.withValues(alpha: 0.5),
          ),
        ),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
              children: [
                if (report != null) ...[
                  OtaReportCard(report: report, state: state, now: _now),
                  if (state.running) ...[
                    const SizedBox(height: 10),
                    const _Hint(
                      'Pode sair desta tela: a atualização continua e '
                      'aparece na tela Rede.',
                      icon: Icons.info_outline_rounded,
                    ),
                  ],
                  const SizedBox(height: 24),
                ],
                const InfoSectionHeader('VERSÕES EM EXECUÇÃO'),
                const SizedBox(height: 10),
                OtaRunningVersions(units: units, storedOnBoard: held),
                const SizedBox(height: 24),
                const InfoSectionHeader('LIGAÇÃO'),
                const SizedBox(height: 10),
                InfoCard(
                  children: [
                    InfoReadRow(
                      label: 'Ligação com a placa',
                      value: _linkText(link, state.baud),
                      icon: Icons.usb_rounded,
                    ),
                    for (final e in held.entries) ...[
                      const InfoRowDivider(),
                      InfoReadRow(
                        label: 'Guardado na placa',
                        value: otaHeldLine(
                            e.key, e.value, rollout.families[e.key]),
                        icon: Icons.inventory_2_outlined,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 24),
                const InfoSectionHeader('ARQUIVO'),
                const SizedBox(height: 10),
                _FileCard(state: state),
                if (file != null &&
                    file.family != SafrProductFamily.board &&
                    !state.finished) ...[
                  const SizedBox(height: 10),
                  _Hint(
                    file.family == SafrProductFamily.leaf
                        ? 'Este arquivo fica guardado na placa. Nenhum '
                            'dispositivo é atualizado neste envio: os '
                            'detectores a bateria serão atualizados em uma '
                            'etapa futura.'
                        : 'Este arquivo fica guardado na placa. Nenhum '
                            'dispositivo é atualizado neste envio: depois de '
                            'guardado, use "Enviar aos dispositivos", mais '
                            'abaixo.',
                    icon: Icons.info_outline_rounded,
                  ),
                ],
                const SizedBox(height: 16),
                _Actions(
                  state: state,
                  canStart: canStart,
                  onPick: state.running ? null : controller.pickFile,
                  onStart:
                      canStart ? () => _start(state, board?.fwVersion) : null,
                  onCancel: state.canCancel ? controller.cancel : null,
                ),
                if (file != null && !state.running && !canStart) ...[
                  const SizedBox(height: 10),
                  _Hint(
                    blockedByAlarm
                        ? 'Há alarme ativo. Rearme a central antes de '
                            'atualizar a placa.'
                        : 'A placa não está respondendo. Verifique o cabo '
                            'USB.',
                  ),
                ],
                if (kOtaAllowForce && file != null) ...[
                  const SizedBox(height: 4),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _force,
                    onChanged: state.running
                        ? null
                        : (v) => setState(() => _force = v),
                    title: Text(
                      'Instalação forçada (bancada)',
                      style:
                          TextStyle(color: context.textPrimary, fontSize: 13),
                    ),
                    subtitle: Text(
                      'Aceita a mesma versão ou uma anterior. Só placas de '
                      'bancada obedecem.',
                      style:
                          TextStyle(color: context.textSecondary, fontSize: 12),
                    ),
                  ),
                ],
                if (families.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  const InfoSectionHeader('DISPOSITIVOS'),
                  for (final family in families) ...[
                    const SizedBox(height: 10),
                    OtaRolloutCard(
                      family: family,
                      version: held[family]!,
                      rollout: rollout.families[family],
                      fromBoard: rollout.boardAnswered == true,
                      candidates: OtaRolloutCandidates.of(nodes, family),
                      nodes: byMac,
                      rootMac: rootMac,
                      now: _now,
                      busy: rollout.command != null,
                      blocked: _rolloutBlocked(
                        linkUp: linkUp,
                        alarm: alarm,
                        pushRunning: state.running,
                        otherRunning: rollout.running != null &&
                            rollout.running!.family != family,
                      ),
                      onStart: (request) => _startRollout(
                        request,
                        held[family]!,
                        request.units.any((n) => n.mac == rootMac)
                            ? _nameOf(byMac[rootMac])
                            : null,
                      ),
                      onPause: () => _steer((c) => c.pause(family)),
                      onResume: () => _steer((c) => c.resume(family)),
                      onAbort: () {
                        final f = rollout.families[family];
                        if (f != null) _abortRollout(f);
                      },
                    ),
                  ],
                ],
                const SizedBox(height: 24),
                OtaDetailsHeader(
                  open: detailsOpen,
                  summary: _detailsSummary(state, log.length),
                  onToggle: () =>
                      setState(() => _detailsChoice = !detailsOpen),
                ),
                if (detailsOpen) ...[
                  if (state.steps.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const InfoSectionHeader('ANDAMENTO'),
                    const SizedBox(height: 10),
                    InfoCard(
                      children: [OtaStepList(state: state, now: _now)],
                    ),
                  ],
                  if (state.finished) ...[
                    const SizedBox(height: 12),
                    OtaCounters(state: state),
                  ],
                  const SizedBox(height: 20),
                  const InfoSectionHeader('REGISTRO'),
                  const SizedBox(height: 10),
                  OtaLogCard(state: state, log: log),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String? _nameOf(TopologyNode? n) => n == null
      ? null
      : (n.name?.isNotEmpty == true ? n.name! : n.mac);

  static String _detailsSummary(OtaPushState state, int lines) {
    final steps = state.steps.length;
    if (steps == 0 && lines == 0) return 'Passos e registro do envio';
    return '$steps ${steps == 1 ? 'passo' : 'passos'} · '
        '$lines ${lines == 1 ? 'linha' : 'linhas'} de registro';
  }

  static String _linkText(SerialLinkStatus link, int baud) => switch (link) {
        SerialLinkStatus.connected => 'Conectada · $baud bps',
        SerialLinkStatus.stalled => 'Placa sem resposta',
        SerialLinkStatus.connecting => 'Conectando…',
        SerialLinkStatus.error => 'Falha na comunicação',
        SerialLinkStatus.disconnected => 'Cabo USB desconectado',
      };
}

// ── File ──────────────────────────────────────────────────────────────────────

class _FileCard extends StatelessWidget {
  const _FileCard({required this.state});
  final OtaPushState state;

  @override
  Widget build(BuildContext context) {
    final file = state.file;
    final error = state.fileError;

    if (file == null) {
      final reading = state.phase == OtaPushPhase.readingFile;
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: error != null
                ? AppColors.error.withValues(alpha: 0.6)
                : context.borderColor.withValues(alpha: 0.6),
            width: error != null ? 1 : 0.5,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              error != null
                  ? Icons.error_outline_rounded
                  : Icons.insert_drive_file_outlined,
              color: error != null ? AppColors.error : context.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                error ??
                    (reading
                        ? 'Lendo o arquivo…'
                        : 'Escolha o arquivo do firmware (.bin). O tipo e '
                            'a versão são lidos do próprio arquivo.'),
                style: TextStyle(
                  color: error != null
                      ? context.textPrimary
                      : context.textSecondary,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return InfoCard(
      children: [
        InfoReadRow(
          label: 'Arquivo',
          value: file.name,
          icon: Icons.insert_drive_file_outlined,
        ),
        const InfoRowDivider(),
        InfoReadRow(
          label: 'Para',
          value: '${firmwareFamilyLabel(file.family)} '
              '(${file.header.projectName})',
          icon: Icons.developer_board_rounded,
        ),
        const InfoRowDivider(),
        InfoReadRow(
          label: 'Versão',
          value: file.version,
          icon: Icons.sell_outlined,
        ),
        const InfoRowDivider(),
        InfoReadRow(
          label: 'Tamanho',
          value: '${otaSizeText(file.size)} · ${file.chunkCount} blocos',
          icon: Icons.straighten_rounded,
        ),
        const InfoRowDivider(),
        InfoReadRow(
          label: 'SHA-256',
          value: file.sha256Short,
          icon: Icons.fingerprint_rounded,
          mono: true,
        ),
      ],
    );
  }
}

// ── Actions ───────────────────────────────────────────────────────────────────

class _Actions extends StatelessWidget {
  const _Actions({
    required this.state,
    required this.canStart,
    required this.onPick,
    required this.onStart,
    required this.onCancel,
  });

  final OtaPushState state;
  final bool canStart;
  final VoidCallback? onPick;
  final VoidCallback? onStart;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final hasFile = state.file != null;
    return Wrap(
      spacing: 12,
      runSpacing: 10,
      children: [
        if (!state.running)
          hasFile
              ? OutlinedButton.icon(
                  onPressed: onPick,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: const Text('Escolher outro arquivo'),
                )
              : FilledButton.icon(
                  onPressed: onPick,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: const Text('Escolher arquivo'),
                ),
        if (hasFile && !state.running)
          FilledButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.system_update_alt_rounded, size: 18),
            label:
                Text(state.finished ? 'Enviar de novo' : 'Enviar para a placa'),
          ),
        if (state.running)
          OutlinedButton.icon(
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded, size: 18),
            label: Text(onCancel == null
                ? 'Não é possível cancelar agora'
                : 'Cancelar envio'),
          ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text, {this.icon = Icons.warning_amber_rounded});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final warning = icon == Icons.warning_amber_rounded;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 16,
          color: warning ? AppColors.warning : context.textSecondary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 12.5,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}
