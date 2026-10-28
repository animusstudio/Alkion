/// Renderer-independent canonical IDs, matching `kMuscleLabels` exactly.
/// Both sides of a rendered region consume the same aggregate value.
enum WorkloadMuscle {
  chest,
  back,
  shoulders,
  quads,
  hamstrings,
  calves,
  biceps,
  triceps;

  static WorkloadMuscle? fromKey(String? key) {
    for (final muscle in values) {
      if (muscle.name == key) return muscle;
    }
    return null;
  }
}

enum WorkoutWorkloadMode { planned, active, saved }

enum WorkloadAvailability { ready, loading, unavailable }

enum WorkloadCoverageStatus { empty, complete, partial, unmapped }

/// Only set membership and completion affect workload. Unknown warmup evidence
/// stays null; compatibility display fallbacks must not classify it as working.
class WorkloadSetInput {
  const WorkloadSetInput({
    required this.completed,
    required this.isWarmup,
    this.deleted = false,
  });

  final bool completed;
  final bool? isWarmup;
  final bool deleted;
}

class WorkloadExerciseInput {
  const WorkloadExerciseInput({required this.muscleGroup, required this.sets});

  final String? muscleGroup;
  final Iterable<WorkloadSetInput> sets;
}

class MuscleWorkload {
  const MuscleWorkload({required this.count, required this.score});

  final int count;

  /// Relative set volume in this workout, never physiological intensity.
  final double score;
}

class WorkloadCoverage {
  const WorkloadCoverage({
    required this.status,
    required this.mappedSets,
    required this.unmappedSets,
    required this.unknownKindSets,
    required this.warmupSets,
    required this.pendingSets,
    required this.deletedSets,
  });

  final WorkloadCoverageStatus status;
  final int mappedSets;
  final int unmappedSets;
  final int unknownKindSets;
  final int warmupSets;
  final int pendingSets;
  final int deletedSets;
}

/// A ready projection always contains all eight regions. Loading and failed
/// reads have no values or coverage, so they cannot masquerade as empty success.
class WorkoutWorkload {
  WorkoutWorkload._({
    required this.mode,
    required this.availability,
    required Map<WorkloadMuscle, MuscleWorkload> muscles,
    required this.coverage,
  }) : muscles = Map.unmodifiable(muscles);

  factory WorkoutWorkload.loading(WorkoutWorkloadMode mode) =>
      WorkoutWorkload._(
        mode: mode,
        availability: WorkloadAvailability.loading,
        muscles: const {},
        coverage: null,
      );

  factory WorkoutWorkload.unavailable(WorkoutWorkloadMode mode) =>
      WorkoutWorkload._(
        mode: mode,
        availability: WorkloadAvailability.unavailable,
        muscles: const {},
        coverage: null,
      );

  final WorkoutWorkloadMode mode;
  final WorkloadAvailability availability;
  final Map<WorkloadMuscle, MuscleWorkload> muscles;
  final WorkloadCoverage? coverage;
}

/// Counts working sets by exact canonical exercise key. Planned projections
/// include pending working sets; active/saved projections require completion.
/// The caller passes the current authoritative snapshot on each recomputation.
WorkoutWorkload calculateWorkoutWorkload({
  required WorkoutWorkloadMode mode,
  required Iterable<WorkloadExerciseInput> exercises,
}) {
  final counts = {for (final muscle in WorkloadMuscle.values) muscle: 0};
  var mapped = 0;
  var unmapped = 0;
  var unknownKind = 0;
  var warmup = 0;
  var pending = 0;
  var deleted = 0;
  for (final exercise in exercises) {
    final muscle = WorkloadMuscle.fromKey(exercise.muscleGroup);
    for (final set in exercise.sets) {
      if (set.deleted) {
        deleted++;
      } else if (mode != WorkoutWorkloadMode.planned && !set.completed) {
        pending++;
      } else if (set.isWarmup == null) {
        unknownKind++;
      } else if (set.isWarmup!) {
        warmup++;
      } else if (muscle == null) {
        unmapped++;
      } else {
        counts[muscle] = counts[muscle]! + 1;
        mapped++;
      }
    }
  }
  final maxCount = counts.values.fold(0, (a, b) => a > b ? a : b);
  final status = mapped + unmapped + unknownKind == 0
      ? WorkloadCoverageStatus.empty
      : unmapped + unknownKind == 0
      ? WorkloadCoverageStatus.complete
      : mapped > 0
      ? WorkloadCoverageStatus.partial
      : WorkloadCoverageStatus.unmapped;
  return WorkoutWorkload._(
    mode: mode,
    availability: WorkloadAvailability.ready,
    muscles: {
      for (final entry in counts.entries)
        entry.key: MuscleWorkload(
          count: entry.value,
          score: maxCount == 0 ? 0 : entry.value / maxCount,
        ),
    },
    coverage: WorkloadCoverage(
      status: status,
      mappedSets: mapped,
      unmappedSets: unmapped,
      unknownKindSets: unknownKind,
      warmupSets: warmup,
      pendingSets: pending,
      deletedSets: deleted,
    ),
  );
}
