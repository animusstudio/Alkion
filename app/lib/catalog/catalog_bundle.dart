import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Invalid, incompatible or tampered inputs are surfaced to the caller. The
/// caller owns recovery and may continue offering owned/custom exercises.
class CatalogFormatException implements Exception {
  const CatalogFormatException(this.message);
  final String message;
  @override
  String toString() => 'CatalogFormatException: $message';
}

Map<String, dynamic> catalogObject(dynamic value, String at) {
  if (value is! Map<String, dynamic>) {
    throw CatalogFormatException('Expected object: $at');
  }
  return value;
}

String catalogString(dynamic value, String at) {
  if (value is! String || value.trim().isEmpty) {
    throw CatalogFormatException('Expected nonempty string: $at');
  }
  return value;
}

List<dynamic> catalogList(dynamic value, String at) {
  if (value is! List) throw CatalogFormatException('Expected list: $at');
  return value;
}

Map<String, String> _strings(dynamic value, String at) => Map.unmodifiable(
  catalogObject(
    value,
    at,
  ).map((key, value) => MapEntry(key, catalogString(value, '$at.$key'))),
);

/// Stable JSON used for effective vocabulary/profile identity (asset identity
/// itself always hashes the actual supplied bytes).
String catalogCanonicalJson(dynamic value) {
  dynamic sorted(dynamic v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sorted(v[key])};
    }
    if (v is List) return v.map(sorted).toList();
    return v;
  }

  return jsonEncode(sorted(value));
}

String catalogHash(String value) =>
    sha256.convert(utf8.encode(value)).toString();

class CatalogEntity {
  CatalogEntity(this.id, this.key, Map<String, String> names)
    : names = Map.unmodifiable(names);
  final String id;
  final String key;
  final Map<String, String> names;
}

class CatalogVariant extends CatalogEntity {
  CatalogVariant({
    required String id,
    required String key,
    required Map<String, String> names,
    required this.familyId,
    required this.revision,
    required this.equipmentKind,
    required Map<String, String> facets,
    required this.measurementProfileKey,
    required this.muscleCoverage,
    required List<CatalogMuscleRelationship> muscleRelationships,
  }) : facets = Map.unmodifiable(facets),
       muscleRelationships = List.unmodifiable(muscleRelationships),
       super(id, key, names);
  final String familyId;
  final int revision;
  final String equipmentKind;
  final Map<String, String> facets;
  final String measurementProfileKey;
  final String muscleCoverage;
  final List<CatalogMuscleRelationship> muscleRelationships;
}

class CatalogMuscleRelationship {
  const CatalogMuscleRelationship(this.anatomyNodeId, this.role);
  final String anatomyNodeId;
  final String role;
}

class CatalogMeasurementProfile {
  CatalogMeasurementProfile(
    this.key,
    List<String> requiredMetrics,
    List<String> optionalMetrics,
    this.progressionPolicy,
  ) : requiredMetrics = List.unmodifiable(requiredMetrics),
      optionalMetrics = List.unmodifiable(optionalMetrics);
  final String key;
  final List<String> requiredMetrics;
  final List<String> optionalMetrics;
  final String progressionPolicy;
}

class CatalogFilter {
  const CatalogFilter({
    this.familyIds = const [],
    this.equipmentKinds = const [],
    this.facets = const {},
    this.excludedFacets = const {},
  });
  final List<String> familyIds;
  final List<String> equipmentKinds;
  final Map<String, List<String>> facets;
  final Map<String, List<String>> excludedFacets;

  factory CatalogFilter.fromJson(Map<String, dynamic> json) {
    List<String> values(dynamic v) => catalogList(
      v,
      'selector',
    ).map((e) => catalogString(e, 'selector value')).toList(growable: false);
    Map<String, List<String>> group(String key) => Map.unmodifiable(
      catalogObject(json[key] ?? <String, dynamic>{}, key).map(
        (key, value) => MapEntry(key, List<String>.unmodifiable(values(value))),
      ),
    );
    return CatalogFilter(
      familyIds: List.unmodifiable(values(json['family_ids'] ?? [])),
      equipmentKinds: List.unmodifiable(values(json['equipment_kinds'] ?? [])),
      facets: group('facets'),
      excludedFacets: group('excluded_facets'),
    );
  }
  bool matches(CatalogVariant v) =>
      (familyIds.isEmpty || familyIds.contains(v.familyId)) &&
      (equipmentKinds.isEmpty || equipmentKinds.contains(v.equipmentKind)) &&
      facets.entries.every((e) => e.value.contains(v.facets[e.key])) &&
      excludedFacets.entries.every((e) => !e.value.contains(v.facets[e.key]));
  Map<String, dynamic> toJson() => {
    'family_ids': familyIds,
    'equipment_kinds': equipmentKinds,
    'facets': facets,
    'excluded_facets': excludedFacets,
  };
}

class CatalogCollection extends CatalogEntity {
  CatalogCollection(super.id, super.key, super.names, this.selector);
  final CatalogFilter selector;
}

class CatalogTerm {
  CatalogTerm({
    required this.id,
    required this.text,
    required this.locale,
    required this.kind,
    required this.targetId,
    required this.source,
    this.selector = const CatalogFilter(),
    this.qualifier = false,
    this.hasSelector = false,
    this.displayLocales = const [],
  });
  final String id, text, locale, kind, targetId, source;
  final CatalogFilter selector;
  final bool qualifier, hasSelector;
  final List<String> displayLocales;
}

class CatalogBundle {
  CatalogBundle._({
    required this.digest,
    required this.catalogRevision,
    required this.searchRevision,
    required this.families,
    required this.variants,
    required this.collections,
    required this.equipmentModels,
    required this.measurementProfiles,
    required this.terms,
    required this.equipmentKinds,
    required this.facetVocabulary,
  });
  final String digest, catalogRevision, searchRevision;
  final Map<String, CatalogEntity> families, equipmentModels;
  final Map<String, CatalogVariant> variants;
  final Map<String, CatalogCollection> collections;
  final Map<String, CatalogMeasurementProfile> measurementProfiles;
  final List<CatalogTerm> terms;
  final Set<String> equipmentKinds;
  final Map<String, Set<String>> facetVocabulary;

  CatalogMeasurementProfile measurementFor(CatalogVariant v) =>
      measurementProfiles[v.measurementProfileKey]!;
  CatalogEntity? entity(String kind, String id) => switch (kind) {
    'variant' => variants[id],
    'family' => families[id],
    'collection' => collections[id],
    'equipment_model' => equipmentModels[id],
    _ => null,
  };
  List<CatalogVariant> variantsForFamily(String familyId) =>
      List.unmodifiable(variants.values.where((v) => v.familyId == familyId));

  factory CatalogBundle.fromJsonString(String text, {String? expectedSha256}) =>
      CatalogBundle.fromBytes(
        utf8.encode(text),
        expectedSha256: expectedSha256,
      );

  factory CatalogBundle.fromBytes(List<int> bytes, {String? expectedSha256}) {
    final digest = sha256.convert(bytes).toString();
    if (expectedSha256 != null && expectedSha256 != digest) {
      throw const CatalogFormatException('Catalog digest mismatch');
    }
    try {
      final root = catalogObject(jsonDecode(utf8.decode(bytes)), 'catalog');
      if (root['schema_version'] != 1 ||
          root['format'] != 'alkion-exercise-catalog') {
        throw const CatalogFormatException('Unsupported catalog format/schema');
      }
      final revision = catalogString(
        root['catalog_revision'],
        'catalog_revision',
      );
      final search = catalogString(root['search_revision'], 'search_revision');
      final seen = <String>{};
      final seenKeys = <String, Set<String>>{};
      void identify(
        Map<String, dynamic> row,
        String table, {
        bool uuid = false,
      }) {
        final id = catalogString(row['id'], '$table.id');
        if (!seen.add(id)) throw CatalogFormatException('Duplicate ID: $id');
        if (uuid &&
            !RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ).hasMatch(id)) {
          throw CatalogFormatException('Invalid stable ID: $id');
        }
        if (row.containsKey('key') &&
            !(seenKeys[table] ??= <String>{}).add(
              catalogString(row['key'], '$table.key'),
            )) {
          throw CatalogFormatException('Duplicate key: $table');
        }
      }

      List<Map<String, dynamic>> rows(String key) => catalogList(
        root[key],
        key,
      ).map((e) => catalogObject(e, key)).toList();
      Map<String, String> names(Map<String, dynamic> row) {
        final result = _strings(row['names'], 'names');
        if (!result.containsKey('en')) {
          throw const CatalogFormatException('English name required');
        }
        return result;
      }

      final equipment = rowsOrStrings(
        root['equipment_kinds'],
        'equipment_kinds',
      );
      final vocabulary =
          catalogObject(root['facet_vocabulary'], 'facet_vocabulary').map(
            (key, value) => MapEntry(
              key,
              Set<String>.unmodifiable(rowsOrStrings(value, key)),
            ),
          );
      final measurement = <String, CatalogMeasurementProfile>{};
      const profiles = <String, List<List<String>>>{
        'load_reps': [
          ['reported_load', 'repetitions'],
          <String>[],
        ],
        'distance_duration': [
          ['distance', 'duration'],
          <String>[],
        ],
        'distance_duration_load': [
          ['distance', 'duration', 'reported_load'],
          <String>[],
        ],
        'duration_distance_optional': [
          ['duration'],
          ['distance'],
        ],
        'duration_load_optional': [
          ['duration'],
          ['reported_load'],
        ],
        'duration_reps_optional': [
          ['duration'],
          ['repetitions'],
        ],
        'reps_distance_optional': [
          ['repetitions'],
          ['distance'],
        ],
        'reps_duration_optional_load': [
          ['repetitions'],
          ['duration', 'reported_load'],
        ],
      };
      for (final row in rows('measurement_profiles')) {
        final key = catalogString(row['key'], 'measurement key');
        final required = rowsOrStrings(
          row['required_metrics'],
          'required_metrics',
        );
        final optional = rowsOrStrings(
          row['optional_metrics'],
          'optional_metrics',
        );
        final expected = profiles[key];
        bool same(List<String> a, List<String> b) =>
            a.length == b.length && a.toSet().containsAll(b);
        if (expected == null ||
            !same(required, expected[0]) ||
            !same(optional, expected[1]) ||
            row['progression_policy'] !=
                (key == 'load_reps' ? 'load_reps_only' : 'unsupported') ||
            measurement.containsKey(key)) {
          throw CatalogFormatException('Unsupported measurement profile: $key');
        }
        measurement[key] = CatalogMeasurementProfile(
          key,
          required,
          optional,
          row['progression_policy'],
        );
      }
      final families = <String, CatalogEntity>{};
      for (final row in rows('families')) {
        identify(row, 'families', uuid: true);
        families[row['id']] = CatalogEntity(row['id'], row['key'], names(row));
      }
      final anatomy = <String>{};
      for (final row in catalogList(
        root['anatomy_nodes'] ?? [],
        'anatomy_nodes',
      )) {
        final node = catalogObject(row, 'anatomy_node');
        final id = catalogString(node['id'], 'anatomy_node.id');
        if (!anatomy.add(id)) {
          throw const CatalogFormatException('Duplicate anatomy node');
        }
      }
      final muscles = <String, Map<String, dynamic>>{};
      for (final row in rows('muscle_profiles')) {
        if (row.containsKey('id')) identify(row, 'muscle_profiles');
        final id = catalogString(row['variant_id'], 'variant_id');
        if (muscles.containsKey(id)) {
          throw const CatalogFormatException('Duplicate muscle binding');
        }
        if (!['unknown', 'partial'].contains(row['coverage'])) {
          throw const CatalogFormatException('Unsupported muscle coverage');
        }
        muscles[id] = row;
      }
      final variants = <String, CatalogVariant>{};
      final signatures = <String>{};
      for (final row in rows('variants')) {
        identify(row, 'variants', uuid: true);
        final facets = _strings(row['facets'], 'facets');
        final muscle = muscles[row['id']];
        if (!families.containsKey(row['family_id']) ||
            !equipment.contains(row['equipment_kind']) ||
            !measurement.containsKey(row['measurement_profile']) ||
            row['revision'] is! int ||
            row['revision'] < 1 ||
            muscle == null ||
            muscle['variant_revision'] != row['revision'] ||
            facets.entries.any(
              (e) => !(vocabulary[e.key]?.contains(e.value) ?? false),
            )) {
          throw CatalogFormatException(
            'Invalid variant references: ${row['id']}',
          );
        }
        final signature = catalogCanonicalJson([
          row['family_id'],
          row['equipment_kind'],
          facets,
          row['measurement_profile'],
        ]);
        if (!signatures.add(signature)) {
          throw const CatalogFormatException('Duplicate execution signature');
        }
        final relationshipKeys = <String>{};
        final relationships =
            catalogList(muscle['relationships'], 'relationships').map((r) {
              final relation = catalogObject(r, 'relationship');
              final role = catalogString(relation['role'], 'role');
              if (!['primary', 'secondary', 'stabilizer'].contains(role)) {
                throw const CatalogFormatException('Invalid muscle role');
              }
              final node = catalogString(
                relation['anatomy_node_id'],
                'anatomy_node_id',
              );
              if (!anatomy.contains(node) ||
                  !relationshipKeys.add('$node:$role')) {
                throw const CatalogFormatException(
                  'Invalid muscle relationship reference',
                );
              }
              return CatalogMuscleRelationship(node, role);
            }).toList();
        if (muscle['coverage'] == 'unknown' && relationships.isNotEmpty) {
          throw const CatalogFormatException(
            'Unknown muscle profile contains claims',
          );
        }
        variants[row['id']] = CatalogVariant(
          id: row['id'],
          key: row['key'],
          names: names(row),
          familyId: row['family_id'],
          revision: row['revision'],
          equipmentKind: row['equipment_kind'],
          facets: facets,
          measurementProfileKey: row['measurement_profile'],
          muscleCoverage: muscle['coverage'],
          muscleRelationships: relationships,
        );
      }
      if (variants.length != muscles.length ||
          families.isEmpty ||
          variants.isEmpty ||
          families.keys.any(
            (id) => !variants.values.any((v) => v.familyId == id),
          )) {
        throw const CatalogFormatException('Incomplete family/muscle bindings');
      }
      void validateFilter(CatalogFilter filter) {
        if (!families.keys.toSet().containsAll(filter.familyIds) ||
            !equipment.toSet().containsAll(filter.equipmentKinds)) {
          throw const CatalogFormatException('Invalid selector reference');
        }
        for (final entry in [
          ...filter.facets.entries,
          ...filter.excludedFacets.entries,
        ]) {
          if (!(vocabulary[entry.key]?.containsAll(entry.value) ?? false) ||
              entry.value.isEmpty) {
            throw const CatalogFormatException('Invalid selector facet');
          }
        }
      }

      final collections = <String, CatalogCollection>{};
      for (final row in rows('collections')) {
        identify(row, 'collections', uuid: true);
        final selector = CatalogFilter.fromJson(
          catalogObject(row['selector'], 'selector'),
        );
        validateFilter(selector);
        if (!variants.values.any(selector.matches)) {
          throw const CatalogFormatException('Empty collection');
        }
        collections[row['id']] = CatalogCollection(
          row['id'],
          row['key'],
          names(row),
          selector,
        );
      }
      final models = <String, CatalogEntity>{};
      for (final row in rows('equipment_models')) {
        identify(row, 'equipment_models', uuid: true);
        if (row['verification_status'] != 'verified') {
          throw const CatalogFormatException('Unverified equipment model');
        }
        models[row['id']] = CatalogEntity(
          row['id'],
          row['key'],
          row.containsKey('names')
              ? names(row)
              : {'en': catalogString(row['model'], 'model')},
        );
      }
      final terms = <CatalogTerm>[];
      for (final table in ['aliases', 'scoped_terms', 'abbreviations']) {
        for (final row in rows(table)) {
          identify(row, table);
          final target = catalogObject(row['target'], 'target');
          final selector = CatalogFilter.fromJson(
            catalogObject(row['selector'] ?? <String, dynamic>{}, 'selector'),
          );
          validateFilter(selector);
          final kind = catalogString(target['kind'], 'target.kind');
          final id = catalogString(target['id'], 'target.id');
          final exists = switch (kind) {
            'family' => families.containsKey(id),
            'variant' => variants.containsKey(id),
            'collection' => collections.containsKey(id),
            'equipment_model' => models.containsKey(id),
            _ => false,
          };
          if (!exists ||
              (row['qualifier'] == true && !row.containsKey('selector'))) {
            throw const CatalogFormatException('Invalid term target/qualifier');
          }
          terms.add(
            CatalogTerm(
              id: row['id'],
              text: catalogString(row['text'], 'term.text'),
              locale: catalogString(row['locale'], 'term.locale'),
              kind: kind,
              targetId: id,
              source: table,
              selector: selector,
              qualifier: row['qualifier'] == true,
              hasSelector: row.containsKey('selector'),
              displayLocales: List.unmodifiable(
                rowsOrStrings(row['display_locales'] ?? [], 'display_locales'),
              ),
            ),
          );
        }
      }
      final bundle = CatalogBundle._(
        digest: digest,
        catalogRevision: revision,
        searchRevision: search,
        families: Map.unmodifiable(families),
        variants: Map.unmodifiable(variants),
        collections: Map.unmodifiable(collections),
        equipmentModels: Map.unmodifiable(models),
        measurementProfiles: Map.unmodifiable(measurement),
        terms: List.unmodifiable(terms),
        equipmentKinds: Set.unmodifiable(equipment),
        facetVocabulary: Map.unmodifiable(vocabulary),
      );
      for (final term in terms) {
        if (term.kind != 'equipment_model' &&
            !variants.values.any(
              (v) =>
                  bundle.targetMatches(term.kind, term.targetId, v) &&
                  term.selector.matches(v),
            )) {
          throw CatalogFormatException('Empty term scope: ${term.id}');
        }
      }
      return bundle;
    } on CatalogFormatException {
      rethrow;
    } on Object catch (e) {
      throw CatalogFormatException('Malformed catalog: ${e.runtimeType}');
    }
  }
  bool targetMatches(String kind, String id, CatalogVariant v) =>
      switch (kind) {
        'variant' => v.id == id,
        'family' => v.familyId == id,
        'collection' => collections[id]?.selector.matches(v) ?? false,
        _ => false,
      };
}

List<String> rowsOrStrings(dynamic value, String at) =>
    List.unmodifiable(catalogList(value, at).map((e) => catalogString(e, at)));
