import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/active_session_draft.dart';
import '../data/day_template_repository.dart';
import '../data/exercise_repository.dart';
import '../data/models.dart';
import '../data/session_repository.dart';
import '../data/session_writer.dart';
import '../l10n/app_localizations.dart';
import '../session/active_session_controller.dart';
import '../session/active_session_screen.dart';
import '../session/resume.dart';
import '../session/session_manager.dart';
import '../store/local_store.dart';
import '../theme/motion.dart';
import '../widgets/w_dialog.dart';

/// Starts an active session, optionally pre-loaded from a [DayTemplate].
///
/// Builds an [ActiveSessionController], seeds it from [template] (or empty for
/// a custom session), guards [BuildContext.mounted], and pushes
/// [ActiveSessionScreen] on the **root** navigator wrapped in a
/// [ChangeNotifierProvider].
Future<void> startSession(
  BuildContext context, {
  DayTemplate? template,
  VoidCallback? onOpenPlan,
}) async {
  final manager = context.read<SessionManager>();
  final database = context.read<LocalDatabase>();
  // Read before any await so the context is still valid (used for the
  // localized custom-session name below).
  final customName = AppLocalizations.of(context).todayCustomSession;

  // A workout is already running → resume it instead of starting a new one.
  if (manager.hasActive) {
    await openActiveSession(context, manager);
    return;
  }

  // A second tap while this one is still building must not register a second
  // workout.
  if (!manager.tryBeginLaunch()) {
    return;
  }
  ActiveSessionController? unregisteredController;
  var launchReleased = false;
  try {
    // This committed read is the fresh-launch admission. Once admitted, a later
    // Disable does not interrupt the pending build or its eventual workout.
    DayTemplate? admittedTemplate;
    if (template != null) {
      admittedTemplate = await DayTemplateRepository.local(
        database,
      ).byId(template.id);
      if (admittedTemplate == null || !admittedTemplate.isActive) {
        if (context.mounted) {
          await _showPlanRefusal(
            context,
            AppLocalizations.of(
              context,
            ).trainingDayStartUnavailable(template.name),
            onOpenPlan: onOpenPlan,
          );
        }
        return;
      }
    }
    final store = manager.draftStore;
    if (store == null) {
      throw const StoreException('local_store_required');
    }
    await store.load();
    final controller = ActiveSessionController(draftStore: store);
    unregisteredController = controller;
    final sessionRepo = SessionRepository.local(database);

    if (admittedTemplate != null) {
      while (true) {
        try {
          await controller.buildFromTemplate(
            admittedTemplate,
            exerciseRepo: ExerciseRepository.local(database),
            sessionRepo: sessionRepo,
          );
          break;
        } on HistoryOrderReview catch (review) {
          if (!context.mounted) {
            return;
          }
          final chosen = await chooseHistoryOrder(context, review);
          if (chosen == null) {
            return;
          }
          await sessionRepo.resolveOrder(review, chosen);
        }
      }
    } else {
      controller.seedEmpty(name: customName, focus: '');
    }

    if (manager.hasActive) {
      return;
    }
    if (!context.mounted) return;
    await controller.flushPersistence();
    manager.register(controller);
    unregisteredController = null; // SessionManager now owns the controller.
  } on FreshPrescriptionUnavailableException catch (error) {
    if (context.mounted) {
      await showFreshPrescriptionUnavailable(
        context,
        error,
        onOpenPlan: onOpenPlan,
      );
    }
    return;
  } on FreshSessionLimitException catch (error) {
    manager.endLaunch();
    launchReleased = true;
    if (context.mounted) {
      await showFreshSessionLimit(context, error);
    }
    return;
  } catch (error) {
    if (context.mounted) {
      await showWriteFailed(context, error);
    }
    return;
  } finally {
    unregisteredController?.dispose();
    if (!launchReleased) manager.endLaunch();
  }

  if (!context.mounted) {
    return;
  }
  await openActiveSession(context, manager);
}

Future<void> _showPlanRefusal(
  BuildContext context,
  String message, {
  VoidCallback? onOpenPlan,
}) async {
  if (!context.mounted) return;
  final l = AppLocalizations.of(context);
  final open = await showWDialog<bool>(
    context,
    title: l.trainingStartUnavailable,
    message: message,
    actions: [
      WDialogAction(label: l.commonOk, value: false),
      if (onOpenPlan != null)
        WDialogAction(label: l.trainingOpenPlan, value: true),
    ],
  );
  if (open == true && context.mounted) onOpenPlan?.call();
}

Future<void> showFreshPrescriptionUnavailable(
  BuildContext context,
  FreshPrescriptionUnavailableException error, {
  VoidCallback? onOpenPlan,
}) {
  final l = AppLocalizations.of(context);
  return _showPlanRefusal(
    context,
    error.rirPolicy
        ? l.trainingRirPolicyUnavailable(error.exerciseName)
        : l.trainingRepStartUnavailable(error.exerciseName),
    onOpenPlan: onOpenPlan,
  );
}

/// Explains a refused fresh prescription without changing its source.
Future<void> showFreshSessionLimit(
  BuildContext context,
  FreshSessionLimitException error,
) async {
  if (!context.mounted) return;
  final l = AppLocalizations.of(context);
  final detail = switch (error.limit) {
    FreshSessionLimit.workingSets => l.alkionFreshWorkingLimit(
      error.exerciseName!,
      error.count!,
    ),
    FreshSessionLimit.warmupSets => l.alkionFreshWarmupLimit(
      error.exerciseName!,
      error.count!,
    ),
    FreshSessionLimit.templateSlots => l.alkionFreshSlotLimit(error.count!),
    FreshSessionLimit.generatedSets => l.alkionFreshTotalLimit(
      error.exerciseName!,
    ),
  };
  await showWDialog<void>(
    context,
    title: l.alkionFreshLimitTitle,
    message: '$detail\n\n${l.alkionFreshLimitCorrection}',
    actions: [WDialogAction(label: l.commonOk, value: null)],
  );
}

/// Pushes the session route for the manager's active controller (no-op if
/// none or already open). Shared by start, mini-bar tap and notification tap.
Future<void> openActiveSession(
  BuildContext context,
  SessionManager manager,
) async {
  final controller = manager.active;
  if (controller == null || manager.screenOpen) {
    return;
  }

  await Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 250),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) =>
          ChangeNotifierProvider<ActiveSessionController>.value(
            value: controller,
            child: const ActiveSessionScreen(),
          ),
      transitionsBuilder: (_, anim, __, child) {
        final curved = CurvedAnimation(parent: anim, curve: Motion.curve);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.06),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    ),
  );
}

/// Restores the finished workout [sessionId] as the live workout, without
/// navigating, and returns its controller — or null when it cannot be resumed
/// right now: another workout is active, a launch is already running (a
/// double tap), its snapshot is no longer resumable, or the session is gone.
///
/// Writes nothing to the database: the finished rows are replaced only when
/// the resumed workout is finished again (see `replaceSession`).
Future<ActiveSessionController?> prepareResume(
  SessionManager manager,
  String sessionId, {
  required SessionRepository sessionRepo,
  required ExerciseRepository exerciseRepo,
  required DraftStore draftStore,
  DateTime? now,
}) async {
  final t = now ?? DateTime.now();
  final f = manager.lastFinished;
  // Every guard runs synchronously, before the first await: two taps must not
  // both get through and register two copies of the same session.
  if (manager.hasActive || f == null || !isResumable(f, sessionId, t)) {
    return null;
  }
  if (!manager.tryBeginLaunch()) {
    return null;
  }
  try {
    final session = await sessionRepo.sessionById(sessionId);
    if (session == null) {
      throw const StoreException('workout_recovery_review_required');
    }
    final rows = await sessionRepo.setsForSession(sessionId);
    final original = await restoreFinishedDraft(
      f,
      rows,
      durationMin: session.durationMin,
      exerciseRepo: exerciseRepo,
      sessionRepo: sessionRepo,
      now: t,
    );
    final payload = original.toJson()
      ..['sessionDate'] = session.date
      ..['sessionDateEvidence'] = session.dateEvidence?.toJson()
      ..['localRevision'] = session.localRevision
      ..['setBases'] = await sessionRepo.allSetBases(sessionId);
    final draft = SessionDraft.fromJson(payload);
    if (manager.hasActive) {
      return null;
    }
    await draftStore.load();
    await draftStore.save(draft);
    final controller = ActiveSessionController.fromDraft(
      draft,
      draftStore: draftStore,
    );
    manager.register(controller);
    return controller;
  } finally {
    manager.endLaunch();
  }
}

/// Finishes [controller]'s workout through its local repository workflow and
/// hands the committed snapshot to [manager] for History resume.
/// Prepare before awaiting, commit the local workflow, then adopt its already
/// durable finished snapshot. A failed/uncertain commit retains the same intent
/// for reconciliation rather than publishing a new successful finish.
Future<String> finishWorkout(
  ActiveSessionController controller,
  SessionManager? manager, {
  required WorkoutRepository repository,
}) async {
  // commitFinish installs its shared completion before synchronous preparation.
  final id = await controller.commitFinish(repository);
  final finished = controller.lastFinished;
  if (finished != null) {
    manager?.adoptCommitted(finished);
  }
  return id;
}

/// History's Resume action: restores the finished workout [sessionId] and
/// opens it. Callers handle "another workout is running" themselves (it needs
/// a dialog); here that case, like every other refusal, is a silent no-op.
Future<void> resumeFinishedSession(
  BuildContext context,
  String sessionId,
) async {
  final manager = context.read<SessionManager>();
  final controller = await prepareResume(
    manager,
    sessionId,
    sessionRepo: SessionRepository.local(context.read<LocalDatabase>()),
    exerciseRepo: ExerciseRepository.local(context.read<LocalDatabase>()),
    draftStore: manager.draftStore!,
  );
  if (controller == null || !context.mounted) {
    return;
  }
  await openActiveSession(context, manager);
}

/// Returns the next [DayTemplate] in position-based rotation, or null if there
/// are no day templates.
///
/// Delegates to [DayTemplateRepository.nextInRotation].
Future<DayTemplate?> nextInRotation(
  DayTemplateRepository dayRepo,
  SessionRepository sessionRepo,
) async {
  final days = await dayRepo.watchDays().first;
  return selectNextDay(days, await sessionRepo.lastDayForRotation());
}

Future<String?> chooseHistoryOrder(
  BuildContext context,
  HistoryOrderReview review,
) {
  final l = AppLocalizations.of(context);
  return showWDialog<String>(
    context,
    title: l.alkionOrderChoiceTitle,
    message: l.alkionOrderChoiceBody,
    actions: [
      for (final row in review.choices)
        WDialogAction(
          label:
              '${row['split_label'] ?? ''} · ${row['date']} · ${row['session_id']}',
          value: row['session_id'] as String,
        ),
    ],
  );
}

/// While a data capture holds the source (its callbacks are frozen) a new
/// workout would live in memory only: refuse it with the hold's copy and
/// return true. Otherwise false.
Future<bool> refusedDuringCaptureHold(
  BuildContext context,
  SessionManager manager,
) async {
  if (!manager.callbacksFrozen) {
    return false;
  }
  final l = AppLocalizations.of(context);
  await showWDialog<void>(
    context,
    title: l.captureWritesPausedTitle,
    message: l.captureNewWorkoutRefused,
    actions: [WDialogAction(label: l.commonOk, value: null)],
  );
  return true;
}
