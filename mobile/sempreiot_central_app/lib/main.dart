import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'core/config/amplify_config.dart';
import 'features/iot/data/services/iot_credentials_service.dart';
import 'core/config/app_config.dart';
import 'core/database/app_database.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_provider.dart';
import 'features/app/application/app_init_provider.dart';
import 'features/central/application/safr_ingest_provider.dart';
import 'features/central/application/supervision_provider.dart';
import 'features/central/data/services/factory_init_service.dart';
import 'presentation/screens/auth/login_screen.dart';
import 'presentation/screens/main/main_screen.dart';
import 'presentation/screens/splash/splash_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load();
  await _configureAmplify(); // Both modes need Amplify Auth
  final prefs = await SharedPreferences.getInstance();
  debugPrintPreferences(prefs);
  runApp(ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    child: const SempreIoTApp(),
  ));
}

Future<void> _configureAmplify() async {
  try {
    await Amplify.addPlugin(AmplifyAuthCognito());
    await Amplify.configure(buildAmplifyConfig());
  } on AmplifyAlreadyConfiguredException {
    // safe to ignore during hot restart
  }
}

class SempreIoTApp extends ConsumerWidget {
  const SempreIoTApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);
    return MaterialApp(
      title: 'SempreIoT',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      home: AppConfig.isCentral ? const _CentralRoot() : const _AppRoot(),
    );
  }
}

// ── APP mode ─────────────────────────────────────────────────────────────────

class _AppRoot extends ConsumerWidget {
  const _AppRoot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appState = ref.watch(appInitProvider);
    return appState.when(
      data: (ready) => ready ? const MainScreen() : const LoginScreen(),
      loading: () => const SplashScreen(),
      error: (_, __) => const LoginScreen(),
    );
  }
}

// ── CENTRAL mode ──────────────────────────────────────────────────────────────

/// Runs once on central-mode startup:
///   1. Ensures default metadata rows exist in the DB.
///   2. If FACTORY env var is present, applies factory reset from its JSON.
///   3. Starts serial data ingestion.
///   4. Purges serial packets older than 30 days.
final centralInitProvider = FutureProvider<void>((ref) async {
  final db = ref.read(appDatabaseProvider);

  await db.seedDefaultMetadata();

  if (AppConfig.hasFactory) {
    await FactoryInitService.applyFactory(db, AppConfig.factoryJson);
  }

  // SAFR pipeline: ingest (parse + persist + ACK), supervision watchdog
  // and downlink (TIME_SYNC on link-up).
  ref.read(safrIngestProvider);
  ref.read(supervisionProvider);

  await db.deleteOlderThan(
    DateTime.now().toUtc().subtract(const Duration(days: 30)),
  );
});

/// Lock/unlock state is managed inside MainScreen itself.
class _CentralRoot extends ConsumerWidget {
  const _CentralRoot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initState = ref.watch(centralInitProvider);
    return initState.when(
      data: (_) => const MainScreen(),
      loading: () => const SplashScreen(),
      // Fail open in central mode — device must remain functional.
      error: (_, __) => const MainScreen(),
    );
  }
}
