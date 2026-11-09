import '../domain/catalog_execution.dart';
import '../domain/evidence.dart';
import '../l10n/app_localizations.dart';
import 'catalog_picker.dart';

Map<String, String> catalogInputValues(CatalogSetEvidence evidence) => {
  for (final entry in evidence.metrics.entries)
    if (entry.value.raw is String) entry.key: entry.value.raw as String,
};

/// The long labelled form ("Load (kg): 18 · Repetitions: 12").
///
/// Superseded by `catalogSetCompact` (`catalog_set_format.dart`). Kept only
/// for the log bar label and the live screen's Next label and reference,
/// which the live-workout declutter plan's T3 moves over and then deletes
/// this.
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
