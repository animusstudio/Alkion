import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/exercise_repository.dart';
import '../data/models.dart';
import '../data/muscles.dart';
import '../l10n/app_localizations.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../widgets/fit_label.dart';
import '../widgets/plan_form.dart';

/// The Exercises sub-tab: a catalog of all exercises grouped by muscle.
///
/// [onOpenEditor] is called with the exercise id to edit (null = new exercise).
class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key, required this.onOpenEditor});

  /// Called with the exercise id to edit (null = new exercise).
  final void Function(String? id) onOpenEditor;

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  late final ExerciseRepository _repo;
  late final Stream<List<Exercise>> _catalogStream = _repo.watchCatalog();

  /// One watch for all exercise best loads, retained across top-tab changes.
  StreamSubscription<Map<String, double>>? _prSubscription;
  Map<String, double>? _prMap;

  @override
  void initState() {
    super.initState();
    _repo = ExerciseRepository.local(context.read<LocalDatabase>());
    _prSubscription = _repo.watchPrTopSets().listen((map) {
      if (mounted) setState(() => _prMap = map);
    });
  }

  @override
  void dispose() {
    _prSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when unit changes so PR values re-display in new unit.
    final units = context.watch<UnitService>();
    final tokens = context.tokens;

    return StreamBuilder<List<Exercise>>(
      stream: _catalogStream,
      builder: (context, snap) {
        final exercises = snap.data ?? [];
        final prMap = _prMap ?? {};

        // Group by muscleGroup.
        final groups = <String, List<Exercise>>{};
        for (final ex in exercises) {
          (groups[ex.muscleGroup] ??= []).add(ex);
        }

        // Order: known muscles in canonical order, then unknowns (other bucket).
        final ordered = orderedMuscles(groups.keys);

        return ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, bottomNavInset(context)),
          children: [
            // Pinned 'New exercise' accent button.
            _NewExerciseButton(
              tokens: tokens,
              onTap: () => widget.onOpenEditor(null),
            ),
            const SizedBox(height: 24),

            if (snap.hasData && exercises.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  AppLocalizations.of(context).progressEmpty,
                  textAlign: TextAlign.center,
                  style: WorkoutType.body(size: 16, color: tokens.dim),
                ),
              ),

            // Muscle-group sections.
            for (final muscle in ordered) ...[
              _MuscleSection(
                muscle: muscle,
                exercises: groups[muscle]!,
                prMap: prMap,
                units: units,
                tokens: tokens,
                onTap: (id) => widget.onOpenEditor(id),
              ),
              const SizedBox(height: 16),
            ],
          ],
        );
      },
    );
  }
}

// ── New exercise button ────────────────────────────────────────────────────────

class _NewExerciseButton extends StatelessWidget {
  const _NewExerciseButton({required this.tokens, required this.onTap});

  final WorkoutTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return PrimaryBtn(l.planNewExercise, enabled: true, onTap: onTap);
  }
}

// ── Muscle section ─────────────────────────────────────────────────────────────

class _MuscleSection extends StatelessWidget {
  const _MuscleSection({
    required this.muscle,
    required this.exercises,
    required this.prMap,
    required this.units,
    required this.tokens,
    required this.onTap,
  });

  final String muscle;
  final List<Exercise> exercises;
  final Map<String, double> prMap;
  final UnitService units;
  final WorkoutTokens tokens;
  final void Function(String id) onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section label: muscle group name
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
          child: Text(
            localizedMuscle(context, muscle).toUpperCase(),
            style: WorkoutType.body(
              size: 12,
              weight: FontWeight.w700,
              color: tokens.faint,
              letterSpacing: 0.06 * 12,
            ),
          ),
        ),

        // Exercise rows
        Column(
          children: [
            for (int i = 0; i < exercises.length; i++)
              Padding(
                padding: EdgeInsets.only(
                  bottom: i < exercises.length - 1 ? 6 : 0,
                ),
                child: _ExerciseRow(
                  exercise: exercises[i],
                  pr: prMap[exercises[i].id] ?? 0,
                  units: units,
                  tokens: tokens,
                  onTap: () => onTap(exercises[i].id),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// ── Exercise row ───────────────────────────────────────────────────────────────

class _ExerciseRow extends StatelessWidget {
  const _ExerciseRow({
    required this.exercise,
    required this.pr,
    required this.units,
    required this.tokens,
    required this.onTap,
  });

  final Exercise exercise;
  final double pr;
  final UnitService units;
  final WorkoutTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Sub-label: '{equip ?? localizedMuscle(muscleGroup)}{ · compound}'
    final subParts = <String>[
      exercise.equip?.isNotEmpty == true
          ? exercise.equip!
          : localizedMuscle(context, exercise.muscleGroup),
      if (exercise.compound) '· ${l.exerciseCompound}',
    ];
    final subLabel = subParts.join(' ');

    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: tokens.surface,
            border: Border.all(color: tokens.line),
            borderRadius: BorderRadius.circular(AppRadius.panel),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: exercise.compound
                          ? tokens.accentText
                          : tokens.lineStrong,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FitLabel(
                      exercise.name,
                      maxLines: 2,
                      style: WorkoutType.body(
                        size: 16,
                        weight: FontWeight.w700,
                        color: tokens.text,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(WIcons.edit, size: 20, color: tokens.dim),
                ],
              ),
              const SizedBox(height: 8),
              FitLabel(
                subLabel,
                maxLines: 2,
                style: WorkoutType.body(size: 12, color: tokens.dim),
              ),
              if (pr > 0) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      l.exerciseEditorPr,
                      style: WorkoutType.body(size: 12, color: tokens.dim),
                    ),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: units.fmtWt(pr),
                              style: WorkoutType.mono(
                                size: 14,
                                weight: FontWeight.w700,
                                color: tokens.accentText,
                              ),
                            ),
                            TextSpan(
                              text: units.uLabel,
                              style: WorkoutType.mono(
                                size: 12,
                                color: tokens.dim,
                              ),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
