import 'dart:async';
import 'package:flutter/foundation.dart';
import '../catalog/catalog.dart';
import '../domain/catalog_execution.dart';
import '../session/active_session_controller.dart';
import '../store/local_store.dart';
import 'body_workload.dart';
import 'body_workload_adapters.dart';
import 'catalog_execution_repository.dart';
import 'models.dart';

Map<String, CatalogMuscleResolution> recordedMuscleResolutions(
  Map<String, CatalogMuscleResolution> current,
) => {
  for (final e in current.entries)
    e.key: CatalogMuscleResolution(
      profile: e.value.currentAssessment
          ? e.value.recordedProfile
          : e.value.profile,
      reason: (e.value.recordedProfile ?? e.value.profile) == null
          ? e.value.reason
          : null,
    ),
};

class SavedWorkloadViews {
  const SavedWorkloadViews(this.recorded, this.current);
  final WorkoutWorkload recorded, current;
}

Future<SavedWorkloadViews> resolveSavedWorkloads({
  required LocalDatabase database,
  required List<LoggedSet> sets,
  required Map<String, Exercise> exercisesById,
  CatalogBundle? currentBundle,
}) async {
  final token = database.token;
  final resolutions = await CatalogExecutionRepository.local(database)
      .resolveMuscles(
        [
          for (final set in sets)
            if (set.catalog != null) set.catalog!.selection,
        ],
        currentBundle: currentBundle,
        currentAssessment: true,
      );
  requireWorkloadToken(database, token);
  return SavedWorkloadViews(
    savedWorkoutWorkload(
      sets: sets,
      exercisesById: exercisesById,
      resolutions: recordedMuscleResolutions(resolutions),
    ),
    savedWorkoutWorkload(
      sets: sets,
      exercisesById: exercisesById,
      resolutions: resolutions,
    ),
  );
}

void requireWorkloadToken(LocalDatabase database, StoreToken token) {
  if (database.token.profileId != token.profileId ||
      database.token.generation != token.generation) {
    throw const StoreException('stale_workload_projection');
  }
}

/// Owns only ephemeral, profile-bound resolution results. Every recomputation
/// uses the current draft while pins remain the draft's frozen selections.
class ActiveWorkloadProjection extends ChangeNotifier {
  ActiveWorkloadProjection(this.controller, this.database)
    : _token = database?.token {
    controller.addListener(_refresh);
    _refresh();
  }
  final ActiveSessionController controller;
  final LocalDatabase? database;
  final StoreToken? _token;
  Map<String, CatalogMuscleResolution> _resolutions = {};
  Set<String>? _keys;
  int _epoch = 0;
  bool _disposed = false;
  WorkoutWorkload workload = WorkoutWorkload.loading(
    WorkoutWorkloadMode.active,
  );
  void _refresh() {
    final draft = controller.draftOrNull;
    if (draft == null) return;
    if (database != null) {
      try {
        requireWorkloadToken(database!, _token!);
      } catch (_) {
        _epoch++;
        workload = WorkoutWorkload.unavailable(WorkoutWorkloadMode.active);
        notifyListeners();
        return;
      }
    }
    final selections = <String, CatalogSelectionEvidence>{
      for (final block in draft.blocks) ...{
        if (block.catalogSelection != null)
          block.catalogSelection!.muscleResolutionKey: block.catalogSelection!,
        for (final set in [...block.warmupSets, ...block.workingSets])
          if (set.catalog != null)
            set.catalog!.selection.muscleResolutionKey: set.catalog!.selection,
      },
    };
    final keys = selections.keys.toSet();
    if (_keys != null && setEquals(_keys, keys)) {
      if (workload.availability == WorkloadAvailability.ready) {
        workload = activeWorkoutWorkload(draft, resolutions: _resolutions);
        notifyListeners();
      }
      return;
    }
    _keys = keys;
    final epoch = ++_epoch;
    if (keys.isEmpty || database == null) {
      workload = activeWorkoutWorkload(draft);
      notifyListeners();
      return;
    }
    workload = WorkoutWorkload.loading(WorkoutWorkloadMode.active);
    notifyListeners();
    unawaited(() async {
      try {
        final results = await CatalogExecutionRepository.local(
          database!,
        ).resolveMuscles(selections.values.toList());
        requireWorkloadToken(database!, _token!);
        if (_disposed || epoch != _epoch || controller.draftOrNull == null) {
          return;
        }
        _resolutions = results;
        workload = activeWorkoutWorkload(
          controller.draft,
          resolutions: results,
        );
      } catch (_) {
        if (_disposed || epoch != _epoch) return;
        workload = WorkoutWorkload.unavailable(WorkoutWorkloadMode.active);
      }
      notifyListeners();
    }());
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    controller.removeListener(_refresh);
    super.dispose();
  }
}
