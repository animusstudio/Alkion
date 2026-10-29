import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../widgets/fit_label.dart';
import '../widgets/pr_badge.dart';
import '../widgets/rir_picker.dart';
import '../widgets/tag.dart';
import 'active_session_controller.dart';

/// One not-live set in an exercise block: a read-only line that is a 48dp tap
/// target as a whole (a tap makes the set live). A just-logged working set
/// additionally shows the RIR correction strip under it while
/// [showRirPrompt] is true.
///
/// Logged: `1  140kg × 6  RIR 1   [TOP|PR]  ●✓`
/// Pending: `3  140kg × 6   ○`
class SetLine extends StatelessWidget {
  const SetLine({
    super.key,
    required this.set,
    required this.workIndex,
    required this.unit,
    required this.isLiveTop,
    required this.isLivePr,
    required this.showRirPrompt,
    required this.onTap,
    required this.onRir,
    this.onClearRir,
  });

  final SetState set;

  /// 1-based working-set index; -1 for warm-ups.
  final int workIndex;
  final UnitService unit;
  final bool isLiveTop;
  final bool isLivePr;
  final bool showRirPrompt;
  final VoidCallback onTap;
  final ValueChanged<int> onRir;
  final VoidCallback? onClearRir;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final done = set.done;
    final strip = showRirPrompt && done && !set.isWarmup;
    // A logged working set with no RIR (resumed, or added in History) shows
    // none, as History's line does.
    final rir = done && !set.isWarmup ? set.rir : null;

    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                children: [
                  SizedBox(
                    width: 26,
                    child: Text(
                      set.isWarmup ? l.sessionWarmupShort : '$workIndex',
                      textAlign: TextAlign.center,
                      style: WorkoutType.mono(
                        size: 13,
                        weight: FontWeight.w500,
                        color: done && !set.isWarmup
                            ? tokens.accentText
                            : tokens.faint,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    // The weight and reps are numbers: they never ellipsize.
                    // The group is laid out at its natural width and, only
                    // when the row is too narrow for it, scales down as a
                    // whole. The RIR text takes whatever is left and gives
                    // way first.
                    child: LayoutBuilder(
                      builder: (context, box) => Row(
                        children: [
                          ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: box.maxWidth),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text:
                                          (!set.weightTouched &&
                                              (set.weightUnavailable ||
                                                  double.tryParse(
                                                        set.weightText,
                                                      ) ==
                                                      null))
                                          ? '—'
                                          : unit.fmtWt(set.weightKg),
                                      style: WorkoutType.mono(
                                        size: 15,
                                        weight: FontWeight.w500,
                                        color: done ? tokens.text : tokens.dim,
                                      ),
                                    ),
                                    TextSpan(
                                      text: unit.uLabel,
                                      style: WorkoutType.mono(
                                        size: 12,
                                        color: tokens.dim,
                                      ),
                                    ),
                                    TextSpan(
                                      text: '  ×  ',
                                      style: WorkoutType.mono(
                                        size: 12,
                                        color: tokens.faint,
                                      ),
                                    ),
                                    TextSpan(
                                      text: set.repsAvailable
                                          ? '${set.reps}'
                                          : '—',
                                      style: WorkoutType.mono(
                                        size: 15,
                                        weight: FontWeight.w500,
                                        color: done ? tokens.text : tokens.dim,
                                      ),
                                    ),
                                  ],
                                ),
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          ),
                          if (rir != null)
                            Flexible(
                              child: Padding(
                                padding: const EdgeInsets.only(left: 10),
                                child: FitLabel(
                                  l.sessionRir(rir),
                                  style: WorkoutType.mono(
                                    size: 12,
                                    color: tokens.dim,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (isLivePr)
                    const PRBadge(small: true)
                  else if (isLiveTop)
                    Tag(label: l.sessionTagTop, tone: TagTone.solid),
                  const SizedBox(width: 10),
                  _StatusGlyph(done: done, tokens: tokens),
                ],
              ),
            ),
            AnimatedSize(
              duration: Motion.of(context, Motion.base),
              curve: Motion.curve,
              alignment: Alignment.topCenter,
              child: strip
                  // The whole strip absorbs taps, so one beside or below the
                  // chips (blank in two rows) never focuses the set. Kept out
                  // of the semantics tree: it must not add a tap node.
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      excludeFromSemantics: true,
                      onTap: () {},
                      child: Padding(
                        padding: const EdgeInsets.only(left: 22, bottom: 8),
                        // When the chips wrap to two rows, the caption stays
                        // level with the first.
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  height: 48,
                                  child: Center(
                                    child: Text(
                                      l.sessionColRir,
                                      style: WorkoutType.body(
                                        size: 12,
                                        color: tokens.dim,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: RirPicker(
                                    value: set.rir,
                                    onChanged: onRir,
                                  ),
                                ),
                              ],
                            ),
                            if (set.rir != null && onClearRir != null)
                              TextButton(
                                onPressed: onClearRir,
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(48, 48),
                                  foregroundColor: tokens.text,
                                ),
                                child: FitLabel(
                                  l.sessionClearRir,
                                  maxLines: 2,
                                  style: WorkoutType.body(color: tokens.dim),
                                ),
                              ),
                          ],
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

/// Filled accent check when logged, an empty ring when pending. Decorative:
/// the whole line is the tap target.
class _StatusGlyph extends StatelessWidget {
  const _StatusGlyph({required this.done, required this.tokens});

  final bool done;
  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done ? tokens.accent : null,
        border: done ? null : Border.all(color: tokens.lineStrong, width: 1.5),
      ),
      alignment: Alignment.center,
      child: done
          ? Icon(WIcons.check, size: 14, color: tokens.accentInk)
          : null,
    );
  }
}
