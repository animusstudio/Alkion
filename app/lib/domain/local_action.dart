import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'evidence.dart';

enum GrantFamily { workouts, bodyweight, targets }

enum RecordKind {
  exercise,
  trainingDay,
  trainingSlot,
  workout,
  workoutSet,
  bodyweight,
  muscleTarget,
}

extension RecordFamily on RecordKind {
  GrantFamily get family => switch (this) {
    RecordKind.bodyweight => GrantFamily.bodyweight,
    RecordKind.muscleTarget => GrantFamily.targets,
    _ => GrantFamily.workouts,
  };
}

enum SyncEligibility { localOnly, awaitingAttachment, unsupportedMapping }

enum LocalActionKind {
  definitionCreate,
  definitionEdit,
  definitionDelete,
  definitionRestore,
  planCreate,
  planEdit,
  planClone,
  planDelete,
  planRestore,
  planReorder,
  slotAdd,
  slotRemove,
  slotReplace,
  slotReorder,
  workoutFinish,
  workoutReplace,
  workoutEdit,
  workoutDelete,
  workoutRestore,
  bodyweightRecord,
  bodyweightEdit,
  bodyweightDelete,
  bodyweightRestore,
  targetSet,
  targetDelete,
  targetRestore,
  targetKeepEmpty,
}

extension ActionTarget on LocalActionKind {
  RecordKind get targetKind => switch (this) {
    LocalActionKind.definitionCreate ||
    LocalActionKind.definitionEdit ||
    LocalActionKind.definitionDelete ||
    LocalActionKind.definitionRestore => RecordKind.exercise,
    LocalActionKind.planCreate ||
    LocalActionKind.planEdit ||
    LocalActionKind.planClone ||
    LocalActionKind.planDelete ||
    LocalActionKind.planRestore ||
    LocalActionKind.planReorder => RecordKind.trainingDay,
    LocalActionKind.slotAdd ||
    LocalActionKind.slotRemove ||
    LocalActionKind.slotReplace ||
    LocalActionKind.slotReorder => RecordKind.trainingSlot,
    LocalActionKind.workoutFinish ||
    LocalActionKind.workoutReplace ||
    LocalActionKind.workoutEdit ||
    LocalActionKind.workoutDelete ||
    LocalActionKind.workoutRestore => RecordKind.workout,
    LocalActionKind.bodyweightRecord ||
    LocalActionKind.bodyweightEdit ||
    LocalActionKind.bodyweightDelete ||
    LocalActionKind.bodyweightRestore => RecordKind.bodyweight,
    _ => RecordKind.muscleTarget,
  };
}

final class LocalRef {
  const LocalRef(this.profileId, this.kind, this.id);
  final String profileId;
  final RecordKind kind;
  final String id;
  Map<String, Object?> toJson() => {
    'profile_id': profileId,
    'kind': kind.name,
    'id': id,
  };
}

/// Canonical source table names remain different from local logical kinds.
final class SourceOrigin {
  SourceOrigin({
    required this.profileId,
    required this.namespace,
    required this.sourceKind,
    required this.externalId,
  }) {
    if (namespace.isEmpty ||
        externalId.isEmpty ||
        !sourceKinds.contains(sourceKind)) {
      throw const FormatException('Explicit canonical source origin required');
    }
  }
  static const sourceKinds = {
    'exercises',
    'day_templates',
    'day_template_items',
    'sessions',
    'sets',
    'bodyweight_logs',
    'muscle_targets',
  };
  final String profileId, namespace, sourceKind, externalId;
  Map<String, Object?> toJson() => {
    'profile_id': profileId,
    'namespace': namespace,
    'source_kind': sourceKind,
    'external_id': externalId,
  };
}

final class OperationDependency {
  const OperationDependency(this.profileId, this.family, this.operationId);
  final String profileId, operationId;
  final GrantFamily family;
}

/// An immutable *local* command. No server revision, binding or acknowledgement
/// is inferred from localRevision. A future checked translation is a new attempt.
final class LocalAction {
  LocalAction({
    required this.operationId,
    required this.target,
    required this.action,
    required this.baseLocalRevision,
    required OperationInstant createdAt,
    required Map<String, Object?> input,
    this.semanticVersion = 1,
    this.eligibility = SyncEligibility.awaitingAttachment,
    this.origin,
    List<OperationDependency> dependencies = const [],
  }) : dependencies = List.unmodifiable(dependencies) {
    if (operationId.isEmpty ||
        target.id.isEmpty ||
        semanticVersion != 1 ||
        baseLocalRevision < 0 ||
        action.targetKind != target.kind) {
      throw const FormatException('Invalid typed local action');
    }
    if (origin != null && origin!.profileId != target.profileId) {
      throw const FormatException('Foreign origin');
    }
    for (final dep in dependencies) {
      if (dep.profileId != target.profileId ||
          dep.family != target.kind.family ||
          dep.operationId == operationId) {
        throw const FormatException('Foreign or cyclic operation dependency');
      }
    }
    _bytes = localBytes({
      'format': 'alkion-local-action/1',
      'operation_id': operationId,
      'target': target.toJson(),
      'action': action.name,
      'base_local_revision': baseLocalRevision,
      'semantic_version': semanticVersion,
      'eligibility': eligibility.name,
      'created_at': createdAt.text,
      'origin': origin?.toJson(),
      'input': input,
      'dependencies': [
        for (final dep in dependencies)
          {'family': dep.family.name, 'operation_id': dep.operationId},
      ],
    });
  }
  final String operationId;
  final LocalRef target;
  final LocalActionKind action;
  final int baseLocalRevision, semanticVersion;
  final SyncEligibility eligibility;
  final SourceOrigin? origin;
  final List<OperationDependency> dependencies;
  late final Uint8List _bytes;
  Uint8List get bytes => Uint8List.fromList(_bytes);
  String get hash => sha256.convert(_bytes).toString();
  GrantFamily get family => target.kind.family;
}

final class LocalActionResult {
  LocalActionResult(this.bytes, {this.replayed = false});
  final Uint8List bytes;
  final bool replayed;
}
