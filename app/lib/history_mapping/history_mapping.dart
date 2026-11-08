import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../catalog/catalog.dart';
import '../domain/evidence.dart';
import '../store/local_store.dart';
import '../transfer/history_v1.dart';
import '../transfer/json_span_reader.dart';
import '../transfer/transfer_service.dart';

const historyMappingFormat = 'alkion-history-test-mappings';
const historyTestNamespace = 'history-test';
const maxHistoryMappingBytes = 2 * 1024 * 1024;

/// Review metadata only. A mapping never changes a source row or supplies
/// typed/native measurement evidence, a finish intent, or a server identity.
final class HistoryMapping {
  HistoryMapping({
    required this.sourceName,
    required this.status,
    required this.rationale,
    this.variantId,
    this.variantRevision,
    this.displayName,
    this.measurementProfile,
  });
  final String sourceName, status, rationale;
  final String? variantId, displayName, measurementProfile;
  final int? variantRevision;
  bool get resolved => status != 'unresolved';
  Map<String, Object?> toJson() => {
    'source_name': sourceName,
    'status': status,
    'rationale': rationale,
    if (resolved) ...{
      'variant_id': variantId,
      'variant_revision': variantRevision,
      'display_name': displayName,
      'measurement_profile': measurementProfile,
      'measurement_context': {
        'recorded_unit': 'kg',
        'load_convention': 'reported_mass',
        'resistance_source': 'external',
      },
    },
  };
}

final class HistoryMappingReview {
  HistoryMappingReview({
    required this.sourceDigest,
    required this.entries,
    this.catalogDigest,
    this.catalogRevision,
  });
  final String sourceDigest;
  final String? catalogDigest, catalogRevision;
  final List<HistoryMapping> entries;
  Map<String, Object?> toJson() => {
    'format': historyMappingFormat,
    'version': 1,
    'source_sha256': sourceDigest,
    'catalog_sha256': catalogDigest,
    'catalog_revision': catalogRevision,
    'entries': entries.map((e) => e.toJson()).toList(),
  };
  Map<String, int> get counts => {
    for (final status in ['exact', 'approximate', 'unresolved'])
      status: entries.where((e) => e.status == status).length,
  };

  factory HistoryMappingReview.unresolved(
    HistoryV1Document source,
  ) => HistoryMappingReview(
    sourceDigest: source.digest,
    entries: [
      for (final name in sourceNames(source))
        HistoryMapping(
          sourceName: name,
          status: 'unresolved',
          rationale:
              'No reviewed catalog mapping supplied; source retained unchanged.',
        ),
    ],
  );
}

/// Distinct exact exercise names, sorted; a mapping never fuzzy-matches.
List<String> sourceNames(HistoryV1Document source) => List.unmodifiable(
  source.blocks.map((b) => b.values['name'] as String).toSet().toList()..sort(),
);

/// A supplied sidecar is explicit human review, never fuzzy matching. Missing
/// names remain unresolved. Extra names, duplicate keys and stale catalog
/// identities are refused before any overlay can be selected.
HistoryMappingReview readHistoryMappings(
  Uint8List bytes,
  HistoryV1Document document, {
  CatalogBundle? catalog,
}) {
  if (bytes.length > maxHistoryMappingBytes) {
    throw const FormatException('mapping_resource_limit');
  }
  readJsonSpans(bytes);
  final root = jsonDecode(utf8.decode(bytes));
  if (root is! Map<String, dynamic> ||
      root['format'] != historyMappingFormat ||
      root['version'] != 1 ||
      root['source_sha256'] != document.digest ||
      root['entries'] is! List) {
    throw const FormatException('mapping_source_or_format_mismatch');
  }
  final names = sourceNames(document).toSet();
  final mapped = <String, HistoryMapping>{};
  for (final value in root['entries'] as List) {
    if (value is! Map<String, dynamic> ||
        value['source_name'] is! String ||
        !names.contains(value['source_name']) ||
        mapped.containsKey(value['source_name']) ||
        !const [
          'exact',
          'approximate',
          'unresolved',
        ].contains(value['status']) ||
        value['rationale'] is! String ||
        (value['rationale'] as String).trim().isEmpty ||
        (value['rationale'] as String).length > 4096) {
      throw const FormatException('mapping_entry_invalid');
    }
    final name = value['source_name'] as String;
    final status = value['status'] as String;
    final variant = catalog?.variants[value['variant_id']];
    if (status != 'unresolved') {
      if (catalog == null ||
          root['catalog_sha256'] != catalog.digest ||
          root['catalog_revision'] != catalog.catalogRevision ||
          variant == null ||
          variant.revision != value['variant_revision'] ||
          variant.measurementProfileKey != value['measurement_profile'] ||
          variant.measurementProfileKey != 'load_reps' ||
          !_externalMass(variant)) {
        throw const FormatException('mapping_catalog_or_context_incompatible');
      }
      final context = value['measurement_context'];
      if (context != null &&
          (context is! Map ||
              context['recorded_unit'] != 'kg' ||
              context['load_convention'] != 'reported_mass' ||
              context['resistance_source'] != 'external')) {
        throw const FormatException('mapping_measurement_context_incompatible');
      }
    } else if (value['variant_id'] != null ||
        value['variant_revision'] != null ||
        value['measurement_profile'] != null) {
      throw const FormatException('mapping_unresolved_has_target');
    }
    mapped[name] = HistoryMapping(
      sourceName: name,
      status: status,
      rationale: value['rationale'] as String,
      variantId: status == 'unresolved' ? null : variant!.id,
      variantRevision: status == 'unresolved' ? null : variant!.revision,
      displayName: status == 'unresolved'
          ? null
          : variant!.names['en'] ?? variant.names.values.first,
      measurementProfile: status == 'unresolved'
          ? null
          : variant!.measurementProfileKey,
    );
  }
  return HistoryMappingReview(
    sourceDigest: document.digest,
    catalogDigest: root['catalog_sha256'] as String?,
    catalogRevision: root['catalog_revision'] as String?,
    entries: [
      for (final fallback in HistoryMappingReview.unresolved(document).entries)
        mapped[fallback.sourceName] ?? fallback,
    ],
  );
}

bool _externalMass(CatalogVariant variant) {
  // A reported kg observation cannot acquire added-load, bodyweight or
  // assistance semantics from a test overlay. Check contradictions before
  // an explicit source or equipment fallback; unknown load modes fail closed.
  final loadMode = variant.facets['load_mode'];
  if (loadMode != null &&
      !const {'external', 'reported_mass'}.contains(loadMode)) {
    return false;
  }
  const incompatible = {
    'added',
    'added_load',
    'bodyweight',
    'assistance',
    'assisted',
    'counterweight',
    'band',
    'elastic_band',
    'resistance_band',
    'band_assistance',
    'band_resistance',
    'jump_assistance',
  };
  if (incompatible.contains(variant.equipmentKind) ||
      variant.facets.values.any(incompatible.contains)) {
    return false;
  }
  final explicit = variant.facets['resistance_source'];
  if (explicit != null) return explicit == 'external';
  return const {
    'barbell',
    'dumbbell',
    'kettlebell',
    'machine',
    'cable',
    'plate',
    'weight_stack',
    'smith_machine',
    'free_weight',
  }.contains(variant.equipmentKind);
}

/// Current selection plus immutable review records use the existing profile
/// local-state/review contracts, separately from imported source selections.
final class HistoryMappingStore {
  const HistoryMappingStore(this.db);
  final LocalDatabase db;
  String _key(String namespace, String digest) =>
      'history-test:$namespace:$digest';
  Future<Uint8List?> reviewBytes({
    required String namespace,
    required String digest,
  }) => db.readTransaction((tx) async {
    final row = await tx.localState(
      LocalStateKind.catalogSelection,
      _key(namespace, digest),
    );
    return row == null
        ? null
        : Uint8List.fromList((row['payload_bytes'] as List).cast<int>());
  });
  Future<int> select(
    HistoryMappingReview review, {
    required String namespace,
  }) => db.writeTransaction((tx) async {
    checkNamespace(namespace);
    final source = await tx.getOptional(
      'SELECT 1 FROM source_artifacts a JOIN import_generations g ON a.profile_id=g.profile_id AND a.artifact_id=g.artifact_id WHERE a.profile_id=? AND a.digest=? AND g.namespace=? AND g.selected=1',
      [tx.profileId, review.sourceDigest, namespace],
    );
    if (source == null) {
      throw const StoreException('mapping_history_not_selected');
    }
    final key = _key(namespace, review.sourceDigest);
    final bytes = localBytes(review.toJson());
    final old = await tx.localState(LocalStateKind.catalogSelection, key);
    if (old != null &&
        base64Encode((old['payload_bytes'] as List).cast<int>()) ==
            base64Encode(bytes)) {
      return old['revision'] as int;
    }
    final revision = await tx.putLocalState(
      LocalStateKind.catalogSelection,
      key,
      bytes,
      expectedRevision: old?['revision'] as int? ?? 0,
    );
    await tx.addReview(
      id: 'history-mapping-${sha256.convert(localBytes([key, revision, review.toJson()]))}',
      category: 'history_test_mapping',
      evidence: localBytes({
        'namespace': namespace,
        'revision': revision,
        'review': review.toJson(),
      }),
    );
    return revision;
  });

  Future<Map<String, HistoryMapping>> byExerciseId() => db.readTransaction((
    tx,
  ) async {
    final rows = await tx.getAll(
      "SELECT state_key,payload_bytes FROM local_state WHERE profile_id=? AND state_kind='catalogSelection' AND state_key LIKE 'history-test:%'",
      [tx.profileId],
    );
    final result = <String, HistoryMapping>{};
    for (final row in rows) {
      final review = decodeBytesJson(row['payload_bytes']);
      if (review['format'] != historyMappingFormat || review['version'] != 1) {
        throw const StoreException('mapping_newer_state_preserved');
      }
      final key = row['state_key'] as String;
      final namespace = key.substring(
        'history-test:'.length,
        key.lastIndexOf(':'),
      );
      final origins = await tx.getAll(
        "SELECT o.local_id,p.projection_bytes FROM origin_mappings o JOIN exercises e ON e.profile_id=o.profile_id AND e.id=o.local_id JOIN source_revisions r ON r.profile_id=e.profile_id AND r.source_revision_id=e.source_revision_id JOIN source_projections p ON p.profile_id=r.profile_id AND p.source_revision_id=r.source_revision_id JOIN import_generations g ON g.profile_id=r.profile_id AND g.namespace=r.namespace JOIN source_artifacts a ON a.profile_id=g.profile_id AND a.artifact_id=g.artifact_id WHERE o.profile_id=? AND o.source_kind='exercises' AND o.namespace=? AND g.selected=1 AND a.digest=?",
        [tx.profileId, namespace, review['source_sha256']],
      );
      final entries = {
        for (final e in review['entries'] as List) (e as Map)['source_name']: e,
      };
      for (final origin in origins) {
        // Both readers retain field projection evidence. Use that source name,
        // independently of a successor's later local name correction.
        final projection = decodeBytesJson(origin['projection_bytes']);
        final name =
            ((projection['fields'] as Map)['name'] as Map)['projected'];
        final e = entries[name];
        if (e is! Map) continue;
        result[origin['local_id'] as String] = HistoryMapping(
          sourceName: e['source_name'] as String,
          status: e['status'] as String,
          rationale: e['rationale'] as String,
          variantId: e['variant_id'] as String?,
          variantRevision: e['variant_revision'] as int?,
          displayName: e['display_name'] as String?,
          measurementProfile: e['measurement_profile'] as String?,
        );
      }
    }
    return Map.unmodifiable(result);
  });
}
