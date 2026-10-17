import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import 'active_session_controller.dart';

/// Drag-and-drop reordering of the workout's exercises, as a sheet of
/// compact, equal-height rows (name + progress). Each row drags by its handle
/// or by a long press anywhere on it; every drop applies to the live workout
/// at once via [ActiveSessionController.moveBlockTo].
///
/// Reordering happens here rather than on the exercise cards themselves
/// because an expanded card (live set, rulers) can be many times taller than
/// its neighbours, and Flutter's reorderable list cannot reliably move a tall
/// item past short ones.
Future<void> showReorderExercisesSheet(
  BuildContext context, {
  required ActiveSessionController controller,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: context.tokens.overlay,
    useSafeArea: true,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (_) => _ReorderExercisesSheet(controller: controller),
  );
}

class _ReorderExercisesSheet extends StatelessWidget {
  const _ReorderExercisesSheet({required this.controller});

  final ActiveSessionController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.75;

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.symmetric(vertical: 8),
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(AppRadius.sheet),
          border: Border.all(color: tokens.lineStrong),
        ),
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final blocks =
                controller.draftOrNull?.blocks ?? const <BlockState>[];
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
                  child: FitLabel(
                    l.sessionReorderExercises,
                    maxLines: 2,
                    style: WorkoutType.display(
                      size: 22,
                      weight: FontWeight.w700,
                      color: tokens.text,
                    ),
                  ),
                ),
                Flexible(
                  child: ReorderableListView.builder(
                    shrinkWrap: true,
                    buildDefaultDragHandles: false,
                    itemCount: blocks.length,
                    onReorderStart: (_) => HapticFeedback.mediumImpact(),
                    // onReorderItem already reports the final index.
                    onReorderItem: controller.moveBlockTo,
                    proxyDecorator: (child, index, animation) => Material(
                      color: Colors.transparent,
                      elevation: 6,
                      shadowColor: Colors.black,
                      child: child,
                    ),
                    itemBuilder: (context, i) => _Row(
                      key: ObjectKey(blocks[i]),
                      block: blocks[i],
                      index: i,
                      tokens: tokens,
                      l: l,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.block,
    required this.index,
    required this.tokens,
    required this.l,
  });

  final BlockState block;
  final int index;
  final WorkoutTokens tokens;
  final AppLocalizations l;

  @override
  Widget build(BuildContext context) {
    final done = block.workingSets.where((s) => s.done).length;
    final total = block.workingSets.length;
    return ReorderableDelayedDragStartListener(
      index: index,
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        color: tokens.surface,
        padding: const EdgeInsets.only(left: 18, right: 4),
        child: Row(
          children: [
            Expanded(
              child: FitLabel(
                block.exercise.name,
                maxLines: 2,
                style: WorkoutType.body(
                  size: 15,
                  weight: FontWeight.w600,
                  color: tokens.text,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$done/$total',
              style: WorkoutType.mono(
                size: 12,
                weight: FontWeight.w700,
                color: done == total && total > 0
                    ? tokens.accentText
                    : tokens.dim,
              ),
            ),
            Semantics(
              // No tap action: the list supplies the move actions.
              label: '${l.sessionReorderExercises}: ${block.exercise.name}',
              excludeSemantics: true,
              child: ReorderableDragStartListener(
                index: index,
                child: SizedBox(
                  key: ValueKey('reorder-handle-${block.exercise.id}'),
                  width: 48,
                  height: 48,
                  child: Icon(Icons.drag_handle, size: 22, color: tokens.dim),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
