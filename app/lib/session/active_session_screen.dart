import '../catalog_ui/catalog_picker.dart';
import '../catalog_ui/catalog_scope.dart';
import '../catalog_ui/catalog_runtime_state.dart';
import '../catalog_ui/catalog_evidence_widgets.dart';
import '../domain/catalog_execution.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/exercise_repository.dart';
import '../data/day_template_repository.dart';
import '../data/catalog_execution_repository.dart';
import '../data/body_workload_projection.dart';
import '../ui/body_figure.dart';
import '../data/session_repository.dart';
import '../data/session_writer.dart';
import '../l10n/app_localizations.dart';
import '../settings/settings_service.dart';
import '../shell/session_launcher.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/workout_canvas.dart';
import '../theme/alkion_icon.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../util/error_message.dart';
import '../widgets/fit_label.dart';
import '../widgets/pending_input.dart';
import '../widgets/w_action_sheet.dart';
import '../widgets/w_dialog.dart';
import '../widgets/w_toast.dart';
import 'active_session_controller.dart';
import 'confirmed_set_feedback.dart';
import 'exercise_block.dart';
import 'catalog_set_values_editor.dart';
import 'exercise_picker_sheet.dart';
import 'log_set_bar.dart';
import 'reorder_exercises_sheet.dart';
import 'resume.dart';
import '../widgets/glyph_loading.dart';
import 'session_header.dart';
import 'session_manager.dart';
import 'session_summary_screen.dart';
import 'weekly_volume_sheet.dart';

/// Full-bleed overlay for an active workout session.
///
/// Visual spec: `docs/design_handoff_workout_tracker/design/app/screen-log.jsx`
/// `ActiveSession`.
///
/// - Sticky [SessionHeader]: minimize, title/focus, sets progress + elapsed,
///   the workout ⋯ menu, and — while resting — a draining rest bar with a
///   countdown, "Next · …" line and +30s / Skip chips (no floating card
///   covers the list anymore).
/// - Body: the list of [ExerciseBlock]s + dashed "Add exercise".
/// - Pinned [LogSetBar] in `bottomNavigationBar`: logs the live set (starting
///   rest afterward) or finishes the workout when nothing is live.
/// - Finish prepares and commits a revisioned local workout action.
class ActiveSessionScreen extends StatefulWidget {
  const ActiveSessionScreen({super.key});

  @override
  State<ActiveSessionScreen> createState() => _ActiveSessionScreenState();
}

class _ActiveSessionScreenState extends State<ActiveSessionScreen> {
  Timer? _ticker;

  // Captured references so the ticker/dispose can reach the manager and
  // controller without a BuildContext.
  SessionManager? _manager;
  ActiveSessionController? _controller;

  /// The app-level messenger the live workout's Undo toasts go to; they act
  /// on this screen, so they leave with it ([_leaving]).
  ScaffoldMessengerState? _messenger;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _undoToast;
  int _logFeedbackEvent = 0;
  SetState? _confirmedLogCandidate;

  // Haptic guards: fire once per countdown. Re-armed (cleared) when +30s pushes
  // remaining back above the respective threshold.
  bool _tickHapticFired = false; // 3s remaining → selectionClick
  bool _buzzHapticFired = false; // 0s remaining → vibrate

  /// On the live card, so logging can scroll the next live set into view.
  final GlobalKey _liveCardKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 1-second ticker that forces a rebuild for the elapsed counter and rest timer.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      // In the background the scheduled rest-end notification alerts
      // instead: no haptics here (one buzz, not two), and the rest is left
      // for the resume reconciliation, so stopping it cannot replace that
      // alert. Guards consumed here re-arm if the rest is still running.
      if (!(_manager?.appForeground ?? true)) {
        _tickHapticFired = _buzzHapticFired = true;
        return;
      }
      _handleRestHaptics();
      // Screen-open rest revert: when remaining hits 0 while the screen is
      // open, stop the rest here (the OS alarm covers the backgrounded case;
      // the deleted SessionManager Dart timer used to cover this one).
      // stopRest is a guarded no-op if already stopped.
      // While a Finish or notification action is pending the rest is not
      // stopped here; the controller refuses rest changes until it settles.
      final c = _controller;
      final start = c?.restStart;
      if (c != null && start != null && !c.callbacksFrozen) {
        final remaining =
            c.restTotal - DateTime.now().difference(start).inSeconds;
        if (remaining <= 0) {
          c.stopRest();
        }
      }
      setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<SessionManager>().screenOpen = true;
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _manager = context.read<SessionManager>();
    _controller = context.read<ActiveSessionController>();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  /// Back or minimize: an Undo left up (set logged or set removed) would
  /// show over Today and act on a workout no longer on screen. Called as the
  /// route pops, never from dispose (the messenger may be going away too).
  void _leaving() {
    if (_undoToast != null) _messenger?.clearSnackBars();
  }

  /// Tracks an Undo toast until it closes, so [_leaving] can take it down.
  void _trackUndoToast(
    ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? toast,
  ) {
    if (toast == null) return;
    _undoToast = toast;
    toast.closed.then((_) {
      // A replaced toast closes after its successor is shown; only the
      // latest tracked toast clears the marker.
      if (mounted && identical(_undoToast, toast)) _undoToast = null;
    });
  }

  /// Fires countdown haptics at the 3s and 0s thresholds, once each, and
  /// re-arms the guards if +30s lifts remaining back above a threshold.
  void _handleRestHaptics() {
    final c = _controller;
    final start = c?.restStart;
    if (c == null || start == null) {
      return;
    }
    final elapsed = DateTime.now().difference(start).inSeconds;
    final remaining = c.restTotal - elapsed;

    // Re-arm guards when +30s pushes remaining back above the thresholds.
    if (remaining > 3) {
      _tickHapticFired = false;
    }
    if (remaining > 0) {
      _buzzHapticFired = false;
    }

    if (remaining <= 3 && remaining > 0 && !_tickHapticFired) {
      _tickHapticFired = true;
      HapticFeedback.selectionClick();
    }
    if (remaining <= 0 && !_buzzHapticFired) {
      _buzzHapticFired = true;
      HapticFeedback.vibrate();
      _announce(AppLocalizations.of(context).sessionRestOver);
    }
  }

  /// Speaks [message] through the platform screen reader (no-op without one).
  void _announce(String message) {
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _manager?.screenOpen = false;
    super.dispose();
  }

  // ── Back / close handling ─────────────────────────────────────────────────

  Future<void> _handleClose(
    BuildContext context,
    ActiveSessionController controller,
  ) async {
    // A pristine draft (nothing done, touched, added, removed or moved) has
    // nothing to lose: it leaves without asking.
    if (!controller.hasEdits) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (!await _discard(context, controller)) {
        return;
      }
      if (context.mounted) {
        Navigator.of(context).pop();
      }
      return;
    }

    final l = AppLocalizations.of(context);
    final copy = discardDialogCopy(l, controller.draft);
    final confirmed = await showWConfirm(
      context,
      title: copy.title,
      message: copy.message,
      cancelLabel: l.sessionKeepGoing,
      confirmLabel: l.commonDiscard,
      destructive: true,
    );

    if (confirmed == true) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
      }
      if (!context.mounted || !await _discard(context, controller)) {
        return;
      }
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  /// Discards the workout, including its draft file. False (with the error
  /// shown, the workout left running when nothing was discarded) if that
  /// failed — e.g. while a notification action or a Finish is still pending
  /// ("try again"), or while the store needs recovery.
  Future<bool> _discard(
    BuildContext context,
    ActiveSessionController controller,
  ) async {
    final l = AppLocalizations.of(context);
    try {
      await controller.discard();
      return true;
    } catch (error) {
      debugPrint('discard failed: $error');
      if (context.mounted) {
        showWToast(context, userMessage(l, error).message, error: true);
      }
      // Discarded in memory but its file survived: leave the empty screen.
      return !controller.hasSession;
    }
  }

  // ── Finish handling ───────────────────────────────────────────────────────

  bool _finishing = false;

  Future<void> _handleFinish(
    BuildContext context,
    ActiveSessionController controller,
  ) async {
    if (_finishing) return;
    // A retry finishes the already prepared workout as it is: no question.
    if (!controller.finishPending) {
      final unlogged = controller.unloggedWorkingSets;
      if (unlogged > 0) {
        final l = AppLocalizations.of(context);
        final confirmed = await showWConfirm(
          context,
          title: l.sessionUnloggedSetsTitle(unlogged),
          message: l.sessionUnloggedSetsMessage,
          cancelLabel: l.sessionKeepGoing,
          confirmLabel: l.sessionFinishAnyway,
        );
        if (confirmed != true ||
            !context.mounted ||
            _finishing ||
            !controller.hasSession) {
          return;
        }
      }
    }
    setState(() => _finishing = true);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    try {
      // Adopts the finish snapshot only after the transaction commits.
      final sessionId = await finishWorkout(
        controller,
        _manager,
        repository: WorkoutRepository.local(context.read<LocalDatabase>()),
      );
      if (context.mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => SessionSummaryScreen(sessionId: sessionId),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _finishing = false);
      if (context.mounted) {
        showWToast(
          context,
          AppLocalizations.of(context).sessionSaveFailedMessage,
          error: true,
          duration: const Duration(seconds: 3),
        );
      }
    }
  }

  /// Why Finish is unavailable: nothing logged yet, or a logged set misses
  /// its required measurements.
  void _explainFinishUnavailable(ActiveSessionController c) {
    final l = AppLocalizations.of(context);
    showWToast(
      context,
      c.doneWork == 0 ? l.sessionFinishNeedsSet : l.catalogRequired,
    );
  }

  // ── Rest / log-bar handling ───────────────────────────────────────────────

  int _restSecondsFor(BlockState b) {
    final settings = context.read<SettingsService>();
    return b.exercise.defaultRestSeconds ??
        (b.exercise.compound
            ? settings.restCompoundSeconds
            : settings.restIsolationSeconds);
  }

  /// The log bar: logs the live set (the bar has already committed any
  /// in-flight typed value), starts rest after a newly logged working set,
  /// and scrolls the next live set into view.
  void _logLive(ActiveSessionController c) {
    // Settling may synchronously report the ruler's final value. Read the
    // immutable evidence only after the barrier, never from a stale snapshot.
    commitPendingInput();
    final live = c.liveSet;
    if (live?.set.catalog case final evidence?) {
      if (!evidence.validForLogging) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).catalogRequired)),
        );
        return;
      }
    }
    final r = c.logLiveSet(
      showRir: context.read<SettingsService>().rirControls == RirControls.show,
    );
    if (r == null) {
      return;
    }
    setState(() {
      _confirmedLogCandidate = r.set;
      _logFeedbackEvent++;
    });
    if (r.newlyDone) {
      final top = liveTopOf(r.block);
      final isPr = r.set.catalog != null
          ? catalogTopForSet(r.block, r.set).isPr
          : !r.set.isWarmup && top.isPr && r.set.weightKg == top.topKg;
      isPr ? HapticFeedback.heavyImpact() : HapticFeedback.mediumImpact();
      if (!r.set.isWarmup) {
        c.startRestAfterLog(r.set, _restSecondsFor(r.block));
        _offerUndo(c, r.block, r.set);
      } else {
        // A working set's toast is a live region and speaks for itself.
        _announce(AppLocalizations.of(context).sessionWarmupLogged);
      }
    } else {
      HapticFeedback.selectionClick();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _liveCardKey.currentContext;
      if (ctx == null || !mounted) {
        return;
      }
      Scrollable.ensureVisible(
        ctx,
        duration: Motion.of(context, Motion.base),
        curve: Motion.curve,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  /// "Set N logged · Undo" for about five seconds after a newly logged
  /// working set. It replaces any earlier toast, so only the latest log can
  /// be undone from here.
  void _offerUndo(ActiveSessionController c, BlockState block, SetState set) {
    final l = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    _trackUndoToast(
      showWToast(
        context,
        l.sessionSetLogged(block.workingSets.indexOf(set) + 1),
        duration: const Duration(seconds: 5),
        action: WToastAction(
          label: l.commonUndo,
          onPressed: () => _undo(c, set),
        ),
      ),
    );
  }

  /// Un-logs [set] (Undo, or "Mark as not done"): it becomes the live set
  /// again and the rest its log started stops. A no-op once the set is gone,
  /// already not done, or a Finish is pending.
  void _undo(ActiveSessionController c, SetState set) {
    if (!mounted) return;
    // Switching the live set: settle any in-flight value first.
    commitPendingInput();
    c.undoLog(set);
  }

  void _removeSet(ActiveSessionController c, BlockState b, SetState s) {
    final index = c.removeSet(b, s);
    final l = AppLocalizations.of(context);
    _trackUndoToast(
      (ScaffoldMessenger.of(context)..hideCurrentSnackBar()).showSnackBar(
        SnackBar(
          content: Text(l.sessionSetRemoved),
          action: SnackBarAction(
            label: l.commonUndo,
            onPressed: () => c.restoreSet(b, s, index),
          ),
        ),
      ),
    );
  }

  Future<void> _openWorkoutMenu(ActiveSessionController c) async {
    commitPendingInput();
    final l = AppLocalizations.of(context);
    final picked = await showWActionSheet<String>(
      context,
      title: l.sessionWorkoutOptions,
      actions: [
        WSheetAction(
          label: l.bodyWorkload,
          value: 'workload',
          icon: AlkionGlyph.accessibility,
        ),
        WSheetAction(
          label: l.todayWeeklyVolume,
          value: 'volume',
          icon: AlkionGlyph.progress,
        ),
        // Always tappable: when the workout cannot finish yet, the tap
        // explains why instead of a silently faint row.
        WSheetAction(
          label: l.sessionFinishWorkout,
          value: 'finish',
          icon: AlkionGlyph.check,
        ),
        WSheetAction(
          label: l.sessionDiscardWorkout,
          value: 'discard',
          icon: AlkionGlyph.delete,
          destructive: true,
        ),
      ],
    );
    if (!mounted || picked == null) {
      return;
    }
    if (picked == 'workload') {
      commitPendingInput();
      final projection = ActiveWorkloadProjection(
        c,
        context.read<LocalDatabase?>(),
      );
      try {
        await showBodyWorkloadSheet(
          context,
          workload: () => projection.workload,
          changes: projection,
        );
      } finally {
        projection.dispose();
      }
      return;
    }
    if (picked == 'volume') {
      commitPendingInput();
      await showWeeklyVolumeSheet(
        context,
        controller: c,
        database: context.read<LocalDatabase?>(),
      );
      return;
    }
    if (picked == 'finish') {
      if (!c.canFinish && !c.finishPending) {
        _explainFinishUnavailable(c);
        return;
      }
      await _handleFinish(context, c);
    }
    if (picked == 'discard' && mounted) {
      await _handleClose(context, c);
    }
  }

  Future<void> _openSetMenu(
    ActiveSessionController c,
    BlockState block,
    SetState set,
  ) async {
    commitPendingInput();
    final l = AppLocalizations.of(context);
    final picked = await showWActionSheet<String>(
      context,
      title: set.isWarmup
          ? l.sessionLiveWarmup
          : l.sessionLiveSet(block.workingSets.indexOf(set) + 1),
      actions: [
        if (set.done)
          WSheetAction(label: l.sessionMarkNotDone, value: 'undone'),
        WSheetAction(
          label: l.sessionAddWarmupSet,
          value: 'warmup',
          icon: AlkionGlyph.flame,
        ),
        WSheetAction(
          label: l.commonDelete,
          value: 'remove',
          icon: AlkionGlyph.delete,
          destructive: true,
        ),
      ],
    );
    if (!mounted || picked == null) return;
    switch (picked) {
      case 'undone':
        _undo(c, set);
      case 'warmup':
        c.addWarmupSet(block, unit: context.read<UnitService>().unit);
      case 'remove':
        if (await confirmRemoveSessionSet(context, set) && mounted) {
          _removeSet(c, block, set);
        }
    }
  }

  Future<void> _openBlockMenu(
    ActiveSessionController c,
    BlockState b, {
    SetState? contextSet,
  }) async {
    commitPendingInput();
    final l = AppLocalizations.of(context);
    final blocks = c.draft.blocks;
    final catalog = CatalogScope.maybeOf(context);
    final typedSelection = contextSet?.catalog?.selection ?? b.catalogSelection;
    CatalogChoice? contextChoice;
    if (catalog != null && typedSelection != null) {
      contextChoice = catalog.choiceForSelection(typedSelection);
    } else if (catalog != null &&
        catalog.exercises.containsKey(b.exercise.id)) {
      contextChoice = contextSet == null
          ? catalog.blockContexts[b] ?? catalog.exercises[b.exercise.id]!
          : _choiceFor(catalog, b, contextSet);
    }
    final locale = Localizations.localeOf(context).languageCode;
    final picked = await showWActionSheet<String>(
      context,
      title: contextChoice == null
          ? typedSelection?.displayLabel ?? b.exercise.name
          : _contextLabel(catalog!, contextChoice, locale),
      actions: [
        if (typedSelection != null ||
            catalog?.exercises[b.exercise.id] != null) ...[
          if (contextChoice?.variantId != null)
            WSheetAction(label: l.catalogChangeSetup, value: 'setup'),
          WSheetAction(label: l.catalogAddAgain, value: 'again'),
          WSheetAction(label: l.catalogRoutineUse, value: 'routine'),
        ],
        WSheetAction(
          label: l.sessionAddSet,
          value: 'set',
          icon: AlkionGlyph.add,
        ),
        WSheetAction(
          label: l.sessionMoveUp,
          value: 'up',
          icon: AlkionGlyph.chevronUp,
          enabled: !identical(b, blocks.first),
        ),
        WSheetAction(
          label: l.sessionMoveDown,
          value: 'down',
          icon: AlkionGlyph.chevronDown,
          enabled: !identical(b, blocks.last),
        ),
        WSheetAction(
          label: l.sessionReorderExercises,
          value: 'reorder',
          icon: AlkionGlyph.reorder,
          enabled: blocks.length > 1,
        ),
        WSheetAction(
          label: l.sessionRemoveExercise,
          value: 'remove',
          icon: AlkionGlyph.delete,
          destructive: true,
        ),
      ],
    );
    if (!mounted || picked == null) {
      return;
    }
    switch (picked) {
      case 'setup':
        await _changeSetup(c, b, catalog!, currentChoice: contextChoice);
      case 'routine':
        final origin = c.originSlotIdFor(b);
        final templateId = c.draft.templateId;
        if (origin == null || templateId == null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l.catalogRoutineNotice)));
        } else {
          final template = await DayTemplateRepository.local(
            context.read<LocalDatabase>(),
          ).byId(templateId);
          if (!mounted) return;
          final slot = template?.slots.where((s) => s.id == origin).firstOrNull;
          if (typedSelection != null &&
              template != null &&
              slot != null &&
              slot.localRevision == c.originSlotRevisionFor(b) &&
              slot.exerciseId == b.exercise.id &&
              template.localRevision != null) {
            final repo = DayTemplateRepository.local(
              context.read<LocalDatabase>(),
            );
            final dependencies = await CatalogExecutionRepository.local(
              context.read<LocalDatabase>(),
            ).dependenciesForSelection(typedSelection);
            if (!mounted || !c.hasSession) return;
            final intent = repo.prepareSlotContext(
              slotId: origin,
              slotRevision: slot.localRevision!,
              dayId: templateId,
              dayRevision: template.localRevision!,
              expectedExerciseId: b.exercise.id,
              selection: typedSelection,
              dependencies: dependencies,
              targets: {
                for (final entry in slot.catalogTargets.entries)
                  if (entry.key != 'reported_load' &&
                      typedSelection.profile.metrics.contains(entry.key))
                    entry.key: entry.value,
              },
            );
            try {
              await repo.commitPrepared(intent);
            } catch (_) {
              if (mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(l.catalogSaveFailed)));
              }
            }
            return;
          }
          final applied =
              typedSelection == null &&
              catalog!.useInRoutine(
                origin,
                contextChoice!,
                actualSlot: slot,
                exerciseId: b.exercise.id,
                expectedRevision: c.originSlotRevisionFor(b),
              );
          if (!applied) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(l.catalogRoutineNotice)));
          }
        }
      case 'again':
        if (typedSelection != null) {
          final exercise = await ExerciseRepository.local(
            context.read<LocalDatabase>(),
          ).byId(typedSelection.exerciseId);
          if (!mounted || exercise == null) return;
          await c.addCatalogBlock(
            exercise,
            typedSelection,
            sessionRepo: SessionRepository.local(context.read<LocalDatabase>()),
            allowRepeat: true,
          );
          return;
        }
        final choice = contextChoice!;
        final ex = await catalog!.materialize(
          choice,
          ExerciseRepository.local(context.read<LocalDatabase>()),
          locale: Localizations.localeOf(context).languageCode,
        );
        if (!mounted) return;
        await c.addBlock(
          ex,
          sessionRepo: SessionRepository.local(context.read<LocalDatabase>()),
          allowRepeat: true,
          unit: context.read<UnitService>().unit,
        );
        catalog.blockContexts[c.draft.blocks.last] = choice;
      case 'set':
        typedSelection == null
            ? c.addSet(b, unit: context.read<UnitService>().unit)
            : c.appendCatalogSet(b, typedSelection);
      case 'undone':
        _undo(c, contextSet!);
      case 'remove-set':
        _removeSet(c, b, contextSet!);
      case 'warmup':
        c.addWarmupSet(b, unit: context.read<UnitService>().unit);
      case 'up':
        c.moveBlock(b, -1);
      case 'down':
        c.moveBlock(b, 1);
      case 'reorder':
        await showReorderExercisesSheet(context, controller: c);
      case 'remove':
        if (b.allSets.any((s) => s.done)) {
          final confirmed = await showWConfirm(
            context,
            title: l.sessionRemoveExerciseTitle,
            message: l.sessionRemoveExerciseMessage,
            confirmLabel: l.commonRemove,
            destructive: true,
          );
          if (confirmed == true) {
            c.removeBlock(b);
          }
        } else {
          c.removeBlock(b);
        }
    }
  }

  CatalogChoice _choiceFor(
    CatalogRuntimeState state,
    BlockState b,
    SetState s,
  ) {
    if (s.catalog != null) {
      return state.choiceForSelection(s.catalog!.selection);
    }
    final origin = _controller?.originSlotIdFor(b);
    final blockChoice = state.blockContexts.putIfAbsent(
      b,
      () => state.routineContexts[origin] ?? state.exercises[b.exercise.id]!,
    );
    return state.setContexts.putIfAbsent(s.id, () => blockChoice);
  }

  Set<String> _inDayChoiceKeys(
    CatalogRuntimeState state,
    ActiveSessionController controller,
  ) => {
    for (final block in controller.draft.blocks)
      if (state.exercises.containsKey(block.exercise.id))
        for (final set in block.allSets) _choiceFor(state, block, set).key,
  };

  String _contextLabel(
    CatalogRuntimeState state,
    CatalogChoice choice,
    String locale,
  ) => [
    state.identifyingLabel(choice, locale),
    if (choice.setupId != 'default') state.distinction(choice, locale),
  ].where((part) => part.isNotEmpty).join(' · ');

  String _typedSetLabel(
    CatalogRuntimeState? state,
    CatalogSelectionEvidence selection,
  ) {
    if (state != null &&
        selection.bundleDigest == state.bundle.digest &&
        state.bundle.variants.containsKey(selection.variantId)) {
      return state.identifyingLabel(
        state.choiceForSelection(selection),
        Localizations.localeOf(context).languageCode,
      );
    }
    return selection.displayLabel;
  }

  /// A catalog-backed workout leaves the final rest without a Finish target.
  String _restNextLabel(
    CatalogRuntimeState? catalog,
    ActiveSessionController controller,
    AppLocalizations l,
    UnitService unit,
  ) {
    final next = controller.nextPendingSet;
    if (catalog != null && next == null) return '';
    return restNextLabel(l, unit, next);
  }

  String _typedNextLabel(
    ActiveSessionController controller,
    AppLocalizations l,
  ) {
    final next = controller.nextPendingSet;
    if (next?.set.catalog case final evidence?) {
      return l.sessionRestNext(
        [
          evidence.selection.displayLabel,
          if (evidence.selection.contextLabel.isNotEmpty)
            evidence.selection.contextLabel,
          catalogEvidenceSummary(evidence, l),
        ].where((s) => s.isNotEmpty).join(' · '),
      );
    }
    return '';
  }

  Future<void> _changeSetup(
    ActiveSessionController c,
    BlockState b,
    CatalogRuntimeState catalog, {
    CatalogChoice? currentChoice,
  }) async {
    commitPendingInput();
    final current =
        currentChoice ??
        catalog.blockContexts[b] ??
        catalog.exercises[b.exercise.id]!;
    if (current.variantId == null) return;
    for (final s in b.allSets) {
      _choiceFor(catalog, b, s);
    }
    final l = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final choice = await showWActionSheet<String>(
      context,
      title:
          '${l.catalogCurrentSetup(_contextLabel(catalog, current, locale))}\n${l.catalogNewSetNotice}',
      scrollableTitle: true,
      actions: [
        WSheetAction(label: l.catalogChooseExecution, value: 'execution'),
        for (final known
            in catalog.setups[current.variantId] ?? <CatalogChoice>[])
          WSheetAction(
            label: catalog.distinction(known, locale),
            value: known.setupId,
            selected: known.setupId == current.setupId,
          ),
        WSheetAction(label: l.catalogNewMachine, value: 'new'),
      ],
    );
    if (!mounted || choice == null) return;
    CatalogChoice? selected;
    if (choice == 'execution') {
      final variant = catalog.bundle.variants[current.variantId]!;
      final choices = await showCatalogPicker(
        context,
        state: catalog,
        familyId: variant.familyId,
        currentChoice: current,
        setupIntent: true,
        inDayChoiceKeys: _inDayChoiceKeys(catalog, c),
      );
      selected = choices?.firstOrNull;
    } else if (choice == 'new') {
      final name = await showCatalogSetupNickname(context);
      if (name != null) selected = catalog.newSetup(current, name);
    } else {
      selected = catalog.setups[current.variantId]!.firstWhere(
        (s) => s.setupId == choice,
      );
    }
    if (!mounted || selected == null) return;
    try {
      await catalog.materialize(
        selected,
        ExerciseRepository.local(context.read<LocalDatabase>()),
        locale: locale,
      );
      if (!mounted || !catalog.active || !c.hasSession) return;
      final selection = catalog.selectionFor(selected)!;
      final reference = await SessionRepository.local(
        context.read<LocalDatabase>(),
      ).catalogLoadReference(selection, excludeSessionId: c.draft.sessionId);
      if (!mounted || !catalog.active || !c.hasSession) return;
      final added = c.appendCatalogSet(
        b,
        selection,
        dependencies: catalog.dependenciesFor(selected),
      );
      if (reference.bestMetrics?['reported_load'] case final best?) {
        b.catalogBaselines[selection.compatibilityKey] = best;
      }
      b.bestKg = reference.bestKg;
      if (reference.lastMetrics case final metrics?) {
        b.catalogLastMetrics[selection.compatibilityKey] = metrics;
      }
      final last = reference.last;
      b.lastTop = last == null
          ? null
          : (weight: last.weightKg, reps: last.reps, date: last.date);
      c.focusSet(added);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.catalogSaveFailed)));
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ActiveSessionController>();
    final catalog = CatalogScope.maybeOf(context);
    final tokens = context.tokens;
    final unit = context.watch<UnitService>();
    final preferences = context.watch<SettingsService>();
    final l = AppLocalizations.of(context);

    if (!controller.hasSession) {
      // Should not normally be seen; the screen is only pushed when a session
      // is already built.
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            // Header, the live set panel, then the exercise rows. Static: no
            // load is pending here (e.g. the pop after finish or discard).
            child: GlyphSkeleton.blocks(active: false, const [
              GlyphBlock(22, widthFactor: .55),
              GlyphBlock(12, widthFactor: .35, gap: 8),
              GlyphBlock(220, gap: 24),
              GlyphBlock(14, widthFactor: .7, gap: 24),
              GlyphBlock(14, widthFactor: .5, gap: 16),
              GlyphBlock(14, widthFactor: .62, gap: 16),
            ]),
          ),
        ),
      );
    }

    final draft = controller.draft;
    final live = controller.liveSet;

    // Back (like minimize) cannot leave while a Finish is in flight, so the
    // summary it opens is never skipped. A failed Finish awaiting a retry
    // can still be left; the workout is kept until Finish commits.
    return PopScope(
      canPop: !_finishing,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _leaving();
      },
      child: _buildScaffold(
        context,
        controller,
        catalog,
        tokens,
        unit,
        preferences,
        l,
        draft,
        live,
      ),
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    ActiveSessionController controller,
    CatalogRuntimeState? catalog,
    WorkoutTokens tokens,
    UnitService unit,
    SettingsService preferences,
    AppLocalizations l,
    SessionDraft draft,
    LiveSet? live,
  ) {
    return Scaffold(
      body: WorkoutCanvas(
        child: Column(
          children: [
            // +30s and Skip are unavailable until a pending save settles.
            ValueListenableBuilder<bool>(
              valueListenable: controller.callbacksFrozenListenable,
              builder: (context, frozen, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SessionHeader(
                    draft: draft,
                    elapsed: controller.elapsed,
                    doneWork: controller.doneWork,
                    totalWork: controller.totalWork,
                    prCount: controller.prCount,
                    restStart: controller.restStart,
                    restTotal: controller.restTotal,
                    restEndedAt: controller.restEndedAt,
                    showRestRow: controller.hasLoggedSet,
                    nextLabel: controller.nextPendingSet?.set.catalog != null
                        ? _typedNextLabel(controller, l)
                        : _restNextLabel(catalog, controller, l, unit),
                    onMinimize: () {
                      // A Finish in flight must reach its summary.
                      if (_finishing) return;
                      commitPendingInput();
                      Navigator.of(context).pop();
                    },
                    onMenu: () {
                      if (!controller.finishPending) {
                        _openWorkoutMenu(controller);
                      }
                    },
                    onAdd30s: () {
                      HapticFeedback.lightImpact();
                      controller.addRestTime(30);
                    },
                    onSkip: controller.stopRest,
                    restExtensionAvailable: !frozen,
                  ),
                  // Persistent while a Finish failed and awaits a retry: the
                  // workout is kept unchanged until Finish commits.
                  if (controller.finishPending && !_finishing)
                    const FinishNotSavedBanner(),
                ],
              ),
            ),
            Expanded(
              child: AbsorbPointer(
                absorbing: controller.finishPending,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    if (draft.blocks.isEmpty) ...[
                      const SizedBox(height: 40),
                      _EmptySessionPlaceholder(tokens: tokens, l: l),
                      const SizedBox(height: 20),
                    ],
                    for (final block in draft.blocks)
                      Reveal(
                        key: ObjectKey(block),
                        child: ExerciseBlock(
                          block: block,
                          showRir: preferences.rirControls == RirControls.show,
                          showRepRange: preferences.repEntry == RepEntry.range,
                          unit: unit,
                          liveSetId: live?.set.id,
                          rirPromptSetId: controller.rirPromptSetId,
                          liveCardKey: _liveCardKey,
                          onLongPressHeader: draft.blocks.length < 2
                              ? null
                              : () {
                                  HapticFeedback.mediumImpact();
                                  showReorderExercisesSheet(
                                    context,
                                    controller: controller,
                                  );
                                },
                          onFocusSet: (_, s) {
                            // Settle in-flight edits first (same rule as the log
                            // bar): a gliding ruler would otherwise keep writing
                            // into the set being left.
                            commitPendingInput();
                            controller.focusSet(s);
                          },
                          valuesEditorBuilder: (set) => CatalogSetValuesEditor(
                            evidence: set.catalog!,
                            unit: unit,
                            enabled: !controller.finishPending,
                            onMetricChanged: (metric, text, quantityUnit) =>
                                controller.updateCatalogMetric(
                                  set,
                                  metric,
                                  text,
                                  unit: quantityUnit,
                                ),
                          ),
                          selectionLabel: (set) {
                            final selection = set.catalog!.selection;
                            final header =
                                block.catalogSelection ??
                                block.allSets
                                    .firstWhere(
                                      (candidate) => candidate.catalog != null,
                                    )
                                    .catalog!
                                    .selection;
                            final label = _typedSetLabel(catalog, selection);
                            if (selection.compatibilityKey ==
                                    header.compatibilityKey &&
                                label == header.displayLabel &&
                                selection.contextLabel == header.contextLabel) {
                              return '';
                            }
                            return [
                              label,
                              selection.contextLabel,
                            ].where((part) => part.isNotEmpty).join(' · ');
                          },
                          referenceBuilder: (set) {
                            final selection = set.catalog!.selection;
                            final metrics = block
                                .catalogLastMetrics[selection.compatibilityKey];
                            if (metrics == null) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  FitLabel(
                                    catalogEvidenceSummary(
                                      CatalogSetEvidence(
                                        selection: selection,
                                        metrics: metrics,
                                      ),
                                      l,
                                    ),
                                    maxLines: 3,
                                    style: WorkoutType.body(
                                      size: 12,
                                      color: tokens.dim,
                                    ),
                                  ),
                                  if (!set.done)
                                    TextButton(
                                      onPressed: () {
                                        commitPendingInput();
                                        controller.useCatalogValues(
                                          set,
                                          metrics,
                                        );
                                      },
                                      style: TextButton.styleFrom(
                                        minimumSize: const Size(48, 48),
                                      ),
                                      child: Text(l.catalogUseLast),
                                    ),
                                ],
                              ),
                            );
                          },
                          onSetMenu: (set) {
                            commitPendingInput();
                            _openSetMenu(controller, block, set);
                          },
                          onSetChanged: (_, __) => controller.markChanged(),
                          onRir: (_, s, v) => controller.setRirFromPrompt(s, v),
                          onClearRir: (_, s) =>
                              controller.setRirFromPrompt(s, null),
                          onMarkNotDone: (_, s) => _undo(controller, s),
                          onRemoveSet: (b, s) => _removeSet(controller, b, s),
                          onMenu: (b) => _openBlockMenu(controller, b),
                        ),
                      ),
                    const SizedBox(height: 10),
                    _AddExerciseButton(
                      height: 48,
                      icon: AlkionGlyph.add,
                      label: l.sessionAddExercise,
                      tokens: tokens,
                      onTap: () async {
                        final repo = ExerciseRepository.local(
                          context.read<LocalDatabase>(),
                        );
                        final sessionRepo = SessionRepository.local(
                          context.read<LocalDatabase>(),
                        );
                        // The ordinary owned-exercise picker keeps its duplicate guard.
                        final all = [
                          for (final e in await repo.all())
                            if (!controller.hasExercise(e.id)) e,
                        ];
                        if (!context.mounted) {
                          return;
                        }
                        CatalogChoice? catalogChoice;
                        CatalogSelectionEvidence? executionSelection;
                        final picked = await showExercisePicker(
                          context,
                          exercises: all,
                          onCatalogChoice: (choice) => catalogChoice = choice,
                          onExecutionSelection: (selection) =>
                              executionSelection = selection,
                          inDayChoiceKeys: catalog == null
                              ? const {}
                              : _inDayChoiceKeys(catalog, controller),
                        );
                        if (picked != null) {
                          try {
                            await controller.addBlock(
                              picked,
                              sessionRepo: sessionRepo,
                              unit: unit.unit,
                              allowRepeat:
                                  catalog != null &&
                                  catalogChoice != null &&
                                  !catalogChoice!.isOwned,
                              catalogSelection: executionSelection,
                            );
                          } on FreshPrescriptionUnavailableException catch (
                            error
                          ) {
                            if (context.mounted) {
                              await showFreshPrescriptionUnavailable(
                                context,
                                error,
                              );
                            }
                          } on FreshSessionLimitException catch (error) {
                            if (context.mounted) {
                              await showFreshSessionLimit(context, error);
                            }
                          }
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      // In bottomNavigationBar (not the body) so the undo snackbar floats above it.
      bottomNavigationBar: ConfirmedSetFeedback(
        controller: controller,
        event: _logFeedbackEvent,
        loggedSet: _confirmedLogCandidate,
        child: LogSetBar(
          live: controller.finishPending ? null : live,
          canFinish: controller.canFinish || controller.finishPending,
          busy: _finishing,
          unit: unit,
          onLog: () => _logLive(controller),
          onFinish: () => _handleFinish(context, controller),
        ),
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _EmptySessionPlaceholder extends StatelessWidget {
  const _EmptySessionPlaceholder({required this.tokens, required this.l});

  final WorkoutTokens tokens;
  final AppLocalizations l;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: tokens.surface,
            border: Border.all(color: tokens.line),
          ),
          alignment: Alignment.center,
          child: AlkionIcon(AlkionGlyph.workout, size: 26, color: tokens.faint),
        ),
        const SizedBox(height: 16),
        Text(
          l.sessionEmptyTitle,
          style: WorkoutType.display(
            size: 18,
            weight: FontWeight.w500,
            color: tokens.text,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          l.sessionEmptySubtitle,
          style: WorkoutType.body(size: 14, color: tokens.dim),
        ),
      ],
    );
  }
}

class _AddExerciseButton extends StatelessWidget {
  const _AddExerciseButton({
    required this.height,
    required this.icon,
    required this.label,
    required this.tokens,
    required this.onTap,
  });

  final double height;
  final AlkionGlyph icon;
  final String label;
  final WorkoutTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: Size(double.infinity, height),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        foregroundColor: tokens.text,
        backgroundColor: tokens.surface2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AlkionIcon(icon, size: 20, color: tokens.dim),
          const SizedBox(width: 8),
          Flexible(
            child: FitLabel(
              label,
              maxLines: 2,
              style: WorkoutType.body(
                size: 14,
                weight: FontWeight.w500,
                color: tokens.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The live workout's notice after a Finish failed: the workout is not saved
/// yet, is kept as it is (editing stays blocked) and Finish retries the same
/// prepared workout.
class FinishNotSavedBanner extends StatelessWidget {
  const FinishNotSavedBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      key: const Key('finish-not-saved-banner'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: tokens.surface2,
        border: Border(bottom: BorderSide(color: tokens.danger)),
      ),
      child: Semantics(
        liveRegion: true,
        child: Text(
          AppLocalizations.of(context).finishNotSavedBanner,
          style: WorkoutType.body(size: 13, color: tokens.text),
        ),
      ),
    );
  }
}
