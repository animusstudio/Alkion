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
          _FieldGuide(
            label: l.sessionWeight,
            hint: l.sessionTapValueToType,
            color: tokens.accentText,
            guide: tokens.lineStrong,
          ),
        ),
        RulerPicker(
          key: const Key('live-weight'),
          unitLabel: unit.uLabel,
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
        inset(
          _FieldGuide(
            label: l.sessionReps,
            color: tokens.accentText,
            guide: tokens.lineStrong,
          ),
        ),
        RulerPicker(
          key: const Key('live-reps'),
          showMinorTicks: false,
          unitLabel: l.sessionReps,
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

/// The marker is decoration; the field name remains ordinary localized text.
class _FieldGuide extends StatelessWidget {
  const _FieldGuide({
    required this.label,
    this.hint,
    required this.color,
    required this.guide,
  });
  final String label;
  final String? hint;
  final Color color;
  final Color guide;
  @override
  Widget build(BuildContext context) {
    final style = WorkoutType.body(size: 12, color: context.tokens.dim);
    Widget marker() => ExcludeSemantics(
      child: SizedBox.square(
        dimension: 12,
        child: CustomPaint(painter: _GuidePainter(color: color, marker: true)),
      ),
    );
    Widget leader() => Expanded(
      child: ExcludeSemantics(
        child: SizedBox(
          height: 12,
          child: CustomPaint(painter: _GuidePainter(color: guide)),
        ),
      ),
    );
    // The adjustable ruler below owns the field name and value. Repeating
    // the visual label adds a duplicate screen-reader stop with no action.
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          double widthOf(String value) {
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
              hint != null &&
              widthOf(label) + widthOf(hint!) + 52 > constraints.maxWidth;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  marker(),
                  const SizedBox(width: 8),
                  Flexible(child: FitLabel(label, maxLines: 2, style: style)),
                  const SizedBox(width: 8),
                  leader(),
                  if (hint != null && !stacked) ...[
                    const SizedBox(width: 8),
                    Text(hint!, style: style),
                  ],
                ],
              ),
              if (stacked) ...[
                const SizedBox(height: 4),
                FitLabel(hint!, maxLines: 2, style: style),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _GuidePainter extends CustomPainter {
  const _GuidePainter({required this.color, this.marker = false});
  final Color color;
  final bool marker;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    if (marker) {
      for (var y = 0; y < 3; y++) {
        for (var x = 0; x < 3; x++) {
          canvas.drawRect(Rect.fromLTWH(1 + x * 4, 1 + y * 4, 2, 2), paint);
        }
      }
    } else {
      for (var x = 0.0; x < size.width; x += 4) {
        canvas.drawRect(Rect.fromLTWH(x, size.height / 2, 1, 1), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_GuidePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.marker != marker;
}
