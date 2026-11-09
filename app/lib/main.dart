import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as paths;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'animus/connection.dart';
import 'animus/config.dart';
import 'animus/entry.dart';
import 'animus/runtime.dart';
import 'animus/workout_send.dart';
import 'animus/recovery_review.dart';
import 'data/active_session_draft.dart';
import 'data/finished_session_store.dart';
import 'data/session_writer.dart';
import 'data/workflow_state_quarantine.dart';
import 'data/exercise_repository.dart' show DomainRecovery;
import 'identity/alkion_identity.dart';
import 'identity/alkion_flutter_identity.dart';
import 'files/publication_directory.dart';
import 'identity/identity_service.dart';
import 'identity/alkion_profile.dart';
import 'l10n/app_localizations.dart';
import 'recovery/backup.dart' as backup;
import 'recovery/recovery_host.dart';
import 'recovery/restore.dart';
import 'recovery/stored_copies.dart';
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
import 'ui/launch_failure_app.dart';
import 'util/error_surface.dart';
import 'units/unit_service.dart';
import 'widgets/kept_data_notice.dart';
import 'widgets/pending_input.dart';
import 'widgets/storage_recovery_banner.dart';
import 'widgets/w_toast.dart';
import 'catalog/catalog.dart';
import 'catalog/catalog_development.dart';
import 'catalog_ui/catalog_runtime_state.dart';
import 'catalog_ui/catalog_loading.dart';
import 'catalog_ui/catalog_scope.dart';
import 'history_mapping/history_mapping.dart';
import 'history_mapping/history_mapping_label.dart';

export 'ui/launch_failure_app.dart' show AlkionPreflightApp;

Future<LocalStore> openAlkionStore(AlkionProfile profile) => LocalStore.open(
  profile: profile,
  expectedProfileId: profile.profileId,
  schema: remoteRecoverySchemaRegistry(),
);
final appNavigatorKey = GlobalKey<NavigatorState>();

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
    this.animus,
    this.catalog,
    this.catalogUnavailable,
  ) {
    workoutSender = AnimusWorkoutSender(
      database: store,
      installationId: store.profile.installationId,
      connection: animus,
    );
    recoveryReview = AnimusRecoveryReview(
      database: store,
      installationId: store.profile.installationId,
      connection: animus,
      sender: workoutSender,
    );
  }
  final Directory supportRoot;
  final LocalStore store;
  final SettingsService settings;
  final UnitService units;
  final IdentityService identity;
  final SessionManager sessions;
  final AnimusConnectionController animus;
  late final AnimusWorkoutSender workoutSender;
  late final AnimusRecoveryReview recoveryReview;
  final CatalogRuntimeState? catalog;
  final bool catalogUnavailable;
  static Future<AlkionRuntime> open(
    Directory supportRoot, {
    WorkoutNotification? notifications,
    AnimusConnectionController Function(AlkionProfile, int)? connectionFactory,
    LocalStore? preparedStore,
    CatalogBundle? catalogBundle,
    Future<CatalogDevelopmentInput> Function()? catalogLoader,
    void Function(SettingsService settings)? onCatalogLoading,
  }) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    late final AlkionProfile profile;
    try {
      final selected = preparedStore == null
          ? await AlkionProfile.open(supportRoot: supportRoot)
          : await AlkionProfile.existing(supportRoot: supportRoot);
      if (selected == null ||
          (preparedStore != null &&
              (preparedStore.profile.root.path != selected.root.path ||
                  preparedStore.profile.installationId !=
                      selected.installationId ||
                  preparedStore.profileId != selected.profileId))) {
        throw const StoreException('entry_profile_conflict');
      }
      profile = selected;
    } catch (_) {
      await preparedStore?.close();
      rethrow;
    }
    final store = preparedStore ?? await openAlkionStore(profile);
    try {
      final settings = SettingsService.local(store),
          units = UnitService.local(store),
          identity = IdentityService.local(store);
      await settings.load();
      await units.load();
      await identity.load();
      if (catalogBundle == null &&
          (catalogLoader != null ||
              const bool.fromEnvironment('ALKION_CATALOG_DEV'))) {
        onCatalogLoading?.call(settings);
      }
      final catalogInput = catalogBundle == null
          ? await (catalogLoader ?? loadDevelopmentCatalog)()
          : CatalogDevelopmentInput(bundle: catalogBundle);
      var catalog = catalogInput.bundle == null
          ? null
          : CatalogRuntimeState(catalogInput.bundle!, store);
      var catalogUnavailable = catalogInput.unavailable;
      try {
        await catalog?.initialize();
      } on Object {
        catalog?.dispose();
        catalog = null;
        catalogUnavailable = true;
      }
      // Before any controller, autosave or notification owns the rows: copy
      // unreadable saved workout state into reviews and retire it, so it can
      // neither lock launch nor be overwritten. Storage failures propagate.
      await quarantineUnreadableWorkflowState(store, decoder: _decoderInfo);
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
        (connectionFactory ??
            (profile, generation) => createAnimusConnection(
              installationId: profile.installationId,
              profileId: profile.profileId,
              generation: generation,
              database: () => store,
            ))(profile, store.token.generation),
        catalog,
        catalogUnavailable,
      );
      sessions
        ..onPersistenceError = runtime._reportPersistenceFailure
        ..onPersistenceCleared = runtime._clearPersistenceFailure;
      try {
        runtime.workflowNotices.value = await WorkflowStateQuarantine(
          store,
        ).pendingNotices();
      } on Object {
        // Informational, like the catalog above: a notice that cannot be
        // read never blocks launch. Nothing was acknowledged, so it comes
        // back at the next launch.
      }
      runtime.historyMappings = await HistoryMappingStore(store).byExerciseId();
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

  final persistenceFailure = ValueNotifier<Object?>(null);

  /// Kept unreadable workout state whose one-time notice is not acknowledged
  /// yet; set once at open.
  final workflowNotices = ValueNotifier<List<KeptWorkflowState>>(const []);
  Future<void>? _acknowledging;

  /// The notice's OK: records that [reviewIds] were seen, then drops them
  /// from [workflowNotices]. A call while one is running joins it. A failed
  /// write drops them too, for this run only: nothing was recorded, so the
  /// notice shows again at the next launch. Never throws.
  Future<void> acknowledgeWorkflowNotices(Iterable<String> reviewIds) =>
      _acknowledging ??= _acknowledgeNow(
        reviewIds.toSet(),
      ).whenComplete(() => _acknowledging = null);

  Future<void> _acknowledgeNow(Set<String> shown) async {
    try {
      await WorkflowStateQuarantine(store).acknowledge(shown);
    } on Object {
      // The notice never blocks the app.
    }
    if (_closed) return;
    workflowNotices.value = [
      for (final notice in workflowNotices.value)
        if (!shown.contains(notice.reviewId)) notice,
    ];
  }

  /// Mapping rows already stored in the profile; display only.
  Map<String, HistoryMapping> historyMappings = const {};

  Future<void> _flushTail = Future.value();
  Future<void>? _retry;
  bool _closing = false;
  bool _ownersDisposed = false, _closed = false;

  bool _teardownBegan = false;

  /// Whether [close] got past its flush barrier and disposed the sessions,
  /// notifications and catalog owners.
  bool get ownersDisposed => _ownersDisposed;

  /// Whether [close] got past its flush barrier and began tearing down: the
  /// lifecycle observer, the persistence callbacks and possibly notifications
  /// are gone. While false after a failed [close] (the barrier itself
  /// refused), the runtime still works and can be shown again.
  bool get teardownBegan => _teardownBegan;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closing) {
      return;
    }
    unawaited(
      // An open editor (a History set card under a pulled-down shade) owes
      // nothing yet, so only a write that failed to land fails this flush.
      flushPersistence(includeOpenForms: false).catchError((Object error) {
        // The barrier retains owed input; the visible failure remains reviewable
        // on resume. A lifecycle callback is never a successful export boundary.
      }),
    );
  }

  /// Flushes every owner's owed writes in order. The strict default, used by
  /// backup, restore and [close], also refuses with `unsaved_editor_input`
  /// while an open form holds unsaved input; that refusal is not a storage
  /// failure, so it leaves the storage banner as it was. Every other failure
  /// raises the banner, and a clean flush clears it.
  Future<void> flushPersistence({bool includeOpenForms = true}) {
    commitPendingInput();
    final result = _flushTail.then((_) => _flushNow(includeOpenForms));
    _flushTail = result.then<void>((_) {}, onError: (Object error) {});
    return result;
  }

  Future<void> _flushNow(bool includeOpenForms) async {
    // An owed editor write that keeps failing must not hold back the other
    // owners: record its failure, flush them anyway, then report the first.
    (Object, StackTrace)? failure;
    try {
      await UnsavedEditors.instance.drainOrThrow(includeOpenForms: false);
    } catch (error, stack) {
      failure = (error, stack);
    }
    try {
      await sessions.flushPersistence();
      await settings.flushPersistence();
      await units.flushPersistence();
      await identity.flushPersistence();
      await catalog?.flushPersistence();
    } catch (error, stack) {
      failure ??= (error, stack);
    }
    if (failure != null) {
      _reportPersistenceFailure(failure.$1);
      Error.throwWithStackTrace(failure.$1, failure.$2);
    }
    if (!_closed) persistenceFailure.value = null;
    // Strict barriers also refuse while a form holds unsaved input. Nothing
    // is owed, so this refusal leaves the (now clear) banner alone.
    if (includeOpenForms) await UnsavedEditors.instance.drainOrThrow();
  }

  void _reportPersistenceFailure(Object error) {
    if (!_closed) persistenceFailure.value = error;
  }

  /// A later successful autosave clears the banner only while it still shows
  /// the autosave failure it replaces; any other failure stays visible.
  void _clearPersistenceFailure(Object error) {
    if (!_closed && identical(persistenceFailure.value, error)) {
      persistenceFailure.value = null;
    }
  }

  /// The banner's Retry: recovers the store, then re-runs the lenient flush.
  /// A call while one is running joins it, so a double tap recovers once.
  Future<void> retryPersistence() =>
      _retry ??= _retryNow().whenComplete(() => _retry = null);

  Future<void> _retryNow() async {
    // Once close() has begun, its own barrier owns the final flush.
    if (_closing) return;
    try {
      await store.recover();
      if (_closing) return;
      await flushPersistence(includeOpenForms: false);
    } catch (error) {
      _reportPersistenceFailure(error);
    }
  }

  /// Flushes, disposes every owner and closes the store. A failure clears
  /// [_closing] on every path, so a later call retries the remaining steps:
  /// a flush that failed runs again, owners already disposed are not
  /// disposed twice.
  Future<void> close({
    @visibleForTesting Future<void> Function()? closeStore,
  }) async {
    if (_closed) return;
    _closing = true;
    try {
      await _closeNow(closeStore);
    } catch (_) {
      _closing = false;
      rethrow;
    }
  }

  Future<void> _closeNow(Future<void> Function()? closeStore) async {
    // Fence remote callbacks synchronously, before any local barrier yields.
    // Drain covered API evidence before SQLite; provider cleanup is separate.
    final senderClose = workoutSender.close();
    final reviewClose = recoveryReview.close();
    unawaited(animus.close());
    final apiDrain = animus.drainApi();
    if (!_ownersDisposed) await flushPersistence();
    _teardownBegan = true;
    WidgetsBinding.instance.removeObserver(this);
    sessions
      ..onPersistenceError = null
      ..onPersistenceCleared = null;
    await senderClose;
    await reviewClose;
    await apiDrain;
    if (!_ownersDisposed) {
      await sessions.closeNotifications();
      sessions.dispose();
      catalog?.dispose();
      _ownersDisposed = true;
    }
    await (closeStore ?? store.close)();
    settings.dispose();
    units.dispose();
    identity.dispose();
    persistenceFailure.dispose();
    workflowNotices.dispose();
    workoutSender.dispose();
    recoveryReview.dispose();
    animus.dispose();
    _closed = true;
  }
}

const _decoderTimeout = Duration(seconds: 2);

/// The running build for the quarantine's decoder record. A version that
/// cannot be read is recorded as `unknown`; it never fails the quarantine.
/// Only called once damage is found, so a clean launch calls no plugin; a
/// platform that does not answer within [_decoderTimeout] counts as unknown.
Future<DecoderInfo> _decoderInfo() async {
  try {
    final info = await PackageInfo.fromPlatform().timeout(_decoderTimeout);
    return DecoderInfo(
      appVersion: info.version.isEmpty ? 'unknown' : info.version,
      buildNumber: info.buildNumber.isEmpty ? 'unknown' : info.buildNumber,
    );
  } on Object {
    return DecoderInfo();
  }
}

Future<void> main() async {
  // First, so even a failure while starting never shows the bare gray box.
  installReleaseErrorSurface();
  WidgetsFlutterBinding.ensureInitialized();
  // Before anything renders, including the launch failure screen.
  GoogleFonts.config.allowRuntimeFetching = false;
  await startAlkion();
}

/// The body of [main]: finds the checked support root and launches. A failure
/// before [launchAlkion] can present its own screen shows the launch failure
/// screen, whose Try again re-runs this whole body.
Future<void> startAlkion({
  @visibleForTesting Future<Directory> Function()? supportRoot,
  @visibleForTesting Future<void> Function(Directory root)? launch,
  @visibleForTesting void Function(Widget app) present = runApp,
}) async {
  try {
    final root = await (supportRoot ?? checkedAlkionSupportRoot)();
    await (launch ?? launchAlkion)(root);
  } catch (error) {
    present(
      AlkionPreflightApp(
        error: error,
        relaunch: () => startAlkion(
          supportRoot: supportRoot,
          launch: launch,
          present: present,
        ),
      ),
    );
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
  Future<CatalogDevelopmentInput> Function()? catalogLoader,
}) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  Future<void> relaunch() =>
      launchAlkion(root, present: present, catalogLoader: catalogLoader);
  try {
    final service = RestoreService(root);
    final entry = AnimusEntryLifecycle(root);
    await entry.recover();
    final fresh = await service.freshState();
    if (fresh != null) {
      AnimusConfig? entryConfig;
      var entryMisconfigured = false;
      try {
        entryConfig = readAnimusEntryConfig();
      } on Object {
        entryMisconfigured = true;
      }
      present(
        AlkionFirstStartApp(
          service: service,
          state: fresh,
          entryConfig: entryConfig,
          entryMisconfigured: entryMisconfigured,
          prepareConnection: entry.prepareConnection,
          abandonAuthentication: entry.abandonAuthentication,
          hasLocalProfile: () => entry.hasLocalProfile,
          continueOffline: () async {
            await entry.continueOffline();
            await _launchAlkionRuntime(
              root,
              present: present,
              relaunch: relaunch,
              catalogLoader: catalogLoader,
              preparedStore: entry.takePreparedStore(),
            );
          },
          confirmConnection: () async {
            final connection = await entry.confirmConnection();
            if (connection != null) {
              await _launchAlkionRuntime(
                root,
                present: present,
                relaunch: relaunch,
                catalogLoader: catalogLoader,
                connection: connection,
                preparedStore: entry.takePreparedStore(),
              );
            }
          },
          startLocal: () async {
            await entry.abandonAuthentication();
            final current = await service.freshState();
            if (current == null || !current.canStartLocal) {
              throw const StoreException('fresh_restore_interrupted');
            }
            await _launchAlkionRuntime(
              root,
              present: present,
              relaunch: relaunch,
              catalogLoader: catalogLoader,
            );
          },
          relaunch: relaunch,
        ),
      );
      return;
    }
    await _launchAlkionRuntime(
      root,
      present: present,
      relaunch: relaunch,
      catalogLoader: catalogLoader,
    );
  } catch (error) {
    await _presentLaunchFailure(
      root,
      error,
      present: present,
      relaunch: relaunch,
    );
  }
}

Future<void> _presentLaunchFailure(
  Directory root,
  Object error, {
  required void Function(Widget) present,
  required Future<void> Function() relaunch,
}) async {
  if (error is GenerationSelectionException &&
      error.category == 'restore_interrupted') {
    final service = RestoreService(root);
    present(
      AlkionRecoveryApp.interrupted(
        relaunch: relaunch,
        service: service,
        pending: await service.pending(),
      ),
    );
  } else {
    present(AlkionPreflightApp(error: error, relaunch: relaunch));
  }
}

Future<void> _launchAlkionRuntime(
  Directory root, {
  required void Function(Widget) present,
  required Future<void> Function() relaunch,
  AnimusConnectionController? connection,
  LocalStore? preparedStore,
  Future<CatalogDevelopmentInput> Function()? catalogLoader,
}) async {
  var displayedCatalogLoad = false;
  late final AlkionRuntime runtime;
  try {
    runtime = await AlkionRuntime.open(
      root,
      onCatalogLoading: (settings) {
        displayedCatalogLoad = true;
        // The real root's first frame waits (briefly) for the arm artwork,
        // so the native splash hands over to the same mark without a gap.
        if (identical(present, runApp)) holdFirstFrameForStartupMark();
        present(
          CatalogLoadingApp(accent: settings.accent, locale: settings.locale),
        );
      },
      connectionFactory: connection == null ? null : (_, _) => connection,
      preparedStore: preparedStore,
      catalogLoader: catalogLoader,
    );
  } catch (error) {
    // Once loading replaces first-start, its action handler is disposed and
    // cannot present a failure. Before takeover, keep its inline error handling.
    if (!displayedCatalogLoad) rethrow;
    await _presentLaunchFailure(
      root,
      error,
      present: present,
      relaunch: relaunch,
    );
    return;
  }
  present(
    AlkionApp(
      runtime: runtime,
      revealCatalog: displayedCatalogLoad && runtime.catalog != null,
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
    Future<StoredCopyRoots> Function()? copyRoots,
    @visibleForTesting this.closeStore,
  }) : backupDirectory = backupDirectory ?? _privateBackupDirectory,
       copyRoots =
           copyRoots ??
           (backupDirectory == null
               ? platformStoredCopyRoots
               : () async => StoredCopyRoots(backups: await backupDirectory()));
  final AlkionRuntime runtime;
  final Future<void> Function() relaunch;
  final void Function(Widget app) present;
  final Future<Directory> Function() backupDirectory;

  /// Where the private copies are, for the read-only last-backup date and
  /// stored-copy sizes. Resolving them creates nothing.
  final Future<StoredCopyRoots> Function() copyRoots;

  /// Test seam for [AlkionRuntime.close]'s store step; null in the app.
  final Future<void> Function()? closeStore;

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
  Future<DateTime?> lastBackupCreated() async =>
      newestBackupCreated((await copyRoots()).backups, profileId);

  @override
  Future<StoredCopySizes> storedCopies() async =>
      measureStoredCopies(await copyRoots());

  @override
  bool get workoutActive =>
      runtime.sessions.hasActive || runtime.sessions.launching;

  @override
  Future<void> restoreBackup(String path) async {
    final sessions = runtime.sessions;
    // Synchronously, before the first await: a running workout refuses the
    // restore, and holding the launch fence keeps one from starting or
    // resuming while the backup is verified. Released on every path.
    if (sessions.hasActive || !sessions.tryBeginLaunch()) {
      throw const StoreException('workout_active');
    }
    try {
      await _restoreHoldingLaunch(path);
    } finally {
      sessions.endLaunch();
    }
  }

  Future<void> _restoreHoldingLaunch(String path) async {
    final verified = await verifyBackup(path);
    verified.requireWriterVariant();
    if (verified.profileId != profileId) {
      throw const StoreException('foreign_profile');
    }
    if (runtime.sessions.hasActive) {
      throw const StoreException('workout_active');
    }
    await runtime.flushPersistence();
    // Read before close() disposes the settings owner.
    final (locale, brightness, accent) = (
      runtime.settings.locale,
      runtime.settings.brightness,
      runtime.settings.accent,
    );
    present(
      AlkionRestoringApp(
        locale: locale,
        brightness: brightness,
        accent: accent,
      ),
    );
    try {
      await runtime.close(closeStore: closeStore);
    } catch (error) {
      // Relaunching now would meet this runtime's still-open store as
      // `profile_in_use`; Reopen first resolves the failed close.
      present(
        AlkionRecoveryApp.failed(
          relaunch: _reopenAfterFailedClose,
          error: error,
          locale: locale,
          brightness: brightness,
          accent: accent,
        ),
      );
      return;
    }
    try {
      await RestoreService(
        runtime.supportRoot,
        schema: runtime.store.schema,
      ).restore(File(path));
      present(
        AlkionRecoveryApp.restored(
          relaunch: relaunch,
          locale: locale,
          brightness: brightness,
          accent: accent,
        ),
      );
    } catch (error) {
      present(
        AlkionRecoveryApp.failed(
          relaunch: relaunch,
          error: error,
          locale: locale,
          brightness: brightness,
          accent: accent,
        ),
      );
    }
  }

  /// Reopen after the runtime failed to close for a restore (nothing was
  /// restored). When the flush barrier itself refused, before any teardown,
  /// the same runtime still works and is shown again (its Animus connection,
  /// workout sender and recovery review stay closed until the next launch).
  /// Once teardown began, the close is retried and the app relaunched; a
  /// retry that fails again throws, which the screen shows as a retryable
  /// error. Never relaunches over a store this runtime still holds.
  Future<void> _reopenAfterFailedClose() async {
    if (!runtime.teardownBegan) {
      present(AlkionApp(runtime: runtime, recovery: this));
      return;
    }
    await runtime.close(closeStore: closeStore);
    await relaunch();
  }
}

class AlkionApp extends StatelessWidget {
  const AlkionApp({
    super.key,
    required this.runtime,
    this.revealCatalog = false,
    this.recovery,
    @visibleForTesting this.databaseOverride,
  });
  final AlkionRuntime runtime;
  final bool revealCatalog;
  final RecoveryHost? recovery;
  final LocalDatabase? databaseOverride;
  @override
  Widget build(BuildContext context) {
    final app = MultiProvider(
      providers: [
        Provider<LocalDatabase>.value(value: databaseOverride ?? runtime.store),
        Provider<RecoveryHost?>.value(value: recovery),
        ListenableProvider<AnimusWorkoutSendPort?>.value(
          value: runtime.workoutSender,
        ),
        ListenableProvider<AnimusRecoveryReviewPort?>.value(
          value: runtime.recoveryReview,
        ),
        Provider<CatalogDevelopmentInput>.value(
          value: CatalogDevelopmentInput(
            bundle: runtime.catalog?.bundle,
            unavailable: runtime.catalogUnavailable,
          ),
        ),
        ChangeNotifierProvider<AnimusConnectionController?>.value(
          value: runtime.animus,
        ),
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
          return MaterialApp(
            navigatorKey: appNavigatorKey,
            scaffoldMessengerKey: appScaffoldMessengerKey,
            title: AlkionIdentity.displayName,
            builder: (context, child) => _RuntimeNotificationNavigation(
              runtime: runtime,
              child: HistoryMappingScope(
                mappings: runtime.historyMappings,
                child: Stack(
                  children: [
                    if (child != null)
                      CatalogReadyReveal.startup(
                        enabled: revealCatalog,
                        child: child,
                      ),
                    // One self-contained notice child; later notices are
                    // siblings here, never folded into this banner.
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: StorageRecoveryBanner(
                        failure: runtime.persistenceFailure,
                        onRetry: runtime.retryPersistence,
                      ),
                    ),
                    // Built only while no storage error holds the top slot:
                    // the banner takes it, and the notice stays pending
                    // until Retry clears the error. Never two overlays.
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: ValueListenableBuilder<Object?>(
                        valueListenable: runtime.persistenceFailure,
                        builder: (context, failure, _) => failure != null
                            ? const SizedBox.shrink()
                            : KeptDataNotice(
                                notices: runtime.workflowNotices,
                                onAcknowledge:
                                    runtime.acknowledgeWorkflowNotices,
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
            home: const AppShell(),
          );
        },
      ),
    );
    return runtime.catalog == null
        ? app
        : CatalogScope(state: runtime.catalog!, child: app);
  }
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
          NotificationLimitation.unavailable =>
            l.alkionNotificationsUnavailable,
        };
        showWToast(
          navigation,
          message,
          duration: const Duration(seconds: 8),
          action: WToastAction(label: l.commonOk, onPressed: () {}),
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

Future<void> logOutAndForget({
  Object? auth,
  SettingsService? settings,
  Object? syncHealth,
}) async => AlkionIdentity.unavailable('account connection');
