import 'package:flutter/material.dart';

import '../catalog_ui/catalog_set_format.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/alkion_icon.dart';
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
/// Logged: `1  140kg × 6  [RIR 1]   [TOP|PR]  ●✓` (a typed set: `18 kg × 12`)
/// Pending: `3   ○` (blank until logged; the live card holds the values)
///
/// The exercise is named by the block header; a set done in another variant
/// or setup shows that once, dim, as [variantLabel].
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
    this.onMenu,
    this.showRir = true,
    this.variantLabel,
  });

  final bool showRir;
  final SetState set;

  /// 1-based working-set index; -1 for warm-ups.
  final int workIndex;
  final UnitService unit;
  final bool isLiveTop;
  final bool isLivePr;
  final bool showRirPrompt;
  final VoidCallback onTap;

  /// A chip tap sets RIR; tapping the selected chip clears it (null).
  final ValueChanged<int?> onRir;
  final VoidCallback? onMenu;

  /// The set's variant or setup when it differs from the block header;
  /// null or empty otherwise.
  final String? variantLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final done = set.done;
    final strip = showRir && showRirPrompt && done && !set.isWarmup;
    // A logged working set with no RIR (resumed, or added in History) shows
    // none, as History's line does.
    final rir = showRir && done && !set.isWarmup ? set.rir : null;
    final variant = variantLabel ?? '';

    return Semantics(
      container: true,
      button: true,
      label: setLineSemanticsLabel(
        l,
        unit,
        set,
        workIndex,
        showRir: showRir,
        variantLabel: variant,
      ),
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
                  // The row's own label says all this to a screen reader.
                  SizedBox(
                    width: 26,
                    child: ExcludeSemantics(
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
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (variant.isNotEmpty)
                              FitLabel(
                                variant,
                                maxLines: 2,
                                style: WorkoutType.body(
                                  size: 12,
                                  color: tokens.dim,
                                ),
                              ),
                            // A pending set stays blank until logged.
                            if (done)
                              // The weight and reps are numbers: they never
                              // ellipsize. The group scales down as a whole
                              // only when the row is too narrow for it; the
                              // RIR tag wraps under it rather than squeeze it.
                              Wrap(
                                spacing: 10,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  set.catalog != null
                                      ? CatalogSetText(set.catalog!)
                                      : _ClassicValues(
                                          set: set,
                                          unit: unit,
                                          tokens: tokens,
                                        ),
                                  if (rir != null)
                                    Tag(
                                      key: const Key('set-line-rir'),
                                      label: l.sessionRir(rir),
                                    ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (isLivePr)
                    const PRBadge(small: true)
                  else if (isLiveTop)
                    Tag(label: l.sessionTagTop, tone: TagTone.solid),
                  const SizedBox(width: 10),
                  _StatusGlyph(done: done, tokens: tokens),
                  if (onMenu != null)
                    IconButton(
                      key: ValueKey('set-menu-${set.id}'),
                      tooltip: l.sessionSetOptions(
                        set.isWarmup
                            ? l.sessionLiveWarmup
                            : l.sessionLiveSet(workIndex),
                      ),
                      onPressed: onMenu,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      icon: AlkionIcon(
                        AlkionGlyph.more,
                        size: 20,
                        color: tokens.dim,
                      ),
                    ),
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
                        child: Row(
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
                              // Tapping the selected chip clears the RIR.
                              child: RirPicker(
                                value: set.rir,
                                onChanged: onRir,
                                onClear: () => onRir(null),
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

/// A logged classic set's `140kg × 6`, laid out at its natural width and
/// scaled down as a whole when the row is too narrow.
class _ClassicValues extends StatelessWidget {
  const _ClassicValues({
    required this.set,
    required this.unit,
    required this.tokens,
  });

  final SetState set;
  final UnitService unit;
  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    final weightShown =
        set.weightTouched ||
        (!set.weightUnavailable && double.tryParse(set.weightText) != null);
    final number = WorkoutType.mono(
      size: 15,
      weight: FontWeight.w500,
      color: tokens.text,
    );
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: weightShown ? unit.fmtWt(set.weightKg) : '—',
              style: number,
            ),
            TextSpan(
              text: unit.uLabel,
              style: WorkoutType.mono(size: 12, color: tokens.dim),
            ),
            TextSpan(
              text: '  ×  ',
              style: WorkoutType.mono(size: 12, color: tokens.faint),
            ),
            TextSpan(
              text: set.repsAvailable ? '${set.reps}' : '—',
              style: number,
            ),
          ],
        ),
        maxLines: 1,
        softWrap: false,
      ),
    );
  }
}

/// What a screen reader says for [set]'s line: "Set 2, 140 kg × 6, RIR 1,
/// done" (warm-up: "Warm-up, …"; a typed set reads its compact form, "Set 2,
/// 18 kg × 12, done"). A pending set has no values on screen and reads "Set 3,
/// not done". A different variant or setup ([variantLabel]) follows the name.
/// The visual digits and marks are excluded so nothing repeats.
String setLineSemanticsLabel(
  AppLocalizations l,
  UnitService unit,
  SetState set,
  int workIndex, {
  bool showRir = true,
  String variantLabel = '',
}) {
  final name = set.isWarmup
      ? l.sessionWarmupSpoken
      : l.sessionSetSpoken(workIndex);
  final String? values;
  if (!set.done) {
    values = null;
  } else if (set.catalog case final evidence?) {
    final compact = catalogSetCompact(evidence, l);
    values = compact.isEmpty ? l.sessionSetNoValue : compact;
  } else {
    final weightShown =
        set.weightTouched ||
        (!set.weightUnavailable && double.tryParse(set.weightText) != null);
    final weight = weightShown
        ? '${unit.fmtWt(set.weightKg)} ${unit.uLabel}'
        : l.sessionSetNoValue;
    final reps = set.repsAvailable ? '${set.reps}' : l.sessionSetNoValue;
    values = '$weight × $reps';
  }
  final rir = showRir && set.done && !set.isWarmup ? set.rir : null;
  return [
    name,
    if (variantLabel.isNotEmpty) variantLabel,
    ?values,
    if (rir != null) l.sessionRir(rir),
    set.done ? l.sessionSetStateDone : l.sessionSetStateNotDone,
  ].join(', ');
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
          ? AlkionIcon(AlkionGlyph.check, size: 16, color: tokens.accentInk)
          : null,
    );
  }
}
