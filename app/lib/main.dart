import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as paths;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'data/active_session_draft.dart';
import 'data/finished_session_store.dart';
import 'data/session_writer.dart';
import 'data/exercise_repository.dart';
import 'data/catalog_seed.dart';
import 'identity/alkion_identity.dart';
import 'identity/alkion_flutter_identity.dart';
import 'files/publication_directory.dart';
import 'identity/identity_service.dart';
import 'identity/alkion_profile.dart';
import 'l10n/app_localizations.dart';
import 'recovery/backup.dart' as backup;
import 'recovery/recovery_host.dart';
import 'recovery/restore.dart';
import 'session/session_manager.dart';
import 'session/workout_notification.dart';
import 'shell/session_launcher.dart';
import 'settings/settings_service.dart';
import 'shell/app_shell.dart';
import 'store/generation_selection.dart';
import 'store/local_store.dart';
import 'store/schema.dart';
import 'theme/app_theme.dart';
import 'ui/alkion_recovery/recovery_app.dart';
import 'ui/alkion_recovery/first_start_screen.dart';
import 'ui/onboarding_screen.dart';
import 'units/unit_service.dart';
import 'widgets/pending_input.dart';

Future<LocalStore> openAlkionStore(AlkionProfile profile) => LocalStore.open(
  profile: profile,
  expectedProfileId: profile.profileId,
  schema: workflowSchemaRegistry(),
);
final appNavigatorKey = GlobalKey<NavigatorState>();

enum HomeRoute { onboarding, shell }

HomeRoute homeRouteFor({required bool onboardingComplete}) =>
    onboardingComplete ? HomeRoute.shell : HomeRoute.onboarding;
bool shouldConnectSync({required bool syncEnabled, required bool loggedIn}) =>
    false;

/// Explicit root injection lets tests exercise the real production composition.
class AlkionRuntime with WidgetsBindingObserver {
  AlkionRuntime._(
    this.supportRoot,
    this.store,
    this.settings,
    this.units,
    this.identity,
    this.sessions,
  );
  final Directory supportRoot;
  final LocalStore store;
  final SettingsService settings;
  final UnitService units;
  final IdentityService identity;
  final SessionManager sessions;
  static Future<AlkionRuntime> open(
    Directory supportRoot, {
    WorkoutNotification? notifications,
  }) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final profile = await AlkionProfile.open(supportRoot: supportRoot);
    final store = await openAlkionStore(profile);
    try {
      final settings = SettingsService.local(store),
          units = UnitService.local(store),
          identity = IdentityService.local(store);
      await settings.load();
      await units.load();
      await identity.load();
      final drafts = DraftStore.local(store);
      final sessions = SessionManager(
        draftStore: drafts,
        finishedStore: FinishedSessionStore.local(store),
      );
      await sessions.resumeFromDraft();
      await sessions.loadLastFinished();
      sessions.init();
      final runtime = AlkionRuntime._(
        supportRoot,
        store,
        settings,
        units,
        identity,
        sessions,
      );
      final notifier = notifications ?? WorkoutNotification();
      notifier.locale = settings.locale?.languageCode;
      await sessions.initializeNotifications(notifier);
      WidgetsBinding.instance.addObserver(runtime);
      return runtime;
    } catch (_) {
      await store.close();
      rethrow;
    }
  }

  PreparedDomainAction? _onboardingIntent;
  Future<void> completeOnboarding(OnboardingChoice choice) async {
    if (choice == OnboardingChoice.starter) {
      final intent = _onboardingIntent ??= prepareStarterCatalog(store);
      await ExerciseRepository.local(store).commitPrepared(intent);
    }
    await identity.completeOnboarding();
    _onboardingIntent = null;
  }

  final persistenceFailure = ValueNotifier<Object?>(null);
  Future<void> _flushTail = Future.value();
  bool _closing = false;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closing) {
      return;
    }
    unawaited(
      flushPersistence().catchError((Object error) {
        // The barrier retains owed input; the visible failure remains reviewable
        // on resume. A lifecycle callback is never a successful export boundary.
      }),
    );
  }

  Future<void> flushPersistence() {
    commitPendingInput();
    final result = _flushTail.then((_) => _flushNow());
    _flushTail = result.then<void>((_) {}, onError: (Object error) {});
    return result;
  }

  Future<void> _flushNow() async {
    try {
      await UnsavedEditors.instance.drainOrThrow();
      await sessions.flushPersistence();
      await settings.flushPersistence();
      await units.flushPersistence();
      await identity.flushPersistence();
      persistenceFailure.value = null;
    } catch (error) {
      persistenceFailure.value = error;
      rethrow;
    }
  }

  Future<void> retryPersistence() async {
    try {
      await store.recover();
      await flushPersistence();
    } catch (error) {
      persistenceFailure.value = error;
    }
  }

  Future<void> close() async {
    _closing = true;
    try {
      await flushPersistence();
    } catch (_) {
      _closing = false;
      rethrow;
    }
    WidgetsBinding.instance.removeObserver(this);
    await sessions.closeNotifications();
    sessions.dispose();
    await store.close();
    settings.dispose();
    units.dispose();
    identity.dispose();
    persistenceFailure.dispose();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final root = await checkedAlkionSupportRoot();
    await launchAlkion(root);
  } catch (error) {
    runApp(AlkionPreflightApp(error: error));
  }
}

/// Identity is checked before even asking the platform for a storage directory.
Future<Directory> checkedAlkionSupportRoot({
  Future<AlkionAndroidStorage?> Function()? verifyIdentity,
  Future<Directory> Function()? supportDirectory,
}) async {
  final storage =
      await (verifyIdentity ?? AlkionFlutterIdentity.verifyPlatformIdentity)();
  final supplied = await (supportDirectory ?? getApplicationSupportDirectory)();
  final support = storage?.checkedSupportDirectory(supplied) ?? supplied;
  return paths.basename(support.path) == AlkionIdentity.applicationId
      ? support
      : Directory(paths.join(support.path, AlkionIdentity.applicationId));
}

/// Opens the selected store generation. An interrupted restore keeps every
/// store closed and shows its explicit complete/keep-current choice instead.
Future<void> launchAlkion(
  Directory root, {
  void Function(Widget app) present = runApp,
}) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  Future<void> relaunch() => launchAlkion(root, present: present);
  try {
    final service = RestoreService(root);
    final fresh = await service.freshState();
    if (fresh != null) {
      present(
        AlkionFirstStartApp(
          service: service,
          state: fresh,
          startLocal: () =>
              _launchAlkionRuntime(root, present: present, relaunch: relaunch),
          relaunch: relaunch,
        ),
      );
      return;
    }
    await _launchAlkionRuntime(root, present: present, relaunch: relaunch);
  } on GenerationSelectionException catch (error) {
    if (error.category != 'restore_interrupted') {
      present(AlkionPreflightApp(error: error));
      return;
    }
    final service = RestoreService(root);
    present(
      AlkionRecoveryApp.interrupted(
        relaunch: relaunch,
        service: service,
        pending: await service.pending(),
      ),
    );
  } catch (error) {
    present(AlkionPreflightApp(error: error));
  }
}

Future<void> _launchAlkionRuntime(
  Directory root, {
  required void Function(Widget) present,
  required Future<void> Function() relaunch,
}) async {
  final runtime = await AlkionRuntime.open(root);
  present(
    AlkionApp(
      runtime: runtime,
      recovery: RuntimeRecoveryHost(
        runtime,
        relaunch: relaunch,
        present: present,
      ),
    ),
  );
}

/// Manual backup/restore for the running runtime. Backup flushes owed input
/// and snapshots the open store. Restore verifies first, flushes, replaces the
/// UI, closes the runtime (all owners, timers and watches), and only then
/// stages and selects; the next runtime opens the selected generation.
final class RuntimeRecoveryHost implements RecoveryHost {
  RuntimeRecoveryHost(
    this.runtime, {
    required this.relaunch,
    this.present = runApp,
    Future<Directory> Function()? backupDirectory,
  }) : backupDirectory = backupDirectory ?? _privateBackupDirectory;
  final AlkionRuntime runtime;
  final Future<void> Function() relaunch;
  final void Function(Widget app) present;
  final Future<Directory> Function() backupDirectory;

  static Future<Directory> _privateBackupDirectory() async {
    if (!Platform.isAndroid) return getApplicationDocumentsDirectory();
    return checkedAndroidPublicationDirectory('document-backups');
  }

  @override
  String get profileId => runtime.store.profileId;

  @override
  Future<backup.BackupReceipt> createBackup() async {
    await runtime.flushPersistence();
    return backup.createBackup(runtime.store, await backupDirectory());
  }

  @override
  Future<backup.VerifiedBackup> verifyBackup(String path) =>
      backup.verifyBackupFile(File(path), schema: runtime.store.schema);

  @override
  Future<void> restoreBackup(String path) async {
    final verified = await verifyBackup(path);
    verified.requireWriterVariant();
    if (verified.profileId != profileId) {
      throw const StoreException('foreign_profile');
    }
    await runtime.flushPersistence();
    present(const AlkionRestoringApp());
    try {
      await runtime.close();
    } catch (error) {
      present(AlkionRecoveryApp.failed(relaunch: relaunch, error: error));
      return;
    }
    try {
      await RestoreService(
        runtime.supportRoot,
        schema: runtime.store.schema,
      ).restore(File(path));
      present(AlkionRecoveryApp.restored(relaunch: relaunch));
    } catch (error) {
      present(AlkionRecoveryApp.failed(relaunch: relaunch, error: error));
    }
  }
}

class AlkionApp extends StatelessWidget {
  const AlkionApp({super.key, required this.runtime, this.recovery});
  final AlkionRuntime runtime;
  final RecoveryHost? recovery;
  @override
  Widget build(BuildContext context) => MultiProvider(
    providers: [
      Provider<LocalDatabase>.value(value: runtime.store),
      Provider<RecoveryHost?>.value(value: recovery),
      Provider<DomainRecovery>.value(
        value: DomainRecovery(runtime.store.recover),
      ),
      ChangeNotifierProvider.value(value: runtime.settings),
      ChangeNotifierProvider.value(value: runtime.units),
      ChangeNotifierProvider.value(value: runtime.identity),
      ChangeNotifierProvider.value(value: runtime.sessions),
    ],
    child: Builder(
      builder: (context) {
        final settings = context.watch<SettingsService>();
        final identity = context.watch<IdentityService>();
        return MaterialApp(
          navigatorKey: appNavigatorKey,
          scaffoldMessengerKey: appScaffoldMessengerKey,
          title: AlkionIdentity.displayName,
          builder: (context, child) => ValueListenableBuilder<Object?>(
            valueListenable: runtime.persistenceFailure,
            builder: (context, error, _) => _RuntimeNotificationNavigation(
              runtime: runtime,
              child: Stack(
                children: [
                  if (child != null) child,
                  if (error != null)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: SafeArea(
                        child: Material(
                          color: Theme.of(context).colorScheme.errorContainer,
                          elevation: 4,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  AppLocalizations.of(
                                    context,
                                  ).alkionStoreRecoveryTitle,
                                ),
                                Text(
                                  AppLocalizations.of(
                                    context,
                                  ).alkionStoreRecoveryBody,
                                ),
                                TextButton(
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size(48, 48),
                                  ),
                                  onPressed: runtime.retryPersistence,
                                  child: Text(
                                    AppLocalizations.of(context).alkionRetry,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          theme: buildTheme(settings.brightness, settings.accent),
          locale: settings.locale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: identity.onboardingComplete
              ? const AppShell()
              : OnboardingScreen(onChosen: runtime.completeOnboarding),
        );
      },
    ),
  );
}

final appScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Defers cold-launch navigation and feedback until the selected app exists.
class _RuntimeNotificationNavigation extends StatefulWidget {
  const _RuntimeNotificationNavigation({
    required this.runtime,
    required this.child,
  });
  final AlkionRuntime runtime;
  final Widget child;
  @override
  State<_RuntimeNotificationNavigation> createState() =>
      _RuntimeNotificationNavigationState();
}

class _RuntimeNotificationNavigationState
    extends State<_RuntimeNotificationNavigation> {
  bool _scheduled = false, _opening = false;
  NotificationLimitation? _shown;
  @override
  void initState() {
    super.initState();
    widget.runtime.sessions.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(_RuntimeNotificationNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.runtime, widget.runtime)) {
      oldWidget.runtime.sessions.removeListener(_changed);
      widget.runtime.sessions.addListener(_changed);
      _shown = null;
      _changed();
    }
  }

  void _changed() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final sessions = widget.runtime.sessions;
      final limitation = sessions.notificationLimitation;
      final navigation = appNavigatorKey.currentContext;
      if (limitation != null && limitation != _shown && navigation != null) {
        _shown = limitation;
        final l = AppLocalizations.of(navigation);
        final message = switch (limitation) {
          NotificationLimitation.denied => l.alkionNotificationsDenied,
          NotificationLimitation.inexact => l.alkionNotificationsInexact,
          NotificationLimitation.unavailable =>
            l.alkionNotificationsUnavailable,
        };
        appScaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 8),
            action: SnackBarAction(label: l.commonOk, onPressed: () {}),
          ),
        );
      } else if (limitation == null) {
        _shown = null;
      }
      if (sessions.takeNotificationOpenRequest() &&
          !_opening &&
          navigation != null) {
        _opening = true;
        unawaited(
          openActiveSession(
            navigation,
            sessions,
          ).whenComplete(() => _opening = false),
        );
      }
    });
  }

  @override
  void dispose() {
    widget.runtime.sessions.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class AlkionPreflightApp extends StatelessWidget {
  const AlkionPreflightApp({super.key, this.error});
  final Object? error;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: AlkionIdentity.displayName,
    home: Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '${AlkionIdentity.displayName}\nLocal storage is unavailable. Your existing files are preserved.\n${error ?? ''}',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> logOutAndForget({
  Object? auth,
  SettingsService? settings,
  Object? syncHealth,
}) async => AlkionIdentity.unavailable('account connection');
