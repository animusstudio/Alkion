import '../catalog/catalog.dart';
import '../session/active_session_controller.dart';
import '../store/local_store.dart';
import 'body_workload.dart';
import 'body_workload_adapters.dart';
import 'body_workload_projection.dart';
import 'catalog_execution_repository.dart';
import 'day_template_repository.dart';
import 'exercise_repository.dart';
import 'models.dart';

/// Resolves every slot of [day] with [resolveSlot], so a null slot value
/// counts as the workout will build it. Only set counts and muscles matter
/// here: a slot whose reps are unavailable still has sets, and Start keeps its
/// own refusal. Null when a slot's exercise is missing from [exercisesById].
List<ResolvedSlot>? resolvePlannedDaySlots(
  DayTemplate day,
  Map<String, Exercise> exercisesById,
) {
  final slots = <ResolvedSlot>[];
  for (final slot in day.slots) {
    final exercise = exercisesById[slot.exerciseId];
    if (exercise == null) return null;
    slots.add(resolveSlot(slot, exercise));
  }
  return slots;
}

/// The planned working-set workload of one saved training day, under the same
/// fresh-session bounds as [plannedWorkoutWorkload]. A missing exercise or an
/// exceeded bound is unavailable, never zero counts.
WorkoutWorkload plannedDayWorkload(
  DayTemplate day,
  Map<String, Exercise> exercisesById,
  Map<String, CatalogMuscleResolution> resolutions,
) {
  final slots = resolvePlannedDaySlots(day, exercisesById);
  if (slots == null) {
    return WorkoutWorkload.unavailable(WorkoutWorkloadMode.planned);
  }
  try {
    return plannedWorkoutWorkload(
      slots,
      selections: [for (final slot in day.slots) slot.catalog],
      resolutions: resolutions,
    );
  } on FreshSessionLimitException {
    return WorkoutWorkload.unavailable(WorkoutWorkloadMode.planned);
  }
}

/// What planned workloads need from the store: every owned exercise and the
/// muscle resolution of every catalog selection the days use.
class PlanWorkloadInputs {
  const PlanWorkloadInputs({
    required this.exercisesById,
    required this.resolutions,
  });

  final Map<String, Exercise> exercisesById;
  final Map<String, CatalogMuscleResolution> resolutions;

  /// Reads the inputs for [days] once. Catalog selections resolve against the
  /// current assessment of [bundle], the policy Today uses. Throws when a read
  /// fails or the profile or store generation changes while reading; callers
  /// present that as unavailable, never as zero counts.
  static Future<PlanWorkloadInputs> load(
    LocalDatabase db,
    Iterable<DayTemplate> days,
    CatalogBundle? bundle,
  ) async {
    final token = db.token;
    final exercises = await ExerciseRepository.local(db).all();
    requireWorkloadToken(db, token);
    final resolutions = await CatalogExecutionRepository.local(db)
        .resolveMuscles(
          [
            for (final day in days)
              for (final slot in day.slots)
                if (slot.catalog case final selection?) selection,
          ],
          currentBundle: bundle,
          currentAssessment: true,
        );
    requireWorkloadToken(db, token);
    return PlanWorkloadInputs(
      exercisesById: {for (final exercise in exercises) exercise.id: exercise},
      resolutions: resolutions,
    );
  }

  /// [plannedDayWorkload] of [day] over these inputs.
  WorkoutWorkload dayWorkload(DayTemplate day) =>
      plannedDayWorkload(day, exercisesById, resolutions);
}
