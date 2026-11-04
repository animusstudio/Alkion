import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../data/models.dart';
import '../catalog/catalog.dart';
import '../widgets/fit_label.dart';
import 'history_mapping.dart';
import '../transfer/reps_import_strings.dart';

class HistoryMappingScope extends InheritedWidget {
  const HistoryMappingScope({
    super.key,
    required this.mappings,
    required super.child,
  });
  final Map<String, HistoryMapping> mappings;
  static HistoryMapping? forExercise(BuildContext context, String id) => context
      .dependOnInheritedWidgetOfExactType<HistoryMappingScope>()
      ?.mappings[id];

  /// Presentation only: mapped source occurrences remain History records,
  /// while the catalog offers their canonical variants for new workouts.
  static List<Exercise> selectable(
    BuildContext context,
    List<Exercise> exercises, {
    required CatalogBundle? catalog,
  }) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<HistoryMappingScope>();
    if (catalog == null || scope == null || scope.mappings.isEmpty) {
      return exercises;
    }
    return exercises
        .where((exercise) {
          final mapping = scope.mappings[exercise.id];
          final target = catalog.variants[mapping?.variantId];
          return mapping == null ||
              !mapping.resolved ||
              target == null ||
              target.revision != mapping.variantRevision ||
              target.measurementProfileKey != mapping.measurementProfile;
        })
        .toList(growable: false);
  }

  @override
  bool updateShouldNotify(HistoryMappingScope oldWidget) =>
      !identical(mappings, oldWidget.mappings);
}

/// Review details shown when opening an imported exercise. Original names and
/// measurements remain unchanged; mapping is separate presentation metadata.
class HistoryMappingLabel extends StatelessWidget {
  const HistoryMappingLabel({super.key, required this.exerciseId});
  final String exerciseId;
  @override
  Widget build(BuildContext context) {
    final mapping = HistoryMappingScope.forExercise(context, exerciseId);
    if (mapping == null) return const SizedBox.shrink();
    final copy = RepsImportStrings.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: FitLabel(
        '${mapping.displayName == null ? '' : '${mapping.displayName} · '}${switch (mapping.status) {
          'exact' => copy.exact,
          'approximate' => copy.approximate,
          _ => copy.unresolved,
        }}\n${mapping.rationale}',
        maxLines: 12,
        style: WorkoutType.body(size: 12, color: context.tokens.dim),
      ),
    );
  }
}
