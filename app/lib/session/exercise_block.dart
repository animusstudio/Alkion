import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../domain/evidence.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../util/prescription_format.dart';
import '../widgets/pr_badge.dart';
import '../widgets/fit_label.dart';
import '../widgets/w_dialog.dart';
import 'active_session_controller.dart';
import 'live_set_card.dart';
import 'set_line.dart';

/// A display badge is scoped to the performed set's exact context, even when a
/// block changed setup. It never uses compatibility weight/reps placeholders.
({String? id, bool isPr}) catalogTopForSet(BlockState block, SetState set) {
  final selection = set.catalog?.selection;
  if (set.isWarmup || selection == null || !selection.supportsLoadProgression) {
    return (id: null, isPr: false);
  }
  ExactDecimal? top;
  String? id;
  for (final candidate in block.workingSets) {
    if (!candidate.done ||
        candidate.catalog?.selection.compatibilityKey !=
            selection.compatibilityKey) {
      continue;
    }
    final value = candidate.catalog?.metrics['reported_load']?.loadKg;
    if (value != null && (top == null || value.compareTo(top) > 0)) {
      top = value;
      id = candidate.id;
    }
  }
  final best = block.catalogBaselines[selection.compatibilityKey]?.loadKg;
  return (
    id: id,
    isPr:
        id == set.id && top != null && best != null && top.compareTo(best) > 0,
  );
}

/// A collapsible accordion card for one exercise in the active session.
///
/// Renders the workout's live set as a [LiveSetCard] and every other set as
/// a [SetLine]. The header's `⋯` button opens the exercise's menu (add set /
/// warm-up, reorder, remove) via [onMenu].
///
/// Visual spec: `docs/design_handoff_workout_tracker/design/app/screen-log.jsx`
/// `ExerciseBlock`.
class ExerciseBlock extends StatefulWidget {
  const ExerciseBlock({
    super.key,
    required this.block,
    required this.unit,
    required this.liveSetId,
    required this.rirPromptSetId,
    this.liveCardKey,
    this.onLongPressHeader,
    required this.onFocusSet,
    required this.onSetChanged,
    required this.onRir,
    this.onClearRir,
    required this.onMarkNotDone,
    this.onRemoveSet,
    required this.onMenu,
    this.valuesEditorBuilder,
    this.referenceBuilder,
    this.selectionLabel,
    this.onSetMenu,
  });

  final BlockState block;
  final UnitService unit;

  /// The workout's live set id; when it belongs to this block that set renders
  /// as the [LiveSetCard] and the block renders expanded.
  final String? liveSetId;

  /// The logged set whose RIR strip is open, if it is in this block.
  final String? rirPromptSetId;

  /// Put on the live card (when it is in this block) so the screen can scroll
  /// it into view.
  final GlobalKey? liveCardKey;

  /// A long press on the header (the screen opens exercise reordering).
  final VoidCallback? onLongPressHeader;

  final void Function(BlockState, SetState) onFocusSet;
  final void Function(BlockState, SetState) onSetChanged;
  final void Function(BlockState, SetState, int) onRir;
  final void Function(BlockState, SetState)? onClearRir;
  final void Function(BlockState, SetState) onMarkNotDone;

  /// Swipe-left removal of a set. Null disables the swipe. A ticked set is
  /// confirmed first; an unticked one goes straight away.
  final void Function(BlockState, SetState)? onRemoveSet;

  /// The header's ⋯ button (add set / warm-up, reorder, remove exercise).
  final void Function(BlockState) onMenu;
  final Widget Function(SetState)? valuesEditorBuilder, referenceBuilder;
  final String Function(SetState)? selectionLabel;
  final void Function(SetState)? onSetMenu;

  @override
  State<ExerciseBlock> createState() => _ExerciseBlockState();
}

class _ExerciseBlockState extends State<ExerciseBlock>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  /// A ticked set holds logged work, so removing it is confirmed (the same
  /// rule as removing an exercise); an unticked set goes without asking.
  Future<bool> _confirmRemoveSet(SetState s) async {
    if (!s.done) return true;
    final l = AppLocalizations.of(context);
    final confirmed = await showWConfirm(
      context,
      title: l.sessionRemoveSetTitle,
      message: l.sessionRemoveSetMessage,
      confirmLabel: l.commonRemove,
      destructive: true,
    );
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final block = widget.block;
    final ex = block.exercise;
    final resolved = block.resolved;
    final unit = widget.unit;

    final working = block.workingSets;
    final doneWorking = working.where((s) => s.done).length;
    final allDone = working.isNotEmpty && doneWorking == working.length;
    final top = liveTopOf(block);
    final containsLive =
        widget.liveSetId != null &&
        block.allSets.any((s) => s.id == widget.liveSetId);
    final showSets = block.expanded || containsLive;
    final typed = block.allSets.any((set) => set.catalog != null);

    final prescription = formatPrescription(
      workSets: resolved.workSets,
      reps: qualifiedRepPair(resolved.repLow, resolved.repHigh),
      rirLow: resolved.hasRirTarget ? resolved.rirLow : null,
      rirHigh: resolved.hasRirTarget ? resolved.rirHigh : null,
      unavailable: l.trainingUnavailable,
    );
    final subLabel =
        '${ex.muscleGroup} · $prescription${resolved.rirUnavailable ? ' · ${l.trainingRirUnavailable}' : ''}';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(bottom: BorderSide(color: tokens.line)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ─────────────────────────────────────────────────────
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: containsLive
                ? null
                : () => setState(() => block.expanded = !block.expanded),
            onLongPress: widget.onLongPressHeader,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    key: ValueKey('block-badge-${ex.id}'),
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: tokens.surface2,
                      borderRadius: BorderRadius.circular(AppRadius.control),
                    ),
                    alignment: Alignment.center,
                    child: allDone
                        ? Icon(WIcons.check, size: 18, color: tokens.text)
                        : Text(
                            '$doneWorking/${working.length}',
                            maxLines: 1,
                            softWrap: false,
                            style: WorkoutType.mono(
                              size: 13,
                              weight: FontWeight.w500,
                              color: tokens.dim,
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FitLabel(
                          typed
                              ? (block.catalogSelection ??
                                        block.allSets
                                            .firstWhere(
                                              (s) => s.catalog != null,
                                            )
                                            .catalog!
                                            .selection)
                                    .displayLabel
                              : ex.name,
                          maxLines: 2,
                          style: WorkoutType.body(
                            size: 16,
                            weight: FontWeight.w500,
                            color: tokens.text,
                          ),
                        ),
                        const SizedBox(height: 4),
                        FitLabel(
                          typed
                              ? (block.catalogSelection ??
                                        block.allSets
                                            .firstWhere(
                                              (s) => s.catalog != null,
                                            )
                                            .catalog!
                                            .selection)
                                    .contextLabel
                              : subLabel,
                          maxLines: 3,
                          style: WorkoutType.body(size: 12, color: tokens.dim),
                        ),
                        if (!typed && top.topKg > 0) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Flexible(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text.rich(
                                    TextSpan(
                                      children: [
                                        TextSpan(
                                          text: unit.fmtWt(top.topKg),
                                          style: WorkoutType.mono(
                                            size: 14,
                                            weight: FontWeight.w500,
                                            color: tokens.text,
                                          ),
                                        ),
                                        TextSpan(
                                          text: unit.uLabel,
                                          style: WorkoutType.mono(
                                            size: 12,
                                            color: tokens.dim,
                                          ),
                                        ),
                                      ],
                                    ),
                                    maxLines: 1,
                                    softWrap: false,
                                  ),
                                ),
                              ),
                              if (top.isPr) ...[
                                const SizedBox(width: 8),
                                const PRBadge(small: true),
                              ],
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: l.sessionExerciseOptions,
                    excludeSemantics: true,
                    child: IconButton(
                      key: ValueKey('block-menu-${ex.id}'),
                      onPressed: () => widget.onMenu(block),
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      icon: Icon(WIcons.more, size: 20, color: tokens.dim),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Sets ───────────────────────────────────────────────────────
          if (showSets)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: AnimatedSize(
                duration: Motion.of(context, Motion.base),
                curve: Motion.curve,
                alignment: Alignment.topCenter,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final s in block.allSets)
                      _setWidget(
                        block,
                        s,
                        top,
                        topSetIdOf(block, top.topKg),
                        tokens,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _setWidget(
    BlockState block,
    SetState s,
    ({double topKg, bool isPr}) top,
    String? topSetId,
    WorkoutTokens tokens,
  ) {
    final workIdx = s.isWarmup ? -1 : block.workingSets.indexOf(s) + 1;
    final Widget child;
    if (s.id == widget.liveSetId) {
      final card = LiveSetCard(
        key: ValueKey('live-${s.id}'),
        set: s,
        exercise: block.exercise,
        workIndex: workIdx,
        lastTop: block.lastTop,
        lastTopUnavailable: block.lastTopUnavailable,
        unit: widget.unit,
        onChanged: () => widget.onSetChanged(block, s),
        onMarkNotDone: () => widget.onMarkNotDone(block, s),
        valuesEditor: s.catalog == null
            ? null
            : widget.valuesEditorBuilder?.call(s),
        reference: s.catalog == null ? null : widget.referenceBuilder?.call(s),
        selectionLabel: s.catalog == null
            ? null
            : widget.selectionLabel?.call(s),
        onMenu: s.catalog == null || widget.onSetMenu == null
            ? null
            : () => widget.onSetMenu!(s),
      );
      child = widget.liveCardKey == null
          ? card
          : KeyedSubtree(key: widget.liveCardKey, child: card);
    } else {
      final catalogTop = catalogTopForSet(block, s);
      final isLiveTop = s.catalog == null
          ? s.id == topSetId
          : s.id == catalogTop.id;
      child = SetLine(
        set: s,
        workIndex: workIdx,
        unit: widget.unit,
        isLiveTop: isLiveTop,
        isLivePr: s.catalog == null ? isLiveTop && top.isPr : catalogTop.isPr,
        showRirPrompt: s.id == widget.rirPromptSetId,
        onTap: () => widget.onFocusSet(block, s),
        onRir: (v) => widget.onRir(block, s, v),
        onClearRir: widget.onClearRir == null
            ? null
            : () => widget.onClearRir!(block, s),
      );
    }
    final onRemoveSet = widget.onRemoveSet;
    return Reveal(
      key: ValueKey(s.id),
      child: onRemoveSet == null
          ? child
          : Dismissible(
              key: ValueKey('dismiss-${s.id}'),
              direction: DismissDirection.endToStart,
              background: _RemoveSetBackground(tokens: tokens),
              confirmDismiss: (_) => _confirmRemoveSet(s),
              onDismissed: (_) => onRemoveSet(block, s),
              child: child,
            ),
    );
  }
}

// ── Helper sub-widgets ────────────────────────────────────────────────────────

/// Red trash background revealed while a set row is swiped left.
class _RemoveSetBackground extends StatelessWidget {
  const _RemoveSetBackground({required this.tokens});

  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 14),
      decoration: BoxDecoration(
        color: tokens.surface2,
        border: Border.all(color: tokens.danger),
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Icon(WIcons.trash, size: 18, color: tokens.danger),
    );
  }
}

/// The one set the finished workout will record as its top set, mirroring
/// `topSetIndex` in session_writer.dart: among done working sets at [topKg],
/// the most reps wins, then the earliest set. Null when nothing is logged.
@visibleForTesting
String? topSetIdOf(BlockState block, double topKg) {
  if (topKg <= 0) return null;
  SetState? best;
  for (final s in block.workingSets) {
    if (!s.done || s.weightKg != topKg) continue;
    if (best == null || s.reps > best.reps) best = s;
  }
  return best?.id;
}
