import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'auth/auth_store.dart';
import 'capture/capture_journal.dart';
import 'capture/capture_startup.dart';
import 'capture/capture_transport.dart';
import 'capture/session_capture_hooks.dart';
import 'capture/source_write_gate.dart';
import 'capture/startup_inventory.dart';
import 'data/active_session_draft.dart';
import 'data/finished_session_store.dart';
import 'data/catalog_seed.dart';
import 'data/is_template_backfill.dart';
import 'data/muscle_target_repository.dart';
import 'data/session_repository.dart';
import 'data/session_writer.dart';
import 'data/template_absorb.dart';
import 'data/top_set_backfill.dart';
import 'identity/identity_service.dart';
import 'l10n/app_localizations.dart';
import 'session/session_manager.dart';
import 'session/workout_notification.dart';
import 'settings/settings_service.dart';
import 'shell/app_shell.dart';
import 'shell/session_launcher.dart';
import 'sync/db.dart';
import 'sync/db.dart' as sync_db show openDatabase;
import 'sync/sync_health.dart';
import 'theme/app_theme.dart';
import 'ui/capture_recovery_screen.dart';
import 'ui/onboarding_screen.dart';
import 'units/unit_service.dart';
import 'util/error_surface.dart';
import 'widgets/w_dialog.dart';

final appNavigatorKey = GlobalKey<NavigatorState>();

enum HomeRoute { onboarding, shell }

HomeRoute homeRouteFor({required bool onboardingComplete}) =>
    onboardingComplete ? HomeRoute.shell : HomeRoute.onboarding;

bool shouldConnectSync({required bool syncEnabled, required bool loggedIn}) =>
    syncEnabled && loggedIn;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Turn an uncaught build exception into a readable, copyable card instead of
  // Flutter's featureless gray box, whose text only ever reaches the device log.
  // Skip this in debug builds so Flutter's red error screen — with its fuller
  // on-screen diagnostics — stays available to developers.
  if (!kDebugMode) installErrorSurface();

  // Load locale date symbols so DateFormat can render localized weekday and
  // month names for every supported locale (it/de/es), not just en.
  await initializeDateFormatting();

  // Capture first: before settings, the database, identity, boot migrations,
  // the stored-workout loaders or sync touch anything, check whether a data
  // capture holds the source and keep any stored bytes a loader would delete.
  final appSupport = await getApplicationSupportDirectory();
  final capture = CaptureLocations(appSupport);
  // Every source writer from here on admits through this one gate.
  final gate = SourceWriteGate(stateDirectory: capture.gate);
  appSourceGate = gate;
  final boot = _AppBoot(RawPreservation(capture.preparation, base: appSupport));
  final outcome = await runCaptureAwareStartup(
    journal: CaptureJournal(capture.journal, base: appSupport),
    probeGate: () => probeSourceGate(gate, base: appSupport),
    source: appSupport,
    preservation: RawPreservation(capture.preparation, base: appSupport),
    files: [
      await draftStartupFile(boot.draftStore, (_) => boot.loadDraft()),
      await finishedStartupFile(boot.finishedStore, boot.loadFinished),
    ],
    steps: boot,
    now: DateTime.now(),
  );
  // Without the capture plugin (not capture-capable), a store whose bytes
  // could not be preserved is simply not loaded and stays on disk as it is;
  // see StartupAllowed.skippedLoaders.
  if (outcome case CaptureRecoveryRequired(:final recovery)) {
    runApp(CaptureRecoveryApp(recovery: recovery));
    return;
  }

  final settingsService = boot.settingsService;
  final auth = boot.auth;
  final syncHealth = SyncHealth(
    status: db.statusStream,
    initial: db.currentStatus,
    pendingChanges: pendingUploadCount,
    signedIn: () => auth.email != null,
    syncEnabled: () => settingsService.syncEnabled,
    settings: settingsService,
  );
  await syncHealth.start();

  runApp(App(
    syncHealth: syncHealth,
    auth: auth,
    settingsService: settingsService,
    unitService: boot.unitService,
    identity: boot.identity,
    sessionManager: boot.sessionManager,
  ));
}

/// The ordinary boot, step by step in its long-standing order:
/// settings → openDatabase → identity → backfills → absorb →
/// SessionManager/notification → resume draft → finished snapshot →
/// optional connectSync. [runCaptureAwareStartup] decides whether it runs.
class _AppBoot implements OrdinaryStartupSteps {
  _AppBoot(this.preservation);

  /// Where a capture keeps the pre-flush draft bytes.
  final RawPreservation preservation;

  final draftStore = DraftStore();
  final finishedStore = FinishedSessionStore();
  final settingsService = SettingsService();
  final unitService = UnitService();
  final auth = AuthStore();
  final identity = IdentityService();
  late final SessionManager sessionManager;

  /// The session side of a data capture (commit input, drain and flush,
  /// freeze/resume callbacks).
  late final SessionCaptureHooks captureHooks;

  @override
  Future<void> loadSettings() async {
    // Load client-local settings first so apiBaseUrl is set before
    // openDatabase/connectSync (PowerSync and the connector read it at
    // startup).
    await settingsService.load();
    await unitService.load();
    apiBaseUrl = settingsService.serverUrl;
  }

  @override
  Future<void> openDatabase() => sync_db.openDatabase();

  @override
  Future<void> initIdentity() => identity.init(
        probeExistingUserId: () => SessionRepository(db).anyUserId(),
      );

  @override
  Future<void> runBootMigrations() =>
      runSourceWrite('boot.migrations', (ticket) async {
        await backfillTopSets(db, parent: ticket);

        // Normalize is_template = NULL → 0 (rows created by pre-fix builds)
        // BEFORE absorb, so its de-dup queries (exact is_template = 0) can
        // see owned rows.
        await backfillIsTemplate(db, parent: ticket);

        // Absorb synced template rows into user-owned rows (nothing is
        // locked).
        await absorbTemplates(db, identity.currentUserId, parent: ticket);
      });

  @override
  Future<void> prepareSessions() async {
    sessionManager = SessionManager(finishedStore: finishedStore);
    sessionManager.init();
    captureHooks = SessionCaptureHooks(
      manager: sessionManager,
      preservation: preservation,
    );
    final workoutNotification = WorkoutNotification();
    await workoutNotification.init(
      onTap: () {
        final ctx = appNavigatorKey.currentContext;
        if (ctx != null) openActiveSession(ctx, sessionManager);
      },
      onAdd30: () => sessionManager.add30FromNotification(),
    );
    sessionManager.notifier = workoutNotification;
  }

  Future<void> loadDraft() => sessionManager.resumeFromDraft(store: draftStore);

  Future<void> loadFinished(DateTime now) =>
      sessionManager.loadLastFinished(now: now);

  @override
  Future<void> connect() async {
    final loggedIn = await auth.load();
    if (shouldConnectSync(
        syncEnabled: settingsService.syncEnabled, loggedIn: loggedIn)) {
      await connectSync(auth); // resume sync only for an opted-in remembered session
    }
  }
}

/// Signs out and wipes the local data, as one admitted operation: stops
/// sync and clears the database, revokes and forgets the tokens, turns sync
/// off and forgets the last sync time. Refused whole (`admission_closed`,
/// nothing changed) while a data capture prepares or holds the source.
Future<void> logOutAndForget({
  required AuthStore auth,
  required SettingsService settings,
  required SyncHealth syncHealth,
}) async {
  TransportAdmission.instance.ensureOpen('account.logout');
  await runSourceWrite('account.logout', (ticket) async {
    TransportAdmission.instance.ensureOpen('account.logout');
    await disconnectAndClear(parent: ticket);
    await auth.logout();
    await settings.setSyncEnabled(false, parent: ticket);
    // Forget this account's last sync (clear() also recomputes).
    await syncHealth.clear(parent: ticket);
  });
}

class App extends StatefulWidget {
  const App({
    super.key,
    required this.auth,
    required this.settingsService,
    required this.unitService,
    required this.identity,
    required this.sessionManager,
    required this.syncHealth,
  });

  final AuthStore auth;
  final SettingsService settingsService;
  final UnitService unitService;
  final IdentityService identity;
  final SessionManager sessionManager;
  final SyncHealth syncHealth;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  Future<void> _onLogout() async {
    await logOutAndForget(
      auth: widget.auth,
      settings: widget.settingsService,
      syncHealth: widget.syncHealth,
    );
    setState(() {}); // returns to the local app shell, not a login wall
  }

  Future<void> _onOnboardingChosen(
      BuildContext ctx, OnboardingChoice choice) async {
    try {
      await runSourceWrite('onboarding.complete', (ticket) async {
        if (choice == OnboardingChoice.starter) {
          await runSourceWrite('onboarding.seed', (ticket) async {
            await db.writeTransaction(
              (tx) => seedStarterCatalog(
                  PowerSyncTxExecutor(tx), widget.identity.currentUserId),
            );
            await MuscleTargetRepository(db).seedDefaultsIfEmpty(
                widget.identity.currentUserId,
                parent: ticket);
          }, parent: ticket);
        }
        // Notifies → re-route to shell.
        await widget.identity.completeOnboarding(parent: ticket);
      });
    } on SourceGateException catch (e) {
      // Refused while a data capture holds the source: nothing was seeded.
      if (ctx.mounted) await showWriteFailed(ctx, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: widget.unitService),
        ChangeNotifierProvider.value(value: widget.settingsService),
        ChangeNotifierProvider.value(value: widget.identity),
        ChangeNotifierProvider.value(value: widget.sessionManager),
        ChangeNotifierProvider.value(value: widget.syncHealth),
      ],
      // Builder is required so that ctx.watch<SettingsService>() is a
      // descendant of the MultiProvider (calling watch in _AppState.build()
      // would throw ProviderNotFoundException — _AppState is the provider's
      // parent, not a descendant).
      child: Builder(
        builder: (ctx) {
          final s = ctx.watch<SettingsService>();
          final identity = ctx.watch<IdentityService>();
          return MaterialApp(
            navigatorKey: appNavigatorKey,
            title: 'workout-tracker',
            theme: buildTheme(s.brightness, s.accentColor),
            locale: s.locale,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: homeRouteFor(
                        onboardingComplete: identity.onboardingComplete) ==
                    HomeRoute.onboarding
                ? OnboardingScreen(
                    onChosen: (choice) => _onOnboardingChosen(ctx, choice))
                : AppShell(onLogout: _onLogout, auth: widget.auth),
          );
        },
      ),
    );
  }
}
