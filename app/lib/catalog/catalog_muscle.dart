import 'dart:collection';
import 'dart:convert';

import 'catalog_bundle.dart';
import 'muscle_schema.dart';

dynamic catalogFrozen(dynamic value) => _CatalogSnapshotFreezer().freeze(value);

/// Retained only while building one bundle, so shared immutable input subtrees
/// are copied once without retaining caller-owned data or sharing across loads.
final class _CatalogSnapshotFreezer {
  final _copies = HashMap<Object, dynamic>.identity();

  dynamic freeze(dynamic value) {
    if (value is Map) {
      return _copies[value] ??= Map<String, dynamic>.unmodifiable({
        for (final e in value.entries) e.key as String: freeze(e.value),
      });
    }
    if (value is List) {
      return _copies[value] ??= List<dynamic>.unmodifiable(value.map(freeze));
    }
    return value;
  }
}

bool _muscleRoleValid(Map<String, dynamic> row) => row['kind'] == 'strength'
    ? ['primary', 'secondary', 'stabilizer'].contains(row['role'])
    : [
            'stretch_target',
            'mobility_target',
            'conditioning_participation',
          ].contains(row['kind']) &&
          row['role'] == null;

bool _sameMuscleIds(Iterable<dynamic> a, Iterable<dynamic> b) {
  final first = a.toSet(), second = b.toSet();
  return first.length == second.length && first.containsAll(second);
}

bool _validMuscleDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final year = int.parse(value.substring(0, 4)),
      month = int.parse(value.substring(5, 7)),
      day = int.parse(value.substring(8, 10));
  final parsed = DateTime.utc(year, month, day);
  return year > 0 &&
      parsed.year == year &&
      parsed.month == month &&
      parsed.day == day;
}

bool _validMuscleTimestamp(String value) =>
    RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$').hasMatch(value) &&
    _validMuscleDate(value.substring(0, 10)) &&
    int.parse(value.substring(11, 13)) < 24 &&
    int.parse(value.substring(14, 16)) < 60 &&
    int.parse(value.substring(17, 19)) < 60;

/// Exact UTC timestamps can establish same-day order. A date-only capture
/// establishes order only when its calendar day follows declaration's day.
bool _muscleSearchAfterDeclaration(String declared, String searched) =>
    searched.contains('T')
    ? declared.compareTo(searched) <= 0
    : declared.substring(0, 10).compareTo(searched) < 0;

void _validateMuscleClosure(
  Map<String, dynamic> profile,
  Map<String, dynamic> assessment,
  Map<String, dynamic> scope,
  Map<String, Map<String, dynamic>> cells,
  Map<String, Map<String, dynamic>> relationships,
  Map<String, Map<String, dynamic>> claims,
  Map<String, Map<String, dynamic>> sources,
) {
  final dispositions = <String, Map<String, dynamic>>{};
  final unresolved = cells.keys.toSet();
  for (final value in assessment['dispositions'] as List) {
    final d = catalogObject(value, 'disposition');
    final cell = cells[d['cell_id']];
    if (cell == null ||
        dispositions.containsKey(d['cell_id']) ||
        !(d['claim_ids'] as List).every(claims.containsKey)) {
      throw const CatalogFormatException('Invalid scope disposition');
    }
    final matching = relationships.values
        .where((r) => r['cell_id'] == d['cell_id'])
        .toList();
    if (d['status'] == 'supported') {
      final claimIds = {for (final r in matching) ...r['claim_ids'] as List};
      if (matching.isEmpty ||
          !_sameMuscleIds(
            d['relationship_ids'] as List,
            matching.map((r) => r['id']),
          ) ||
          !_sameMuscleIds(d['claim_ids'] as List, claimIds) ||
          d['next_evidence_needed'] != null) {
        throw const CatalogFormatException(
          'Unsupported scope closure evidence',
        );
      }
      unresolved.remove(d['cell_id']);
    } else if (d['status'] == 'excluded') {
      final evidence = [for (final id in d['claim_ids'] as List) claims[id]!];
      if ((d['relationship_ids'] as List).isNotEmpty ||
          matching.isNotEmpty ||
          evidence.isEmpty ||
          !evidence.every(
            (c) =>
                c['claim_kind'] == 'scope_exclusion' &&
                c['access_result'] == 'accessible' &&
                c['support_status'] == 'supports' &&
                sources[c['source_id']]?['publication_status'] == 'current' &&
                c['variant_id'] == profile['variant_id'] &&
                c['variant_revision'] == profile['variant_revision'] &&
                c['execution_sha256'] == profile['execution_sha256'] &&
                c['exact_setup_match'] == true &&
                [
                  'anatomy_node_id',
                  'kind',
                  'role',
                  'action',
                ].every((k) => c[k] == cell[k]),
          ) ||
          d['next_evidence_needed'] != null) {
        throw const CatalogFormatException(
          'Missing exact affirmative exclusion',
        );
      }
      unresolved.remove(d['cell_id']);
    } else if ((d['relationship_ids'] as List).isNotEmpty ||
        d['next_evidence_needed'] == null) {
      throw const CatalogFormatException(
        'Unresolved scope cell needs evidence gap',
      );
    }
    dispositions[d['cell_id']] = d;
  }
  final explicitGaps = [
    assessment['unresolved'],
    assessment['contradictions'],
    assessment['omitted_claims'],
  ].any((v) => (v as List).isNotEmpty);
  if (profile['coverage'] == 'complete') {
    if (assessment['assessment_status'] != 'assessed' ||
        assessment['researcher_id'] == assessment['reconciler_id'] ||
        (assessment['reconciliation'] as Map)['status'] != 'accepted' ||
        (assessment['reconciliation'] as Map)['reviewed_on'] == null ||
        assessment['closure_rationale'] == null ||
        unresolved.isNotEmpty ||
        explicitGaps ||
        !_muscleSearchAfterDeclaration(
          scope['declared_on'] as String,
          assessment['searched_on'] as String,
        )) {
      throw const CatalogFormatException('Unclosed complete scope');
    }
  } else if (unresolved.isEmpty && !explicitGaps) {
    throw const CatalogFormatException(
      'Incomplete assessment needs explicit gaps',
    );
  }
  if ((relationships.isEmpty) != (profile['coverage'] == 'unknown') ||
      (assessment['assessment_status'] == 'pending' &&
          (relationships.isNotEmpty || profile['coverage'] != 'unknown'))) {
    throw const CatalogFormatException(
      'Coverage does not match admitted relationships',
    );
  }
}

/// Strength roles never apply to stretch, mobility or conditioning participation.
enum CatalogMuscleKind {
  strength,
  stretchTarget,
  mobilityTarget,
  conditioningParticipation,
}

enum CatalogMuscleRole { primary, secondary, stabilizer }

enum CatalogMuscleCoverage { unknown, partial, complete }

enum CatalogMuscleConfidence { unassessed, low, moderate, high }

enum CatalogMuscleEvidenceBasis {
  direct,
  biomechanicalInference,
  legacyUnavailable,
}

final class CatalogAssessedRelationship {
  CatalogAssessedRelationship.fromJson(Map<String, dynamic> json)
    : raw = Map.unmodifiable(json),
      anatomyNodeId = json['anatomy_node_id'] as String,
      kind = switch (json['kind']) {
        'strength' => CatalogMuscleKind.strength,
        'stretch_target' => CatalogMuscleKind.stretchTarget,
        'mobility_target' => CatalogMuscleKind.mobilityTarget,
        'conditioning_participation' =>
          CatalogMuscleKind.conditioningParticipation,
        _ => throw const CatalogFormatException('Unknown relationship kind'),
      },
      role = json['role'] == null
          ? null
          : CatalogMuscleRole.values.byName(json['role'] as String);
  final Map<String, dynamic> raw;
  final String anatomyNodeId;
  final CatalogMuscleKind kind;
  final CatalogMuscleRole? role;
  String? get confidence => raw['confidence'] as String?;
  CatalogMuscleConfidence? get confidenceLevel => confidence == null
      ? null
      : CatalogMuscleConfidence.values.byName(confidence!);
  CatalogMuscleEvidenceBasis get basis => switch (evidenceBasis) {
    'direct' => CatalogMuscleEvidenceBasis.direct,
    'biomechanical_inference' =>
      CatalogMuscleEvidenceBasis.biomechanicalInference,
    _ => CatalogMuscleEvidenceBasis.legacyUnavailable,
  };
  String? get evidenceBasis => raw['evidence_basis'] as String?;
  String? get rationale => raw['rationale'] as String?;
  List<String> get claimIds =>
      List<String>.from(raw['claim_ids'] as List? ?? const []);
}

final class CatalogAnatomyNode {
  CatalogAnatomyNode.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      parentId = json['parent_id'] as String?,
      names = Map.unmodifiable(Map<String, String>.from(json['names'] as Map));
  final String id;
  final String? parentId;
  final Map<String, String> names;
}

final class CatalogSemanticMapping {
  CatalogSemanticMapping.fromJson(Map<String, dynamic> json)
    : anatomyNodeId = json['anatomy_node_id'] as String,
      regionIds = List.unmodifiable(
        (json['render_region_ids'] as List).cast<String>(),
      ),
      status = json['mapping_status'] as String;
  final String anatomyNodeId, status;
  final List<String> regionIds;
}

/// Immutable consumer snapshot. Declared human review remains distinct from
/// independently verified qualification, which is not inferred by this reader.
final class CatalogMuscleProfile {
  factory CatalogMuscleProfile.fromSnapshot(Map<String, dynamic> snapshot) =>
      CatalogMuscleProfile._(catalogFrozen(snapshot) as Map<String, dynamic>);
  CatalogMuscleProfile._(Map<String, dynamic> snapshot)
    : snapshot = Map.unmodifiable(snapshot),
      profile = Map.unmodifiable(catalogObject(snapshot['profile'], 'profile')),
      assessment = Map.unmodifiable(
        catalogObject(snapshot['assessment'], 'assessment'),
      ),
      anatomy = Map.unmodifiable({
        for (final row in catalogList(
          catalogObject(snapshot['anatomy'], 'anatomy')['nodes'],
          'nodes',
        ))
          (row as Map<String, dynamic>)['id'] as String:
              CatalogAnatomyNode.fromJson(row),
      }),
      mappings = List.unmodifiable([
        for (final row in catalogList(
          catalogObject(snapshot['semanticMap'], 'map')['mappings'],
          'mappings',
        ))
          CatalogSemanticMapping.fromJson(catalogObject(row, 'mapping')),
      ]),
      relationships = List.unmodifiable([
        for (final row in catalogList(
          catalogObject(snapshot['profile'], 'profile')['relationships'],
          'relationships',
        ))
          CatalogAssessedRelationship.fromJson(
            catalogObject(row, 'relationship'),
          ),
      ]);
  final Map<String, dynamic> snapshot, profile, assessment;
  final Map<String, CatalogAnatomyNode> anatomy;
  final List<CatalogSemanticMapping> mappings;
  final List<CatalogAssessedRelationship> relationships;
  String? get id => profile['id'] as String?;
  int? get revision => profile['revision'] as int?;
  String get coverage => profile['coverage'] as String;
  CatalogMuscleCoverage get coverageStatus =>
      CatalogMuscleCoverage.values.byName(coverage);
  String get assessmentStatus => assessment['assessment_status'] as String;
  Map<String, dynamic>? get humanReview =>
      profile['human_review'] as Map<String, dynamic>?;
  Map<String, dynamic>? get scope =>
      profile['scope_ref'] as Map<String, dynamic>?;
  Map<String, dynamic>? get scopeDefinition =>
      snapshot['scopeDefinition'] as Map<String, dynamic>?;
  String get anatomyRevision =>
      catalogObject(snapshot['anatomy'], 'anatomy')['revision'] as String;
  String? get semanticMapRevision =>
      catalogObject(snapshot['semanticMap'], 'map')['revision'] as String?;
  List<Map<String, dynamic>> get regions => [
    for (final r
        in catalogObject(snapshot['semanticMap'], 'map')['regions'] as List)
      catalogObject(r, 'region'),
  ];
  List<Map<String, dynamic>> get claims => [
    for (final r in snapshot['claims'] as List) catalogObject(r, 'claim'),
  ];
  List<Map<String, dynamic>> get sources => [
    for (final r in snapshot['sources'] as List) catalogObject(r, 'source'),
  ];
  bool get isLegacy => snapshot['legacy'] == true;
  String get sourceBundleDigest => snapshot['sourceBundleSha256'] as String;
  String get sourceNamespace => snapshot['sourceNamespace'] as String;
  String get sourceRevision => snapshot['sourceRevision'] as String;
  bool get humanQualificationVerified => false;
  String get executionSha256 => snapshot['executionSha256'] as String;
  Map<String, dynamic> get execution =>
      catalogObject(snapshot['execution'], 'execution');
  Map<String, dynamic> toJson() => Map.from(snapshot);
}

Map<String, dynamic> catalogExecutionSnapshot(Map<String, dynamic> row) => {
  for (final key in [
    'family_id',
    'equipment_kind',
    'facets',
    'measurement_profile',
  ])
    key: row[key],
  'variant_id': row['id'],
  'variant_revision': row['revision'],
};

/// The catalog hash excludes labels and the muscle pointer; measurement meaning
/// includes complete definitions, retained by v2 private staging.
String catalogExecutionCatalogHash(Map<String, dynamic> catalog) {
  final executions =
      [
        for (final row in catalog['variants'] as List)
          catalogExecutionSnapshot(catalogObject(row, 'variant')),
      ]..sort(
        (a, b) =>
            (a['variant_id'] as String).compareTo(b['variant_id'] as String),
      );
  final measurements = [
    for (final row in catalog['measurement_profiles'] as List)
      catalogObject(row, 'measurement'),
  ]..sort((a, b) => (a['key'] as String).compareTo(b['key'] as String));
  return catalogHash(
    catalogCanonicalJson({
      'namespace': 'alkion-exercises',
      'executions': executions,
      'measurement_definitions': measurements,
    }),
  );
}

final class CatalogMuscleBundle {
  CatalogMuscleBundle._(this.raw, this.digest, this.profiles);
  final Map<String, dynamic> raw;
  final String digest;
  final Map<String, CatalogMuscleProfile> profiles;

  factory CatalogMuscleBundle.fromBytes(
    List<int> bytes,
    Map<String, dynamic> catalog,
    List<int> trustedScopeRegistryBytes,
    String catalogDigest,
  ) {
    final digest = catalogHash(utf8.decode(bytes));
    final ref = catalogObject(
      catalog['muscle_bundle_ref'],
      'muscle_bundle_ref',
    );
    if (ref.keys.toSet().difference({
          'namespace',
          'revision',
          'sha256',
        }).isNotEmpty ||
        ref['namespace'] != 'alkion.exercise-catalog' ||
        ref['sha256'] != digest) {
      throw const CatalogFormatException('Muscle bundle reference mismatch');
    }
    final root = catalogObject(jsonDecode(utf8.decode(bytes)), 'muscle bundle');
    final registry = catalogObject(
      jsonDecode(utf8.decode(trustedScopeRegistryBytes)),
      'trusted scope registry',
    );
    validateMuscleSchema(registry, definition: 'scope_registry');
    validateMuscleSchema(root);
    if (root['revision'] != ref['revision']) {
      throw const CatalogFormatException('Muscle bundle revision mismatch');
    }
    final binding = catalogObject(root['catalog_binding'], 'catalog_binding');
    final executionHash = catalogExecutionCatalogHash(catalog);
    if (binding['catalog_revision'] != catalog['catalog_revision'] ||
        binding['execution_catalog_sha256'] != executionHash) {
      throw const CatalogFormatException('Muscle execution catalog mismatch');
    }
    Map<String, Map<String, dynamic>> index(
      dynamic rows,
      String at, [
      String key = 'id',
    ]) {
      final result = <String, Map<String, dynamic>>{};
      for (final value in catalogList(rows, at)) {
        final row = catalogObject(value, at),
            id = catalogString((value as Map)[key], at);
        if (result.containsKey(id)) {
          throw CatalogFormatException('Duplicate $at identity');
        }
        result[id] = row;
      }
      return result;
    }

    final registryRef = catalogObject(
      root['scope_registry_ref'],
      'scope registry ref',
    );
    if (registryRef['revision'] != registry['revision'] ||
        registryRef['sha256'] != catalogHash(catalogCanonicalJson(registry))) {
      throw const CatalogFormatException('Trusted scope registry mismatch');
    }
    final scopes = <String, Map<String, dynamic>>{};
    for (final value in registry['scopes'] as List) {
      final row = catalogObject(value, 'scope');
      final key = '${row['id']}:${row['revision']}';
      if (scopes.containsKey(key)) {
        throw const CatalogFormatException('Duplicate scope revision');
      }
      scopes[key] = row;
    }
    final anatomy = catalogObject(root['anatomy'], 'anatomy');
    final nodes = index(anatomy['nodes'], 'nodes');
    for (final node in nodes.values) {
      var parent = node['parent_id'];
      final seen = <String>{node['id']};
      while (parent != null) {
        if (!nodes.containsKey(parent) || !seen.add(parent as String)) {
          throw const CatalogFormatException('Invalid anatomy parent');
        }
        parent = nodes[parent]!['parent_id'];
      }
    }
    final map = catalogObject(root['semantic_map'], 'semantic map');
    final regions = index(map['regions'], 'regions');
    final mapped = <String>{};
    for (final value in map['mappings'] as List) {
      final row = catalogObject(value, 'mapping');
      if (!nodes.containsKey(row['anatomy_node_id']) ||
          !mapped.add(row['anatomy_node_id']) ||
          !(row['render_region_ids'] as List).every(regions.containsKey)) {
        throw const CatalogFormatException('Invalid semantic mapping');
      }
    }
    final actors = index(root['actors'], 'actors'),
        sources = index(root['sources'], 'sources'),
        claims = index(root['claims'], 'claims');
    final assessments = index(root['assessments'], 'assessments');
    final history = <String, Map<String, dynamic>>{};
    for (final value in root['profile_history'] as List) {
      final row = catalogObject(value, 'history');
      validateMuscleSchema(
        row['payload'],
        definition: row['schema_version'] == 1
            ? 'v1_muscle_profile'
            : 'profile',
      );
      final payload = catalogObject(row['payload'], 'history payload');
      final key = '${row['profile_id']}:${row['profile_revision']}';
      if (history.containsKey(key) ||
          row['profile_sha256'] != catalogHash(catalogCanonicalJson(payload)) ||
          payload['id'] != row['profile_id'] ||
          payload['revision'] != row['profile_revision']) {
        throw const CatalogFormatException('Invalid profile history digest');
      }
      history[key] = row;
    }
    final variants = index(catalog['variants'], 'variants');
    for (final claim in claims.values) {
      final source = sources[claim['source_id']];
      if (source == null ||
          claim['url'] != source['url'] ||
          (claim['anatomy_node_id'] != null &&
              !nodes.containsKey(claim['anatomy_node_id']))) {
        throw const CatalogFormatException('Invalid evidence reference');
      }
      if (claim['anatomy_node_id'] != null &&
          claim['granularity'] != nodes[claim['anatomy_node_id']]!['kind']) {
        throw const CatalogFormatException('Unsupported claim granularity');
      }
      if (claim['claim_kind'] == 'anatomy_action') {
        if (claim['variant_id'] != null ||
            claim['variant_revision'] != null ||
            claim['execution_sha256'] != null ||
            claim['anatomy_node_id'] == null ||
            claim['kind'] != null ||
            claim['role'] != null) {
          throw const CatalogFormatException(
            'General anatomy claim asserts execution role',
          );
        }
      } else {
        final v = variants[claim['variant_id']];
        if (v == null ||
            claim['variant_revision'] != v['revision'] ||
            claim['execution_sha256'] !=
                catalogHash(
                  catalogCanonicalJson(catalogExecutionSnapshot(v)),
                )) {
          throw const CatalogFormatException('Evidence execution mismatch');
        }
        if (claim['claim_kind'] == 'execution_mechanics') {
          if (claim['anatomy_node_id'] != null ||
              claim['kind'] != null ||
              claim['role'] != null ||
              claim['granularity'] != 'movement_only') {
            throw const CatalogFormatException(
              'Mechanics claim asserts anatomical role',
            );
          }
        } else if (claim['anatomy_node_id'] == null ||
            !_muscleRoleValid(claim)) {
          throw const CatalogFormatException(
            'Invalid relationship claim kind or role',
          );
        }
      }
    }
    final profiles = <String, CatalogMuscleProfile>{};
    final freezer = _CatalogSnapshotFreezer();
    final profileIds = <String>{};
    final scopeHashes = HashMap<Object, String>.identity();
    final scopeCells =
        HashMap<Object, Map<String, Map<String, dynamic>>>.identity();
    for (final value in root['profiles'] as List) {
      final p = catalogObject(value, 'profile'),
          variant = variants[p['variant_id']];
      final execution = variant == null
          ? null
          : catalogExecutionSnapshot(variant);
      final hash = execution == null
          ? null
          : catalogHash(catalogCanonicalJson(execution));
      final a = assessments[p['assessment_id']];
      if (variant == null ||
          profiles.containsKey(p['variant_id']) ||
          !profileIds.add(p['id']) ||
          p['variant_revision'] != variant['revision'] ||
          p['execution_sha256'] != hash ||
          a == null ||
          a['variant_id'] != p['variant_id'] ||
          a['variant_revision'] != p['variant_revision'] ||
          a['execution_sha256'] != hash ||
          a['profile_id'] != p['id'] ||
          a['profile_revision'] != p['revision'] ||
          a['profile_sha256'] != catalogHash(catalogCanonicalJson(p)) ||
          a['catalog_revision'] != catalog['catalog_revision'] ||
          a['execution_catalog_sha256'] != executionHash ||
          a['anatomy_revision'] != anatomy['revision'] ||
          catalogCanonicalJson(a['scope_ref']) !=
              catalogCanonicalJson(p['scope_ref']) ||
          !actors.containsKey(a['researcher_id']) ||
          (a['reconciler_id'] == null
              ? a['assessment_status'] != 'pending'
              : !actors.containsKey(a['reconciler_id']))) {
        throw const CatalogFormatException('Invalid assessment binding');
      }
      final scopeRef = catalogObject(p['scope_ref'], 'scope ref'),
          scope = scopes['${scopeRef['id']}:${scopeRef['revision']}'];
      if (scope == null ||
          scope['revision'] != scopeRef['revision'] ||
          scopeHashes.putIfAbsent(
                scope,
                () => catalogHash(catalogCanonicalJson(scope)),
              ) !=
              scopeRef['sha256'] ||
          scope['anatomy_revision'] != anatomy['revision'] ||
          !(scope['execution_bindings'] as List).any(
            (b) =>
                b['variant_id'] == p['variant_id'] &&
                b['variant_revision'] == p['variant_revision'] &&
                b['execution_sha256'] == hash,
          )) {
        throw const CatalogFormatException('Untrusted profile scope');
      }
      final facets = catalogObject(variant['facets'], 'execution facets');
      final laterality = facets['side'] ?? facets['laterality'];
      final expectedSide = ['bilateral', 'left', 'right'].contains(laterality)
          ? laterality
          : 'unspecified';
      if (p['side_scope'] != expectedSide) {
        throw const CatalogFormatException(
          'Muscle side scope exceeds execution',
        );
      }
      final review = catalogObject(p['human_review'], 'human review');
      if (review['status'] == 'pending' &&
          [
            review['reviewer_id'],
            review['reviewed_on'],
            review['attestation_id'],
          ].any((v) => v != null)) {
        throw const CatalogFormatException('Invalid pending review');
      }
      if (review['status'] == 'reviewed' &&
          (actors[review['reviewer_id']]?['kind'] != 'human' ||
              review['reviewed_on'] == null ||
              review['attestation_id'] == null)) {
        throw const CatalogFormatException('Invalid human review');
      }
      final cells = scopeCells.putIfAbsent(
        scope,
        () => index(scope['cells'], 'scope cells'),
      );
      final relationshipIds = <String>{},
          relationshipCells = <String>{},
          usedClaims = <String>{};
      final relationshipRows = <String, Map<String, dynamic>>{};
      for (final value in p['relationships'] as List) {
        final r = catalogObject(value, 'relationship');
        final cell = cells[r['cell_id']];
        relationshipRows[r['id']] = r;
        if (cell == null ||
            cell['anatomy_node_id'] != r['anatomy_node_id'] ||
            cell['kind'] != r['kind'] ||
            cell['role'] != r['role'] ||
            !relationshipIds.add(r['id']) ||
            !relationshipCells.add(r['cell_id']) ||
            (r['claim_ids'] as List).toSet().length !=
                (r['claim_ids'] as List).length ||
            !nodes.containsKey(r['anatomy_node_id']) ||
            ((r['kind'] == 'strength') != (r['role'] != null))) {
          throw const CatalogFormatException('Invalid relationship');
        }
        for (final id in r['claim_ids'] as List) {
          final c = claims[id];
          if (c == null ||
              c['support_status'] != 'supports' ||
              c['access_result'] != 'accessible' ||
              sources[c['source_id']]?['publication_status'] != 'current') {
            throw const CatalogFormatException('Invalid supporting claim');
          }
          if (c['claim_kind'] != 'anatomy_action' &&
              (c['variant_id'] != p['variant_id'] ||
                  c['variant_revision'] != p['variant_revision'] ||
                  c['execution_sha256'] != hash)) {
            throw const CatalogFormatException('Evidence execution mismatch');
          }
          usedClaims.add(id);
        }
        final evidence = [for (final id in r['claim_ids'] as List) claims[id]!];
        if (r['evidence_basis'] == 'direct' &&
            !evidence.any(
              (c) =>
                  c['claim_kind'] == 'execution_relationship' &&
                  c['anatomy_node_id'] == r['anatomy_node_id'] &&
                  c['kind'] == r['kind'] &&
                  c['role'] == r['role'] &&
                  c['action'] == cell['action'] &&
                  c['exact_setup_match'] == true,
            )) {
          throw const CatalogFormatException(
            'Missing direct relationship claim',
          );
        }
        if (r['evidence_basis'] == 'direct' &&
            (r['reasoning_chain'] as List).isNotEmpty) {
          throw const CatalogFormatException(
            'Direct evidence contains inference chain',
          );
        }
        if (r['evidence_basis'] == 'biomechanical_inference' &&
            ((r['reasoning_chain'] as List).length < 2 ||
                !evidence.any(
                  (c) =>
                      c['claim_kind'] == 'execution_mechanics' &&
                      c['action'] == cell['action'],
                ) ||
                !evidence.any(
                  (c) =>
                      c['claim_kind'] == 'anatomy_action' &&
                      c['anatomy_node_id'] == r['anatomy_node_id'] &&
                      c['action'] == cell['action'],
                ))) {
          throw const CatalogFormatException('Missing inference evidence');
        }
        final criteria = catalogObject(
          r['confidence_criteria'],
          'confidence criteria',
        );
        final sourceIds = evidence.map((c) => c['source_id']).toSet();
        if (!_sameMuscleIds(
          criteria['independent_source_ids'] as List,
          sourceIds,
        )) {
          throw const CatalogFormatException('Confidence source mismatch');
        }
        if (r['confidence'] == 'high' &&
            (sourceIds
                        .map((id) => sources[id]!['publisher_id'])
                        .toSet()
                        .length <
                    2 ||
                criteria['exact_execution_supported'] != true ||
                criteria['material_conflict'] != false)) {
          throw const CatalogFormatException('Unsupported high confidence');
        }
        if (r['confidence'] == 'low' &&
            (criteria['limitations'] as List).isEmpty) {
          throw const CatalogFormatException(
            'Low confidence needs limitations',
          );
        }
      }
      _validateMuscleClosure(
        p,
        a,
        scope,
        cells,
        relationshipRows,
        claims,
        sources,
      );
      final baseline = (catalog['legacy_muscle_profiles'] as List)
          .cast<Map<String, dynamic>>()
          .where((b) => b['variant_id'] == p['variant_id'])
          .toList();
      Map<String, dynamic>? terminalBaseline;
      var predecessor = p['previous_profile'];
      var revision = p['revision'] as int;
      final chain = <String>{};
      while (predecessor != null) {
        final pr = catalogObject(predecessor, 'predecessor');
        final key = '${pr['id']}:${pr['revision']}';
        final old = history[key];
        if (!chain.add(key) ||
            pr['id'] != p['id'] ||
            pr['revision'] != revision - 1 ||
            old == null ||
            old['profile_sha256'] != pr['sha256']) {
          throw const CatalogFormatException('Missing profile predecessor');
        }
        revision = pr['revision'];
        if (old['schema_version'] == 1) {
          terminalBaseline = catalogObject(old['payload'], 'v1 baseline');
          if (old['source_artifact_sha256'] !=
              binding['baseline_catalog_sha256']) {
            throw const CatalogFormatException(
              'Baseline source artifact mismatch',
            );
          }
        }
        predecessor = old['schema_version'] == 1
            ? null
            : catalogObject(old['payload'], 'history')['previous_profile'];
      }
      // Executions introduced in v2 have no v1 row. Their validated lineage
      // terminates at their first v2 revision rather than a fabricated baseline.
      final bornInV2 =
          baseline.isEmpty && terminalBaseline == null && revision == 1;
      if (!bornInV2 &&
          (baseline.length != 1 ||
              terminalBaseline == null ||
              catalogCanonicalJson(terminalBaseline) !=
                  catalogCanonicalJson(baseline.single) ||
              terminalBaseline['id'] != p['id'] ||
              terminalBaseline['revision'] != revision)) {
        throw const CatalogFormatException('Incomplete or changed v1 baseline');
      }
      final selectedClaims = [for (final id in usedClaims) claims[id]!];
      final sourceIds = {for (final c in selectedClaims) c['source_id']};
      profiles[p['variant_id']] = CatalogMuscleProfile._(
        freezer.freeze({
              'format': 'alkion-muscle-pin',
              'version': 2,
              'legacy': false,
              'sourceNamespace': root['namespace'],
              'sourceRevision': root['revision'],
              'sourceBundleSha256': digest,
              'sourceCatalogSha256': catalogDigest,
              'measurementDefinition': (catalog['measurement_profiles'] as List)
                  .firstWhere(
                    (m) => m['key'] == execution!['measurement_profile'],
                  ),
              'catalogNamespace': 'alkion-exercises',
              'catalogRevision': catalog['catalog_revision'],
              'humanQualificationVerified': false,
              'scopeRegistryRef': registryRef,
              'scopeDefinition': scope,
              'execution': execution,
              'executionSha256': hash,
              'profile': p,
              'assessment': {
                for (final key in [
                  'id',
                  'assessment_status',
                  'reconciliation',
                  'scope_ref',
                  'unresolved',
                  'contradictions',
                  'omitted_claims',
                  'closure_rationale',
                ])
                  key: a[key],
              },
              'anatomy': anatomy,
              'semanticMap': map,
              'claims': selectedClaims,
              'sources': [for (final id in sourceIds) sources[id]!],
            })
            as Map<String, dynamic>,
      );
    }
    if (profiles.length != variants.length ||
        assessments.length != profiles.length) {
      throw const CatalogFormatException('Incomplete muscle assessments');
    }
    return CatalogMuscleBundle._(
      Map.unmodifiable(root),
      digest,
      Map.unmodifiable(profiles),
    );
  }
}

/// Small offline validator for the keywords used by the pinned portable schema.
/// It does not fetch remote schemas or infer trust from evidence payloads.
void validateMuscleSchema(dynamic value, {String definition = 'bundle'}) {
  final schema = jsonDecode(muscleSchemaJson) as Map<String, dynamic>;
  bool check(dynamic v, Map<String, dynamic> s) {
    if (s['\$ref'] != null) {
      return check(
        v,
        catalogObject(
          (schema['\$defs'] as Map)[(s['\$ref'] as String).split('/').last],
          'schema',
        ),
      );
    }
    bool equal(dynamic a, dynamic b) =>
        catalogCanonicalJson(a) == catalogCanonicalJson(b);
    if (s.containsKey('const') && !equal(v, s['const'])) return false;
    if (s['enum'] != null && !(s['enum'] as List).any((e) => equal(v, e))) {
      return false;
    }
    if (s['anyOf'] != null &&
        !(s['anyOf'] as List).any(
          (e) => check(v, catalogObject(e, 'schema')),
        )) {
      return false;
    }
    if (s['allOf'] != null &&
        !(s['allOf'] as List).every(
          (e) => check(v, catalogObject(e, 'schema')),
        )) {
      return false;
    }
    if (s['if'] != null) {
      final branch = check(v, catalogObject(s['if'], 'schema'))
          ? s['then']
          : s['else'];
      if (branch != null && !check(v, catalogObject(branch, 'schema'))) {
        return false;
      }
    }
    bool type(String t) => switch (t) {
      'object' => v is Map<String, dynamic>,
      'array' => v is List,
      'string' => v is String,
      'integer' => v is int,
      'number' => v is num,
      'boolean' => v is bool,
      'null' => v == null,
      _ => false,
    };
    if (s['type'] != null &&
        !(s['type'] is List
            ? (s['type'] as List).any((t) => type(t as String))
            : type(s['type'] as String))) {
      return false;
    }
    if (v is Map<String, dynamic>) {
      final props = catalogObject(
        s['properties'] ?? <String, dynamic>{},
        'schema',
      );
      if ((s['required'] as List? ?? const []).any((k) => !v.containsKey(k))) {
        return false;
      }
      for (final entry in v.entries) {
        if (props.containsKey(entry.key)) {
          if (!check(entry.value, catalogObject(props[entry.key], 'schema'))) {
            return false;
          }
        } else if (s['additionalProperties'] == false) {
          return false;
        } else if (s['additionalProperties'] is Map &&
            !check(
              entry.value,
              catalogObject(s['additionalProperties'], 'schema'),
            )) {
          return false;
        }
      }
    }
    if (v is List) {
      if (v.length < (s['minItems'] as int? ?? 0) ||
          v.length > (s['maxItems'] as int? ?? 2147483647)) {
        return false;
      }
      if (s['uniqueItems'] == true &&
          v.map(catalogCanonicalJson).toSet().length != v.length) {
        return false;
      }
      if (s['items'] != null &&
          !v.every((e) => check(e, catalogObject(s['items'], 'schema')))) {
        return false;
      }
    }
    if (v is String) {
      if (v.runes.length < (s['minLength'] as int? ?? 0) ||
          v.runes.length > (s['maxLength'] as int? ?? 2147483647)) {
        return false;
      }
      if (s['pattern'] != null && !RegExp(s['pattern'] as String).hasMatch(v)) {
        return false;
      }
      if (s['format'] == 'date' && !_validMuscleDate(v)) {
        return false;
      }
      if (s['format'] == 'date-time' && !_validMuscleTimestamp(v)) {
        return false;
      }
      if (s['format'] == 'uri' && !(Uri.tryParse(v)?.hasScheme ?? false)) {
        return false;
      }
    }
    if (v is num && s['minimum'] != null && v < (s['minimum'] as num)) {
      return false;
    }
    return true;
  }

  if (!check(
    value,
    catalogObject((schema['\$defs'] as Map)[definition], 'schema'),
  )) {
    throw const CatalogFormatException('Invalid muscle schema');
  }
}
