import 'package:provider/provider.dart';
import '../catalog_ui/catalog_picker.dart';
import '../catalog_ui/catalog_trial_scope.dart';
import '../data/exercise_repository.dart';
import '../store/local_store.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';

/// Shows a modal bottom sheet that lets the user search and pick an exercise.
///
/// Returns the selected [Exercise], or null if dismissed.
///
/// Visual spec: `docs/design_handoff_workout_tracker/design/app/screen-log.jsx`
/// `ExerciseSheet`.
///
/// Layout:
/// - Search field at the top.
/// - Exercises grouped by muscle (alphabetical within each group).
/// - A compound dot indicator next to compound exercises.
/// - Tap to select and dismiss.
Future<Exercise?> showExercisePicker(
  BuildContext context, {
  required List<Exercise> exercises,
  ValueChanged<CatalogChoice>? onCatalogChoice,
}) async {
  final trial = CatalogTrialScope.maybeOf(context);
  if (trial != null) {
    final locale = Localizations.localeOf(context).languageCode;
    final repo = ExerciseRepository.local(context.read<LocalDatabase>());
    final picked = await showCatalogPicker(context, state: trial);
    if (picked == null || picked.isEmpty) return null;
    onCatalogChoice?.call(picked.single);
    try {
      return await trial.materialize(picked.single, repo, locale: locale);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).catalogSaveFailed),
          ),
        );
      }
      return null;
    }
  }
  return showModalBottomSheet<Exercise>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: context.tokens.overlay,
    useSafeArea: true,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (_) => _ExercisePickerSheet(exercises: exercises),
  );
}

class _ExercisePickerSheet extends StatefulWidget {
  const _ExercisePickerSheet({required this.exercises});

  final List<Exercise> exercises;

  @override
  State<_ExercisePickerSheet> createState() => _ExercisePickerSheetState();
}

class _ExercisePickerSheetState extends State<_ExercisePickerSheet> {
  String _query = '';
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Exercise> get _filtered {
    if (_query.isEmpty) {
      return widget.exercises;
    }
    final q = _query.toLowerCase();
    return widget.exercises
        .where(
          (e) =>
              e.name.toLowerCase().contains(q) ||
              e.muscleGroup.toLowerCase().contains(q),
        )
        .toList();
  }

  /// Group exercises by muscle group, preserving insertion order.
  /// Exercises with no muscle group fall under [otherLabel].
  Map<String, List<Exercise>> _group(
    List<Exercise> exercises,
    String otherLabel,
  ) {
    final result = <String, List<Exercise>>{};
    for (final ex in exercises) {
      final key = ex.muscleGroup.isEmpty ? otherLabel : ex.muscleGroup;
      (result[key] ??= []).add(ex);
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final filtered = _filtered;
    final grouped = _group(filtered, l.sessionOtherMuscle);
    final muscles = grouped.keys.toList()..sort();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) {
          return Container(
            decoration: BoxDecoration(
              color: tokens.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadius.sheet),
              ),
            ),
            child: Column(
              children: [
                // ── Drag handle ──────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 6),
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: tokens.lineStrong,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // ── Title ────────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: FitLabel(
                          l.sessionAddExercise,
                          maxLines: 2,
                          style: WorkoutType.display(
                            size: 22,
                            weight: FontWeight.w500,
                            color: tokens.text,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonTooltip,
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        icon: Icon(Icons.close, size: 20, color: tokens.dim),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // ── Search field ─────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 48),
                    decoration: BoxDecoration(
                      color: tokens.sunken,
                      borderRadius: BorderRadius.circular(AppRadius.control),
                      border: Border.all(color: tokens.line),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: 12),
                        Icon(WIcons.search, size: 16, color: tokens.faint),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            autofocus: false,
                            style: WorkoutType.body(
                              size: 14,
                              color: tokens.text,
                            ),
                            decoration: InputDecoration(
                              hintText: l.sessionSearchExercises,
                              filled: true,
                              fillColor: tokens.sunken,
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadius.control,
                                ),
                                borderSide: BorderSide(
                                  color: tokens.focus,
                                  width: 2,
                                ),
                              ),
                              hintStyle: WorkoutType.body(
                                size: 14,
                                color: tokens.faint,
                              ),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 12,
                              ),
                            ),
                            onChanged: (v) => setState(() => _query = v),
                          ),
                        ),
                        if (_query.isNotEmpty)
                          IconButton(
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).clearButtonTooltip,
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                            icon: Icon(
                              Icons.close,
                              size: 20,
                              color: tokens.dim,
                            ),
                          ),
                        const SizedBox(width: 12),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // ── Exercise list ────────────────────────────────────────
                Expanded(
                  child: filtered.isEmpty
                      ? _EmptyState(tokens: tokens)
                      : ListView.builder(
                          controller: scrollController,
                          padding: EdgeInsets.only(
                            bottom:
                                24 + MediaQuery.viewPaddingOf(context).bottom,
                          ),
                          itemCount: muscles.fold<int>(
                            0,
                            (n, m) => n + 1 + grouped[m]!.length,
                          ),
                          itemBuilder: (_, idx) {
                            // Flatten muscle-group headers + exercise rows
                            var pos = 0;
                            for (final muscle in muscles) {
                              if (idx == pos) {
                                return _MuscleHeader(
                                  label: muscle,
                                  tokens: tokens,
                                );
                              }
                              pos++;
                              final items = grouped[muscle]!;
                              if (idx < pos + items.length) {
                                final ex = items[idx - pos];
                                return _ExerciseRow(
                                  exercise: ex,
                                  tokens: tokens,
                                  onTap: () => Navigator.of(context).pop(ex),
                                );
                              }
                              pos += items.length;
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _MuscleHeader extends StatelessWidget {
  const _MuscleHeader({required this.label, required this.tokens});

  final String label;
  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        label,
        style: WorkoutType.body(
          size: 12,
          weight: FontWeight.w500,
          color: tokens.dim,
        ),
      ),
    );
  }
}

class _ExerciseRow extends StatelessWidget {
  const _ExerciseRow({
    required this.exercise,
    required this.tokens,
    required this.onTap,
  });

  final Exercise exercise;
  final WorkoutTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // Compound indicator dot
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: exercise.compound
                      ? tokens.accentText
                      : tokens.surface3,
                ),
              ),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FitLabel(
                      exercise.name,
                      maxLines: 2,
                      style: WorkoutType.body(
                        size: 16,
                        weight: FontWeight.w500,
                        color: tokens.text,
                      ),
                    ),
                    if (exercise.equip != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: FitLabel(
                          exercise.equip!,
                          maxLines: 2,
                          style: WorkoutType.body(size: 12, color: tokens.dim),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.tokens});

  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(WIcons.dumbbell, size: 32, color: tokens.faint),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.of(context).sessionNoExercisesFound,
              style: WorkoutType.body(
                size: 15,
                weight: FontWeight.w500,
                color: tokens.dim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
