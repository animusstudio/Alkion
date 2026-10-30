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

/// Verifies the pinned revision, never the mutable current context label.
Future<void> validateCatalogSelection(
  LocalRead tx,
  CatalogSelectionEvidence selection,
) async {
  final context = await tx.getOptional(
    "SELECT payload_bytes,deleted FROM record_revisions WHERE profile_id=? AND kind='trackingContext' AND record_id=? AND revision=?",
    [tx.profileId, selection.contextId, selection.contextRevision],
  );
  if (context == null || context['deleted'] == 1) {
    throw const StoreException('catalog_context_unavailable');
  }
  final fields = decodeCatalogBytes(context['payload_bytes']!);
  final pinned = CatalogSelectionEvidence.fromJson(
    decodeCatalogBytes(fields['execution_bytes']!),
  );
  if (base64Encode(localBytes(pinned.toJson())) !=
      base64Encode(localBytes(selection.toJson()))) {
    throw const StoreException('catalog_context_mismatch');
  }
  if (selection.bindingId != null) {
    final binding = await tx.getOptional(
      "SELECT payload_bytes,deleted FROM record_revisions WHERE profile_id=? AND kind='catalogBinding' AND record_id=? AND revision=?",
      [tx.profileId, selection.bindingId, selection.bindingRevision],
    );
    if (binding == null || binding['deleted'] == 1) {
      throw const StoreException('catalog_binding_unavailable');
    }
    final fields = decodeCatalogBytes(binding['payload_bytes']!);
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
      throw const StoreException('catalog_binding_mismatch');
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
    String resistanceSource = 'unknown',
    String loadConvention = 'unknown',
    String? operationId,
  }) async {
    final token = db.token;
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
              binding['bundle_digest'] != bundle!.digest)) {
        throw const StoreException('incompatible_catalog_revision');
      }
      final context = await tx.record(
        LocalRef(tx.profileId, RecordKind.trackingContext, contextId),
      );
      if (context != null) {
        final selection = CatalogSelectionEvidence.fromJson(
          decodeCatalogBytes(context['execution_bytes']!),
        );
        if (context['deleted'] == 1 ||
            selection.exerciseId != exerciseId ||
            selection.variantId != variantId ||
            selection.bundleDigest != bundle?.digest) {
          throw const StoreException('catalog_context_mismatch');
        }
        await validateCatalogSelection(tx, selection);
        return PreparedCatalogSelection(selection, null, token);
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
        contextRevision: 1,
        bindingId: bindingId,
        bindingRevision:
            binding?['revision'] as int? ?? (bindingId == null ? null : 1),
        familyId: variant?.familyId,
        variantId: variantId,
        variantRevision: variant?.revision,
        bundleDigest: bundle?.digest,
        catalogNamespace: catalogNamespace,
        profile: metricProfile,
        displayLabel: label,
        contextLabel: nickname?.trim() ?? '',
        resistanceSource: resistanceSource,
        loadConvention: loadConvention,
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
        0,
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
    if (input['create_binding'] == true) {
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
