import 'dart:convert';

/// What the unit can hold of what the installer types at setup (protocol
/// §7.11, `siot_config.h`): the slots are counted in **bytes of UTF-8**, so an
/// accented letter costs two. The wizard refuses to continue past them: a
/// longer text was cut by the unit at the byte limit, possibly inside a
/// character, and a frame carrying the cut name was refused by the tablet.
abstract final class ProvisioningLimits {
  /// NAME in NAME_ANNOUNCE / SET_DEVICE.
  static const nameMaxBytes = 32;

  /// ADDRESS (endereçamento) in NAME_ANNOUNCE.
  static const addressMaxBytes = 16;

  static bool fits(String text, int maxBytes) =>
      utf8.encode(text).length <= maxBytes;
}
