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
import '../../application/serial_link_provider.dart';
import '../../application/topology_provider.dart';
import '../../domain/ota/firmware_image.dart';
import '../../domain/safr/safr_product.dart';
import '../widgets/device_detail_widgets.dart';
import '../widgets/firmware_update_widgets.dart';

/// "Atualização de firmware": sends a firmware file from the tablet to the
/// board over the USB cable (protocol §13.3) and says plainly what came of
/// it. Top to bottom:
///
///  1. the report card — what was sent, who received it, what changed —
///     while a push runs and after it ended;
///  2. "Versões em execução": what every unit runs NOW, and what waits for
///     it on the board;
///  3. the link and what this session saw stored on the board;
///  4. the file and the actions;
///  5. "Detalhes": the steps, the numbers and the log, which can be copied.
///     Open while a push runs and after one that did not end well.
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

  bool _detailsOpen(OtaPushState state) {
    if (_detailsFor != state.startedAt) {
      _detailsFor = state.startedAt;
      _detailsChoice = null;
    }
    return _detailsChoice ??
        (state.running ||
            state.phase == OtaPushPhase.failed ||
            state.phase == OtaPushPhase.rolledBack);
  }

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !ref.read(otaPushProvider).running) return;
      setState(() => _now = DateTime.now());
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
    final board = ref.watch(boardDeviceProvider).valueOrNull;
    final units = OtaUnitGroups.of(ref.watch(topologyProvider));
    final link = ref.watch(serialLinkProvider);
    final alarm = ref.watch(activeAlarmProvider);
    final controller = ref.read(otaPushProvider.notifier);

    final linkUp = link == SerialLinkStatus.connected;
    final file = state.file;
    final blockedByAlarm = alarm && state.isBoardImage;
    final canStart =
        file != null && !state.running && linkUp && !blockedByAlarm;
    final report = otaPushReport(state);
    final detailsOpen = _detailsOpen(state);

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
                OtaRunningVersions(
                  units: units,
                  storedOnBoard: state.storedOnBoard,
                ),
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
                    for (final e in state.storedOnBoard.entries) ...[
                      const InfoRowDivider(),
                      InfoReadRow(
                        label: 'Guardado na placa',
                        value: '${otaFirmwareShortName(e.key)} ${e.value} · '
                            'ainda não enviado aos dispositivos',
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
                  const _Hint(
                    'Este arquivo fica guardado na placa. Nenhum dispositivo '
                    'é atualizado neste envio: mandar da placa para os '
                    'dispositivos ainda não está disponível.',
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
                const SizedBox(height: 24),
                OtaDetailsHeader(
                  open: detailsOpen,
                  summary: _detailsSummary(state),
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
                  OtaLogCard(state: state),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _detailsSummary(OtaPushState state) {
    final steps = state.steps.length;
    final lines = state.log.length;
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
