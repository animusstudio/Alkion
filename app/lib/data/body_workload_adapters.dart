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
}) => calculateWorkoutWorkload(
  mode: WorkoutWorkloadMode.planned,
  exercises: plannedSlotWorkloadInputs(
    slots,
    selections: selections,
    resolutions: resolutions,
    physicalId: (slot, set) => 'planned:$slot:$set',
  ),
);

/// The working-set inputs of one planned workout, under the fresh-session
/// limits a new session from these slots would meet: at most
/// [freshTemplateSlotLimit] slots, 1 to 99 working and 0 to 99 warm-up sets per
/// slot, and [freshGeneratedSetLimit] generated sets in total. Every slot is
/// checked before any input is returned; a violation throws
/// [FreshSessionLimitException]. Warm-ups count toward the bounds only and are
/// never inputs. [physicalId] names set `set` of slot `slot` (both 0-based);
/// it must be distinct for every set the caller passes to one calculation.
List<WorkloadExerciseInput> plannedSlotWorkloadInputs(
  Iterable<ResolvedSlot> slots, {
  required String Function(int slot, int set) physicalId,
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
  return [
    for (final (index, slot) in boundedSlots.indexed)
      WorkloadExerciseInput(
        catalogBacked:
            (index < selections.length && selections[index] != null) ||
            slot.exercise.executionDefinition != null,
        resolution: index < selections.length
            ? resolutions[selections[index]?.muscleResolutionKey]
            : null,
        muscleGroup: slot.exercise.muscleGroup,
        sets: Iterable.generate(
          slot.workSets,
          (set) => WorkloadSetInput(
            physicalId: physicalId(index, set),
            completed: false,
            isWarmup: false,
          ),
        ),
      ),
  ];
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
