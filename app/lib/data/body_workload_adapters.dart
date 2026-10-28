import '../session/active_session_controller.dart';
import 'body_workload.dart';
import 'models.dart';

/// Uses resolved counts for the selected day, including exercise overrides.
/// Preflights the fresh-session limits before generating any set inputs. Invalid
/// prescriptions throw [FreshSessionLimitException] and need explicit correction;
/// callers must present an unavailable projection rather than empty success.
WorkoutWorkload plannedWorkoutWorkload(Iterable<ResolvedSlot> slots) {
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
    exercises: boundedSlots.map(
      (slot) => WorkloadExerciseInput(
        muscleGroup: slot.exercise.muscleGroup,
        sets: Iterable.generate(
          slot.workSets,
          (_) => const WorkloadSetInput(completed: false, isWarmup: false),
        ),
      ),
    ),
  );
}

/// Takes the controller's current draft; no cached totals or planned targets.
/// Reinvoke after completion, undo, add/remove, edits or resume.
WorkoutWorkload activeWorkoutWorkload(SessionDraft draft) =>
    calculateWorkoutWorkload(
      mode: WorkoutWorkloadMode.active,
      exercises: draft.blocks.map(
        (block) => WorkloadExerciseInput(
          muscleGroup: block.exercise.muscleGroup,
          sets: block.workingSets.map(
            (set) => WorkloadSetInput(
              completed: set.done,
              isWarmup: _warmupEvidence(set.isWarmup, set.rawFields),
              deleted: _deleted(set.rawFields),
            ),
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
}) => calculateWorkoutWorkload(
  mode: WorkoutWorkloadMode.saved,
  exercises: sets.map(
    (set) => WorkloadExerciseInput(
      muscleGroup: exercisesById[set.exerciseId]?.muscleGroup,
      sets: [
        WorkloadSetInput(
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
