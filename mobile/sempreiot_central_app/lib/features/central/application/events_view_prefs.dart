import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/theme/theme_provider.dart' show sharedPreferencesProvider;

/// "Limpar" on Eventos (2026-11-23): the moment from which the list is
/// shown, kept on this device across restarts — per central ([String?]
/// null = the tablet's own list).
///
/// **Nothing is erased.** The event table is the installation's record
/// (system reference §3.6.1): clearing only moves the line from which this
/// screen lists, so a test starts on an empty screen, and "Mostrar
/// anteriores" brings everything back. The central's mirror and the phones
/// are not touched by it.
final eventsClearedAtProvider =
    NotifierProvider.family<EventsClearedAt, DateTime?, String?>(
        EventsClearedAt.new);

class EventsClearedAt extends FamilyNotifier<DateTime?, String?> {
  String get _key => 'events_cleared_at_${arg ?? 'local'}';

  @override
  DateTime? build(String? arg) {
    final ms = _prefs()?.getInt(_key);
    return ms == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  /// The list starts now.
  void clear([DateTime? now]) {
    final at = (now ?? DateTime.now()).toUtc();
    state = at;
    _prefs()?.setInt(_key, at.millisecondsSinceEpoch);
  }

  /// Everything is listed again.
  void showAll() {
    state = null;
    _prefs()?.remove(_key);
  }

  /// Null where the app did not load them (a widget test): the choice then
  /// works for the session and is not remembered.
  SharedPreferences? _prefs() {
    try {
      return ref.read(sharedPreferencesProvider);
    } on UnimplementedError {
      return null;
    }
  }
}

/// Eventos' two views (2026-11-24): **grouped** — the lines of one network
/// incident in one tile — or **lines**, every line by itself. Kept on this
/// device; grouped until the operator says otherwise.
final eventsGroupedProvider =
    NotifierProvider<EventsGrouped, bool>(EventsGrouped.new);

class EventsGrouped extends Notifier<bool> {
  static const _key = 'events_grouped';

  @override
  bool build() => _prefs()?.getBool(_key) ?? true;

  void set(bool grouped) {
    state = grouped;
    _prefs()?.setBool(_key, grouped);
  }

  SharedPreferences? _prefs() {
    try {
      return ref.read(sharedPreferencesProvider);
    } on UnimplementedError {
      return null;
    }
  }
}
