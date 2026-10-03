import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'credentials_admin_provider.dart';

/// Who may start a firmware update: the Master or the Nível 4 PIN, asked
/// before every action that starts something on the units (Atualizar,
/// Tentar de novo, Continuar, Retomar). Pausar and Cancelar never ask:
/// stopping must stay one tap away.
///
/// **Relaxed for the bench** (docs/ota/before-production.md item 8,
/// 2026-10-02): the PIN is asked once, then not again until the app
/// restarts. `firmware/ci/check.sh --release` fails while this is true.
const otaPinOncePerSession = true;

/// Who unlocked the update in this app session (bench: once per session);
/// null = nobody yet.
final otaPinGrantProvider = StateProvider<EditorRole?>((_) => null);
