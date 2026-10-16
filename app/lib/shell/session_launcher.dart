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
Future<void> startSession(BuildContext context, {DayTemplate? template}) async {
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
  try {
    final store = manager.draftStore;
    if (store == null) {
      throw const StoreException('local_store_required');
    }
    await store.load();
    final controller = ActiveSessionController(draftStore: store);
    final sessionRepo = SessionRepository.local(database);

    if (template != null) {
      while (true) {
        try {
          await controller.buildFromTemplate(
            template,
            exerciseRepo: ExerciseRepository.local(database),
            sessionRepo: sessionRepo,
          );
          break;
        } on HistoryOrderReview catch (review) {
          if (!context.mounted) {
            controller.dispose();
            return;
          }
          final chosen = await chooseHistoryOrder(context, review);
          if (chosen == null) {
            controller.dispose();
            return;
          }
          await sessionRepo.resolveOrder(review, chosen);
        }
      }
    } else {
      controller.seedEmpty(name: customName, focus: '');
    }

    if (manager.hasActive) {
      controller.dispose(); // cancels its pending autosave
      return;
    }
    await controller.flushPersistence();
    manager.register(controller);
  } catch (error) {
    if (context.mounted) {
      await showWriteFailed(context, error);
    }
    return;
  } finally {
    manager.endLaunch();
  }

  if (!context.mounted) {
    return;
  }
  await openActiveSession(context, manager);
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

/// Finishes [controller]'s workout inside the single write transaction that
/// [transact] runs, and only once that transaction has COMMITTED hands the
/// finish snapshot to [manager], so the workout can be resumed from History.
/// (`finish()` notifies inside the transaction, before the commit; adopting
/// there would let a failed commit replace a good snapshot.)
///
/// One source operation: its ticket spans the transaction, the draft clear
/// inside it and the awaited `recordFinished`, including that save's error
/// and clear continuations, so a capture cannot take its boundary between
/// the COMMIT and the persisted snapshot.
Future<String> finishWorkout(
  ActiveSessionController controller,
  SessionManager? manager, {
  required WorkoutRepository repository,
}) async {
  // Prepare on the synchronous call stack before the first await.
  controller.prepareFinish(repository);
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
