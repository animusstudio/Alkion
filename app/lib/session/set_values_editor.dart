import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../util/number_input.dart';
import '../widgets/number_entry_sheet.dart';
import '../widgets/ruler_picker.dart';

/// The weight/reps ruler editor shared by the live workout's [LiveSetCard]
/// and (later) the History set editor: captions, full-bleed [RulerPicker]s,
/// and tap-to-type modal entry.
///
/// The weight ruler works in display units (kg or lb), with a coarse step
/// (1 kg / 5 lb) and a fine step it zooms into on a slow drag or a hold
/// (0.25 kg / 1 lb). [onWeight] converts back to kg through
/// [UnitService.toKg]; typed input does the same (see the stepper rules in
/// app/CLAUDE.md).
class SetValuesEditor extends StatelessWidget {
  const SetValuesEditor({
    super.key,
    required this.weightKg,
    required this.reps,
    required this.unit,
    required this.onWeight,
    required this.onReps,
  });

  final double weightKg;
  final int reps;
  final UnitService unit;
  final ValueChanged<double> onWeight;
  final ValueChanged<int> onReps;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);

    TextStyle caption() =>
        WorkoutType.body(size: 12, weight: FontWeight.w700, color: tokens.dim);
    // Text keeps the card's inset; the rulers run the card's full width so
    // their ruled edge reads as part of the card, fading into its sides.
    Widget inset(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: child,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        inset(
          Text(
            '${l.sessionColWeight} · ${unit.uLabel.toUpperCase()}',
            style: caption(),
          ),
        ),
        RulerPicker(
          key: const Key('live-weight'),
          value: UnitService.fromKg(weightKg, unit.unit),
          step: unit.unit == Unit.lb ? 5 : 1,
          fineStep: unit.unit == Unit.lb ? 1 : 0.25,
          max: UnitService.fromKg(500, unit.unit),
          format: (v) => UnitService.fmtDisplay(v, unit.unit),
          semanticLabel: '${l.sessionWeight}, ${unit.uLabel}',
          onChanged: (v) =>
              onWeight(clampRound2(UnitService.toKg(v, unit.unit))),
          onTapValue: () => _typeWeight(context, l),
        ),
        const SizedBox(height: 12),
        inset(Text(l.sessionColReps, style: caption())),
        RulerPicker(
          key: const Key('live-reps'),
          value: reps.toDouble(),
          step: 1,
          max: 50,
          itemExtent: 56,
          format: (v) => v.toInt().toString(),
          semanticLabel: l.sessionReps,
          onChanged: (v) => onReps(v.toInt()),
          onTapValue: () => _typeReps(context, l),
        ),
      ],
    );
  }

  Future<void> _typeWeight(BuildContext context, AppLocalizations l) async {
    final v = await showNumberEntrySheet(
      context,
      title: '${l.sessionColWeight} · ${unit.uLabel.toUpperCase()}',
      initialText: unit.fmtWt(weightKg),
      allowDecimal: true,
      parse: (text) => parseNumberInput(
        text,
        min: 0,
        parseDisplay: (d) => UnitService.toKg(d, unit.unit),
      ),
    );
    if (v == null || v == weightKg) return;
    onWeight(v);
  }

  Future<void> _typeReps(BuildContext context, AppLocalizations l) async {
    final v = await showNumberEntrySheet(
      context,
      title: l.sessionColReps,
      initialText: '$reps',
      allowDecimal: false,
      parse: (text) => parseNumberInput(text, min: 0),
    );
    if (v == null || v.toInt() == reps) return;
    onReps(v.toInt());
  }
}
