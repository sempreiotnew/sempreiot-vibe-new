import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_ext.dart';
import '../../../../shared/widgets/encrypted_share_dialog.dart';
import '../../../../shared/widgets/passphrase_dialog.dart';
import '../../../access/presentation/screens/qr_scanner_screen.dart';
import '../../../installation/domain/entities/installation.dart';
import '../../../installation/domain/services/installation_generator.dart';
import '../../../provisioning/domain/entities/device_qr_payload.dart';
import '../../../provisioning/domain/services/provisioning_crypto.dart';
import '../../application/central_installation_provider.dart';
import '../../application/credentials_admin_provider.dart';
import '../../application/safr_downlink_provider.dart';
import '../../domain/safr/safr_identity.dart';
import '../../domain/safr/safr_v2_payloads.dart';
import '../widgets/editor_gate.dart';

/// CENTRAL mode: which installation this tablet belongs to. The code reaches
/// the tablet from an installer's encrypted share (QR or pasted text,
/// lifecycle §2) — and, once the board supports GET_CODE, from the board
/// over USB (lifecycle §4.1). Gated by the Master / Nível 4 PIN (lifecycle §7).
class CentralInstallationScreen extends ConsumerStatefulWidget {
  const CentralInstallationScreen({super.key});

  @override
  ConsumerState<CentralInstallationScreen> createState() =>
      _CentralInstallationScreenState();
}

class _CentralInstallationScreenState
    extends ConsumerState<CentralInstallationScreen> {
  EditorRole? _role;

  Future<void> _audit(String action, Map<String, Object?> detail) =>
      ref.read(appDatabaseProvider).addAudit(
            _role?.auditName ?? 'system',
            action,
            detail,
          );

  Future<void> _import(String raw, {String? passphrase}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final parsed = await ref
          .read(centralInstallationProvider.notifier)
          .import(raw, passphrase: passphrase);
      await _audit('installation_import', {
        'system_id': parsed.installation.systemId,
        'name': parsed.installation.displayName,
        'legacy_plaintext': parsed.legacyPlaintext,
      });
      messenger.showSnackBar(SnackBar(
        content: Text(parsed.legacyPlaintext
            ? 'Instalação "${parsed.installation.displayName}" vinculada a '
                'partir de um backup antigo SEM senha. Peça ao instalador '
                'para usar "Compartilhar" na versão atual do app.'
            : 'Instalação "${parsed.installation.displayName}" vinculada.'),
        backgroundColor: parsed.legacyPlaintext ? AppColors.warning : null,
        duration: Duration(seconds: parsed.legacyPlaintext ? 8 : 4),
      ));
    } on PassphraseRequired {
      if (!mounted) return;
      final passphrase = await showPassphraseDialog(
        context,
        title: 'Senha da instalação',
        message: 'Digite a senha que o instalador definiu ao compartilhar.',
        actionLabel: 'Vincular',
      );
      if (!mounted || passphrase == null) return;
      await _import(raw, passphrase: passphrase);
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(e.message),
        backgroundColor: AppColors.error,
      ));
    }
  }

  Future<void> _scan() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const QrScannerScreen(
          hint: 'Aponte para o QR "Compartilhar" do app do instalador',
        ),
      ),
    );
    if (!mounted || scanned == null || scanned.trim().isEmpty) return;
    await _import(scanned);
  }

  Future<void> _paste() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: const Text('Colar código da instalação'),
        content: TextField(
          controller: controller,
          maxLines: 8,
          autofocus: true,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(
            hintText: '{"v":2,"kdf":"pbkdf2-sha256",...}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Vincular'),
          ),
        ],
      ),
    );
    if (!mounted || raw == null || raw.trim().isEmpty) return;
    await _import(raw);
  }

  Future<void> _share(Installation installation) async {
    final passphrase = await showPassphraseDialog(
      context,
      title: 'Compartilhar instalação',
      message: 'Defina uma senha e diga-a ao instalador. O QR só abre com ela.',
      confirm: true,
      actionLabel: 'Gerar QR',
    );
    if (!mounted || passphrase == null) return;
    final envelope = ref
        .read(centralInstallationProvider.notifier)
        .exportEncrypted(passphrase);
    await _audit('installation_share', {'system_id': installation.systemId});
    if (!mounted) return;
    await showEncryptedShareDialog(
      context,
      title: 'Compartilhar "${installation.displayName}"',
      envelope: envelope,
    );
  }

  /// The board sticker: scanned when this tablet has a camera, else typed.
  Future<DeviceQrPayload?> _askBoardSticker(String why) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: ctx.surfaceColor,
        title: const Text('Etiqueta da placa'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(why, style: TextStyle(color: ctx.textSecondary, fontSize: 13)),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'scan'),
            child: const Text('Escanear a etiqueta (câmera)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'type'),
            child: const Text('Digitar id e pop da etiqueta'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return null;
    if (choice == 'scan') {
      final raw = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          builder: (_) => const QrScannerScreen(hint: 'Aponte para a etiqueta da PLACA'),
        ),
      );
      if (raw == null) return null;
      final parsed = DeviceQrPayload.tryParse(raw);
      if (parsed == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Isto não é uma etiqueta de dispositivo.'),
          backgroundColor: AppColors.error,
        ));
      }
      return parsed;
    }
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
              decoration: const InputDecoration(labelText: 'id', hintText: 'ex.: dev-1a2b3c4d'),
            ),
            TextField(
              controller: popCtrl,
              decoration: const InputDecoration(labelText: 'pop', hintText: '16+ caracteres'),
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continuar')),
        ],
      ),
    );
    if (ok != true) return null;
    final id = idCtrl.text.trim();
    final pop = popCtrl.text.trim();
    if (id.isEmpty || pop.length < 8) return null;
    return DeviceQrPayload(id: id, mac: '', pop: pop);
  }

  /// Lifecycle §4.1: pull the code from the board over USB, no camera needed.
  Future<void> _readCodeFromBoard() async {
    final sticker = await _askBoardSticker(
        'A placa só entrega o código a quem prova ter a etiqueta dela. '
        'Digite (ou escaneie) o id e o pop impressos na placa.');
    if (sticker == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final key = ProvisioningCrypto.deriveSetupKey(id: sticker.id, pop: sticker.pop);
    messenger.showSnackBar(const SnackBar(content: Text('Pedindo o código à placa…')));
    final code = await ref.read(safrDownlinkProvider).sendGetCode(key);
    if (!mounted) return;
    if (code == null) {
      messenger.showSnackBar(const SnackBar(
        content: Text('A placa não respondeu. Confira o cabo USB, o pop da etiqueta '
            'e se a placa já foi configurada (LED magenta).'),
        backgroundColor: AppColors.error,
        duration: Duration(seconds: 8),
      ));
      return;
    }
    final installation = Installation(
      localId: InstallationGenerator.newLocalId(),
      displayName: code.name.isNotEmpty ? code.name : 'Instalação ${code.systemId}',
      systemId: code.systemId,
      netSsid: code.netSsid,
      netPsk: code.netPsk,
      safrPskHex: code.safrPsk.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      channel: code.channel,
      meshId: code.meshId,
      zones: const [],
      createdAt: DateTime.now().toUtc(),
    );
    await ref.read(centralInstallationProvider.notifier).adopt(installation);
    await _audit('installation_from_board', {'system_id': code.systemId, 'name': code.name});
    messenger.showSnackBar(SnackBar(
      content: Text('Código lido da placa: "${installation.displayName}" vinculada.'),
    ));
  }

  /// Lifecycle §5 B (Case B): this tablet creates the code and writes it
  /// into a board that has none.
  Future<void> _createOnBoard() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: const Text('Criar instalação nesta central'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          maxLength: 32,
          decoration: const InputDecoration(labelText: 'Nome da instalação'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, nameCtrl.text), child: const Text('Continuar')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final sticker = await _askBoardSticker(
        'A placa deve estar em modo de instalação (LED branco piscando) e '
        'ligada por USB. Digite (ou escaneie) o id e o pop da etiqueta dela.');
    if (sticker == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final installation = InstallationGenerator.generate(displayName: name.trim());
    final key = ProvisioningCrypto.deriveSetupKey(id: sticker.id, pop: sticker.pop);
    final code = SafrInstallationCode(
      systemId: installation.systemId,
      channel: installation.channel,
      meshId: installation.meshId,
      netSsid: installation.netSsid,
      netPsk: installation.netPsk,
      safrPsk: SafrIdentity.keyFromHex(installation.safrPskHex)!,
      name: installation.displayName,
    );
    messenger.showSnackBar(const SnackBar(content: Text('Gravando o código na placa…')));
    final boardMac = sticker.mac.isNotEmpty ? sticker.mac : 'FF:FF:FF:FF:FF:FF';
    final r = await ref.read(safrDownlinkProvider).sendSetInstallation(key, code, boardMac);
    if (!mounted) return;
    if (!r.ok) {
      messenger.showSnackBar(SnackBar(
        content: Text('A placa não aceitou: ${r.message}'),
        backgroundColor: AppColors.error,
        duration: const Duration(seconds: 8),
      ));
      return;
    }
    await ref.read(centralInstallationProvider.notifier).adopt(installation);
    await _audit('installation_create_case_b', {'system_id': installation.systemId, 'name': installation.displayName});
    messenger.showSnackBar(SnackBar(
      content: Text('Placa configurada. "${installation.displayName}" criada; ela reinicia agora. '
          'Toque em "Compartilhar" para passar o código aos instaladores.'),
      duration: const Duration(seconds: 8),
    ));
  }

  /// Lifecycle §5 J: after a board swap, push every name this tablet knows.
  Future<void> _resendNames() async {
    final db = ref.read(appDatabaseProvider);
    final rows = await db.select(db.meshDevices).get();
    final downlink = ref.read(safrDownlinkProvider);
    var sent = 0, ok = 0;
    for (final r in rows) {
      final name = r.name;
      if (name == null || name.isEmpty || r.layer == 0) continue;
      sent++;
      final res = await downlink.sendSetDevice(r.mac, name, r.zone ?? '');
      if (res.ok) ok++;
    }
    await _audit('installation_resend_names', {'sent': sent, 'ok': ok});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Nomes reenviados: $ok de $sent confirmados pela placa.'),
    ));
    downlink.sendGetDeviceTable();
  }

  Future<void> _clear(Installation installation) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: const Text('Desvincular instalação?'),
        content: const Text(
            'A central volta à identidade de bancada e deixa de aceitar os '
            'quadros desta instalação até vincular de novo.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Desvincular'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(centralInstallationProvider.notifier).clear();
      await _audit('installation_unlink', {'system_id': installation.systemId});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_role == null) {
      return Scaffold(
        backgroundColor: context.bgColor,
        appBar: AppBar(
          backgroundColor: context.barColor,
          foregroundColor: context.textPrimary,
          elevation: 0,
          title: const Text('Instalação',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
        body: EditorGate(
          subtitle: 'Digite o PIN Master ou o PIN de Nível 4\n'
              'para ver ou alterar a instalação desta central.',
          onUnlocked: (r) => setState(() => _role = r),
        ),
      );
    }

    final async = ref.watch(centralInstallationProvider);
    final installation = async.valueOrNull;

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.barColor,
        foregroundColor: context.textPrimary,
        elevation: 0,
        title: const Text('Instalação',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: async.isLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      if (installation == null)
                        _EmptyCard()
                      else
                        _InstallationCard(installation: installation),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _readCodeFromBoard,
                        style: FilledButton.styleFrom(
                            backgroundColor: AppColors.secondary),
                        icon: const Icon(Icons.usb_rounded),
                        label: const Text('Ler código da placa (USB)'),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _createOnBoard,
                        icon: const Icon(Icons.add_circle_outline_rounded),
                        label: const Text('Criar instalação nesta central'),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _scan,
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        label: Text(installation == null
                            ? 'Escanear QR do instalador'
                            : 'Escanear outro QR'),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _paste,
                        icon: const Icon(Icons.content_paste_rounded),
                        label: const Text('Colar código compartilhado'),
                      ),
                      if (installation != null) ...[
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _resendNames,
                          icon: const Icon(Icons.send_rounded),
                          label: const Text('Reenviar nomes à placa'),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: () => _share(installation),
                          icon: const Icon(Icons.share_rounded),
                          label: const Text('Compartilhar com um instalador'),
                        ),
                        const SizedBox(height: 24),
                        TextButton.icon(
                          onPressed: () => _clear(installation),
                          style: TextButton.styleFrom(
                              foregroundColor: AppColors.error),
                          icon: const Icon(Icons.link_off_rounded),
                          label: const Text('Desvincular'),
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

class _EmptyCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: AppColors.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Nenhuma instalação vinculada. A central está usando a '
              'identidade de bancada e vai rejeitar os quadros da placa '
              'provisionada. Se a placa já foi configurada, toque em '
              '"Ler código da placa" e digite o pop da etiqueta dela. Se a '
              'placa está nova, "Criar instalação nesta central".',
              style: TextStyle(color: context.textSecondary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _InstallationCard extends StatelessWidget {
  const _InstallationCard({required this.installation});
  final Installation installation;

  @override
  Widget build(BuildContext context) {
    final systemIdHex =
        '0x${installation.systemId.toRadixString(16).padLeft(4, '0').toUpperCase()}';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.hub_rounded, color: AppColors.secondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  installation.displayName,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _Row(label: 'SYSTEM_ID', value: systemIdHex),
          _Row(label: 'NET_SSID', value: installation.netSsid),
          _Row(label: 'CHANNEL', value: '${installation.channel}'),
          _Row(label: 'MESH_ID', value: '${installation.meshId}'),
          const _Row(label: 'CHAVE SAFR', value: 'presente (16 bytes)'),
          _Row(label: 'ZONAS', value: '${installation.zones.length}'),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(color: context.textSecondary, fontSize: 13)),
          Text(value,
              style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 13,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
