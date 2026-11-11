import 'dart:convert';
import 'package:alkion/catalog/catalog.dart';

/// Independently authored synthetic contract, never a corpus excerpt.
final class SyntheticMuscleCatalog {
  SyntheticMuscleCatalog({
    this.previous,
    String role = 'primary',
    int baselineRevision = 1,
  }) {
    baselineRevision = previous == null
        ? baselineRevision
        : ((previous!.catalog['legacy_muscle_profiles'] as List)
                  .single['revision']
              as int);
    final variant = {
      'id': variantId,
      'key': 'synthetic_curl',
      'family_id': familyId,
      'revision': 1,
      'names': {'en': 'Synthetic curl'},
      'equipment_kind': 'dumbbell',
      'facets': {'grip': 'neutral'},
      'measurement_profile': 'load_reps',
    };
    final legacy = {
      'id': 'synthetic_profile',
      'variant_id': variantId,
      'variant_revision': 1,
      'revision': baselineRevision,
      'coverage': 'unknown',
      'side_scope': 'unspecified',
      'relationships': <dynamic>[],
      'coverage_note': 'Synthetic legacy evidence is unavailable.',
      'review': {
        'status': 'pending',
        'reviewer_id': null,
        'reviewed_on': null,
        'rationale': 'No qualified human review.',
      },
      'coverage_scope': {
        'anatomy_node_ids': ['synthetic_elbow'],
        'roles': ['primary'],
        'notes': 'Synthetic single cell.',
      },
    };
    catalog = {
      'format': 'alkion-exercise-catalog',
      'schema_version': 2,
      'catalog_revision': 'synthetic.1',
      'search_revision': 'synthetic-search.1',
      'equipment_kinds': ['dumbbell'],
      'facet_vocabulary': {
        'grip': ['neutral', 'supinated'],
      },
      'equipment_models': <dynamic>[],
      'families': [
        {
          'id': familyId,
          'key': 'synthetic_curl_family',
          'names': {'en': 'Synthetic curl'},
        },
      ],
      'variants': [variant],
      'measurement_profiles': [
        {
          'key': 'load_reps',
          'required_metrics': ['reported_load', 'repetitions'],
          'optional_metrics': <String>[],
          'progression_policy': 'load_reps_only',
        },
      ],
      'anatomy_nodes': [
        {
          'id': 'synthetic_elbow',
          'names': {
            'en': 'Synthetic elbow muscle',
            'it': 'Muscolo sintetico del gomito',
          },
        },
      ],
      'legacy_muscle_profiles': [legacy],
      'collections': <dynamic>[],
      'aliases': <dynamic>[],
      'scoped_terms': <dynamic>[],
      'abbreviations': <dynamic>[],
    };
    final execution = catalogExecutionSnapshot(variant);
    final executionHash = catalogHash(catalogCanonicalJson(execution));
    final scope = {
      'id': 'synthetic_scope',
      'revision': 1,
      'anatomy_revision': 'synthetic-anatomy.1',
      'declared_on': '2026-11-03T00:00:00Z',
      'declared_by': 'synthetic_editor',
      'rationale': 'Predeclared synthetic scope.',
      'applicable_actions': ['synthetic flexion'],
      'cells': [
        {
          'id': 'synthetic_cell',
          'anatomy_node_id': 'synthetic_elbow',
          'kind': 'strength',
          'role': role,
          'action': 'synthetic flexion',
        },
      ],
      'exclusions': <dynamic>[],
      'execution_bindings': [
        {
          'variant_id': variantId,
          'variant_revision': 1,
          'execution_sha256': executionHash,
        },
      ],
    };
    scopes = {
      'format': 'alkion-muscle-scope-registry',
      'schema_version': 2,
      'revision': 'synthetic-scopes.1',
      'scopes': [scope],
    };
    final scopeRef = {
      'id': 'synthetic_scope',
      'revision': 1,
      'sha256': catalogHash(catalogCanonicalJson(scope)),
    };
    final prev = previous == null
        ? legacy
        : (previous!.bundle['profiles'] as List).single as Map<String, dynamic>;
    final profile = {
      'id': 'synthetic_profile',
      'revision': (prev['revision'] as int) + 1,
      'variant_id': variantId,
      'variant_revision': 1,
      'execution_sha256': executionHash,
      'scope_ref': scopeRef,
      'assessment_id': 'synthetic_assessment',
      'coverage': 'complete',
      'side_scope': 'unspecified',
      'relationships': [
        {
          'id': 'synthetic_relationship',
          'cell_id': 'synthetic_cell',
          'anatomy_node_id': 'synthetic_elbow',
          'kind': 'strength',
          'role': role,
          'phase': 'synthetic resisted phase',
          'confidence': 'moderate',
          'confidence_criteria': {
            'rationale': 'One synthetic source.',
            'limitations': ['Synthetic fixture only.'],
            'independent_source_ids': ['synthetic_source'],
            'exact_execution_supported': true,
            'material_conflict': false,
          },
          'evidence_basis': 'direct',
          'claim_ids': ['synthetic_claim'],
          'rationale': 'Synthetic relation.',
          'setup_comparison': 'Exact synthetic execution.',
          'reasoning_chain': <dynamic>[],
        },
      ],
      'coverage_note': 'Complete only within the synthetic single-cell scope.',
      'human_review': {
        'status': 'pending',
        'reviewer_id': null,
        'reviewed_on': null,
        'attestation_id': null,
        'rationale': 'No qualified human review.',
      },
      'previous_profile': {
        'id': 'synthetic_profile',
        'revision': prev['revision'],
        'sha256': catalogHash(catalogCanonicalJson(prev)),
      },
      'change_rationale': 'Synthetic revision.',
    };
    final assessment = {
      'id': 'synthetic_assessment',
      'variant_id': variantId,
      'variant_revision': 1,
      'execution_sha256': executionHash,
      'profile_id': 'synthetic_profile',
      'profile_revision': profile['revision'],
      'profile_sha256': catalogHash(catalogCanonicalJson(profile)),
      'catalog_revision': catalog['catalog_revision'],
      'execution_catalog_sha256': catalogExecutionCatalogHash(catalog),
      'anatomy_revision': 'synthetic-anatomy.1',
      'scope_ref': scopeRef,
      'assessment_status': 'assessed',
      'researcher_id': 'synthetic_researcher',
      'reconciler_id': 'synthetic_reconciler',
      'reconciliation': {
        'status': 'accepted',
        'reviewed_on': '2026-11-03',
        'rationale': 'Independent synthetic reconciliation.',
      },
      'searched_on': '2026-11-03T01:00:00Z',
      'setup': {
        for (final k in [
          'equipment',
          'grip',
          'support',
          'angle',
          'resistance_direction',
          'laterality',
          'execution_phase',
        ])
          k: null,
      },
      'search_log': [
        {
          'query': 'synthetic exact execution',
          'url': 'https://catalog.example/execution',
          'access_result': 'accessible',
          'outcome': 'Stipulated synthetic evidence; no network research.',
        },
      ],
      'dispositions': [
        {
          'cell_id': 'synthetic_cell',
          'status': 'supported',
          'relationship_ids': ['synthetic_relationship'],
          'claim_ids': ['synthetic_claim'],
          'rationale': 'Synthetic closure.',
          'next_evidence_needed': null,
        },
      ],
      'closure_rationale': 'Single predeclared synthetic cell.',
      'unresolved': <dynamic>[],
      'contradictions': <dynamic>[],
      'omitted_claims': <dynamic>[],
    };
    bundle = {
      'format': 'alkion-muscle-assessment-bundle',
      'schema_version': 2,
      'namespace': 'alkion.exercise-catalog',
      'revision': 'synthetic-muscles.${profile['revision']}',
      'catalog_binding': {
        'catalog_namespace': 'alkion-exercises',
        'catalog_revision': catalog['catalog_revision'],
        'baseline_catalog_sha256': '0' * 64,
        'execution_catalog_sha256': catalogExecutionCatalogHash(catalog),
      },
      'scope_registry_ref': {
        'revision': scopes['revision'],
        'sha256': catalogHash(catalogCanonicalJson(scopes)),
      },
      'anatomy': {
        'revision': 'synthetic-anatomy.1',
        'nodes': [
          {
            'id': 'synthetic_elbow',
            'parent_id': null,
            'kind': 'muscle',
            'names': {
              'en': 'Synthetic elbow muscle',
              'it': 'Muscolo sintetico del gomito',
            },
            'review_status': 'candidate',
            'evidence_ids': <dynamic>[],
          },
        ],
      },
      'semantic_map': {
        'revision': 'synthetic-map.1',
        'regions': [
          {
            'id': 'synthetic_arm_surface',
            'names': {
              'en': 'Synthetic arm surface',
              'it': 'Superficie sintetica del braccio',
            },
            'view': 'front',
            'side_scope': 'combined',
            'geometry_ref': null,
            'review_status': 'symbolic_only',
          },
        ],
        'mappings': [
          {
            'anatomy_node_id': 'synthetic_elbow',
            'render_region_ids': ['synthetic_arm_surface'],
            'mapping_status': 'editorial_candidate',
            'evidence_ids': <dynamic>[],
          },
        ],
      },
      'actors': [
        {
          'id': 'synthetic_researcher',
          'kind': 'agent',
          'name': 'Synthetic researcher',
        },
        {
          'id': 'synthetic_reconciler',
          'kind': 'agent',
          'name': 'Synthetic reconciler',
        },
      ],
      'sources': [
        {
          'id': 'synthetic_source',
          'url': 'https://catalog.example/execution',
          'title': 'Synthetic exact execution',
          'publisher_id': 'synthetic_publisher',
          'publication_status': 'current',
          'source_kind': 'official_reference',
        },
      ],
      'claims': [
        {
          'id': 'synthetic_claim',
          'source_id': 'synthetic_source',
          'url': 'https://catalog.example/execution',
          'locator': 'Synthetic section',
          'accessed_on': '2026-11-03',
          'access_result': 'accessible',
          'support_status': 'supports',
          'claim_kind': 'execution_relationship',
          'variant_id': variantId,
          'variant_revision': 1,
          'execution_sha256': executionHash,
          'anatomy_node_id': 'synthetic_elbow',
          'kind': 'strength',
          'role': role,
          'action': 'synthetic flexion',
          'establishes': 'Synthetic role',
          'setup_comparison': 'Exact synthetic setup',
          'exact_setup_match': true,
          'granularity': 'muscle',
        },
      ],
      'profiles': [profile],
      'assessments': [assessment],
      'profile_history': [
        if (previous != null) ...previous!.bundle['profile_history'] as List,
        {
          'schema_version': previous == null ? 1 : 2,
          'profile_id': 'synthetic_profile',
          'profile_revision': prev['revision'],
          'profile_sha256': catalogHash(catalogCanonicalJson(prev)),
          'payload': prev,
          'source_artifact_sha256': previous == null
              ? '0' * 64
              : catalogHash(utf8.decode(previous!.bundleBytes)),
          'reason': 'Synthetic predecessor retained.',
        },
      ],
      'legacy_evidence': <dynamic>[],
      'legacy_source_refs': <dynamic>[],
    };
    catalog = jsonDecode(jsonEncode(catalog)) as Map<String, dynamic>;
    bundle = jsonDecode(jsonEncode(bundle)) as Map<String, dynamic>;
    scopes = jsonDecode(jsonEncode(scopes)) as Map<String, dynamic>;
    refreshPointer();
  }
  static const variantId = '10000000-0000-4000-8000-000000000010';
  static const addedVariantId = '10000000-0000-4000-8000-000000000011';
  static const familyId = '10000000-0000-4000-8000-000000000001';
  final SyntheticMuscleCatalog? previous;
  late Map<String, dynamic> catalog, bundle, scopes;
  List<int> get bundleBytes => utf8.encode(jsonEncode(bundle));
  List<int> get scopeBytes => utf8.encode(jsonEncode(scopes));
  void refreshPointer() => catalog['muscle_bundle_ref'] = {
    'namespace': bundle['namespace'],
    'revision': bundle['revision'],
    'sha256': catalogHash(utf8.decode(bundleBytes)),
  };
  void addUnknownExecution() {
    Map<String, dynamic> clone(Object value) =>
        jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
    final variant = clone((catalog['variants'] as List).single)
      ..addAll({
        'id': addedVariantId,
        'key': 'synthetic_added_curl',
        'names': {'en': 'Synthetic added curl'},
        'facets': {'grip': 'supinated'},
      });
    (catalog['variants'] as List).add(variant);
    catalog['catalog_revision'] = 'synthetic.2';
    final executionHash = catalogHash(
      catalogCanonicalJson(catalogExecutionSnapshot(variant)),
    );
    final scope = clone((scopes['scopes'] as List).single)
      ..addAll({
        'id': 'synthetic_added_scope',
        'execution_bindings': [
          {
            'variant_id': addedVariantId,
            'variant_revision': 1,
            'execution_sha256': executionHash,
          },
        ],
      });
    (scopes['scopes'] as List).add(scope);
    final scopeRef = {
      'id': scope['id'],
      'revision': 1,
      'sha256': catalogHash(catalogCanonicalJson(scope)),
    };
    final profile = clone((bundle['profiles'] as List).single)
      ..addAll({
        'id': 'synthetic_added_profile',
        'revision': 1,
        'variant_id': addedVariantId,
        'execution_sha256': executionHash,
        'scope_ref': scopeRef,
        'assessment_id': 'synthetic_added_assessment',
        'coverage': 'unknown',
        'relationships': <dynamic>[],
        'previous_profile': null,
        'coverage_note': 'New synthetic execution awaits evidence.',
      });
    final assessment = clone((bundle['assessments'] as List).single)
      ..addAll({
        'id': profile['assessment_id'],
        'variant_id': addedVariantId,
        'execution_sha256': executionHash,
        'scope_ref': scopeRef,
        'profile_id': profile['id'],
        'profile_revision': 1,
        'profile_sha256': catalogHash(catalogCanonicalJson(profile)),
        'assessment_status': 'pending',
        'reconciler_id': null,
        'reconciliation': {
          'status': 'pending',
          'reviewed_on': null,
          'rationale': 'New synthetic execution awaits reconciliation.',
        },
        'dispositions': <dynamic>[],
        'closure_rationale': null,
        'unresolved': [
          {
            'reason': 'New synthetic execution.',
            'next_evidence_needed': 'Execution-specific evidence.',
          },
        ],
      });
    (bundle['profiles'] as List).add(profile);
    (bundle['assessments'] as List).add(assessment);
    final executionCatalogHash = catalogExecutionCatalogHash(catalog);
    for (final a in bundle['assessments'] as List) {
      a['catalog_revision'] = catalog['catalog_revision'];
      a['execution_catalog_sha256'] = executionCatalogHash;
    }
    bundle['catalog_binding']['catalog_revision'] = catalog['catalog_revision'];
    bundle['catalog_binding']['execution_catalog_sha256'] =
        executionCatalogHash;
    bundle['scope_registry_ref']['sha256'] = catalogHash(
      catalogCanonicalJson(scopes),
    );
    refreshPointer();
  }

  CatalogBundle load() => CatalogBundle.fromBytes(
    utf8.encode(jsonEncode(catalog)),
    muscleBundleBytes: bundleBytes,
    trustedScopeRegistryBytes: scopeBytes,
  );
  CatalogBundle loadV1() {
    final v1 =
        {
            ...catalog,
            'schema_version': 1,
            'muscle_profiles': catalog['legacy_muscle_profiles'],
          }
          ..remove('legacy_muscle_profiles')
          ..remove('muscle_bundle_ref');
    return CatalogBundle.fromJsonString(jsonEncode(v1));
  }
}
