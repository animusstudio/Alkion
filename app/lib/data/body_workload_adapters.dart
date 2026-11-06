import '../session/active_session_controller.dart';
import '../domain/catalog_execution.dart';
import 'catalog_execution_repository.dart';
import 'body_workload.dart';
import 'models.dart';

/// Uses resolved counts for the selected day, including exercise overrides.
/// Preflights the fresh-session limits before generating any set inputs. Invalid
/// prescriptions throw [FreshSessionLimitException] and need explicit correction;
/// callers must present an unavailable projection rather than empty success.
WorkoutWorkload plannedWorkoutWorkload(
  Iterable<ResolvedSlot> slots, {
  List<CatalogSelectionEvidence?> selections = const [],
  Map<String, CatalogMuscleResolution> resolutions = const {},
}) {
  final boundedSlots = <ResolvedSlot>[];
  var remaining = freshGeneratedSetLimit;
  for (final slot in slots) {
    if (boundedSlots.length == freshTemplateSlotLimit) {
      throw FreshSessionLimitException(
        FreshSessionLimit.templateSlots,
        count: boundedSlots.length + 1,
      );
    }
    if (slot.workSets < 1 || slot.workSets > 99) {
      throw FreshSessionLimitException(
        FreshSessionLimit.workingSets,
        count: slot.workSets,
        exerciseName: slot.exercise.name,
      );
    }
    if (slot.warmupSets < 0 || slot.warmupSets > 99) {
      throw FreshSessionLimitException(
        FreshSessionLimit.warmupSets,
        count: slot.warmupSets,
        exerciseName: slot.exercise.name,
      );
    }
    if (slot.workSets > remaining ||
        slot.warmupSets > remaining - slot.workSets) {
      throw FreshSessionLimitException(
        FreshSessionLimit.generatedSets,
        exerciseName: slot.exercise.name,
      );
    }
    remaining -= slot.workSets + slot.warmupSets;
    boundedSlots.add(slot);
  }
  return calculateWorkoutWorkload(
    mode: WorkoutWorkloadMode.planned,
    exercises: boundedSlots.indexed.map(
      (entry) => WorkloadExerciseInput(
        catalogBacked:
            (entry.$1 < selections.length && selections[entry.$1] != null) ||
            entry.$2.exercise.executionDefinition != null,
        resolution: entry.$1 < selections.length
            ? resolutions[selections[entry.$1]?.muscleResolutionKey]
            : null,
        muscleGroup: entry.$2.exercise.muscleGroup,
        sets: Iterable.generate(
          entry.$2.workSets,
          (index) => WorkloadSetInput(
            physicalId: 'planned:${entry.$1}:$index',
            completed: false,
            isWarmup: false,
          ),
        ),
      ),
    ),
  );
}

/// Takes the controller's current draft; no cached totals or planned targets.
/// Reinvoke after completion, undo, add/remove, edits or resume.
WorkoutWorkload activeWorkoutWorkload(
  SessionDraft draft, {
  Map<String, CatalogMuscleResolution> resolutions = const {},
}) => calculateWorkoutWorkload(
  mode: WorkoutWorkloadMode.active,
  exercises: draft.blocks.expand(
    (block) => [...block.warmupSets, ...block.workingSets].map(
      (set) => WorkloadExerciseInput(
        muscleGroup: block.exercise.muscleGroup,
        catalogBacked: set.catalog != null || block.catalogSelection != null,
        resolution:
            resolutions[(set.catalog?.selection ?? block.catalogSelection)
                ?.muscleResolutionKey],
        sets: [
          WorkloadSetInput(
            physicalId: '${draft.sessionId}:${set.id}',
            completed: set.done,
            isWarmup: _warmupEvidence(set.isWarmup, set.rawFields),
            deleted: _deleted(set.rawFields),
          ),
        ],
      ),
    ),
  ),
);

/// Project one saved workout's current sets and exercise metadata, obtained by
/// the caller. A missing exercise remains explicitly unmapped. Read errors must
/// be presented with [WorkoutWorkload.unavailable], never an empty input list.
WorkoutWorkload savedWorkoutWorkload({
  required Iterable<LoggedSet> sets,
  required Map<String, Exercise> exercisesById,
  Map<String, CatalogMuscleResolution> resolutions = const {},
}) => calculateWorkoutWorkload(
  mode: WorkoutWorkloadMode.saved,
  exercises: sets.map(
    (set) => WorkloadExerciseInput(
      muscleGroup: exercisesById[set.exerciseId]?.muscleGroup,
      catalogBacked:
          set.catalog != null ||
          exercisesById[set.exerciseId]?.executionDefinition != null,
      resolution: resolutions[set.catalog?.selection.muscleResolutionKey],
      sets: [
        WorkloadSetInput(
          physicalId: set.id,
          completed: true,
          isWarmup: _warmupEvidence(set.isWarmup, set.rawFields),
          deleted: _deleted(set.rawFields),
        ),
      ],
    ),
  ),
);

bool _deleted(Map<String, Object?> raw) =>
    raw['deleted'] is int && raw['deleted'] != 0;

bool? _warmupEvidence(bool value, Map<String, Object?> raw) {
  if (raw.isEmpty) return value; // Native typed sets without imported evidence.
  final original = raw['is_warmup'];
  return original is int ? original != 0 : null;
}
