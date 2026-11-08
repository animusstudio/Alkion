import '../domain/catalog_execution.dart';
import '../domain/evidence.dart';
import '../l10n/app_localizations.dart';
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
