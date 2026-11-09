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

/// The planned working sets of one rotation of the split: every active day of
/// [days] counted once, warm-ups excluded. Inactive days and days whose active
/// flag is unknown add nothing. Each day keeps its own fresh-session bounds
/// (see [plannedSlotWorkloadInputs]), and the whole split is one calculation in
/// which every set is a distinct physical set `split:<day id>:<slot>:<set>`,
/// so a region's count is the number of planned sets touching it. A missing
/// exercise or an exceeded bound on any active day makes the whole split
/// unavailable, never zero counts.
WorkoutWorkload plannedSplitWorkload(
  Iterable<DayTemplate> days,
  Map<String, Exercise> exercisesById,
  Map<String, CatalogMuscleResolution> resolutions,
) {
  final inputs = <WorkloadExerciseInput>[];
  for (final day in days) {
    if (!day.isActive) continue;
    final slots = resolvePlannedDaySlots(day, exercisesById);
    if (slots == null) {
      return WorkoutWorkload.unavailable(WorkoutWorkloadMode.planned);
    }
    try {
      inputs.addAll(
        plannedSlotWorkloadInputs(
          slots,
          selections: [for (final slot in day.slots) slot.catalog],
          resolutions: resolutions,
          physicalId: (slot, set) => 'split:${day.id}:$slot:$set',
        ),
      );
    } on FreshSessionLimitException {
      return WorkoutWorkload.unavailable(WorkoutWorkloadMode.planned);
    }
  }
  return calculateWorkoutWorkload(
    mode: WorkoutWorkloadMode.planned,
    exercises: inputs,
  );
}

/// What one rotation of the split spans.
class SplitBasis {
  const SplitBasis({required this.perWeek, required this.activeDays});

  /// True only when one rotation is provably one week: at least one active
  /// day, and every active day has its own scheduled weekday (0 to 6, no two
  /// equal). Otherwise the next day is picked by rotation and no weekly
  /// frequency is claimed.
  final bool perWeek;

  /// The number of active days in one rotation.
  final int activeDays;

  @override
  bool operator ==(Object other) =>
      other is SplitBasis &&
      other.perWeek == perWeek &&
      other.activeDays == activeDays;

  @override
  int get hashCode => Object.hash(perWeek, activeDays);

  @override
  String toString() => 'SplitBasis(perWeek: $perWeek, activeDays: $activeDays)';
}

/// The basis of [plannedSplitWorkload] over the same [days]: per week only when
/// every active day has a distinct scheduled weekday, per rotation otherwise.
SplitBasis splitBasis(Iterable<DayTemplate> days) {
  final weekdays = <int>{};
  final seen = <String>{};
  var activeDays = 0;
  var distinct = true;
  for (final day in days) {
    // A day passed twice counts once, as in the workload.
    if (!day.isActive || !seen.add(day.id)) continue;
    activeDays++;
    final weekday = day.scheduledWeekday;
    if (weekday == null ||
        weekday < 0 ||
        weekday > 6 ||
        !weekdays.add(weekday)) {
      distinct = false;
    }
  }
  return SplitBasis(
    perWeek: distinct && activeDays > 0,
    activeDays: activeDays,
  );
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

  /// [plannedSplitWorkload] of [days] over these inputs.
  WorkoutWorkload splitWorkload(Iterable<DayTemplate> days) =>
      plannedSplitWorkload(days, exercisesById, resolutions);
}
