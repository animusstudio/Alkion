import 'dart:collection';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../catalog/catalog.dart';
import '../domain/catalog_execution.dart';
import '../domain/evidence.dart';
import '../domain/local_action.dart';
import '../store/local_store.dart';
import 'exercise_repository.dart';
import 'models.dart';

final class CatalogMuscleResolution {
  const CatalogMuscleResolution({
    this.profile,
    this.recordedProfile,
    this.reason,
    this.currentAssessment = false,
  });
  final CatalogMuscleProfile? profile, recordedProfile;
  final String? reason;
  final bool currentAssessment;
  bool get available => profile != null;
}

CatalogMuscleProfile _legacyMusclePin(
  Map<String, dynamic> pin,
  CatalogSelectionEvidence selection,
) {
  final execution = <String, dynamic>{
    'variant_id': pin['variantId'],
    'variant_revision': pin['variantRevision'],
    'family_id': pin['familyId'],
    'equipment_kind': pin['equipmentKind'],
    'facets': pin['facets'],
    'measurement_profile': (pin['measurementProfile'] as Map)['key'],
  };
  return CatalogMuscleProfile.fromSnapshot({
    'format': 'alkion-muscle-pin',
    'version': 2,
    'legacy': true,
    'sourceNamespace': selection.catalogNamespace,
    'sourceRevision': 'legacy-unavailable',
    'sourceBundleSha256': pin['bundleDigest'],
    'catalogNamespace': selection.catalogNamespace,
    'execution': execution,
    'executionSha256': catalogHash(catalogCanonicalJson(execution)),
    'profile': {
      'coverage': pin['muscleCoverage'],
      'relationships': [
        for (final r in pin['muscleRelationships'] as List)
          {
            'anatomy_node_id': r['anatomyNodeId'],
            'kind': 'strength',
            'role': r['role'],
          },
      ],
    },
    'assessment': {'assessment_status': 'legacy_unavailable'},
    'anatomy': {'revision': 'legacy-unavailable', 'nodes': <dynamic>[]},
    'semanticMap': {
      'revision': null,
      'regions': <dynamic>[],
      'mappings': <dynamic>[],
    },
    'claims': <dynamic>[],
    'sources': <dynamic>[],
  });
}

final class _CatalogDecodedPin {
  _CatalogDecodedPin(this.hash, this.fields);
  final String hash;
  final Map<String, dynamic> fields;
  CatalogMuscleProfile? profile;
}

final class _CatalogMusclePinRead {
  _CatalogMusclePinRead(List<Map<String, dynamic>> rows) {
    for (final row in rows) {
      (_namespaces[row['namespace']] ??= []).add(row);
      (_ids[(row['namespace'], row['pin_id'])] ??= []).add(row);
    }
  }
  final _namespaces = <Object?, List<Map<String, dynamic>>>{};
  final _ids = <(Object?, Object?), List<Map<String, dynamic>>>{};
  final _decoded =
      HashMap<Map<String, dynamic>, _CatalogDecodedPin?>.identity();

  List<Map<String, dynamic>> matching(CatalogSelectionEvidence selection) =>
      selection.musclePinDigest == null
      ? _namespaces['${selection.catalogNamespace}:execution'] ?? const []
      : _ids[(selection.musclePinNamespace, selection.musclePinDigest)] ??
            const [];

  _CatalogDecodedPin? decode(Map<String, dynamic> row) {
    if (_decoded.containsKey(row)) return _decoded[row];
    try {
      final bytes = (row['raw_bytes'] as List).cast<int>();
      return _decoded[row] = _CatalogDecodedPin(
        sha256.convert(bytes).toString(),
        decodeCatalogBytes(bytes),
      );
    } on Object {
      _decoded[row] = null;
      return null;
    }
  }
}

CatalogMuscleResolution _resolveRecordedMuscle(
  CatalogSelectionEvidence selection,
  List<Map<String, dynamic>> rows, {
  _CatalogMusclePinRead? pinRead,
}) {
  if (selection.variantId == null) {
    return const CatalogMuscleResolution(reason: 'unbound');
  }
  final explicit = selection.musclePinDigest != null;
  if (explicit &&
      (selection.musclePinNamespace != 'alkion.exercise-catalog:muscle' ||
          selection.catalogNamespace != 'alkion-exercises')) {
    return const CatalogMuscleResolution(reason: 'namespace_mismatch');
  }
  final candidates = <String, CatalogMuscleProfile>{};
  var corrupt = false;
  final pins = pinRead ?? _CatalogMusclePinRead(rows);
  for (final row in pins.matching(selection)) {
    if (row['namespace'] !=
        (explicit
            ? selection.musclePinNamespace
            : '${selection.catalogNamespace}:execution')) {
      continue;
    }
    if (explicit && row['pin_id'] != selection.musclePinDigest) continue;
    try {
      final decoded = pins.decode(row);
      if (decoded == null) {
        corrupt = true;
        continue;
      }
      final hash = decoded.hash;
      final pin = decoded.fields;
      if (explicit) {
        if (row['schema_version'] != 'alkion-muscle-pin/2' ||
            hash != row['digest'] ||
            hash != row['pin_id'] ||
            hash != selection.musclePinDigest ||
            pin['format'] != 'alkion-muscle-pin' ||
            pin['version'] != 2 ||
            pin['catalogNamespace'] != selection.catalogNamespace ||
            pin['sourceCatalogSha256'] != selection.bundleDigest ||
            pin['sourceNamespace'] != 'alkion.exercise-catalog' ||
            pin['executionSha256'] != selection.executionSha256 ||
            (pin['execution'] as Map)['variant_id'] != selection.variantId ||
            (pin['execution'] as Map)['variant_revision'] !=
                selection.variantRevision ||
            catalogHash(catalogCanonicalJson(pin['execution'])) !=
                pin['executionSha256']) {
          corrupt = true;
          continue;
        }
        if (decoded.profile == null) {
          validateMuscleSchema(pin['profile'], definition: 'profile');
        }
        if ((pin['profile'] as Map)['variant_id'] != selection.variantId ||
            (pin['profile'] as Map)['variant_revision'] !=
                selection.variantRevision ||
            (pin['profile'] as Map)['execution_sha256'] !=
                selection.executionSha256 ||
            (pin['execution'] as Map)['family_id'] != selection.familyId) {
          corrupt = true;
          continue;
        }
        candidates[hash] = decoded.profile ??=
            CatalogMuscleProfile.fromSnapshot(pin);
      } else {
        if (pin['variantId'] != selection.variantId ||
            pin['variantRevision'] != selection.variantRevision ||
            pin['bundleDigest'] != selection.bundleDigest) {
          continue;
        }
        if (row['schema_version'] != 'alkion-execution-pin/1' ||
            hash != row['digest'] ||
            hash != row['pin_id'] ||
            pin['familyId'] != selection.familyId ||
            catalogCanonicalJson(pin['measurementProfile']) !=
                catalogCanonicalJson(selection.profile.toJson()) ||
            pin['equipmentKind'] is! String ||
            pin['facets'] is! Map) {
          corrupt = true;
          continue;
        }
        candidates[hash] = decoded.profile ??= _legacyMusclePin(pin, selection);
      }
    } on Object {
      corrupt = true;
    }
  }
  if (corrupt) return const CatalogMuscleResolution(reason: 'corrupt_pin');
  if (candidates.isEmpty) {
    return const CatalogMuscleResolution(reason: 'missing_pin');
  }
  if (candidates.length != 1) {
    return const CatalogMuscleResolution(reason: 'conflicting_pins');
  }
  return CatalogMuscleResolution(profile: candidates.values.single);
}

final class CatalogOwnedSelection {
  const CatalogOwnedSelection({
    required this.exercise,
    required this.selection,
    this.dependencies = const [],
  });
  final Exercise exercise;
  final CatalogSelectionEvidence selection;
  final List<OperationDependency> dependencies;
}

final class PreparedCatalogSelection {
  const PreparedCatalogSelection(this.selection, this.intent, this.token);
  final CatalogSelectionEvidence selection;
  final PreparedDomainAction? intent;
  final StoreToken token;
}

/// Checks historical payloads only. Mutable projection tombstones do not erase
/// the exact revisions retained by an active or recorded selection.
String? _catalogSelectionHistoryFailure(
  CatalogSelectionEvidence selection,
  Map<String, dynamic>? context,
  Map<String, dynamic>? binding,
) {
  if (context == null || context['deleted'] == 1) {
    return 'catalog_context_unavailable';
  }
  if (selection.bindingId != null &&
      (binding == null || binding['deleted'] == 1)) {
    return 'catalog_binding_unavailable';
  }
  try {
    final fields = decodeCatalogBytes(context['payload_bytes']!);
    final pinned = CatalogSelectionEvidence.fromJson(
      decodeCatalogBytes(fields['execution_bytes']!),
    );
    if (catalogCanonicalJson(pinned.toJson()) !=
        catalogCanonicalJson(selection.toJson())) {
      return 'catalog_context_mismatch';
    }
  } on Object {
    return 'catalog_context_corrupt';
  }
  if (selection.bindingId != null) {
    try {
      final fields = decodeCatalogBytes(binding!['payload_bytes']!);
      if (fields['exercise_id'] != selection.exerciseId ||
          fields['variant_id'] != selection.variantId ||
          fields['variant_revision'] != selection.variantRevision ||
          fields['bundle_digest'] != selection.bundleDigest ||
          fields['family_id'] != selection.familyId ||
          fields['catalog_namespace'] != selection.catalogNamespace ||
          fields['label_policy'] != selection.labelPolicy ||
          base64Encode(localBytes(selection.profile.toJson())) !=
              base64Encode(
                (fields['measurement_profile_bytes'] as List).cast<int>(),
              )) {
        return 'catalog_binding_mismatch';
      }
    } on Object {
      return 'catalog_binding_corrupt';
    }
  }
  return null;
}

/// Verifies the pinned revision, never the mutable current context label.
Future<void> validateCatalogSelection(
  LocalRead tx,
  CatalogSelectionEvidence selection,
) async {
  final context = await tx.getOptional(
    "SELECT payload_bytes,deleted FROM record_revisions WHERE profile_id=? AND kind='trackingContext' AND record_id=? AND revision=?",
    [tx.profileId, selection.contextId, selection.contextRevision],
  );
  final binding = selection.bindingId == null
      ? null
      : await tx.getOptional(
          "SELECT payload_bytes,deleted FROM record_revisions WHERE profile_id=? AND kind='catalogBinding' AND record_id=? AND revision=?",
          [tx.profileId, selection.bindingId, selection.bindingRevision],
        );
  final failure = _catalogSelectionHistoryFailure(selection, context, binding);
  if (failure != null) throw StoreException(failure);
  if (selection.musclePinDigest != null) {
    final resolution = _resolveRecordedMuscle(
      selection,
      await tx.getAll(
        'SELECT * FROM catalog_pins WHERE profile_id=? AND namespace=? AND pin_id=?',
        [tx.profileId, selection.musclePinNamespace, selection.musclePinDigest],
      ),
    );
    if (!resolution.available) {
      throw StoreException('catalog_${resolution.reason}');
    }
  }
}

Future<List<OperationDependency>> catalogSelectionDependencies(
  LocalRead tx,
  CatalogSelectionEvidence selection,
) async {
  final ids = <String>{};
  for (final ref in [
    (
      RecordKind.trackingContext,
      selection.contextId,
      selection.contextRevision,
    ),
    if (selection.bindingId != null)
      (
        RecordKind.catalogBinding,
        selection.bindingId!,
        selection.bindingRevision!,
      ),
  ]) {
    final row = await tx.getOptional(
      'SELECT operation_id FROM record_revisions WHERE profile_id=? AND kind=? AND record_id=? AND revision=?',
      [tx.profileId, ref.$1.name, ref.$2, ref.$3],
    );
    if (row?['operation_id'] != null) ids.add(row!['operation_id'] as String);
  }
  return [
    for (final id in ids)
      OperationDependency(tx.profileId, GrantFamily.workouts, id),
  ];
}

final class CatalogExecutionRepository {
  const CatalogExecutionRepository.local(this.db);
  final LocalDatabase db;
  String _id(String key) => const Uuid().v5(
    Namespace.url.value,
    'alkion-catalog:${db.profileId}:$key',
  );
  String defaultContextIdFor(String exerciseId) =>
      _id('context:$exerciseId:default');
  bool isDefaultContext(CatalogSelectionEvidence selection) =>
      selection.contextId == defaultContextIdFor(selection.exerciseId);

  Future<PreparedCatalogSelection> prepareSelection({
    CatalogBundle? bundle,
    String? variantId,
    required String displayLabel,
    String setupId = 'default',
    String? nickname,
    String? customId,
    CatalogMeasurementProfileEvidence? profile,
    Set<String> personalGroups = const {},
    String catalogNamespace = 'alkion-exercises',
    String labelPolicy = 'eligible-familiar/1',
    String resistanceSource = 'unknown',
    String loadConvention = 'unknown',
    String? operationId,
  }) async {
    final token = db.token;
    if (bundle?.schemaVersion == 2 && catalogNamespace != 'alkion-exercises') {
      throw const StoreException('catalog_namespace_mismatch');
    }
    final variant = variantId == null ? null : bundle?.variants[variantId];
    if ((variantId != null && variant == null) ||
        (variantId == null && (customId == null || profile == null))) {
      throw const StoreException('catalog_unavailable');
    }
    final metricProfile = variant == null
        ? profile!
        : CatalogMeasurementProfileEvidence.fromCatalog(
            bundle!.measurementFor(variant),
          );
    final definitionKey = variant == null
        ? 'custom:$customId'
        : '$catalogNamespace:$variantId';
    final exerciseId = _id('exercise:$definitionKey');
    final bindingId = variant == null ? null : _id('binding:$definitionKey');
    final contextId = setupId == 'default'
        ? defaultContextIdFor(exerciseId)
        : setupId;
    return db.readTransaction((tx) async {
      final binding = bindingId == null
          ? null
          : await tx.record(
              LocalRef(tx.profileId, RecordKind.catalogBinding, bindingId),
            );
      if (binding != null &&
          (binding['deleted'] == 1 ||
              binding['variant_revision'] != variant!.revision ||
              binding['catalog_namespace'] != catalogNamespace)) {
        throw const StoreException('incompatible_catalog_revision');
      }
      final context = await tx.record(
        LocalRef(tx.profileId, RecordKind.trackingContext, contextId),
      );
      final previousSelection = context == null
          ? null
          : CatalogSelectionEvidence.fromJson(
              decodeCatalogBytes(context['execution_bytes']!),
            );
      final upgradingBinding =
          binding != null && binding['bundle_digest'] != bundle?.digest;
      final upgradingContext =
          previousSelection != null &&
          previousSelection.bundleDigest != bundle?.digest;
      if (previousSelection != null) {
        if (context!['deleted'] == 1 ||
            previousSelection.exerciseId != exerciseId ||
            previousSelection.variantId != variantId ||
            previousSelection.catalogNamespace != catalogNamespace) {
          throw const StoreException('catalog_context_mismatch');
        }
        await validateCatalogSelection(tx, previousSelection);
        if (!upgradingContext && !upgradingBinding) {
          return PreparedCatalogSelection(previousSelection, null, token);
        }
      }
      if (upgradingBinding || upgradingContext) {
        final pins = await tx.getAll(
          'SELECT * FROM catalog_pins WHERE profile_id=?',
          [tx.profileId],
        );
        // A binding can have several contexts. Use its exact immutable selection,
        // never a label or a current definition as evidence of compatibility.
        CatalogSelectionEvidence? observed = previousSelection;
        if (upgradingBinding &&
            (observed == null ||
                observed.bindingRevision != binding['revision'])) {
          final contexts = await tx.getAll(
            'SELECT execution_bytes FROM exercise_tracking_contexts WHERE profile_id=? AND binding_id=? AND binding_revision=?',
            [tx.profileId, bindingId, binding['revision']],
          );
          if (contexts.isNotEmpty) {
            observed = CatalogSelectionEvidence.fromJson(
              decodeCatalogBytes(contexts.first['execution_bytes']!),
            );
          }
        }
        final old = observed == null
            ? const CatalogMuscleResolution(reason: 'missing_pin')
            : _resolveRecordedMuscle(observed, pins);
        final current = bundle?.muscleProfileFor(variantId!);
        if (old.profile == null ||
            current == null ||
            old.profile!.executionSha256 != current.executionSha256 ||
            (!old.profile!.isLegacy &&
                !current.isLegacy &&
                catalogCanonicalJson(
                      old.profile!.snapshot['measurementDefinition'],
                    ) !=
                    catalogCanonicalJson(
                      current.snapshot['measurementDefinition'],
                    )) ||
            catalogCanonicalJson(observed!.profile.toJson()) !=
                catalogCanonicalJson(metricProfile.toJson())) {
          throw const StoreException('incompatible_catalog_revision');
        }
      }
      final exercise = await tx.record(
        LocalRef(tx.profileId, RecordKind.exercise, exerciseId),
      );
      if (exercise != null && exercise['deleted'] == 1) {
        throw const StoreException('deleted_target');
      }
      if (exercise != null && variant == null) {
        final definition = CatalogExecutionDefinition.fromJson(
          decodeCatalogBytes(exercise['execution_definition_bytes']!),
        );
        if (jsonEncode(definition.profile.toJson()) !=
            jsonEncode(metricProfile.toJson())) {
          throw const StoreException('catalog_definition_mismatch');
        }
      }
      final label =
          binding?['stable_label'] as String? ??
          exercise?['name'] as String? ??
          displayLabel;
      final selection = CatalogSelectionEvidence(
        exerciseId: exerciseId,
        contextId: contextId,
        contextRevision: (context?['revision'] as int? ?? 0) + 1,
        bindingId: bindingId,
        bindingRevision: bindingId == null
            ? null
            : (binding?['revision'] as int? ?? 0) +
                  (binding == null || upgradingBinding ? 1 : 0),
        familyId: variant?.familyId,
        variantId: variantId,
        variantRevision: variant?.revision,
        bundleDigest: bundle?.digest,
        musclePinNamespace: bundle?.schemaVersion == 2
            ? 'alkion.exercise-catalog:muscle'
            : null,
        musclePinDigest: bundle?.schemaVersion == 2
            ? sha256
                  .convert(
                    localBytes(bundle!.muscleProfileFor(variantId!)!.toJson()),
                  )
                  .toString()
            : null,
        executionSha256: bundle?.schemaVersion == 2
            ? bundle!.muscleProfileFor(variantId!)!.executionSha256
            : null,
        catalogNamespace: catalogNamespace,
        // A newer presentation policy never relabels a saved binding/context.
        labelPolicy:
            previousSelection?.labelPolicy ??
            (binding?['label_policy'] as String?) ??
            labelPolicy,
        profile: metricProfile,
        displayLabel: label,
        contextLabel: previousSelection?.contextLabel ?? nickname?.trim() ?? '',
        resistanceSource:
            previousSelection?.resistanceSource ?? resistanceSource,
        loadConvention: previousSelection?.loadConvention ?? loadConvention,
      );
      final definition = CatalogExecutionDefinition(
        profile: metricProfile,
        displayLabel: label,
        personalGroups: personalGroups,
      );
      final input = <String, Object?>{
        'catalog_contract': 1,
        'selection': selection.toJson(),
        'definition': definition.toJson(),
        'create_exercise': exercise == null,
        'create_binding': bindingId != null && binding == null,
        'upgrade_binding': upgradingBinding,
        'binding_base': binding?['revision'],
        'context_base': context?['revision'] ?? 0,
        if (selection.musclePinDigest != null)
          'muscle_pin': bundle!.muscleProfileFor(variantId!)!.toJson(),
        if (variant != null)
          'pin': {
            'variantId': variant.id,
            'variantRevision': variant.revision,
            'familyId': variant.familyId,
            'bundleDigest': bundle!.digest,
            'names': variant.names,
            'facets': variant.facets,
            'equipmentKind': variant.equipmentKind,
            'muscleCoverage': variant.muscleCoverage,
            'muscleRelationships': [
              for (final relationship in variant.muscleRelationships)
                {
                  'anatomyNodeId': relationship.anatomyNodeId,
                  'role': relationship.role,
                },
            ],
            'measurementProfile': metricProfile.toJson(),
          },
      };
      final intent = prepareDomain(
        db,
        exercise == null ? RecordKind.exercise : RecordKind.trackingContext,
        exercise == null
            ? LocalActionKind.catalogDefinitionCreate
            : LocalActionKind.catalogContextCreate,
        exercise == null ? exerciseId : contextId,
        exercise == null ? 0 : (context?['revision'] as int? ?? 0),
        input,
        operationId: operationId,
        dependencies: binding == null
            ? const []
            : [
                for (final row in await tx.getAll(
                  "SELECT operation_id FROM record_revisions WHERE profile_id=? AND kind='catalogBinding' AND record_id=? AND revision=? AND operation_id IS NOT NULL",
                  [tx.profileId, bindingId, binding['revision']],
                ))
                  OperationDependency(
                    tx.profileId,
                    GrantFamily.workouts,
                    row['operation_id'] as String,
                  ),
              ],
        eligibility: SyncEligibility.unsupportedMapping,
      );
      return PreparedCatalogSelection(selection, intent, token);
    }, expected: token);
  }

  Future<CatalogOwnedSelection> commitPrepared(
    PreparedCatalogSelection prepared,
  ) async {
    final intent = prepared.intent;
    if (intent != null) {
      try {
        await db.apply(
          intent.action,
          (tx) => executePreparedInTransaction(tx, intent),
          expected: intent.token,
        );
      } on StoreException catch (error) {
        // Another independently prepared first selection may have won. Only a
        // certain revision conflict may resolve to exactly the same durable IDs.
        if (error.category != 'revision_conflict') rethrow;
        await db.readTransaction(
          (tx) => validateCatalogSelection(tx, prepared.selection),
          expected: prepared.token,
        );
      }
    }
    return db.readTransaction((tx) async {
      await validateCatalogSelection(tx, prepared.selection);
      final row = await tx.record(
        LocalRef(
          tx.profileId,
          RecordKind.exercise,
          prepared.selection.exerciseId,
        ),
      );
      if (row == null || row['deleted'] == 1) {
        throw const StoreException('missing_reference');
      }
      return CatalogOwnedSelection(
        exercise: Exercise.fromRow(row),
        selection: prepared.selection,
        dependencies: await catalogSelectionDependencies(
          tx,
          prepared.selection,
        ),
      );
    }, expected: prepared.token);
  }

  Future<Object?> executePreparedInTransaction(
    LocalTransaction tx,
    PreparedDomainAction intent,
  ) async {
    if (tx.action?.hash != intent.action.hash ||
        intent.input['catalog_contract'] != 1) {
      throw const StoreException('prepared_action_mismatch');
    }
    final input = intent.input;
    final selection = CatalogSelectionEvidence.fromJson(
      catalogEvidenceObject(input['selection']),
    );
    if (intent.action.action == LocalActionKind.catalogContextRename) {
      final previous = await observedRecord(
        tx,
        intent.action.target,
        intent.action.baseLocalRevision,
      );
      final oldSelection = CatalogSelectionEvidence.fromJson(
        decodeCatalogBytes(previous['execution_bytes']!),
      );
      if (selection.contextId != intent.action.target.id ||
          selection.contextRevision != intent.action.baseLocalRevision + 1 ||
          oldSelection.compatibilityKey != selection.compatibilityKey) {
        throw const StoreException('catalog_context_mismatch');
      }
      await putDomain(tx, intent.action.target, {
        ...projectionFields(previous),
        'label': selection.contextLabel,
        'execution_bytes': localBytes(selection.toJson()),
      });
      await validateCatalogSelection(tx, selection);
      return {
        'context_id': selection.contextId,
        'context_revision': selection.contextRevision,
      };
    }
    if (await tx.latestRevision(
          LocalRef(
            tx.profileId,
            RecordKind.trackingContext,
            selection.contextId,
          ),
        ) !=
        (input['context_base'] ?? 0)) {
      throw const StoreException('revision_conflict');
    }
    if (input['upgrade_binding'] == true) {
      await observedRecord(
        tx,
        LocalRef(tx.profileId, RecordKind.catalogBinding, selection.bindingId!),
        input['binding_base'] as int,
      );
    }
    if (input['create_exercise'] == true) {
      final ref = LocalRef(
        tx.profileId,
        RecordKind.exercise,
        selection.exerciseId,
      );
      if (await tx.latestRevision(ref) != 0) {
        throw const StoreException('revision_conflict');
      }
      await putDomain(tx, ref, {
        'name': selection.displayLabel,
        'slug': uniqueSlug(selection.displayLabel, selection.exerciseId),
        'muscle_group': '',
        'compound': 0,
        'base_weight_kg': null,
        'plate_step_kg': null,
        'default_warmup_sets': 0,
        'default_working_sets': 1,
        'is_template': 0,
        'created_at': intent.createdAt,
        'execution_definition_bytes': localBytes(input['definition']),
      });
    }
    if (input['create_binding'] == true || input['upgrade_binding'] == true) {
      await putDomain(
        tx,
        LocalRef(tx.profileId, RecordKind.catalogBinding, selection.bindingId!),
        {
          'exercise_id': selection.exerciseId,
          'catalog_namespace': selection.catalogNamespace,
          'family_id': selection.familyId,
          'variant_id': selection.variantId,
          'variant_revision': selection.variantRevision,
          'bundle_digest': selection.bundleDigest,
          'label_policy': selection.labelPolicy,
          'stable_label': selection.displayLabel,
          'measurement_profile_bytes': localBytes(selection.profile.toJson()),
        },
      );
    }
    if (input['pin'] != null) {
      final pinBytes = localBytes(input['pin']);
      final digest = sha256.convert(pinBytes).toString();
      await tx.execute(
        'INSERT OR IGNORE INTO catalog_pins VALUES(?,?,?,?,?,?,?,?)',
        [
          tx.profileId,
          '${selection.catalogNamespace}:execution',
          digest,
          digest,
          'alkion-execution-pin/1',
          pinBytes,
          localBytes({'bundle_digest': selection.bundleDigest}),
          intent.createdAt,
        ],
      );
    }
    if (input['muscle_pin'] != null) {
      final bytes = localBytes(input['muscle_pin']);
      if (sha256.convert(bytes).toString() != selection.musclePinDigest) {
        throw const StoreException('catalog_pin_mismatch');
      }
      await tx.execute(
        'INSERT OR IGNORE INTO catalog_pins VALUES(?,?,?,?,?,?,?,?)',
        [
          tx.profileId,
          selection.musclePinNamespace,
          selection.musclePinDigest,
          selection.musclePinDigest,
          'alkion-muscle-pin/2',
          bytes,
          localBytes({
            'source_bundle_sha256':
                (input['muscle_pin'] as Map)['sourceBundleSha256'],
          }),
          intent.createdAt,
        ],
      );
    }
    final exercise = await tx.record(
      LocalRef(tx.profileId, RecordKind.exercise, selection.exerciseId),
    );
    if (exercise == null || exercise['deleted'] == 1) {
      throw const StoreException('missing_reference');
    }
    await putDomain(
      tx,
      LocalRef(tx.profileId, RecordKind.trackingContext, selection.contextId),
      {
        'exercise_id': selection.exerciseId,
        'binding_id': selection.bindingId,
        'binding_revision': selection.bindingRevision,
        'label': selection.contextLabel,
        'resistance_source': selection.resistanceSource,
        'load_convention': selection.loadConvention,
        'execution_bytes': localBytes(selection.toJson()),
      },
    );
    await validateCatalogSelection(tx, selection);
    return {
      'exercise_id': selection.exerciseId,
      'context_id': selection.contextId,
    };
  }

  /// One profile-scoped read supplies every pin used by the workout. Current
  /// definitions and their tombstones do not erase immutable historical pins.
  Future<Map<String, CatalogMuscleResolution>> resolveMuscles(
    List<CatalogSelectionEvidence> selections, {
    CatalogBundle? currentBundle,
    bool currentAssessment = false,
  }) => db.readTransaction((tx) async {
    final unique = {
      for (final selection in selections)
        selection.muscleResolutionKey: selection,
    };
    if (unique.isEmpty) return {};
    final rows = <Map<String, dynamic>>[];
    final explicitPins = {
      for (final selection in unique.values)
        if (selection.musclePinDigest != null)
          (selection.musclePinNamespace, selection.musclePinDigest),
    }.toList();
    for (var offset = 0; offset < explicitPins.length; offset += 250) {
      final chunk = explicitPins.skip(offset).take(250).toList();
      rows.addAll(
        await tx.getAll(
          'SELECT * FROM catalog_pins WHERE profile_id=? AND '
          '(${List.filled(chunk.length, '(namespace=? AND pin_id=?)').join(' OR ')})',
          [
            tx.profileId,
            for (final ref in chunk) ...[ref.$1, ref.$2],
          ],
        ),
      );
    }
    // V1 has no pin pointer; only its execution namespace can supply candidates.
    final legacyNamespaces = {
      for (final selection in unique.values)
        if (selection.musclePinDigest == null && selection.variantId != null)
          '${selection.catalogNamespace}:execution',
    };
    for (final namespace in legacyNamespaces) {
      rows.addAll(
        await tx.getAll(
          'SELECT * FROM catalog_pins WHERE profile_id=? AND namespace=?',
          [tx.profileId, namespace],
        ),
      );
    }
    final references = <(String, String, int)>{
      for (final selection in unique.values) ...[
        ('trackingContext', selection.contextId, selection.contextRevision),
        if (selection.bindingId != null)
          ('catalogBinding', selection.bindingId!, selection.bindingRevision!),
      ],
    }.toList();
    final history = <(String, String, int), Map<String, dynamic>>{};
    // Stay below SQLite's portable parameter limit while batching exact refs.
    for (var offset = 0; offset < references.length; offset += 250) {
      final chunk = references.skip(offset).take(250).toList();
      for (final row in await tx.getAll(
        'SELECT kind,record_id,revision,payload_bytes,deleted FROM record_revisions '
        'WHERE profile_id=? AND (${List.filled(chunk.length, '(kind=? AND record_id=? AND revision=?)').join(' OR ')})',
        [
          tx.profileId,
          for (final ref in chunk) ...[ref.$1, ref.$2, ref.$3],
        ],
      )) {
        history[(
              row['kind'] as String,
              row['record_id'] as String,
              row['revision'] as int,
            )] =
            row;
      }
    }
    final pins = _CatalogMusclePinRead(rows);
    return {
      for (final entry in unique.entries)
        entry.key: (() {
          final selection = entry.value;
          if (selection.variantId != null &&
              selection.exerciseId !=
                  _id(
                    'exercise:${selection.catalogNamespace}:${selection.variantId}',
                  )) {
            return const CatalogMuscleResolution(
              reason: 'foreign_profile_or_namespace',
            );
          }
          final failure = _catalogSelectionHistoryFailure(
            selection,
            history[(
              'trackingContext',
              selection.contextId,
              selection.contextRevision,
            )],
            history[(
              'catalogBinding',
              selection.bindingId,
              selection.bindingRevision,
            )],
          );
          if (failure != null) {
            return CatalogMuscleResolution(
              reason: failure,
              currentAssessment: currentAssessment,
            );
          }
          final recorded = _resolveRecordedMuscle(
            selection,
            rows,
            pinRead: pins,
          );
          if (!currentAssessment) return recorded;
          final current = currentBundle?.muscleProfileFor(
            selection.variantId ?? '',
          );
          if (recorded.profile == null) {
            return CatalogMuscleResolution(
              reason: recorded.reason,
              currentAssessment: true,
            );
          }
          if (current == null) {
            return CatalogMuscleResolution(
              recordedProfile: recorded.profile,
              reason: 'current_unavailable',
              currentAssessment: true,
            );
          }
          if (selection.catalogNamespace != 'alkion-exercises' ||
              current.executionSha256 != recorded.profile!.executionSha256 ||
              (!current.isLegacy &&
                  !recorded.profile!.isLegacy &&
                  catalogCanonicalJson(
                        current.snapshot['measurementDefinition'],
                      ) !=
                      catalogCanonicalJson(
                        recorded.profile!.snapshot['measurementDefinition'],
                      ))) {
            return CatalogMuscleResolution(
              recordedProfile: recorded.profile,
              reason: 'incompatible_current_execution',
              currentAssessment: true,
            );
          }
          return CatalogMuscleResolution(
            profile: current,
            recordedProfile: recorded.profile,
            currentAssessment: true,
          );
        })(),
    };
  });

  Future<List<CatalogSelectionEvidence>> selectionsForExercise(
    String id,
  ) async => [
    for (final row in await db.getAll(
      'SELECT execution_bytes FROM exercise_tracking_contexts WHERE profile_id=? AND exercise_id=? AND deleted=0 ORDER BY id',
      [db.profileId, id],
    ))
      CatalogSelectionEvidence.fromJson(
        decodeCatalogBytes(row['execution_bytes']!),
      ),
  ];

  Future<List<OperationDependency>> dependenciesForSelection(
    CatalogSelectionEvidence selection,
  ) => db.readTransaction((tx) => catalogSelectionDependencies(tx, selection));

  PreparedCatalogSelection prepareNewContext(
    CatalogSelectionEvidence previous, {
    String? contextId,
    String? nickname,
    String? operationId,
    List<OperationDependency> dependencies = const [],
  }) {
    final selection = CatalogSelectionEvidence.fromJson({
      ...previous.toJson(),
      'contextId': contextId ?? domainUuid.v4(),
      'contextRevision': 1,
      'contextLabel': nickname?.trim() ?? '',
    });
    final intent = prepareDomain(
      db,
      RecordKind.trackingContext,
      LocalActionKind.catalogContextCreate,
      selection.contextId,
      0,
      {
        'catalog_contract': 1,
        'selection': selection.toJson(),
        'create_exercise': false,
        'create_binding': false,
      },
      operationId: operationId,
      dependencies: dependencies,
      eligibility: SyncEligibility.unsupportedMapping,
    );
    return PreparedCatalogSelection(selection, intent, db.token);
  }

  PreparedDomainAction prepareRenameContext(
    CatalogSelectionEvidence selection,
    String label, {
    String? operationId,
    List<OperationDependency> dependencies = const [],
  }) => prepareDomain(
    db,
    RecordKind.trackingContext,
    LocalActionKind.catalogContextRename,
    selection.contextId,
    selection.contextRevision,
    {
      'catalog_contract': 1,
      'selection': selection
          .withContextLabel(label, selection.contextRevision + 1)
          .toJson(),
    },
    operationId: operationId,
    dependencies: dependencies,
    eligibility: SyncEligibility.unsupportedMapping,
  );
  Future<LocalActionResult> commitContextPrepared(
    PreparedDomainAction intent,
  ) => db.apply(
    intent.action,
    (tx) => executePreparedInTransaction(tx, intent),
    expected: intent.token,
  );
}
