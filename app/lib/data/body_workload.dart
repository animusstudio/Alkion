import '../catalog/catalog.dart';
import 'catalog_execution_repository.dart';

/// Surface regions are independent of catalog browsing and legacy DB groups.
/// Front/back and both sides consume one aggregate physical-set count.
enum WorkloadMuscle {
  chest,
  back,
  shoulders,
  quads,
  hamstrings,
  calves,
  biceps,
  triceps,
  glutes,
  core,
  forearms,
  adductors,
  abductors;

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

/// Fixed labelled bins; score is only the renderer's discrete color input.
const workloadCountBins = ['0', '1', '2–3', '4–6', '7–10', '11+'];
double workloadCountScore(int count) => switch (count) {
  <= 0 => 0,
  1 => .2,
  <= 3 => .4,
  <= 6 => .6,
  <= 10 => .8,
  _ => 1,
};

class WorkloadSetInput {
  const WorkloadSetInput({
    required this.completed,
    required this.isWarmup,
    this.physicalId,
    this.deleted = false,
  });
  final String? physicalId;
  final bool completed;
  final bool? isWarmup;
  final bool deleted;
}

class WorkloadExerciseInput {
  const WorkloadExerciseInput({
    required this.muscleGroup,
    required this.sets,
    this.catalogBacked = false,
    this.resolution,
  });
  final String? muscleGroup;
  final Iterable<WorkloadSetInput> sets;
  final bool catalogBacked;
  final CatalogMuscleResolution? resolution;
}

class MuscleWorkload {
  const MuscleWorkload({required this.count, required this.score});
  final int count;

  /// Discrete fixed set-count bin, never activation or physiological intensity.
  final double score;
}

class WorkloadAnatomyCount {
  WorkloadAnatomyCount({
    required this.id,
    required this.names,
    required this.kind,
    required this.role,
    required this.count,
    required this.mappedRegions,
    this.unmappedReason,
  });
  final String id;
  final Map<String, String> names;
  final CatalogMuscleKind kind;
  final CatalogMuscleRole? role;
  final int count;
  final Set<WorkloadMuscle> mappedRegions;
  final String? unmappedReason;
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
    this.eligibleSets = 0,
    this.catalogSets = 0,
    this.partialProfileSets = 0,
    this.unknownProfileSets = 0,
    this.legacySets = 0,
    this.unmappedAnatomySets = 0,
    this.sideUnspecifiedSets = 0,
  });
  final WorkloadCoverageStatus status;
  final int mappedSets,
      unmappedSets,
      unknownKindSets,
      warmupSets,
      pendingSets,
      deletedSets,
      eligibleSets,
      catalogSets,
      partialProfileSets,
      unknownProfileSets,
      legacySets,
      unmappedAnatomySets,
      sideUnspecifiedSets;
}

/// An immutable projection. Counts across roles/regions are non-additive.
class WorkoutWorkload {
  WorkoutWorkload._({
    required this.mode,
    required this.availability,
    required Map<WorkloadMuscle, MuscleWorkload> muscles,
    required this.coverage,
    this.anatomy = const [],
    this.profiles = const [],
    Map<String, Map<WorkloadMuscle, MuscleWorkload>> regions = const {},
    this.legacyMuscles = const {},
  }) : muscles = Map.unmodifiable(muscles),
       _regions = Map.unmodifiable(regions);
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
  final Map<WorkloadMuscle, MuscleWorkload> muscles, legacyMuscles;
  final WorkloadCoverage? coverage;
  final List<WorkloadAnatomyCount> anatomy;
  final List<CatalogMuscleResolution> profiles;
  final Map<String, Map<WorkloadMuscle, MuscleWorkload>> _regions;
  Map<WorkloadMuscle, MuscleWorkload> regionCounts({
    CatalogMuscleKind kind = CatalogMuscleKind.strength,
    CatalogMuscleRole? role,
    bool legacy = false,
  }) =>
      legacy ? legacyMuscles : _regions[_countKey(kind, role)] ?? _zeroCounts();
}

String _countKey(CatalogMuscleKind kind, CatalogMuscleRole? role) =>
    '${kind.name}:${role?.name ?? 'all'}';
Map<WorkloadMuscle, MuscleWorkload> _zeroCounts() => Map.unmodifiable({
  for (final m in WorkloadMuscle.values)
    m: const MuscleWorkload(count: 0, score: 0),
});
Map<WorkloadMuscle, MuscleWorkload> _counts(
  Map<WorkloadMuscle, Set<String>> ids,
) => Map.unmodifiable({
  for (final m in WorkloadMuscle.values)
    m: MuscleWorkload(
      count: ids[m]?.length ?? 0,
      score: workloadCountScore(ids[m]?.length ?? 0),
    ),
});

/// Only retained semantic rows authorize a surface. No parent/child expansion,
/// anatomy-name guessing or current-map fallback is performed here.
Set<WorkloadMuscle> _mappedRegions(CatalogMuscleProfile profile, String node) {
  final declared = {for (final r in profile.regions) r['id'] as String: r};
  return {
    for (final mapping in profile.mappings.where(
      (m) => m.anatomyNodeId == node,
    ))
      for (final region in mapping.regionIds)
        if (declared.containsKey(region) &&
            WorkloadMuscle.fromKey(region) != null)
          WorkloadMuscle.fromKey(region)!,
  };
}

WorkoutWorkload calculateWorkoutWorkload({
  required WorkoutWorkloadMode mode,
  required Iterable<WorkloadExerciseInput> exercises,
}) {
  final regionIds = <String, Map<WorkloadMuscle, Set<String>>>{};
  final legacyIds = <WorkloadMuscle, Set<String>>{};
  final nodeIds = <String, Set<String>>{};
  final nodeRows = <String, WorkloadAnatomyCount>{};
  final profiles = <String, CatalogMuscleResolution>{};
  final eligible = <String>{},
      mapped = <String>{},
      unmapped = <String>{},
      unknownKind = <String>{},
      warmup = <String>{},
      pending = <String>{},
      deleted = <String>{},
      catalog = <String>{},
      partial = <String>{},
      unknownProfile = <String>{},
      legacy = <String>{},
      unmappedAnatomy = <String>{},
      unspecified = <String>{};
  var synthetic = 0;
  // Reconcile repeated observations of a physical set before classification.
  // Exclusion precedence is preserved even when duplicates arrive out of order.
  final observations =
      <String, ({WorkloadExerciseInput exercise, WorkloadSetInput set})>{};
  for (final exercise in exercises) {
    for (final set in exercise.sets) {
      final id = set.physicalId ?? 'input:${synthetic++}';
      final old = observations[id];
      int exclusion(WorkloadSetInput s) => s.deleted
          ? 4
          : mode != WorkoutWorkloadMode.planned && !s.completed
          ? 3
          : s.isWarmup == null
          ? 2
          : s.isWarmup!
          ? 1
          : 0;
      if (old == null || exclusion(set) > exclusion(old.set)) {
        observations[id] = (exercise: exercise, set: set);
      }
    }
  }
  for (final entry in observations.entries) {
    final id = entry.key,
        exercise = entry.value.exercise,
        set = entry.value.set;
    if (set.deleted) {
      deleted.add(id);
      continue;
    }
    if (mode != WorkoutWorkloadMode.planned && !set.completed) {
      pending.add(id);
      continue;
    }
    if (set.isWarmup == null) {
      unknownKind.add(id);
      continue;
    }
    if (set.isWarmup!) {
      warmup.add(id);
      continue;
    }
    eligible.add(id);
    if (!exercise.catalogBacked) {
      final muscle = WorkloadMuscle.fromKey(exercise.muscleGroup);
      // Only original legacy DB groups are coarse attribution evidence.
      if (muscle != null && muscle.index < 8) {
        legacy.add(id);
        mapped.add(id);
        (legacyIds[muscle] ??= {}).add(id);
      } else {
        unmapped.add(id);
      }
      continue;
    }
    catalog.add(id);
    final resolution = exercise.resolution;
    final profile = resolution?.profile;
    if (resolution != null) {
      final recorded = resolution.recordedProfile;
      final key =
          '${profile?.sourceBundleDigest}:${profile?.id}:${profile?.revision}:${recorded?.sourceBundleDigest}:${recorded?.id}:${recorded?.revision}:${resolution.reason}:${resolution.currentAssessment}';
      profiles[key] = resolution;
    }
    if (profile == null) {
      unknownProfile.add(id);
      unmapped.add(id);
      continue;
    }
    if (profile.coverage == 'partial') {
      partial.add(id);
    }
    if (profile.coverage == 'unknown') {
      unknownProfile.add(id);
    }
    if (profile.profile['side_scope'] == 'unspecified' ||
        profile.profile['side_scope'] == null) {
      unspecified.add(id);
    }
    var surface = false;
    for (final relationship in profile.relationships) {
      final regions = _mappedRegions(profile, relationship.anatomyNodeId);
      if (regions.isEmpty) unmappedAnatomy.add(id);
      for (final role in <CatalogMuscleRole?>{null, relationship.role}) {
        final key = _countKey(relationship.kind, role);
        final byRegion = regionIds[key] ??= {};
        for (final region in regions) {
          (byRegion[region] ??= {}).add(id);
          surface = true;
        }
      }
      final nodeKey =
          '${profile.sourceNamespace}:${profile.anatomyRevision}:${relationship.anatomyNodeId}:${relationship.kind.name}:${relationship.role?.name}';
      (nodeIds[nodeKey] ??= {}).add(id);
      final previous = nodeRows[nodeKey];
      nodeRows[nodeKey] = WorkloadAnatomyCount(
        id: relationship.anatomyNodeId,
        names: profile.anatomy[relationship.anatomyNodeId]?.names ?? const {},
        kind: relationship.kind,
        role: relationship.role,
        count: 0,
        mappedRegions: Set.unmodifiable({
          ...?previous?.mappedRegions,
          ...regions,
        }),
        unmappedReason: regions.isEmpty
            ? 'semantic_surface_unavailable'
            : previous?.unmappedReason,
      );
    }
    if (surface) {
      mapped.add(id);
    } else {
      unmapped.add(id);
    }
  }
  final status = eligible.isEmpty && unknownKind.isEmpty
      ? WorkloadCoverageStatus.empty
      : unmapped.isEmpty &&
            unknownKind.isEmpty &&
            partial.isEmpty &&
            unknownProfile.isEmpty &&
            unmappedAnatomy.isEmpty
      ? WorkloadCoverageStatus.complete
      : mapped.isNotEmpty
      ? WorkloadCoverageStatus.partial
      : WorkloadCoverageStatus.unmapped;
  final regions = {
    for (final entry in regionIds.entries) entry.key: _counts(entry.value),
  };
  return WorkoutWorkload._(
    mode: mode,
    availability: WorkloadAvailability.ready,
    muscles:
        regions[_countKey(CatalogMuscleKind.strength, null)] ?? _zeroCounts(),
    legacyMuscles: _counts(legacyIds),
    regions: regions,
    profiles: List.unmodifiable(profiles.values),
    anatomy: List.unmodifiable([
      for (final entry in nodeRows.entries)
        WorkloadAnatomyCount(
          id: entry.value.id,
          names: entry.value.names,
          kind: entry.value.kind,
          role: entry.value.role,
          count: nodeIds[entry.key]!.length,
          mappedRegions: entry.value.mappedRegions,
          unmappedReason: entry.value.unmappedReason,
        ),
    ]),
    coverage: WorkloadCoverage(
      status: status,
      mappedSets: mapped.length,
      unmappedSets: unmapped.length,
      unknownKindSets: unknownKind.length,
      warmupSets: warmup.length,
      pendingSets: pending.length,
      deletedSets: deleted.length,
      eligibleSets: eligible.length,
      catalogSets: catalog.length,
      partialProfileSets: partial.length,
      unknownProfileSets: unknownProfile.length,
      legacySets: legacy.length,
      unmappedAnatomySets: unmappedAnatomy.length,
      sideUnspecifiedSets: unspecified.length,
    ),
  );
}
