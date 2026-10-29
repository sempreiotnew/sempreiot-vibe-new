/// Steps of the device provisioning wizard, in flow order.
/// POC-BRIEF.md §6.2: scan sticker -> name + endereçamento -> connecting ->
/// identify -> provision -> result.
enum ProvisioningStep {
  /// Scan the device's factory sticker QR (or type id/mac/pop manually).
  scan,

  /// Operator names the device and may pick its endereçamento (where it
  /// is). The zone is set on the tablet (protocol §14.8).
  nameAddress,

  /// Programmatic join of the device's setup SoftAP; /info polling runs
  /// underneath once joined.
  connecting,

  /// Device reached — running POST /identify.
  identifying,

  /// Device rejected the credentials (proof mismatch).
  identifyFailed,

  /// Summary before sending the envelope.
  confirm,

  /// POST /provision sent — polling /status for the outcome.
  provisioning,

  /// Config stored on the device (POC-BRIEF §5 `stored`/`online`).
  resultStored,

  /// Device confirmed a live frame reached the board (`online`).
  resultOnline,

  /// Device reported it could not join / store the config.
  resultFailed,
}

extension ProvisioningStepX on ProvisioningStep {
  /// 0-based index of the visible wizard phase (for the progress header).
  int get phaseIndex => switch (this) {
        ProvisioningStep.scan => 0,
        ProvisioningStep.nameAddress => 1,
        ProvisioningStep.connecting ||
        ProvisioningStep.identifying ||
        ProvisioningStep.identifyFailed =>
          2,
        ProvisioningStep.confirm || ProvisioningStep.provisioning => 3,
        _ => 4,
      };

  bool get isResult =>
      this == ProvisioningStep.resultStored ||
      this == ProvisioningStep.resultOnline ||
      this == ProvisioningStep.resultFailed;
}
