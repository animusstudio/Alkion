import 'package:flutter/material.dart';

import '../domain/catalog_execution.dart';
import '../domain/evidence.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import 'catalog_measurement_form.dart';
import 'catalog_picker.dart';

Map<String, String> catalogInputValues(CatalogSetEvidence evidence) => {
  for (final entry in evidence.metrics.entries)
    if (entry.value.raw is String) entry.key: entry.value.raw as String,
};

String catalogEvidenceSummary(
  CatalogSetEvidence evidence,
  AppLocalizations l,
) => evidence.selection.profile.metrics
    .where(evidence.metrics.containsKey)
    .map((metric) {
      final quantity = evidence.metrics[metric]!;
      final value = switch (quantity.state) {
        ValueState.valid => quantity.raw.toString(),
        ValueState.empty => '—',
        _ => '—',
      };
      return '${catalogMetricLabel(l, metric, unit: quantity.unit)}: $value';
    })
    .join(' · ');

/// Works entirely from the persisted snapshot, including when the private
/// discovery bundle is unavailable or has been replaced.
class CatalogEvidenceCard extends StatelessWidget {
  const CatalogEvidenceCard({
    super.key,
    required this.evidence,
    required this.done,
    required this.onMetricChanged,
    required this.onMenu,
    this.title,
    this.onFocus,
    this.loadUnit = 'kg',
    this.enabled = true,
    this.onUseLast,
  });
  final CatalogSetEvidence evidence;
  final bool done, enabled;
  final String? title;
  final String loadUnit;
  final void Function(String metric, String text, String unit) onMetricChanged;
  final VoidCallback onMenu;
  final VoidCallback? onFocus;
  final VoidCallback? onUseLast;
  @override
  Widget build(BuildContext context) {
    final values = catalogInputValues(evidence);
    final units = {
      for (final metric in evidence.selection.profile.metrics)
        metric:
            evidence.metrics[metric]?.unit ??
            (metric == 'reported_load'
                ? loadUnit
                : CatalogMetricEvidence.defaultUnit(metric)),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: FitLabel(
                  title ?? evidence.selection.displayLabel,
                  maxLines: 3,
                  style: WorkoutType.display(
                    size: 22,
                    color: context.tokens.text,
                  ),
                ),
              ),
              IconButton(
                onPressed: enabled ? onMenu : null,
                tooltip: AppLocalizations.of(context).sessionWorkoutOptions,
                icon: const Icon(Icons.more_horiz),
              ),
            ],
          ),
          if (evidence.selection.contextLabel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                evidence.selection.contextLabel,
                style: WorkoutType.body(size: 14, color: context.tokens.dim),
              ),
            ),
          if (done)
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                alignment: Alignment.centerLeft,
              ),
              onPressed: enabled ? onFocus : null,
              child: Text(
                catalogEvidenceSummary(evidence, AppLocalizations.of(context)),
                style: WorkoutType.mono(size: 15, color: context.tokens.text),
              ),
            )
          else ...[
            if (onUseLast != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: enabled ? onUseLast : null,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: Text(AppLocalizations.of(context).catalogUseLast),
                ),
              ),
            CatalogMeasurementForm(
              profile: evidence.selection.profile.toCatalogMeasurementProfile(),
              values: values,
              units: units,
              enabled: enabled,
              onMetricChanged: (metric, text) =>
                  onMetricChanged(metric, text, units[metric]!),
              onChanged: () {},
            ),
          ],
        ],
      ),
    );
  }
}
