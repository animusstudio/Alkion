import 'dart:convert';
import 'dart:typed_data';

import '../catalog/catalog_bundle.dart' show CatalogMeasurementProfile;
import 'evidence.dart';

Map<String, dynamic> catalogEvidenceObject(Object? value) {
  if (value is! Map) throw const FormatException('Catalog evidence object');
  return Map<String, dynamic>.from(value);
}

void catalogEvidenceKeys(Map<String, dynamic> value, Set<String> keys) {
  if (value.keys.any((key) => !keys.contains(key))) {
    throw const FormatException('Unknown catalog evidence field');
  }
}

void _envelope(Map<String, dynamic> json, String format, Set<String> keys) {
  catalogEvidenceKeys(json, {'format', 'version', ...keys});
  if (json['format'] != format || json['version'] != 1) {
    throw const FormatException('Unsupported catalog evidence version');
  }
}

Map<String, dynamic> decodeCatalogBytes(Object value) =>
    catalogEvidenceObject(jsonDecode(utf8.decode((value as List).cast<int>())));

final class CatalogMeasurementProfileEvidence {
  CatalogMeasurementProfileEvidence({
    required this.key,
    required List<String> requiredMetrics,
    required List<String> optionalMetrics,
    required this.progressionPolicy,
  }) : requiredMetrics = List.unmodifiable(requiredMetrics),
       optionalMetrics = List.unmodifiable(optionalMetrics) {
    final expected = definitions[key];
    bool same(List<String> a, List<String> b) =>
        a.length == b.length && a.toSet().containsAll(b);
    if (expected == null ||
        !same(this.requiredMetrics, expected.$1) ||
        !same(this.optionalMetrics, expected.$2) ||
        progressionPolicy !=
            (key == 'load_reps' ? 'load_reps_only' : 'unsupported')) {
      throw const FormatException('Unsupported measurement policy');
    }
  }
  factory CatalogMeasurementProfileEvidence.fromCatalog(
    CatalogMeasurementProfile profile,
  ) => CatalogMeasurementProfileEvidence(
    key: profile.key,
    requiredMetrics: profile.requiredMetrics,
    optionalMetrics: profile.optionalMetrics,
    progressionPolicy: profile.progressionPolicy,
  );
  factory CatalogMeasurementProfileEvidence.forKey(String key) {
    final value = definitions[key];
    if (value == null) {
      throw const FormatException('Unknown measurement profile');
    }
    return CatalogMeasurementProfileEvidence(
      key: key,
      requiredMetrics: value.$1,
      optionalMetrics: value.$2,
      progressionPolicy: key == 'load_reps' ? 'load_reps_only' : 'unsupported',
    );
  }
  static const definitions = <String, (List<String>, List<String>)>{
    'load_reps': (['reported_load', 'repetitions'], []),
    'distance_duration': (['distance', 'duration'], []),
    'distance_duration_load': (['distance', 'duration', 'reported_load'], []),
    'duration_distance_optional': (['duration'], ['distance']),
    'duration_load_optional': (['duration'], ['reported_load']),
    'duration_reps_optional': (['duration'], ['repetitions']),
    'reps_distance_optional': (['repetitions'], ['distance']),
    'reps_duration_optional_load': (
      ['repetitions'],
      ['duration', 'reported_load'],
    ),
  };
  final String key, progressionPolicy;
  final List<String> requiredMetrics, optionalMetrics;
  List<String> get metrics => [...requiredMetrics, ...optionalMetrics];
  CatalogMeasurementProfile toCatalogMeasurementProfile() =>
      CatalogMeasurementProfile(
        key,
        requiredMetrics,
        optionalMetrics,
        progressionPolicy,
      );
  Map<String, Object?> toJson() => {
    'format': 'alkion-catalog-measurement-profile',
    'version': 1,
    'key': key,
    'requiredMetrics': requiredMetrics,
    'optionalMetrics': optionalMetrics,
    'progressionPolicy': progressionPolicy,
  };
  factory CatalogMeasurementProfileEvidence.fromJson(
    Map<String, dynamic> json,
  ) {
    _envelope(json, 'alkion-catalog-measurement-profile', {
      'key',
      'requiredMetrics',
      'optionalMetrics',
      'progressionPolicy',
    });
    return CatalogMeasurementProfileEvidence(
      key: json['key'] as String,
      requiredMetrics: (json['requiredMetrics'] as List).cast<String>(),
      optionalMetrics: (json['optionalMetrics'] as List).cast<String>(),
      progressionPolicy: json['progressionPolicy'] as String,
    );
  }
}

final class CatalogExecutionDefinition {
  CatalogExecutionDefinition({
    required this.profile,
    required this.displayLabel,
    Set<String> personalGroups = const {},
  }) : personalGroups = Set.unmodifiable(personalGroups);
  final CatalogMeasurementProfileEvidence profile;
  final String displayLabel;
  final Set<String> personalGroups;
  Map<String, Object?> toJson() => {
    'format': 'alkion-execution-definition',
    'version': 1,
    'profile': profile.toJson(),
    'displayLabel': displayLabel,
    'personalGroups': personalGroups.toList()..sort(),
  };
  factory CatalogExecutionDefinition.fromJson(Map<String, dynamic> json) {
    _envelope(json, 'alkion-execution-definition', {
      'profile',
      'displayLabel',
      'personalGroups',
    });
    return CatalogExecutionDefinition(
      profile: CatalogMeasurementProfileEvidence.fromJson(
        catalogEvidenceObject(json['profile']),
      ),
      displayLabel: json['displayLabel'] as String,
      personalGroups: (json['personalGroups'] as List).cast<String>().toSet(),
    );
  }
}

final class CatalogSelectionEvidence {
  CatalogSelectionEvidence({
    required this.exerciseId,
    required this.contextId,
    required this.contextRevision,
    required this.profile,
    required this.displayLabel,
    this.contextLabel = '',
    this.bindingId,
    this.bindingRevision,
    this.familyId,
    this.variantId,
    this.variantRevision,
    this.bundleDigest,
    this.catalogNamespace = 'alkion-exercises',
    this.labelPolicy = 'eligible-familiar/1',
    this.resistanceSource = 'unknown',
    this.loadConvention = 'unknown',
  }) {
    final pins = [
      bindingId,
      bindingRevision,
      familyId,
      variantId,
      variantRevision,
      bundleDigest,
    ];
    if (exerciseId.isEmpty ||
        contextId.isEmpty ||
        contextRevision < 1 ||
        displayLabel.trim().isEmpty ||
        (pins.any((v) => v != null) && pins.any((v) => v == null)) ||
        (bindingRevision != null && bindingRevision! < 1) ||
        (variantRevision != null && variantRevision! < 1) ||
        !const {
          'external',
          'bodyweight',
          'assistance',
          'band',
          'unknown',
        }.contains(resistanceSource) ||
        !const {'reported_mass', 'unknown'}.contains(loadConvention)) {
      throw const FormatException('Unqualified catalog selection');
    }
  }
  final String exerciseId, contextId, displayLabel, contextLabel;
  final int contextRevision;
  final String? bindingId, familyId, variantId, bundleDigest;
  final int? bindingRevision, variantRevision;
  final String catalogNamespace, labelPolicy, resistanceSource, loadConvention;
  final CatalogMeasurementProfileEvidence profile;
  bool get supportsLoadProgression =>
      profile.key == 'load_reps' &&
      resistanceSource == 'external' &&
      loadConvention == 'reported_mass';
  // Labels/context rename revisions do not change physical comparability.
  String get compatibilityKey => jsonEncode([
    exerciseId,
    contextId,
    bindingId,
    bindingRevision,
    familyId,
    variantId,
    variantRevision,
    bundleDigest,
    profile.toJson(),
    resistanceSource,
    loadConvention,
  ]);
  Map<String, Object?> toJson() => {
    'format': 'alkion-catalog-selection',
    'version': 1,
    'exerciseId': exerciseId,
    'contextId': contextId,
    'contextRevision': contextRevision,
    'bindingId': bindingId,
    'bindingRevision': bindingRevision,
    'familyId': familyId,
    'variantId': variantId,
    'variantRevision': variantRevision,
    'bundleDigest': bundleDigest,
    'catalogNamespace': catalogNamespace,
    'labelPolicy': labelPolicy,
    'displayLabel': displayLabel,
    'contextLabel': contextLabel,
    'profile': profile.toJson(),
    'resistanceSource': resistanceSource,
    'loadConvention': loadConvention,
  };
  factory CatalogSelectionEvidence.fromJson(Map<String, dynamic> json) {
    _envelope(json, 'alkion-catalog-selection', {
      'exerciseId',
      'contextId',
      'contextRevision',
      'bindingId',
      'bindingRevision',
      'familyId',
      'variantId',
      'variantRevision',
      'bundleDigest',
      'catalogNamespace',
      'labelPolicy',
      'displayLabel',
      'contextLabel',
      'profile',
      'resistanceSource',
      'loadConvention',
    });
    return CatalogSelectionEvidence(
      exerciseId: json['exerciseId'] as String,
      contextId: json['contextId'] as String,
      contextRevision: json['contextRevision'] as int,
      bindingId: json['bindingId'] as String?,
      bindingRevision: json['bindingRevision'] as int?,
      familyId: json['familyId'] as String?,
      variantId: json['variantId'] as String?,
      variantRevision: json['variantRevision'] as int?,
      bundleDigest: json['bundleDigest'] as String?,
      catalogNamespace: json['catalogNamespace'] as String,
      labelPolicy: json['labelPolicy'] as String,
      displayLabel: json['displayLabel'] as String,
      contextLabel: json['contextLabel'] as String,
      profile: CatalogMeasurementProfileEvidence.fromJson(
        catalogEvidenceObject(json['profile']),
      ),
      resistanceSource: json['resistanceSource'] as String,
      loadConvention: json['loadConvention'] as String,
    );
  }
  CatalogSelectionEvidence withContextLabel(String label, int revision) =>
      CatalogSelectionEvidence.fromJson({
        ...toJson(),
        'contextLabel': label,
        'contextRevision': revision,
      });
}

final class CatalogMetricEvidence {
  const CatalogMetricEvidence({
    required this.state,
    required this.raw,
    required this.unit,
  });
  final ValueState state;
  final Object? raw;
  final String unit;
  factory CatalogMetricEvidence.fromInput(
    String text, {
    required String metric,
    required String unit,
  }) {
    final value = ExactDecimal.tryParse(text);
    final valid =
        value != null &&
        (metric == 'reported_load'
            ? value.coefficient >= BigInt.zero
            : value.coefficient > BigInt.zero) &&
        (metric != 'repetitions' || RegExp(r'^\d+$').hasMatch(text));
    return CatalogMetricEvidence(
      state: text.isEmpty
          ? ValueState.empty
          : valid
          ? ValueState.valid
          : ValueState.invalid,
      raw: text,
      unit: unit,
    );
  }
  static String defaultUnit(String metric) => switch (metric) {
    'reported_load' => 'kg',
    'repetitions' => 'count',
    'duration' => 's',
    'distance' => 'm',
    _ => throw const FormatException('Unknown metric'),
  };
  void validate(String metric) {
    final units = metric == 'reported_load'
        ? {'kg', 'lb'}
        : {defaultUnit(metric)};
    if (!units.contains(unit) ||
        (state == ValueState.valid &&
            (raw is! String ||
                CatalogMetricEvidence.fromInput(
                      raw as String,
                      metric: metric,
                      unit: unit,
                    ).state !=
                    ValueState.valid)) ||
        (state == ValueState.empty && raw != '') ||
        ((state == ValueState.missing || state == ValueState.nullValue) &&
            raw != null)) {
      throw const FormatException('Malformed typed quantity');
    }
  }

  Map<String, Object?> toJson() => {
    'state': state.name,
    'raw': raw,
    'unit': unit,
  };
  factory CatalogMetricEvidence.fromJson(Map<String, dynamic> json) {
    catalogEvidenceKeys(json, {'state', 'raw', 'unit'});
    return CatalogMetricEvidence(
      state: ValueState.values.byName(json['state'] as String),
      raw: json['raw'],
      unit: json['unit'] as String,
    );
  }
  ExactDecimal? get exact => state == ValueState.valid && raw is String
      ? ExactDecimal.tryParse(raw as String)
      : null;
  ExactDecimal? get loadKg {
    final value = exact;
    if (value == null) return null;
    if (unit == 'kg') return value;
    if (unit != 'lb') return null;
    final coefficient = value.coefficient * BigInt.from(45359237);
    final scale = value.scale + 8;
    final digits = coefficient.abs().toString().padLeft(scale + 1, '0');
    final text =
        '${coefficient.isNegative ? '-' : ''}${digits.substring(0, digits.length - scale)}.${digits.substring(digits.length - scale)}';
    return ExactDecimal.parse(text);
  }
}

final class CatalogSetEvidence {
  CatalogSetEvidence({
    required this.selection,
    required Map<String, CatalogMetricEvidence> metrics,
  }) : metrics = Map.unmodifiable(metrics) {
    if (metrics.keys.any((key) => !selection.profile.metrics.contains(key))) {
      throw const FormatException('Metric outside measurement policy');
    }
    for (final entry in metrics.entries) {
      entry.value.validate(entry.key);
    }
  }
  final CatalogSelectionEvidence selection;
  final Map<String, CatalogMetricEvidence> metrics;
  bool get validForLogging =>
      selection.profile.requiredMetrics.every(
        (key) => metrics[key]?.state == ValueState.valid,
      ) &&
      selection.profile.optionalMetrics.every(
        (key) =>
            metrics[key] == null ||
            const {
              ValueState.valid,
              ValueState.missing,
              ValueState.empty,
            }.contains(metrics[key]!.state),
      );
  Map<String, Object?> toJson() => {
    'format': 'alkion-catalog-set',
    'version': 1,
    'selection': selection.toJson(),
    'metrics': {
      for (final entry in metrics.entries) entry.key: entry.value.toJson(),
    },
  };
  Uint8List get bytes => localBytes(toJson());
  factory CatalogSetEvidence.fromJson(Map<String, dynamic> json) {
    _envelope(json, 'alkion-catalog-set', {'selection', 'metrics'});
    return CatalogSetEvidence(
      selection: CatalogSelectionEvidence.fromJson(
        catalogEvidenceObject(json['selection']),
      ),
      metrics: catalogEvidenceObject(json['metrics']).map(
        (key, value) => MapEntry(
          key,
          CatalogMetricEvidence.fromJson(catalogEvidenceObject(value)),
        ),
      ),
    );
  }
}

/// An edit may retain unavailable evidence, but cannot author a new invalid
/// quantity by passing a display fallback through a correction/replace action.
bool catalogLoggingChangeAllowed(
  CatalogSetEvidence next, {
  CatalogSetEvidence? previous,
}) {
  for (final key in next.selection.profile.metrics) {
    final metric = next.metrics[key];
    final accepted = next.selection.profile.requiredMetrics.contains(key)
        ? metric?.state == ValueState.valid
        : metric == null ||
              const {
                ValueState.valid,
                ValueState.missing,
                ValueState.empty,
              }.contains(metric.state);
    if (accepted) continue;
    if (previous == null ||
        jsonEncode(metric?.toJson()) !=
            jsonEncode(previous.metrics[key]?.toJson())) {
      return false;
    }
  }
  return true;
}

Map<String, Object?> catalogTargetsJson(
  Map<String, CatalogMetricEvidence> metrics,
) => {
  'format': 'alkion-catalog-targets',
  'version': 1,
  'metrics': {
    for (final entry in metrics.entries) entry.key: entry.value.toJson(),
  },
};
Map<String, CatalogMetricEvidence> decodeCatalogTargets(
  Object bytes,
  CatalogSelectionEvidence selection,
) {
  final json = decodeCatalogBytes(bytes);
  _envelope(json, 'alkion-catalog-targets', {'metrics'});
  final metrics = catalogEvidenceObject(json['metrics']).map(
    (key, value) => MapEntry(
      key,
      CatalogMetricEvidence.fromJson(catalogEvidenceObject(value)),
    ),
  );
  CatalogSetEvidence(selection: selection, metrics: metrics);
  return Map.unmodifiable(metrics);
}
