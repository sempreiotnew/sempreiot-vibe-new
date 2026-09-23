import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../installation/application/installation_provider.dart';
import '../../installation/domain/entities/installation.dart';
import '../data/services/device_ap_service.dart';
import '../data/services/wifi_join_service.dart';
import '../domain/entities/device_ap_info.dart';
import '../domain/entities/device_qr_payload.dart';
import '../domain/entities/provisioning_step.dart';

class ProvisioningWizardState {
  final ProvisioningStep step;
  final DeviceQrPayload? sticker;
  final DeviceApInfo? deviceInfo;
  final String? deviceName;
  final String? deviceZone;
  final String? error;

  const ProvisioningWizardState({
    this.step = ProvisioningStep.scan,
    this.sticker,
    this.deviceInfo,
    this.deviceName,
    this.deviceZone,
    this.error,
  });

  ProvisioningWizardState copyWith({
    ProvisioningStep? step,
    DeviceQrPayload? sticker,
    DeviceApInfo? deviceInfo,
    String? deviceName,
    String? deviceZone,
    String? error,
    bool clearError = false,
  }) =>
      ProvisioningWizardState(
        step: step ?? this.step,
        sticker: sticker ?? this.sticker,
        deviceInfo: deviceInfo ?? this.deviceInfo,
        deviceName: deviceName ?? this.deviceName,
        deviceZone: deviceZone ?? this.deviceZone,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Drives one device through POC-BRIEF.md §6.2's flow: scan sticker -> name
/// + zone -> connecting -> identify -> provision -> result. Provisions into
/// [installationId] (already chosen before the wizard is opened, from
/// `InstallationDetailScreen`).
class ProvisioningWizardNotifier
    extends StateNotifier<ProvisioningWizardState> {
  ProvisioningWizardNotifier(this._ref, {required this.installationId})
      : super(const ProvisioningWizardState());

  final Ref _ref;
  final String installationId;

  static const _pollInterval = Duration(seconds: 2);

  /// ~60s hunting for the device's SoftAP before giving up.
  static const _maxConnectingPolls = 30;

  /// ~60s waiting for a conclusive /status before giving up.
  static const _maxStatusPolls = 30;

  Timer? _infoTimer;
  Timer? _statusTimer;
  bool _requestInFlight = false;
  String? _lastKnownStatus;

  @override
  void dispose() {
    _cancelTimers();
    WifiJoinService.disconnect();
    super.dispose();
  }

  void _cancelTimers() {
    _infoTimer?.cancel();
    _infoTimer = null;
    _statusTimer?.cancel();
    _statusTimer = null;
    _requestInFlight = false;
  }

  // ── Step 1: sticker ─────────────────────────────────────────────────────

  void setSticker(DeviceQrPayload payload) {
    state = ProvisioningWizardState(
      sticker: payload,
      step: ProvisioningStep.nameZone,
    );
  }

  void backToScan() {
    _cancelTimers();
    WifiJoinService.disconnect();
    state = const ProvisioningWizardState();
  }

  // ── Step 2: name + zone ─────────────────────────────────────────────────

  void submitNameZone({required String name, required String zone}) {
    state = state.copyWith(
      deviceName: name,
      deviceZone: zone,
      step: ProvisioningStep.connecting,
      clearError: true,
    );
    _joinAndPoll();
  }

  void backToNameZone() {
    _cancelTimers();
    state = state.copyWith(step: ProvisioningStep.nameZone, clearError: true);
  }

  // ── Step 3: connect to the SoftAP + find the device ────────────────────

  Future<void> _joinAndPoll() async {
    final sticker = state.sticker;
    if (sticker == null) return;
    final ssid = 'SIOT-SETUP-${sticker.id}';
    try {
      final joined =
          await WifiJoinService.connect(ssid: ssid, password: sticker.pop);
      if (!mounted) return;
      if (!joined) {
        _failJoin('O Android não confirmou a conexão a $ssid.');
        return;
      }
    } on WifiJoinUnsupported catch (e) {
      // Not fatal: the operator can still join manually (UI offers the
      // "abrir Wi-Fi" fallback via WifiJoinService.openWifiSettingsManually)
      // and /info polling below works over whatever network is active.
      debugPrint('[Provisioning] programmatic Wi-Fi join unsupported: $e');
      // Tell the operator right away instead of pretending to join: on iOS
      // (and Android < 10) they must join the setup network by hand and come
      // back; /info polling below picks the device up once they do.
      state = state.copyWith(
        error: 'Neste telefone a conexão é manual: nos Ajustes de Wi-Fi, '
            'entre na rede $ssid usando o POP da etiqueta como senha, aceite '
            'o acesso à rede local se for pedido e volte para o app. '
            'Continuamos procurando o dispositivo enquanto isso.',
      );
    } on WifiJoinFailed catch (e) {
      // The join itself failed — polling 192.168.4.1 now would only run over
      // the phone's normal network and hide the real reason for ~60 s.
      debugPrint('[Provisioning] programmatic Wi-Fi join failed: $e');
      if (!mounted) return;
      _failJoin('O Android recusou a conexão a $ssid '
          '(${e.code}${e.message.isEmpty ? '' : ': ${e.message}'}).');
      return;
    } catch (e) {
      debugPrint('[Provisioning] programmatic Wi-Fi join failed: $e');
    }
    if (!mounted) return;
    _startInfoPolling();
  }

  void _failJoin(String reason) {
    state = state.copyWith(
      error: '$reason Confira se o Wi-Fi do telefone está ligado, aceite o '
          'pedido de conexão do sistema quando aparecer e verifique o POP da '
          'etiqueta. Você também pode entrar na rede manualmente e tocar em '
          '"Tentar novamente".',
    );
  }

  void retryConnecting() {
    state = state.copyWith(step: ProvisioningStep.connecting, clearError: true);
    _joinAndPoll();
  }

  void _startInfoPolling() {
    var attempts = 0;
    _infoTimer?.cancel();
    _infoTimer = Timer.periodic(_pollInterval, (_) async {
      if (_requestInFlight) return;
      _requestInFlight = true;
      attempts++;
      try {
        final info = await DeviceApService.fetchInfo();
        if (!mounted || state.step != ProvisioningStep.connecting) return;
        _infoTimer?.cancel();
        _infoTimer = null;
        state = state.copyWith(
          deviceInfo: info,
          step: ProvisioningStep.identifying,
          clearError: true,
        );
        await _identify();
      } catch (_) {
        if (!mounted) return;
        if (attempts >= _maxConnectingPolls) {
          _infoTimer?.cancel();
          _infoTimer = null;
          state = state.copyWith(
            error: 'Não foi possível encontrar o dispositivo. Verifique se '
                'o telefone está conectado a $ssidHint e tente novamente.',
          );
        }
      } finally {
        _requestInFlight = false;
      }
    });
  }

  String get ssidHint =>
      state.sticker == null ? '' : 'SIOT-SETUP-${state.sticker!.id}';

  // ── Step 4: identify ────────────────────────────────────────────────────

  Future<void> _identify() async {
    final sticker = state.sticker;
    final info = state.deviceInfo;
    if (sticker == null || info == null) return;
    try {
      await DeviceApService.identify(
        id: sticker.id,
        pop: sticker.pop,
        nonceHex: info.nonceHex,
      );
      if (!mounted) return;
      state = state.copyWith(step: ProvisioningStep.confirm, clearError: true);
    } on ProofMismatchException {
      if (!mounted) return;
      state = state.copyWith(
        step: ProvisioningStep.identifyFailed,
        error: 'O dispositivo rejeitou as credenciais. Verifique se o QR '
            'Code corresponde a este dispositivo.',
      );
    } catch (e) {
      if (!mounted) return;
      debugPrint('[Provisioning] identify error: $e');
      // Transient failure right after contact — go back to hunting.
      state = state.copyWith(step: ProvisioningStep.connecting);
      _startInfoPolling();
    }
  }

  void retryIdentify() {
    state = state.copyWith(step: ProvisioningStep.connecting, clearError: true);
    _startInfoPolling();
  }

  // ── Step 5-6: confirm + provision ───────────────────────────────────────

  Future<void> submitProvision() async {
    final sticker = state.sticker;
    final info = state.deviceInfo;
    final name = state.deviceName;
    final zone = state.deviceZone;
    if (sticker == null || info == null || name == null || zone == null) {
      return;
    }
    if (state.step == ProvisioningStep.provisioning) return;

    state = state.copyWith(
      step: ProvisioningStep.provisioning,
      clearError: true,
    );

    final installations = _ref.read(installationListProvider).valueOrNull ?? [];
    Installation? installation;
    for (final i in installations) {
      if (i.localId == installationId) installation = i;
    }
    if (installation == null) {
      state = state.copyWith(
        step: ProvisioningStep.confirm,
        error: 'Instalação não encontrada.',
      );
      return;
    }

    try {
      await DeviceApService.provision(
        id: sticker.id,
        pop: sticker.pop,
        nonceHex: info.nonceHex,
        codeJson: installation.toCodeJson(),
        name: name,
        zone: zone,
      );

      // Board sticker: also hand it the already-provisioned nodes so it can
      // answer INSTALLATION's enrolled list (spec §7.10).
      if (info.model.toUpperCase().startsWith('SIOT-BOARD') &&
          installation.devices.isNotEmpty) {
        try {
          await DeviceApService.enroll([
            for (final d in installation.devices)
              (mac: d.mac, id: d.id, name: d.name, zone: d.zone),
          ]);
        } catch (e) {
          // Non-fatal: the board is still provisioned; the enrolled list
          // can be resent later once GET_INSTALLATION/enroll retry exists.
          debugPrint('[Provisioning] /enroll failed (non-fatal): $e');
        }
      }

      await _ref.read(installationListProvider.notifier).addProvisionedDevice(
            installationId,
            ProvisionedDevice(
              mac: sticker.mac,
              id: sticker.id,
              name: name,
              zone: zone,
            ),
          );
    } catch (e) {
      if (!mounted) return;
      debugPrint('[Provisioning] provision error: $e');
      state = state.copyWith(
        step: ProvisioningStep.confirm,
        error: 'Não foi possível enviar a configuração. Verifique se ainda '
            'está conectado à rede do dispositivo.',
      );
      return;
    }

    _lastKnownStatus = null;
    _startStatusPolling();
  }

  /// The device's SoftAP stays up until /status has been polled once (or
  /// 30s pass — POC-BRIEF §4.1), specifically so this polling can observe
  /// the outcome before the device reboots into normal mode.
  void _startStatusPolling() {
    var attempts = 0;
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(_pollInterval, (_) async {
      if (_requestInFlight) return;
      _requestInFlight = true;
      attempts++;
      try {
        final status = await DeviceApService.fetchStatus();
        if (!mounted) return;
        _lastKnownStatus = status.state;
        switch (status.state) {
          case 'online':
            _finish(ProvisioningStep.resultOnline);
          case 'stored':
            // Not necessarily terminal (spec: stored -> joining -> online),
            // but the SoftAP can vanish any moment after this per spec —
            // keep polling a little in case 'online' follows quickly, but
            // this is already a confirmed, non-fabricated success state.
            if (attempts >= _maxStatusPolls) _finish(ProvisioningStep.resultStored);
          case 'failed':
            _finish(ProvisioningStep.resultFailed);
          default:
            if (attempts >= _maxStatusPolls) {
              _finish(ProvisioningStep.resultFailed);
            }
        }
      } catch (_) {
        if (!mounted) return;
        // The SoftAP legitimately drops once the device reboots into normal
        // mode. Only treat this as success if the device ITSELF already told
        // us 'stored' or 'online' — never fabricate success from silence
        // alone (unlike the old resultAssumed heuristic this replaces).
        final known = _lastKnownStatus;
        if (known == 'online') {
          _finish(ProvisioningStep.resultOnline);
        } else if (known == 'stored') {
          _finish(ProvisioningStep.resultStored);
        } else if (attempts >= _maxStatusPolls) {
          _finish(ProvisioningStep.resultFailed);
        }
      } finally {
        _requestInFlight = false;
      }
    });
  }

  void _finish(ProvisioningStep result) {
    _cancelTimers();
    WifiJoinService.disconnect();
    if (!mounted) return;
    state = state.copyWith(step: result);
  }

  /// From a result screen: provision another device into the same
  /// installation.
  void restart() {
    _cancelTimers();
    WifiJoinService.disconnect();
    state = const ProvisioningWizardState();
  }

  /// From resultFailed: try again with the same sticker/name/zone.
  void retryProvision() {
    state = state.copyWith(step: ProvisioningStep.confirm, clearError: true);
  }
}

final provisioningWizardProvider = StateNotifierProvider.autoDispose
    .family<ProvisioningWizardNotifier, ProvisioningWizardState, String>(
  (ref, installationId) =>
      ProvisioningWizardNotifier(ref, installationId: installationId),
);
