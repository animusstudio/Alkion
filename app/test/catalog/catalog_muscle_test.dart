import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog/catalog_development.dart';
import 'muscle_fixture.dart';

void _refreshMuscleAdmission(SyntheticMuscleCatalog f) {
  final profile = (f.bundle['profiles'] as List).single;
  final assessment = (f.bundle['assessments'] as List).single;
  final scope = (f.scopes['scopes'] as List).first;
  profile['scope_ref']['sha256'] = catalogHash(catalogCanonicalJson(scope));
  assessment['scope_ref'] = {...profile['scope_ref'] as Map};
  assessment['profile_sha256'] = catalogHash(catalogCanonicalJson(profile));
  f.bundle['scope_registry_ref']['sha256'] = catalogHash(
    catalogCanonicalJson(f.scopes),
  );
  f.refreshPointer();
}

SyntheticMuscleCatalog _highConfidenceFixture() {
  final f = SyntheticMuscleCatalog();
  final profile = (f.bundle['profiles'] as List).single;
  final relationship = (profile['relationships'] as List).single;
  (f.bundle['sources'] as List).add({
    ...((f.bundle['sources'] as List).single as Map),
    'id': 'synthetic_source_two',
    'publisher_id': 'synthetic_publisher_two',
    'url': 'https://second-publisher.example/execution',
  });
  (f.bundle['claims'] as List).add({
    ...((f.bundle['claims'] as List).single as Map),
    'id': 'synthetic_claim_two',
    'source_id': 'synthetic_source_two',
    'url': 'https://second-publisher.example/execution',
  });
  relationship['confidence'] = 'high';
  relationship['claim_ids'] = ['synthetic_claim', 'synthetic_claim_two'];
  relationship['confidence_criteria']['independent_source_ids'] = [
    'synthetic_source',
    'synthetic_source_two',
  ];
  (f.bundle['assessments'] as List).single['dispositions'][0]['claim_ids'] = [
    'synthetic_claim',
    'synthetic_claim_two',
  ];
  _refreshMuscleAdmission(f);
  return f;
}

SyntheticMuscleCatalog _excludedCellFixture() {
  final f = SyntheticMuscleCatalog();
  final scope = (f.scopes['scopes'] as List).single;
  (scope['cells'] as List).add({
    ...((scope['cells'] as List).single as Map),
    'id': 'synthetic_excluded_cell',
    'role': 'secondary',
  });
  (f.bundle['sources'] as List).add({
    ...((f.bundle['sources'] as List).single as Map),
    'id': 'synthetic_exclusion_source',
    'publisher_id': 'synthetic_exclusion_publisher',
    'url': 'https://exclusion.example/execution',
  });
  (f.bundle['claims'] as List).add({
    ...((f.bundle['claims'] as List).single as Map),
    'id': 'synthetic_exclusion_claim',
    'source_id': 'synthetic_exclusion_source',
    'url': 'https://exclusion.example/execution',
    'claim_kind': 'scope_exclusion',
    'role': 'secondary',
  });
  ((f.bundle['assessments'] as List).single['dispositions'] as List).add({
    'cell_id': 'synthetic_excluded_cell',
    'status': 'excluded',
    'relationship_ids': <dynamic>[],
    'claim_ids': ['synthetic_exclusion_claim'],
    'rationale': 'Affirmative synthetic exact-setup exclusion.',
    'next_evidence_needed': null,
  });
  _refreshMuscleAdmission(f);
  return f;
}

void main() {
  test('v2 requires referenced raw bundle and separately trusted scopes', () {
    final f = SyntheticMuscleCatalog();
    final b = f.load();
    final p = b.muscleProfileFor(SyntheticMuscleCatalog.variantId)!;
    expect(p.coverage, 'complete');
    expect(
      (p.scopeDefinition!['cells'] as List).single['id'],
      'synthetic_cell',
    );
    expect(p.assessmentStatus, 'assessed');
    expect(p.humanReview!['status'], 'pending');
    expect(p.relationships.single.role, CatalogMuscleRole.primary);
    expect(p.mappings.single.regionIds, ['synthetic_arm_surface']);
    expect(p.anatomy['synthetic_elbow']!.names['en'], 'Synthetic elbow muscle');
    expect(
      () => CatalogBundle.fromJsonString(jsonEncode(f.catalog)),
      throwsA(isA<CatalogFormatException>()),
    );
    expect(
      () => CatalogBundle.fromBytes(
        utf8.encode(jsonEncode(f.catalog)),
        muscleBundleBytes: [...f.bundleBytes, 32],
        trustedScopeRegistryBytes: f.scopeBytes,
      ),
      throwsA(isA<CatalogFormatException>()),
    );
    final next = SyntheticMuscleCatalog(previous: f, role: 'secondary').load();
    expect(
      next.muscleProfileFor(SyntheticMuscleCatalog.variantId)!.revision,
      3,
    );
    expect(
      f.loadV1().muscleProfileFor(SyntheticMuscleCatalog.variantId)!.isLegacy,
      isTrue,
    );
  });
  test('snapshot freezing shares immutable subtrees only within its build', () {
    final shared = <String, dynamic>{
      'rows': [
        <String, dynamic>{'label': 'original'},
      ],
    };
    final input = <String, dynamic>{'scope': shared, 'anatomy': shared};
    final frozen = catalogFrozen(input) as Map<String, dynamic>;
    final other = catalogFrozen(input) as Map<String, dynamic>;
    expect(identical(frozen['scope'], frozen['anatomy']), isTrue);
    expect(identical(frozen['scope'], other['scope']), isFalse);
    (shared['rows'] as List).single['label'] = 'caller mutation';
    expect(frozen['scope']['rows'][0]['label'], 'original');
    expect(
      () => frozen['scope']['rows'][0]['label'] = 'mutation',
      throwsUnsupportedError,
    );
    expect(() => frozen['scope']['rows'].add({}), throwsUnsupportedError);
    final fixture = SyntheticMuscleCatalog();
    final first = fixture.load().muscleProfiles.values.single;
    final second = fixture.load().muscleProfiles.values.single;
    final bytes = catalogCanonicalJson(first.snapshot);
    expect(identical(first.scopeDefinition, second.scopeDefinition), isFalse);
    expect(
      () => first.scopeDefinition!['cells'][0]['action'] = 'mutation',
      throwsUnsupportedError,
    );
    expect(
      () => first.snapshot['anatomy']['nodes'].clear(),
      throwsUnsupportedError,
    );
    (fixture.scopes['scopes'] as List).single['cells'][0]['action'] =
        'caller mutation';
    expect(catalogCanonicalJson(first.snapshot), bytes);
    expect(catalogCanonicalJson(second.snapshot), bytes);
  });

  test('trusted scope revisions are independently addressed', () {
    final f = SyntheticMuscleCatalog();
    final old = (f.scopes['scopes'] as List).single;
    (f.scopes['scopes'] as List).add({...old, 'revision': 2});
    f.bundle['scope_registry_ref']['sha256'] = catalogHash(
      catalogCanonicalJson(f.scopes),
    );
    f.refreshPointer();
    expect(f.load().schemaVersion, 2);
  });
  test('v1 baseline revision two survives successive v2 revisions', () {
    final first = SyntheticMuscleCatalog(baselineRevision: 2);
    final next = SyntheticMuscleCatalog(previous: first);
    expect(
      first.load().muscleProfileFor(SyntheticMuscleCatalog.variantId)!.revision,
      3,
    );
    expect(
      next.load().muscleProfileFor(SyntheticMuscleCatalog.variantId)!.revision,
      4,
    );
  });
  test(
    'real inference enum requires exact mechanics and matching anatomy action',
    () {
      SyntheticMuscleCatalog inferred() {
        final f = SyntheticMuscleCatalog();
        final p = (f.bundle['profiles'] as List).single;
        final r = (p['relationships'] as List).single;
        r['evidence_basis'] = 'biomechanical_inference';
        r['reasoning_chain'] = [
          'Exact mechanics establishes action.',
          'Anatomy action supports bounded involvement.',
        ];
        final c = (f.bundle['claims'] as List).single as Map<String, dynamic>;
        c['claim_kind'] = 'execution_mechanics';
        c['anatomy_node_id'] = null;
        c['kind'] = null;
        c['role'] = null;
        c['granularity'] = 'movement_only';
        (f.bundle['claims'] as List).add({
          ...c,
          'id': 'synthetic_anatomy_claim',
          'claim_kind': 'anatomy_action',
          'variant_id': null,
          'variant_revision': null,
          'execution_sha256': null,
          'anatomy_node_id': 'synthetic_elbow',
          'granularity': 'muscle',
        });
        r['claim_ids'] = ['synthetic_claim', 'synthetic_anatomy_claim'];
        (f.bundle['assessments'] as List)
            .single['dispositions'][0]['claim_ids'] = [
          'synthetic_claim',
          'synthetic_anatomy_claim',
        ];
        (f.bundle['assessments'] as List).single['profile_sha256'] =
            catalogHash(catalogCanonicalJson(p));
        f.refreshPointer();
        return f;
      }

      expect(inferred().load().schemaVersion, 2);
      for (final change in <void Function(SyntheticMuscleCatalog)>[
        (f) => (f.bundle['claims'] as List).last['action'] = 'different action',
        (f) => (f.bundle['claims'] as List).first['claim_kind'] =
            'execution_relationship',
      ]) {
        final f = inferred();
        change(f);
        f.refreshPointer();
        expect(f.load, throwsA(isA<CatalogFormatException>()));
      }
    },
  );
  test('complete scope temporal closure preserves date-only uncertainty', () {
    for (final entry in <(String, bool)>[
      ('2026-11-03T00:00:00Z', true),
      ('2026-11-03T00:00:01Z', true),
      ('2026-11-02T23:59:59Z', false),
      ('2026-11-03', false),
      ('2026-11-04', true),
      ('2026-11-02', false),
      ('2026-11-31', false),
      ('2026-11-03T24:00:00Z', false),
    ]) {
      final f = SyntheticMuscleCatalog();
      (f.bundle['assessments'] as List).single['searched_on'] = entry.$1;
      _refreshMuscleAdmission(f);
      if (entry.$2) {
        expect(f.load().schemaVersion, 2, reason: entry.$1);
      } else {
        expect(
          f.load,
          throwsA(isA<CatalogFormatException>()),
          reason: entry.$1,
        );
      }
    }
    final lateDeclaration = SyntheticMuscleCatalog();
    (lateDeclaration.scopes['scopes'] as List).single['declared_on'] =
        '2026-11-03T12:00:00Z';
    _refreshMuscleAdmission(lateDeclaration);
    expect(lateDeclaration.load, throwsA(isA<CatalogFormatException>()));
  });
  test('confidence criteria require actual independent sources and limitations', () {
    expect(_highConfidenceFixture().load().schemaVersion, 2);
    final moderate = SyntheticMuscleCatalog();
    (moderate.bundle['profiles'] as List)
            .single['relationships'][0]['confidence_criteria']['exact_execution_supported'] =
        false;
    _refreshMuscleAdmission(moderate);
    expect(moderate.load().schemaVersion, 2);
    for (final change in <void Function(SyntheticMuscleCatalog)>[
      (f) => (f.bundle['sources'] as List).last['publisher_id'] =
          'synthetic_publisher',
      (f) =>
          (f.bundle['profiles'] as List)
                  .single['relationships'][0]['confidence_criteria']['exact_execution_supported'] =
              false,
      (f) =>
          (f.bundle['profiles'] as List)
                  .single['relationships'][0]['confidence_criteria']['material_conflict'] =
              true,
      (f) =>
          (f.bundle['profiles'] as List)
              .single['relationships'][0]['confidence_criteria']['independent_source_ids'] = [
            'synthetic_source',
          ],
      (f) => (f.bundle['sources'] as List).last['publication_status'] =
          'retracted',
    ]) {
      final f = _highConfidenceFixture();
      change(f);
      _refreshMuscleAdmission(f);
      expect(f.load, throwsA(isA<CatalogFormatException>()));
    }
    final low = SyntheticMuscleCatalog();
    final r = (low.bundle['profiles'] as List).single['relationships'][0];
    r['confidence'] = 'low';
    _refreshMuscleAdmission(low);
    expect(low.load().schemaVersion, 2);
    r['confidence_criteria']['limitations'] = <dynamic>[];
    _refreshMuscleAdmission(low);
    expect(low.load, throwsA(isA<CatalogFormatException>()));
  });
  test('supported and excluded cells require their exact evidence', () {
    expect(_excludedCellFixture().load().schemaVersion, 2);
    for (final change in <void Function(SyntheticMuscleCatalog)>[
      (f) => (f.bundle['claims'] as List).last['action'] = 'unrelated action',
      (f) => (f.bundle['claims'] as List).last['exact_setup_match'] = false,
      (f) => (f.bundle['claims'] as List).last['access_result'] = 'blocked',
      (f) => (f.bundle['sources'] as List).last['publication_status'] =
          'withdrawn',
      (f) =>
          (f.bundle['assessments'] as List)
                  .single['dispositions'][1]['claim_ids'] =
              <dynamic>[],
    ]) {
      final f = _excludedCellFixture();
      change(f);
      _refreshMuscleAdmission(f);
      expect(f.load, throwsA(isA<CatalogFormatException>()));
    }
    final supported = SyntheticMuscleCatalog();
    (supported.bundle['assessments'] as List)
            .single['dispositions'][0]['claim_ids'] =
        <dynamic>[];
    _refreshMuscleAdmission(supported);
    expect(supported.load, throwsA(isA<CatalogFormatException>()));
    final preciseSource = SyntheticMuscleCatalog();
    (preciseSource.bundle['claims'] as List).single['url'] =
        'https://another.example/execution';
    _refreshMuscleAdmission(preciseSource);
    expect(preciseSource.load, throwsA(isA<CatalogFormatException>()));
  });
  test(
    'incomplete and pending assessments cannot conceal missing evidence',
    () {
      final partial = SyntheticMuscleCatalog();
      (partial.bundle['profiles'] as List).single['coverage'] = 'partial';
      _refreshMuscleAdmission(partial);
      expect(partial.load, throwsA(isA<CatalogFormatException>()));
      (partial.bundle['assessments'] as List).single['unresolved'] = [
        {
          'reason': 'Explicit synthetic unresolved evidence.',
          'next_evidence_needed': 'Independent exact-setup source.',
        },
      ];
      _refreshMuscleAdmission(partial);
      expect(partial.load().schemaVersion, 2);
      (partial.bundle['assessments'] as List).single['assessment_status'] =
          'pending';
      _refreshMuscleAdmission(partial);
      expect(partial.load, throwsA(isA<CatalogFormatException>()));
    },
  );
  test(
    'development v4 loader binds raw muscle and trusted scope metadata',
    () async {
      final f = SyntheticMuscleCatalog(),
          bundle = SyntheticMuscleCatalog().load();
      final catalogBytes = utf8.encode(jsonEncode(f.catalog));
      final manifest = <String, dynamic>{
        'format': 'alkion-catalog-development-manifest',
        'schema_version': 4,
        'private_development_only': true,
        'redistribution_cleared': false,
        'media_included': false,
        'projection_sha256': bundle.digest,
        'catalog_revision': bundle.catalogRevision,
        'search_revision': bundle.searchRevision,
        'muscle_bundle': {
          'namespace': f.bundle['namespace'],
          'revision': f.bundle['revision'],
          'source_sha256': catalogHash(utf8.decode(f.bundleBytes)),
        },
        'scope_registry': {
          'revision': f.scopes['revision'],
          'source_sha256': catalogHash(utf8.decode(f.scopeBytes)),
          'canonical_sha256': catalogHash(catalogCanonicalJson(f.scopes)),
        },
      };
      var missingScopes = false, tamperMuscle = false;
      Future<CatalogDevelopmentInput> load() => loadDevelopmentCatalog(
        enabled: true,
        isAndroid: true,
        nativeIdentity: () async => {
          'applicationId': 'dev.animusstudio.alkion.dev',
          'flavor': 'dev',
          'displayName': 'Alkion Dev',
          'privateCatalogDev': true,
        },
        loadBytes: (path) async {
          if (path.endsWith('manifest.dev.json')) {
            return utf8.encode(jsonEncode(manifest));
          }
          if (path.endsWith('catalog.dev.json')) return catalogBytes;
          if (path.endsWith('muscles.dev.json')) {
            // Trailing whitespace keeps valid UTF-8 JSON with the same
            // content: only the raw-byte source digest can reject it.
            return tamperMuscle ? [...f.bundleBytes, 0x20] : f.bundleBytes;
          }
          if (path.endsWith('muscle-scopes.dev.json') && !missingScopes) {
            return f.scopeBytes;
          }
          throw const FormatException('Synthetic asset absent');
        },
      );
      expect((await load()).bundle!.schemaVersion, 2);
      // The digest check runs in the loader's background isolate; its
      // rejection still reaches the caller as unavailable.
      tamperMuscle = true;
      expect((await load()).unavailable, isTrue);
      tamperMuscle = false;
      expect((await load()).bundle!.schemaVersion, 2);
      missingScopes = true;
      expect((await load()).unavailable, isTrue);
      missingScopes = false;
      manifest['scope_registry']['canonical_sha256'] = 'f' * 64;
      expect((await load()).unavailable, isTrue);
    },
  );
  test(
    'unknown versions, fields, dangling evidence, maps, scope and history fail closed',
    () {
      for (final change in <void Function(SyntheticMuscleCatalog)>[
        (f) => f.catalog['schema_version'] = 7,
        (f) => f.bundle['schema_version'] = 3,
        (f) {
          final p = (f.bundle['profiles'] as List).single;
          p['side_scope'] = 'bilateral';
          (f.bundle['assessments'] as List).single['profile_sha256'] =
              catalogHash(catalogCanonicalJson(p));
        },
        (f) => f.bundle['unrecognized'] = true,
        (f) => (f.bundle['claims'] as List).single['source_id'] = 'missing',
        (f) =>
            (f.bundle['semantic_map']['mappings'] as List)
                .single['render_region_ids'] = [
              'missing',
            ],
        (f) => f.scopes['revision'] = 'different',
        (f) => (f.bundle['profile_history'] as List).clear(),
        (f) =>
            (f.bundle['profiles'] as List)
                    .single['human_review']['reviewer_id'] =
                'self-attested',
      ]) {
        final f = SyntheticMuscleCatalog();
        change(f);
        f.refreshPointer();
        expect(f.load, throwsA(isA<CatalogFormatException>()));
      }
    },
  );
}
