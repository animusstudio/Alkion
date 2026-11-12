import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../util/number_input.dart';
import '../widgets/number_entry_sheet.dart';
import '../widgets/ruler_picker.dart';
import '../widgets/fit_label.dart';

/// The weight/reps ruler editor shared by the live workout's [LiveSetCard]
/// and (later) the History set editor: captions, full-bleed [RulerPicker]s,
/// and tap-to-type modal entry.
///
/// The weight ruler works in display units (kg or lb), with a coarse step
/// (1 kg / 5 lb) and a fine step it zooms into on a slow drag or a hold
/// (0.25 kg / 1 lb). [onWeight] converts back to kg through
/// [UnitService.toKg]; typed input does the same (see the stepper rules in
/// app/CLAUDE.md).
///
/// Limits: weight up to [maxWeightKg] (shown as 500 kg or 1100 lb), reps
/// [minReps] to [maxReps]. Typed text outside them is refused in the sheet
/// with a message; a stored value outside them still shows and is never
/// rewritten unless edited.
class SetValuesEditor extends StatelessWidget {
  const SetValuesEditor({
    super.key,
    required this.weightKg,
    required this.reps,
    required this.unit,
    required this.onWeight,
    required this.onReps,
    this.weightAvailable = true,
    this.repsAvailable = true,
  });

  final bool weightAvailable, repsAvailable;
  final double weightKg;
  final int reps;
  final UnitService unit;
  final ValueChanged<double> onWeight;
  final ValueChanged<int> onReps;

  static const double maxWeightKg = 500;
  static const double maxWeightLb = 1100;
  static const int minReps = 1;
  static const int maxReps = 100;

  /// The weight limit in the display [unit]: a round 1100 lb, not 1102.3.
  static double maxWeightIn(Unit unit) =>
      unit == Unit.lb ? maxWeightLb : maxWeightKg;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    // Text keeps the card's inset; the rulers run the card's full width so
    // their ruled edge reads as part of the card, fading into its sides.
    Widget inset(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: child,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        inset(SetFieldGuide(label: l.sessionWeight, unit: unit.uLabel)),
        RulerPicker(
          key: const Key('live-weight'),
          unitLabel: unit.uLabel,
          value: UnitService.fromKg(weightKg, unit.unit),
          step: unit.unit == Unit.lb ? 5 : 1,
          fineStep: unit.unit == Unit.lb ? 1 : 0.25,
          max: maxWeightIn(unit.unit),
          format: (v) =>
              !weightAvailable && v == UnitService.fromKg(weightKg, unit.unit)
              ? '—'
              : UnitService.fmtDisplay(v, unit.unit),
          semanticLabel: '${l.sessionWeight}, ${unit.uLabel}',
          onChanged: (v) =>
              onWeight(clampRound2(UnitService.toKg(v, unit.unit))),
          onTapValue: () => _typeWeight(context, l),
        ),
        const SizedBox(height: 12),
        inset(SetFieldGuide(label: l.sessionReps, unit: l.sessionRepsUnit)),
        RulerPicker(
          key: const Key('live-reps'),
          showMinorTicks: false,
          unitLabel: l.sessionReps,
          value: reps.toDouble(),
          step: 1,
          min: minReps.toDouble(),
          max: maxReps.toDouble(),
          itemExtent: 47.6,
          format: (v) =>
              !repsAvailable && v == reps ? '—' : v.toInt().toString(),
          semanticLabel: l.sessionReps,
          onChanged: (v) => onReps(v.toInt()),
          onTapValue: () => _typeReps(context, l),
        ),
      ],
    );
  }

  Future<void> _typeWeight(BuildContext context, AppLocalizations l) async {
    final max = maxWeightIn(unit.unit);
    final v = await showNumberEntrySheet(
      context,
      title: '${l.sessionColWeight} · ${unit.uLabel.toUpperCase()}',
      initialText: weightAvailable ? unit.fmtWt(weightKg) : '',
      allowDecimal: true,
      // The limit is checked in display units, before converting to kg.
      validate: (text) {
        final typed = parseNumberInput(text, min: double.negativeInfinity);
        return typed != null && typed > max
            ? l.numberEntryMax(
                '${UnitService.fmtDisplay(max, unit.unit)} ${unit.uLabel}',
              )
            : null;
      },
      parse: (text) => parseNumberInput(
        text,
        min: 0,
        parseDisplay: (d) => UnitService.toKg(d, unit.unit),
      ),
    );
    if (v == null || weightAvailable && v == weightKg) return;
    onWeight(v);
  }

  Future<void> _typeReps(BuildContext context, AppLocalizations l) async {
    final v = await showNumberEntrySheet(
      context,
      title: l.sessionColReps,
      initialText: repsAvailable ? '$reps' : '',
      allowDecimal: false,
      validate: (text) {
        final typed = parseNumberInput(text, min: double.negativeInfinity);
        if (typed == null) return null;
        if (typed < minReps) return l.numberEntryMin('$minReps');
        if (typed > maxReps) return l.numberEntryMax('$maxReps');
        return null;
      },
      parse: (text) => parseNumberInput(
        text,
        min: minReps.toDouble(),
        max: maxReps.toDouble(),
      ),
    );
    if (v == null || repsAvailable && v.toInt() == reps) return;
    onReps(v.toInt());
  }
}

/// The caption above a live ruler: the field name in small dim uppercase on
/// the left and its [unit] in the accent on the right edge of the same row.
///
/// Callers inset it by the card's 16 dp, so the unit lines up with the card's
/// text edge. An optional [hint] follows the name, or stacks under the row
/// when the three no longer fit on one line.
class SetFieldGuide extends StatelessWidget {
  const SetFieldGuide({super.key, required this.label, this.unit, this.hint});

  /// The localized field name, shown uppercase.
  final String label;

  /// The value's unit (`kg`, `lb`, `reps`, `s`, `m`), drawn in `accentText`.
  final String? unit;
  final String? hint;

  /// Tracking matches the `Tag` and eyebrow labels: 0.06 em.
  static TextStyle captionStyle(BuildContext context) => WorkoutType.body(
    size: 12,
    weight: FontWeight.w500,
    color: context.tokens.dim,
    letterSpacing: 0.06 * 12,
  );

  static TextStyle unitStyle(BuildContext context) =>
      WorkoutType.mono(size: 12, color: context.tokens.accentText);

  static const double _gap = 12;

  @override
  Widget build(BuildContext context) {
    final caption = captionStyle(context);
    final hintStyle = WorkoutType.body(size: 12, color: context.tokens.dim);
    final name = label.toUpperCase();

    Widget row({required bool inlineHint}) => Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: inlineHint
              ? FitLabel.rich(
                  TextSpan(
                    text: name,
                    children: [TextSpan(text: '  $hint', style: hintStyle)],
                  ),
                  maxLines: 2,
                  style: caption,
                )
              : FitLabel(name, maxLines: 2, style: caption),
        ),
        if (unit != null) ...[
          const SizedBox(width: _gap),
          Text(
            unit!,
            key: const Key('set-field-unit'),
            maxLines: 1,
            softWrap: false,
            style: unitStyle(context),
          ),
        ],
      ],
    );

    // The adjustable ruler below owns the field name and value. Repeating
    // the visual caption adds a duplicate screen-reader stop with no action.
    if (hint == null) return ExcludeSemantics(child: row(inlineHint: false));
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          double widthOf(String value, TextStyle style) {
            final painter = TextPainter(
              text: TextSpan(text: value, style: style),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            final width = painter.width;
            painter.dispose();
            return width;
          }

          final stacked =
              widthOf(name, caption) +
                  widthOf('  $hint', hintStyle) +
                  (unit == null
                      ? 0
                      : _gap + widthOf(unit!, unitStyle(context))) >
              constraints.maxWidth;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              row(inlineHint: !stacked),
              if (stacked) ...[
                const SizedBox(height: 4),
                FitLabel(hint!, maxLines: 2, style: hintStyle),
              ],
            ],
          );
        },
      ),
    );
  }
}
