
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../access/presentation/screens/qr_scanner_screen.dart';
import '../../../provisioning/data/services/device_ap_service.dart';
import '../../../provisioning/data/services/wifi_join_service.dart';
import '../../../provisioning/domain/entities/device_ap_info.dart';
import '../../../provisioning/domain/entities/device_qr_payload.dart';
import '../../../provisioning/domain/services/provisioning_crypto.dart';
import '../../application/installation_provider.dart';
import '../../domain/entities/installation.dart';
import '../../domain/services/installation_generator.dart';
import 'installation_detail_screen.dart';

enum _Phase { idle, joining, identifying, fetching, done, failed }

/// "Entrar pela placa" (lifecycle §11): an installer with no code and no
/// tablet double-taps the board, scans the BOARD's sticker, joins its
/// admin window and receives the code encrypted for that sticker.
class JoinFromBoardScreen extends ConsumerStatefulWidget {
  const JoinFromBoardScreen({super.key});

  @override
  ConsumerState<JoinFromBoardScreen> createState() => _JoinFromBoardScreenState();
}

class _JoinFromBoardScreenState extends ConsumerState<JoinFromBoardScreen> {
  _Phase _phase = _Phase.idle;
  String _status = '';
  String? _error;
  DeviceQrPayload? _sticker;
  bool _cancelled = false;

  static const _pollEvery = Duration(seconds: 2);
  static const _maxPolls = 30;

  @override
  void dispose() {
    _cancelled = true;
    WifiJoinService.disconnect();
    super.dispose();
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const QrScannerScreen(hint: 'Aponte para a etiqueta da PLACA'),
      ),
    );
    if (!mounted || raw == null) return;
    final sticker = DeviceQrPayload.tryParse(raw);
    if (sticker == null) {
      setState(() => _error = 'Isto não é uma etiqueta de dispositivo.');
      return;
    }
    await _run(sticker);
  }

  Future<void> _type() async {
    final idCtrl = TextEditingController();
    final popCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: const Text('Etiqueta da placa'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: idCtrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'id')),
            TextField(
                controller: popCtrl,
                decoration: const InputDecoration(labelText: 'pop'),
                onSubmitted: (_) => Navigator.pop(ctx, true)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continuar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final id = idCtrl.text.trim();
    final pop = popCtrl.text.trim();
    if (id.isEmpty || pop.length < 8) return;
    await _run(DeviceQrPayload(id: id, mac: '', pop: pop));
  }

  void _set(_Phase phase, String status, {String? error}) {
    if (!mounted) return;
    setState(() {
      _phase = phase;
      _status = status;
      _error = error;
    });
  }

  Future<void> _run(DeviceQrPayload sticker) async {
    _sticker = sticker;
    _cancelled = false;
    final ssid = 'SIOT-SETUP-${sticker.id}';
    _set(_Phase.joining, 'Entrando na rede $ssid…');
    try {
      final joined = await WifiJoinService.connect(ssid: ssid, password: sticker.pop);
      if (!joined) {
        _set(_Phase.failed, '',
            error: 'O Android não confirmou a conexão a $ssid. '
                'A placa está com a janela aberta (LED branco piscando)?');
        return;
      }
    } on WifiJoinUnsupported {
      _set(
          _Phase.joining,
          'Neste telefone a conexão é manual: nos Ajustes de Wi-Fi, '
          'entre em $ssid usando o pop da etiqueta como senha e volte ao app. '
          'Continuamos procurando a placa.');
    } on WifiJoinFailed catch (e) {
      _set(_Phase.failed, '', error: 'O Android recusou a conexão a $ssid (${e.code}).');
      return;
    } catch (e) {
      debugPrint('[JoinFromBoard] join: $e');
    }

    DeviceApInfo? info;
    for (var i = 0; i < _maxPolls && !_cancelled; i++) {
      try {
        info = await DeviceApService.fetchInfo();
        break;
      } catch (_) {
        await Future<void>.delayed(_pollEvery);
      }
    }
    if (_cancelled) return;
    if (info == null) {
      _set(_Phase.failed, '',
          error: 'Placa não encontrada em $ssid. Dê dois toques no '
              'botão da placa para abrir a janela (5 min) e tente de novo.');
      return;
    }
    if (info.id != sticker.id) {
      _set(_Phase.failed, '', error: 'A rede pertence a outra unidade (${info.id}).');
      return;
    }

    _set(_Phase.identifying, 'Provando a etiqueta…');
    try {
      await DeviceApService.identify(id: sticker.id, pop: sticker.pop, nonceHex: info.nonceHex);
    } on ProofMismatchException {
      _set(_Phase.failed, '', error: 'A placa rejeitou o pop. Confira a etiqueta.');
      return;
    } catch (e) {
      _set(_Phase.failed, '', error: 'Falha ao identificar: $e');
      return;
    }

    _set(_Phase.fetching, 'Recebendo o código…');
    String envelope;
    try {
      envelope = await DeviceApService.fetchCode();
    } on DeviceApException catch (e) {
      _set(_Phase.failed, '',
          error: e.statusCode == 404
              ? 'Esta placa não está em janela de administração (ou o firmware é antigo).'
              : 'A placa não entregou o código (${e.statusCode}).');
      return;
    } catch (e) {
      _set(_Phase.failed, '', error: 'Falha ao pedir o código: $e');
      return;
    }
    final key = ProvisioningCrypto.deriveKey(pop: sticker.pop, nonce: _hex(info.nonceHex));
    final code = ProvisioningCrypto.openEnvelope(key: key, id: sticker.id, envelopeB64: envelope);
    if (code == null) {
      _set(_Phase.failed, '', error: 'Não foi possível abrir o código (pop incorreto?).');
      return;
    }
    await WifiJoinService.disconnect();

    Installation shared;
    try {
      final name = code['name'] as String?;
      shared = Installation(
        localId: InstallationGenerator.newLocalId(),
        displayName: name?.isNotEmpty == true ? name! : 'Instalação ${code['system_id']}',
        systemId: code['system_id'] as int,
        netSsid: code['net_ssid'] as String,
        netPsk: code['net_psk'] as String,
        safrPskHex: code['safr_psk_hex'] as String,
        channel: code['channel'] as int,
        meshId: code['mesh_id'] as int,
        zones: const [],
        createdAt: DateTime.now().toUtc(),
      );
    } on TypeError {
      _set(_Phase.failed, '', error: 'Código recebido incompleto.');
      return;
    }
    final (installation, outcome) =
        await ref.read(installationListProvider.notifier).importShared(shared);
    if (!mounted) return;
    _set(
        _Phase.done,
        outcome == ImportSharedOutcome.added
            ? 'Você entrou na instalação "${installation.displayName}".'
            : '"${installation.displayName}" já estava neste telefone; atualizada.');
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => InstallationDetailScreen(installationId: installation.localId),
      ),
    );
  }

  static Uint8List _hex(String h) => Uint8List.fromList([
        for (var i = 0; i + 1 < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)
      ]);

  @override
  Widget build(BuildContext context) {
    final busy = _phase == _Phase.joining ||
        _phase == _Phase.identifying ||
        _phase == _Phase.fetching;
    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.barColor,
        foregroundColor: context.textPrimary,
        elevation: 0,
        title: const Text('Entrar pela placa',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: context.surfaceColor,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Sem ninguém com o código por perto?',
                          style: TextStyle(
                              color: context.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 10),
                      Text(
                        '1. Na placa, dê dois toques no botão. O LED passa a piscar '
                        'branco: a janela fica aberta por 5 minutos e a rede da '
                        'instalação para nesse tempo.\n'
                        '2. Escaneie a etiqueta da PLACA (ou digite id e pop).\n'
                        '3. O telefone entra na rede da placa, prova a etiqueta e '
                        'recebe o código.',
                        style: TextStyle(color: context.textSecondary, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: busy ? null : _scan,
                  style: FilledButton.styleFrom(backgroundColor: AppColors.secondary),
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: const Text('Escanear etiqueta da placa'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: busy ? null : _type,
                  icon: const Icon(Icons.keyboard_rounded),
                  label: const Text('Digitar id e pop'),
                ),
                if (busy || _phase == _Phase.done) ...[
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      if (busy)
                        const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      if (busy) const SizedBox(width: 12),
                      Expanded(
                        child: Text(_status,
                            style: TextStyle(color: context.textPrimary, fontSize: 13)),
                      ),
                    ],
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.error.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
                    ),
                    child: Text(_error!,
                        style: const TextStyle(color: AppColors.error, fontSize: 12)),
                  ),
                  const SizedBox(height: 10),
                  if (_sticker != null)
                    OutlinedButton.icon(
                      onPressed: () => _run(_sticker!),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Tentar novamente'),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
