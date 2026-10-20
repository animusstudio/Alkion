import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/exercise_repository.dart';
import '../data/session_repository.dart';
import '../data/session_writer.dart';
import '../l10n/app_localizations.dart';
import '../settings/settings_service.dart';
import '../shell/session_launcher.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
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
/// - Finish wires through `db.writeTransaction(PowerSyncTxExecutor)`.
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

  Future<void> _handleFinish(
    BuildContext context,
    ActiveSessionController controller,
  ) async {
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
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).sessionSaveFailed('$e')),
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
    final l = AppLocalizations.of(context);
    final picked = await showWActionSheet<String>(
      context,
      title: l.sessionWorkoutOptions,
      actions: [
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
    if (picked == 'finish') {
      await _handleFinish(context, c);
    }
    if (picked == 'discard' && mounted) {
      await _handleClose(context, c);
    }
  }

  Future<void> _openBlockMenu(ActiveSessionController c, BlockState b) async {
    final l = AppLocalizations.of(context);
    final blocks = c.draft.blocks;
    final picked = await showWActionSheet<String>(
      context,
      title: b.exercise.name,
      actions: [
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

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ActiveSessionController>();
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
      body: Column(
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
                  prCount: controller.prCount,
                  restStart: controller.restStart,
                  restTotal: controller.restTotal,
                  restEndedAt: controller.restEndedAt,
                  showRestRow: controller.hasLoggedSet,
                  nextLabel: restNextLabel(l, unit, controller.nextPendingSet),
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
                if (frozen) const CaptureHoldBanner(),
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
                      key: ValueKey(block.exercise.id),
                      child: ExerciseBlock(
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
                        onSetChanged: (_, __) => controller.markChanged(),
                        onRir: (_, s, v) => controller.setRirFromPrompt(s, v),
                        onMarkNotDone: (_, s) => controller.markNotDone(s),
                        onRemoveSet: (b, s) => _removeSet(controller, b, s),
                        onMenu: (b) => _openBlockMenu(controller, b),
                      ),
                    ),
                  const SizedBox(height: 10),
                  _DashedButton(
                    height: 48,
                    icon: WIcons.plus,
                    label: l.sessionAddExercise,
                    tokens: tokens,
                    onTap: () async {
                      final repo = ExerciseRepository.local(
                        context.read<LocalDatabase>(),
                      );
                      final sessionRepo = SessionRepository.local(
                        context.read<LocalDatabase>(),
                      );
                      // Exercises already in the workout aren't offered again.
                      final all = [
                        for (final e in await repo.all())
                          if (!controller.hasExercise(e.id)) e,
                      ];
                      if (!context.mounted) {
                        return;
                      }
                      final picked = await showExercisePicker(
                        context,
                        exercises: all,
                      );
                      if (picked != null) {
                        try {
                          await controller.addBlock(
                            picked,
                            sessionRepo: sessionRepo,
                          );
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
      // In bottomNavigationBar (not the body) so the undo snackbar floats above it.
      bottomNavigationBar: LogSetBar(
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
            weight: FontWeight.w700,
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

class _DashedButton extends StatelessWidget {
  const _DashedButton({
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
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: Size(double.infinity, height),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        foregroundColor: tokens.text,
        side: BorderSide(color: tokens.lineStrong),
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
                weight: FontWeight.w700,
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
