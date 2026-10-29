import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../catalog/catalog.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import 'catalog_picker.dart';
import 'catalog_trial_scope.dart';

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

/// Production-reusable typed metric fields. The trial adapter owns exact text,
/// so navigating, locale changes and setup menus never seed over an edit.
class CatalogMeasurementForm extends StatefulWidget {
  const CatalogMeasurementForm({
    super.key,
    required this.profile,
    required this.values,
    required this.onChanged,
    this.enabled = true,
  });
  final CatalogMeasurementProfile profile;
  final Map<String, String> values;
  final VoidCallback onChanged;
  final bool enabled;
  @override
  State<CatalogMeasurementForm> createState() => _CatalogMeasurementFormState();
}

class _CatalogMeasurementFormState extends State<CatalogMeasurementForm> {
  final _controllers = <String, TextEditingController>{};
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
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              key: ValueKey('metric-$metric'),
              enabled: widget.enabled,
              controller: _controllers.putIfAbsent(
                metric,
                () => TextEditingController(text: widget.values[metric] ?? ''),
              ),
              keyboardType: TextInputType.numberWithOptions(
                decimal: metric != 'repetitions',
              ),
              textInputAction: TextInputAction.next,
              inputFormatters: [
                TextInputFormatter.withFunction(
                  (old, next) =>
                      RegExp(r'^\d*\.?\d*$').hasMatch(next.text) ? next : old,
                ),
              ],
              style: WorkoutType.mono(size: 20, color: context.tokens.text),
              decoration: InputDecoration(
                labelText:
                    '${catalogMetricLabel(l, metric)}${widget.profile.optionalMetrics.contains(metric) ? ' · ${l.catalogOptional}' : ''}',
              ),
              onChanged: (v) {
                widget.values[metric] = v;
                widget.onChanged();
              },
            ),
          ),
      ],
    );
  }
}

class CatalogTrialBlock extends StatelessWidget {
  const CatalogTrialBlock({
    super.key,
    required this.state,
    required this.choice,
    required this.setId,
    required this.title,
    required this.done,
    required this.onChanged,
    required this.onMenu,
  });
  final CatalogTrialState state;
  final CatalogChoice choice;
  final String setId, title;
  final bool done;
  final VoidCallback onChanged, onMenu;
  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    final profile = state.measurement(choice);
    final values = done
        ? state.loggedMetrics[setId] ?? {}
        : state.metricDrafts.putIfAbsent(setId, () => {});
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: FitLabel(
                  title,
                  maxLines: 3,
                  style: WorkoutType.display(
                    size: 22,
                    color: context.tokens.text,
                  ),
                ),
              ),
              IconButton(
                onPressed: onMenu,
                tooltip: AppLocalizations.of(context).catalogChangeSetup,
                icon: const Icon(Icons.more_horiz),
              ),
            ],
          ),
          if (state.distinction(choice, locale).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                state.distinction(choice, locale),
                style: WorkoutType.body(size: 14, color: context.tokens.dim),
              ),
            ),
          if (done)
            Text(
              values.entries
                  .map(
                    (e) =>
                        '${catalogMetricLabel(AppLocalizations.of(context), e.key)}: ${e.value}',
                  )
                  .join(' · '),
              style: WorkoutType.mono(size: 15, color: context.tokens.text),
            )
          else
            CatalogMeasurementForm(
              key: ValueKey(setId),
              profile: profile,
              values: values,
              onChanged: onChanged,
            ),
        ],
      ),
    );
  }
}
