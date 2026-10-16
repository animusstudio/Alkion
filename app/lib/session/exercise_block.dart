import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../widgets/pr_badge.dart';
import '../widgets/w_dialog.dart';
import 'active_session_controller.dart';
import 'live_set_card.dart';
import 'set_line.dart';

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
    required this.onMarkNotDone,
    this.onRemoveSet,
    required this.onMenu,
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
  final void Function(BlockState, SetState) onMarkNotDone;

  /// Swipe-left removal of a set. Null disables the swipe. A ticked set is
  /// confirmed first; an unticked one goes straight away.
  final void Function(BlockState, SetState)? onRemoveSet;

  /// The header's ⋯ button (add set / warm-up, reorder, remove exercise).
  final void Function(BlockState) onMenu;

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

    final rirStr = resolved.rirLow == resolved.rirHigh
        ? '${resolved.rirLow}'
        : '${resolved.rirLow}–${resolved.rirHigh}';
    final subLabel =
        '${ex.muscleGroup} · ${resolved.workSets}×${resolved.repLow}–${resolved.repHigh} @ RIR $rirStr';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(AppRadius.radius),
        border: Border.all(color: showSets ? tokens.lineStrong : tokens.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ─────────────────────────────────────────────────────
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            // The block holding the live set stays open.
            onTap: containsLive
                ? null
                : () => setState(() => block.expanded = !block.expanded),
            onLongPress: widget.onLongPressHeader,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
              child: Row(
                children: [
                  // Completion badge — sizes to its count (min 40dp), so
                  // "2/3" stays whole at large text.
                  Container(
                    key: ValueKey('block-badge-${ex.id}'),
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: allDone ? tokens.accent : tokens.surface3,
                      borderRadius: BorderRadius.circular(
                        AppRadius.radius * 0.5,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: allDone
                        ? Icon(Icons.check, size: 18, color: tokens.accentInk)
                        : Text(
                            '$doneWorking/${working.length}',
                            maxLines: 1,
                            softWrap: false,
                            style: WorkoutType.mono(
                              size: 13,
                              weight: FontWeight.w700,
                              color: tokens.dim,
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ex.name,
                          style: WorkoutType.body(
                            size: 15,
                            weight: FontWeight.w600,
                            color: tokens.text,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WorkoutType.mono(
                            size: 10.5,
                            color: tokens.faint,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (top.topKg > 0) ...[
                    const SizedBox(width: 4),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: unit.fmtWt(top.topKg),
                                style: WorkoutType.mono(
                                  size: 14,
                                  weight: FontWeight.w700,
                                  color: tokens.text,
                                ),
                              ),
                              TextSpan(
                                text: unit.uLabel,
                                style: WorkoutType.mono(
                                  size: 10,
                                  color: tokens.faint,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (top.isPr) ...[
                          const SizedBox(height: 2),
                          const PRBadge(small: true),
                        ],
                      ],
                    ),
                  ],
                  Semantics(
                    button: true,
                    label: l.sessionExerciseOptions,
                    excludeSemantics: true,
                    child: GestureDetector(
                      key: ValueKey('block-menu-${ex.id}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => widget.onMenu(block),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(WIcons.more, size: 20, color: tokens.dim),
                      ),
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
      );
      child = widget.liveCardKey == null
          ? card
          : KeyedSubtree(key: widget.liveCardKey, child: card);
    } else {
      final isLiveTop = s.id == topSetId;
      child = SetLine(
        set: s,
        workIndex: workIdx,
        unit: widget.unit,
        isLiveTop: isLiveTop,
        isLivePr: isLiveTop && top.isPr,
        showRirPrompt: s.id == widget.rirPromptSetId,
        onTap: () => widget.onFocusSet(block, s),
        onRir: (v) => widget.onRir(block, s, v),
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
        color: tokens.danger,
        borderRadius: BorderRadius.circular(AppRadius.radius * 0.5),
      ),
      child: Icon(WIcons.trash, size: 18, color: tokens.bg),
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
