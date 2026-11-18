import '../domain/catalog_execution.dart';

Map<String, String> catalogInputValues(CatalogSetEvidence evidence) => {
  for (final entry in evidence.metrics.entries)
    if (entry.value.raw is String) entry.key: entry.value.raw as String,
};
