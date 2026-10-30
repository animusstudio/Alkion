import '../catalog_ui/catalog_picker.dart';
import '../catalog_ui/catalog_trial_scope.dart';
import '../catalog_ui/catalog_measurement_form.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/exercise_repository.dart';
import '../data/day_template_repository.dart';
import '../data/body_workload_adapters.dart';
import '../ui/body_figure.dart';
import '../data/session_repository.dart';
import '../data/session_writer.dart';
import '../l10n/app_localizations.dart';
import '../settings/settings_service.dart';
import '../shell/session_launcher.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/workout_canvas.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../widgets/fit_label.dart';
import '../widgets/pending_input.dart';
import '../widgets/w_action_sheet.dart';
import '../widgets/w_dialog.dart';
import 'active_session_controller.dart';
import 'exercise_block.dart';
import 'exercise_picker_sheet.dart';
import 'log_set_bar.dart';
import 'reorder_exercises_sheet.dart';
import 'resume.dart';
import 'session_header.dart';
import 'session_manager.dart';
import 'session_summary_screen.dart';

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
      _handleRestHaptics();
      // Screen-open rest revert: when remaining hits 0 while the screen is
      // open, stop the rest here (the OS alarm covers the backgrounded case;
      // the deleted SessionManager Dart timer used to cover this one).
      // stopRest is a guarded no-op if already stopped.
      // While a capture holds the source the rest is not stopped here; it is
      // reconciled to its due time when the capture releases.
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
    }
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
    final hasDone = controller.draft.blocks.any(
      (b) => b.allSets.any((s) => s.done),
    );

    if (!hasDone) {
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
  /// failed — e.g. while a capture holds the source.
  Future<bool> _discard(
    BuildContext context,
    ActiveSessionController controller,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l = AppLocalizations.of(context);
    final danger = context.tokens.danger;
    try {
      await controller.discard();
      return true;
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(content: Text(l.editorSaveFailed), backgroundColor: danger),
      );
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
    if (CatalogTrialScope.maybeOf(context) != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).catalogTrialFinish),
        ),
      );
      return;
    }
    if (_finishing) return;
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).sessionSaveFailedMessage,
            ),
            duration: const Duration(seconds: 3),
            backgroundColor: context.tokens.danger,
          ),
        );
      }
    }
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
    final trial = CatalogTrialScope.maybeOf(context);
    final live = c.liveSet;
    if (trial != null && live != null && _usesTrialForm(trial, live.block)) {
      commitPendingInput();
      final choice = _choiceFor(trial, live.block, live.set);
      final values = trial.metricDrafts[live.set.id] ?? {};
      final profile = trial.measurement(choice);
      if (!catalogMeasurementsValid(profile, values)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).catalogRequired)),
        );
        return;
      }
      trial.loggedMetrics[live.set.id] = Map.of(values);
      trial.setContexts[live.set.id] = choice;
      if (profile.requiredMetrics.contains('repetitions') &&
          profile.requiredMetrics.contains('reported_load')) {
        live.set.weightKg = double.parse(values['reported_load']!);
        live.set.reps = int.parse(values['repetitions']!);
        c.logLiveSet();
      } else {
        // Reuse the actual controller's set/focus lifecycle only. Typed
        // measurements remain in the disposable adapter and never enter reps.
        c.logLiveSet();
      }
      c.startRest(_restSecondsFor(live.block));
      setState(() {});
      return;
    }
    final r = c.logLiveSet();
    if (r == null) {
      return;
    }
    if (r.newlyDone) {
      final top = liveTopOf(r.block);
      final isPr = !r.set.isWarmup && top.isPr && r.set.weightKg == top.topKg;
      isPr ? HapticFeedback.heavyImpact() : HapticFeedback.mediumImpact();
      if (!r.set.isWarmup) {
        c.startRest(_restSecondsFor(r.block));
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

  void _removeSet(ActiveSessionController c, BlockState b, SetState s) {
    final index = c.removeSet(b, s);
    final l = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(l.sessionSetRemoved),
          action: SnackBarAction(
            label: l.commonUndo,
            onPressed: () => c.restoreSet(b, s, index),
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
          icon: Icons.accessibility_new,
        ),
        WSheetAction(
          label: l.sessionFinishWorkout,
          value: 'finish',
          icon: WIcons.check,
          enabled: c.canFinish,
        ),
        WSheetAction(
          label: l.sessionDiscardWorkout,
          value: 'discard',
          icon: WIcons.trash,
          destructive: true,
        ),
      ],
    );
    if (!mounted || picked == null) {
      return;
    }
    if (picked == 'workload') {
      commitPendingInput();
      await showBodyWorkloadSheet(
        context,
        workload: () => activeWorkoutWorkload(c.draft),
        changes: c,
      );
      return;
    }
    if (picked == 'finish') {
      await _handleFinish(context, c);
    }
    if (picked == 'discard' && mounted) {
      await _handleClose(context, c);
    }
  }

  Future<void> _openBlockMenu(
    ActiveSessionController c,
    BlockState b, {
    SetState? contextSet,
  }) async {
    final l = AppLocalizations.of(context);
    final blocks = c.draft.blocks;
    final trial = CatalogTrialScope.maybeOf(context);
    CatalogChoice? contextChoice;
    if (trial != null && trial.exercises.containsKey(b.exercise.id)) {
      contextChoice = contextSet == null
          ? trial.upcomingContexts[b] ??
                trial.blockContexts[b] ??
                trial.exercises[b.exercise.id]!
          : _choiceFor(trial, b, contextSet);
    }
    final locale = Localizations.localeOf(context).languageCode;
    final picked = await showWActionSheet<String>(
      context,
      title: contextChoice == null
          ? b.exercise.name
          : _trialContextLabel(trial!, contextChoice, locale),
      actions: [
        if (trial?.exercises[b.exercise.id] != null) ...[
          if (contextChoice?.variantId != null)
            WSheetAction(label: l.catalogChangeSetup, value: 'setup'),
          WSheetAction(label: l.catalogAddAgain, value: 'again'),
          WSheetAction(label: l.catalogRoutineUse, value: 'routine'),
        ],
        WSheetAction(label: l.sessionAddSet, value: 'set', icon: WIcons.plus),
        WSheetAction(
          label: l.sessionAddWarmupSet,
          value: 'warmup',
          icon: WIcons.flame,
        ),
        WSheetAction(
          label: l.sessionMoveUp,
          value: 'up',
          icon: Icons.keyboard_arrow_up,
          enabled: !identical(b, blocks.first),
        ),
        WSheetAction(
          label: l.sessionMoveDown,
          value: 'down',
          icon: Icons.keyboard_arrow_down,
          enabled: !identical(b, blocks.last),
        ),
        WSheetAction(
          label: l.sessionReorderExercises,
          value: 'reorder',
          icon: Icons.drag_handle,
          enabled: blocks.length > 1,
        ),
        WSheetAction(
          label: l.sessionRemoveExercise,
          value: 'remove',
          icon: WIcons.trash,
          destructive: true,
        ),
      ],
    );
    if (!mounted || picked == null) {
      return;
    }
    switch (picked) {
      case 'setup':
        await _changeTrialSetup(c, b, trial!, currentChoice: contextChoice);
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
          final applied = trial!.useInRoutine(
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
        final choice = contextChoice!;
        final ex = await trial!.materialize(
          choice,
          ExerciseRepository.local(context.read<LocalDatabase>()),
          locale: Localizations.localeOf(context).languageCode,
        );
        if (!mounted) return;
        await c.addBlock(
          ex,
          sessionRepo: SessionRepository.local(context.read<LocalDatabase>()),
          allowRepeat: true,
        );
        trial.blockContexts[c.draft.blocks.last] = choice;
      case 'set':
        c.addSet(b);
      case 'warmup':
        c.addWarmupSet(b);
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

  CatalogChoice _choiceFor(CatalogTrialState state, BlockState b, SetState s) {
    final origin = _controller?.originSlotIdFor(b);
    if (!s.done) {
      state.metricDrafts.putIfAbsent(
        s.id,
        () => Map.of(state.routineMetrics[origin] ?? {}),
      );
    }
    final blockChoice = state.blockContexts.putIfAbsent(
      b,
      () => state.routineContexts[origin] ?? state.exercises[b.exercise.id]!,
    );
    return state.setContexts.putIfAbsent(
      s.id,
      () => state.upcomingContexts[b] ?? blockChoice,
    );
  }

  Set<String> _trialInDayKeys(
    CatalogTrialState state,
    ActiveSessionController controller,
  ) => {
    for (final block in controller.draft.blocks)
      if (state.exercises.containsKey(block.exercise.id))
        for (final set in block.allSets) _choiceFor(state, block, set).key,
  };

  String _trialContextLabel(
    CatalogTrialState state,
    CatalogChoice choice,
    String locale,
  ) => [
    state.identifyingLabel(choice, locale),
    if (choice.setupId != 'default') state.distinction(choice, locale),
  ].where((part) => part.isNotEmpty).join(' · ');

  bool _usesTrialForm(CatalogTrialState state, BlockState b) =>
      state.exercises.containsKey(b.exercise.id);

  String _trialNextLabel(
    CatalogTrialState state,
    ActiveSessionController controller,
    AppLocalizations l,
    UnitService unit,
  ) {
    final next = controller.nextPendingSet;
    // Finish is unavailable in this disposable trial; keep the timer without
    // advertising a completion route or fabricating measurement targets.
    if (next == null) return '';
    if (!_usesTrialForm(state, next.block)) return restNextLabel(l, unit, next);
    final choice = _choiceFor(state, next.block, next.set);
    final locale = Localizations.localeOf(context).languageCode;
    final profile = state.measurement(choice);
    final values = state.metricDrafts[next.set.id] ?? const <String, String>{};
    final distinction = state.distinction(choice, locale);
    return l.sessionRestNext(
      [
        state.label(choice, locale),
        if (distinction.isNotEmpty) distinction,
        next.set.isWarmup
            ? l.sessionLiveWarmup
            : l.sessionLiveSet(next.block.workingSets.indexOf(next.set) + 1),
        for (final metric in [
          ...profile.requiredMetrics,
          ...profile.optionalMetrics,
        ])
          if (values[metric]?.trim().isNotEmpty ?? false)
            '${catalogMetricLabel(l, metric)}: ${values[metric]}',
      ].join(' · '),
    );
  }

  Future<void> _changeTrialSetup(
    ActiveSessionController c,
    BlockState b,
    CatalogTrialState trial, {
    CatalogChoice? currentChoice,
  }) async {
    commitPendingInput();
    final current =
        currentChoice ??
        trial.upcomingContexts[b] ??
        trial.blockContexts[b] ??
        trial.exercises[b.exercise.id]!;
    if (current.variantId == null) return;
    for (final s in b.allSets) {
      _choiceFor(trial, b, s);
    }
    final l = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final choice = await showWActionSheet<String>(
      context,
      title:
          '${l.catalogCurrentSetup(_trialContextLabel(trial, current, locale))}\n${l.catalogNewSetNotice}',
      scrollableTitle: true,
      actions: [
        WSheetAction(label: l.catalogChooseExecution, value: 'execution'),
        for (final known
            in trial.setups[current.variantId] ?? <CatalogChoice>[])
          WSheetAction(
            label: trial.distinction(known, locale),
            value: known.setupId,
            selected: known.setupId == current.setupId,
          ),
        WSheetAction(label: l.catalogNewMachine, value: 'new'),
      ],
    );
    if (!mounted || choice == null) return;
    CatalogChoice? selected;
    if (choice == 'execution') {
      final variant = trial.bundle.variants[current.variantId]!;
      final choices = await showCatalogPicker(
        context,
        state: trial,
        familyId: variant.familyId,
        currentChoice: current,
        setupIntent: true,
        inDayChoiceKeys: _trialInDayKeys(trial, c),
      );
      selected = choices?.firstOrNull;
    } else if (choice == 'new') {
      final name = await showCatalogSetupNickname(context);
      if (name != null) selected = trial.newSetup(current, name);
    } else {
      selected = trial.setups[current.variantId]!.firstWhere(
        (s) => s.setupId == choice,
      );
    }
    if (!mounted || selected == null) return;
    // Existing observations and entered drafts keep their exact setup. A fresh
    // upcoming set owns the new context and starts without an inherited load.
    trial.upcomingContexts[b] = selected;
    trial.remember(selected);
    c.addSet(b);
    final added = b.workingSets.last;
    trial.setContexts[added.id] = selected;
    trial.metricDrafts[added.id] = {};
    c.focusSet(added);
    setState(() {});
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ActiveSessionController>();
    final trial = CatalogTrialScope.maybeOf(context);
    final tokens = context.tokens;
    final unit = context.watch<UnitService>();
    final l = AppLocalizations.of(context);

    if (!controller.hasSession) {
      // Should not normally be seen; the screen is only pushed when a session
      // is already built.
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final draft = controller.draft;
    final live = controller.liveSet;

    return Scaffold(
      body: WorkoutCanvas(
        child: Column(
          children: [
            // +30s is unavailable while a data capture holds the source.
            ValueListenableBuilder<bool>(
              valueListenable: controller.captureFrozen,
              builder: (context, frozen, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SessionHeader(
                    draft: draft,
                    elapsed: controller.elapsed,
                    doneWork: controller.doneWork,
                    totalWork: controller.totalWork,
                    // The trial has no qualified per-context PR contract.
                    prCount: trial == null ? controller.prCount : 0,
                    restStart: controller.restStart,
                    restTotal: controller.restTotal,
                    restEndedAt: controller.restEndedAt,
                    showRestRow: controller.hasLoggedSet,
                    nextLabel: trial == null
                        ? restNextLabel(l, unit, controller.nextPendingSet)
                        : _trialNextLabel(trial, controller, l, unit),
                    onMinimize: () => Navigator.of(context).pop(),
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
                  // Persistent while a data capture holds the source: what is
                  // changed now lives in memory only until the hold ends.
                  if (frozen && !_finishing) const CaptureHoldBanner(),
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
                        child: trial != null && _usesTrialForm(trial, block)
                            ? Column(
                                children: [
                                  for (final s in block.allSets)
                                    CatalogTrialBlock(
                                      key: ValueKey(s.id),
                                      state: trial,
                                      choice: _choiceFor(trial, block, s),
                                      setId: s.id,
                                      title: trial.label(
                                        _choiceFor(trial, block, s),
                                        Localizations.localeOf(
                                          context,
                                        ).languageCode,
                                      ),
                                      done: s.done,
                                      onChanged: () {
                                        controller.focusSet(s);
                                        setState(() {});
                                      },
                                      onMenu: () => _openBlockMenu(
                                        controller,
                                        block,
                                        contextSet: s,
                                      ),
                                    ),
                                ],
                              )
                            : ExerciseBlock(
                                block: block,
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
                                onSetChanged: (_, __) =>
                                    controller.markChanged(),
                                onRir: (_, s, v) =>
                                    controller.setRirFromPrompt(s, v),
                                onClearRir: (_, s) =>
                                    controller.setRirFromPrompt(s, null),
                                onMarkNotDone: (_, s) =>
                                    controller.markNotDone(s),
                                onRemoveSet: (b, s) =>
                                    _removeSet(controller, b, s),
                                onMenu: (b) => _openBlockMenu(controller, b),
                              ),
                      ),
                    const SizedBox(height: 10),
                    _AddExerciseButton(
                      height: 48,
                      icon: WIcons.plus,
                      label: l.sessionAddExercise,
                      tokens: tokens,
                      onTap: () async {
                        final settings = context.read<SettingsService>();
                        final repEntry = settings.repEntry;
                        final rirControls = settings.rirControls;
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
                        final picked = await showExercisePicker(
                          context,
                          exercises: all,
                          onCatalogChoice: (choice) => catalogChoice = choice,
                          inDayChoiceKeys: trial == null
                              ? const {}
                              : _trialInDayKeys(trial, controller),
                        );
                        if (picked != null) {
                          try {
                            await controller.addBlock(
                              picked,
                              sessionRepo: sessionRepo,
                              repEntry: repEntry,
                              rirControls: rirControls,
                              allowRepeat:
                                  trial != null && catalogChoice != null,
                            );
                            if (trial != null &&
                                catalogChoice != null &&
                                controller.draft.blocks.isNotEmpty) {
                              final added = controller.draft.blocks.last;
                              if (added.exercise.id == picked.id) {
                                trial.blockContexts.putIfAbsent(
                                  added,
                                  () => catalogChoice!,
                                );
                                setState(() {});
                              }
                            }
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
      bottomNavigationBar:
          trial != null && live != null && _usesTrialForm(trial, live.block)
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  key: const Key('catalog-log-set'),
                  onPressed: () => _logLive(controller),
                  child: Text(l.catalogLogSet),
                ),
              ),
            )
          : LogSetBar(
              live: controller.finishPending ? null : live,
              canFinish: controller.canFinish || controller.finishPending,
              unit: unit,
              onLog: () => _logLive(controller),
              onFinish: () => _handleFinish(context, controller),
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
          child: Icon(WIcons.dumbbell, size: 26, color: tokens.faint),
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
  final IconData icon;
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
          Icon(icon, size: 20, color: tokens.dim),
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

/// The live workout's notice while a data capture holds the source: its
/// changes are not being saved, and are lost if the app is closed before
/// the hold ends.
class CaptureHoldBanner extends StatelessWidget {
  const CaptureHoldBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      key: const Key('capture-hold-banner'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: tokens.surface2,
        border: Border(bottom: BorderSide(color: tokens.danger)),
      ),
      child: Semantics(
        liveRegion: true,
        child: Text(
          AppLocalizations.of(context).alkionStoreRecoveryBody,
          style: WorkoutType.body(size: 13, color: tokens.text),
        ),
      ),
    );
  }
}
