import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../catalog/catalog.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import 'catalog_picker.dart';

bool catalogMeasurementsValid(
  CatalogMeasurementProfile profile,
  Map<String, String> values,
) {
  bool valid(String metric, {required bool required}) {
    final text = values[metric]?.trim() ?? '';
    if (text.isEmpty) return !required;
    final value = double.tryParse(text);
    if (value == null || !value.isFinite || value < 0) return false;
    if (metric == 'repetitions') {
      return (int.tryParse(text) ?? 0) > 0;
    }
    return metric == 'reported_load' || value > 0;
  }

  return profile.requiredMetrics.every((m) => valid(m, required: true)) &&
      profile.optionalMetrics.every((m) => valid(m, required: false));
}

/// Production-reusable typed metric fields. The caller owns exact text,
/// so navigating, locale changes and setup menus never seed over an edit.
class CatalogMeasurementForm extends StatefulWidget {
  const CatalogMeasurementForm({
    super.key,
    required this.profile,
    required this.values,
    required this.onChanged,
    this.enabled = true,
    this.units = const {},
    this.onMetricChanged,
    this.exclude = const {},
  });
  final CatalogMeasurementProfile profile;
  final Map<String, String> values;
  final VoidCallback onChanged;
  final bool enabled;
  final Map<String, String> units;
  final void Function(String metric, String text)? onMetricChanged;

  /// Metrics another control edits; they get no field here. Empty by default.
  final Set<String> exclude;
  @override
  State<CatalogMeasurementForm> createState() => _CatalogMeasurementFormState();
}

class _CatalogMeasurementFormState extends State<CatalogMeasurementForm> {
  final _controllers = <String, TextEditingController>{};
  @override
  void didUpdateWidget(CatalogMeasurementForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    for (final entry in _controllers.entries) {
      final before = oldWidget.values[entry.key] ?? '';
      final after = widget.values[entry.key] ?? '';
      if (before != after && entry.value.text == before) {
        entry.value.value = TextEditingValue(
          text: after,
          selection: TextSelection.collapsed(offset: after.length),
        );
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      children: [
        for (final metric in [
          ...widget.profile.requiredMetrics,
          ...widget.profile.optionalMetrics,
        ])
          if (!widget.exclude.contains(metric))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                key: ValueKey('metric-$metric'),
                enabled: widget.enabled,
                controller: _controllers.putIfAbsent(
                  metric,
                  () =>
                      TextEditingController(text: widget.values[metric] ?? ''),
                ),
                keyboardType: TextInputType.numberWithOptions(
                  decimal: metric != 'repetitions',
                ),
                textInputAction: TextInputAction.next,
                inputFormatters: [
                  TextInputFormatter.withFunction((old, next) {
                    final text = next.text.replaceAll(',', '.');
                    return RegExp(r'^\d*\.?\d*$').hasMatch(text)
                        ? next.copyWith(text: text)
                        : old;
                  }),
                ],
                style: WorkoutType.mono(size: 20, color: context.tokens.text),
                decoration: InputDecoration(
                  labelText:
                      '${catalogMetricLabel(l, metric, unit: widget.units[metric])}${widget.profile.optionalMetrics.contains(metric) ? ' · ${l.catalogOptional}' : ''}',
                ),
                onChanged: (v) {
                  widget.values[metric] = v;
                  widget.onMetricChanged?.call(metric, v);
                  widget.onChanged();
                },
              ),
            ),
      ],
    );
  }
}
