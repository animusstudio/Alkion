import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../catalog_ui/catalog_picker.dart' show catalogMetricLabel;
import '../domain/catalog_execution.dart';
import '../domain/evidence.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../widgets/fit_label.dart';
import '../widgets/number_entry_sheet.dart';
import '../widgets/pending_input.dart';
import '../widgets/ruler_picker.dart';

/// Rulers are display projections only. Only a deliberate ruler movement or a
/// changed modal submission authors a quantity; mounting, unit changes and
/// opening/closing the modal never normalize retained raw evidence.
class CatalogSetValuesEditor extends StatelessWidget {
  const CatalogSetValuesEditor({
    super.key,
    required this.evidence,
    required this.unit,
    required this.onMetricChanged,
    this.enabled = true,
  });

  final CatalogSetEvidence evidence;
  final UnitService unit;
  final void Function(String metric, String text, String unit) onMetricChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final metric in evidence.selection.profile.metrics)
          _metric(context, l, metric),
      ],
    );
  }

  Widget _metric(BuildContext context, AppLocalizations l, String metric) {
    final quantity = evidence.metrics[metric];
    final load = metric == 'reported_load';
    final quantityUnit = load
        ? unit.uLabel
        : CatalogMetricEvidence.defaultUnit(metric);
    final optional = evidence.selection.profile.optionalMetrics.contains(
      metric,
    );
    final valid = quantity?.state == ValueState.valid;
    final raw = valid ? quantity!.raw as String : '';
    final source = double.tryParse(raw);
    // Convert only a display projection. An explicit load edit is authored in
    // the displayed unit, never converted back into the original evidence.
    final display = source == null
        ? null
        : load && quantity!.unit != quantityUnit
        ? quantity.unit == 'lb'
              ? UnitService.toKg(source, Unit.lb)
              : UnitService.fromKg(source, Unit.lb)
        : source;
    // Keep enormous/unsupported display magnitudes editable through the modal
    // without handing an overflowing scale to the finite ruler implementation.
    final representable =
        display != null &&
        display.isFinite &&
        display <= 1e9 &&
        !(display == 0 && quantity?.exact?.coefficient != BigInt.zero);
    final anchor = representable ? display : 0.0;
    String number(double value) => value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
    // The tape is a quick display, not the exact edit seed. A long retained
    // decimal must remain readable at large text; its full spelling stays in
    // evidence and in the modal below.
    String metricDisplay(double value) => value > 0 && value < .01
        ? value.toStringAsPrecision(2)
        : value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
    String format(double value) {
      if (value == anchor && !valid) return '—';
      if (value == anchor && valid && !representable) return raw;
      if (load) return UnitService.fmtDisplay(value, unit.unit);
      return metricDisplay(value);
    }

    final inputUnit = valid && !representable ? quantity!.unit : quantityUnit;
    final label = catalogMetricLabel(l, metric, unit: inputUnit);
    final seed = !valid
        ? ''
        : !load || quantity!.unit == inputUnit
        ? raw
        : representable
        ? UnitService.fmtDisplay(display, unit.unit)
        : '';
    Future<void> type() async {
      commitPendingInput();
      final text = await showExactNumberEntrySheet(
        context,
        title: label,
        initialText: seed,
        allowDecimal: metric != 'repetitions',
        parse: (input) {
          final exact = input.replaceAll(',', '.');
          final value = CatalogMetricEvidence.fromInput(
            exact,
            metric: metric,
            unit: inputUnit,
          );
          return value.state == ValueState.valid ? exact : null;
        },
      );
      if (text != null && context.mounted) {
        onMetricChanged(metric, text, inputUnit);
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FitLabel(
              '$label${optional ? ' · ${l.catalogOptional}' : ''}',
              maxLines: 2,
              style: WorkoutType.body(size: 12, color: context.tokens.dim),
            ),
          ),
          if (!valid || !representable)
            TextButton(
              key: ValueKey('catalog-type-$metric'),
              onPressed: enabled ? type : null,
              style: TextButton.styleFrom(minimumSize: const Size(48, 80)),
              child: FitLabel(
                '${valid ? raw : '—'} $inputUnit · ${l.sessionTapValueToType}',
                maxLines: 3,
                style: WorkoutType.mono(size: 20, color: context.tokens.text),
              ),
            )
          else
            AbsorbPointer(
              absorbing: !enabled,
              child: ExcludeSemantics(
                excluding: !enabled,
                child: RulerPicker(
                  key: ValueKey('catalog-ruler-$metric'),
                  value: anchor,
                  min: load
                      ? 0
                      : metric == 'repetitions'
                      ? 1
                      : .25,
                  max: math.max(anchor, switch (metric) {
                    'reported_load' => unit.unit == Unit.lb ? 1100.0 : 500.0,
                    'repetitions' => 100.0,
                    'duration' => 3600.0,
                    _ => 10000.0,
                  }),
                  step: load && unit.unit == Unit.lb ? 5 : 1,
                  fineStep: metric == 'repetitions'
                      ? null
                      : load && unit.unit == Unit.lb
                      ? 1
                      : .25,
                  showMinorTicks: metric != 'repetitions',
                  unitLabel: quantityUnit == 'count'
                      ? l.sessionReps
                      : quantityUnit,
                  semanticLabel: label,
                  format: format,
                  onChanged: (value) {
                    if (!enabled) return;
                    final text = metric == 'repetitions'
                        ? value.toInt().toString()
                        : number(value);
                    onMetricChanged(metric, text, quantityUnit);
                  },
                  onTapValue: type,
                ),
              ),
            ),
          if (optional &&
              quantity != null &&
              quantity.state != ValueState.empty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: ValueKey('catalog-clear-$metric'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: enabled
                    ? () {
                        commitPendingInput();
                        onMetricChanged(metric, '', quantity.unit);
                      }
                    : null,
                child: FitLabel(
                  l.commonRemove,
                  maxLines: 2,
                  style: WorkoutType.body(color: context.tokens.dim),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
