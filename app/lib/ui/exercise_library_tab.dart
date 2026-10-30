import '../catalog_ui/catalog_picker.dart';
import '../catalog/catalog.dart';
import '../catalog/catalog_development.dart';
import '../catalog_ui/catalog_trial_scope.dart';
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
  const LibraryTab({
    super.key,
    required this.onOpenEditor,
    this.browserController,
  });

  final CatalogBrowserController? browserController;

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
  final _fallbackSearch = TextEditingController();
  late final _browserController =
      widget.browserController ?? CatalogBrowserController();

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
    _fallbackSearch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when unit changes so PR values re-display in new unit.
    final units = context.watch<UnitService>();
    final tokens = context.tokens;
    final catalogInput = context.watch<CatalogDevelopmentInput?>();

    return StreamBuilder<List<Exercise>>(
      stream: _catalogStream,
      builder: (context, snap) {
        final exercises = snap.data ?? const <Exercise>[];
        final prMap = _prMap ?? {};

        final trial = CatalogTrialScope.maybeOf(context);
        if (trial != null) {
          return CatalogBrowser(
            state: trial,
            ownedExercises: exercises,
            controller: _browserController,
            onEditOwned: widget.onOpenEditor,
            onCreateChoice: (choice) async {
              try {
                await trial.materialize(
                  choice,
                  _repo,
                  locale: Localizations.localeOf(context).languageCode,
                );
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        AppLocalizations.of(context).catalogSaveFailed,
                      ),
                    ),
                  );
                }
              }
            },
          );
        }

        final query = catalogNormalize(_fallbackSearch.text);
        final groups = <String, List<Exercise>>{};
        for (final exercise in exercises) {
          if (catalogNormalize(exercise.name).contains(query)) {
            (groups[exercise.muscleGroup] ??= []).add(exercise);
          }
        }
        final rows = <Object>[
          for (final muscle in orderedMuscles(groups.keys)) ...[
            muscle,
            ...groups[muscle]!,
          ],
        ];
        final l = AppLocalizations.of(context);
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(16, 8, 16, bottomNavInset(context)),
          itemCount: rows.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _NewExerciseButton(
                    tokens: tokens,
                    onTap: () => widget.onOpenEditor(null),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('library-search'),
                    controller: _fallbackSearch,
                    decoration: InputDecoration(
                      hintText: l.exerciseSheetSearchHint,
                      prefixIcon: const Icon(Icons.search),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  if (catalogInput?.unavailable == true)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        l.catalogUnavailable,
                        style: WorkoutType.body(size: 14, color: tokens.dim),
                      ),
                    ),
                  if (snap.hasData && rows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        query.isEmpty ? l.progressEmpty : l.catalogNoResults,
                        style: WorkoutType.body(size: 16, color: tokens.dim),
                      ),
                    ),
                ],
              );
            }
            final row = rows[index - 1];
            if (row is String) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(2, 24, 2, 8),
                child: Text(
                  (row.isEmpty
                          ? l.catalogUnclassified
                          : localizedMuscle(context, row))
                      .toUpperCase(),
                  style: WorkoutType.body(
                    size: 12,
                    weight: FontWeight.w500,
                    color: tokens.faint,
                    letterSpacing: .72,
                  ),
                ),
              );
            }
            final exercise = row as Exercise;
            return _ExerciseRow(
              exercise: exercise,
              pr: prMap[exercise.id] ?? 0,
              units: units,
              tokens: tokens,
              onTap: () => widget.onOpenEditor(exercise.id),
            );
          },
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
    return PrimaryBtn(
      CatalogTrialScope.maybeOf(context) == null
          ? l.planNewExercise
          : l.catalogBrowse,
      enabled: true,
      onTap: onTap,
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
    final trial = CatalogTrialScope.maybeOf(context);
    final choice = trial?.exercises[exercise.id];
    final locale = Localizations.localeOf(context).languageCode;
    final name = choice == null
        ? exercise.name
        : trial!.identifyingLabel(choice, locale);
    // Sub-label: '{equip ?? localizedMuscle(muscleGroup)}{ · compound}'
    final subParts = <String>[
      exercise.equip?.isNotEmpty == true
          ? exercise.equip!
          : localizedMuscle(context, exercise.muscleGroup),
      if (exercise.compound) '· ${l.exerciseCompound}',
    ];
    final subLabel = choice == null
        ? subParts.join(' ')
        : choice.variantId == null
        ? CatalogLabels(locale).unknownMuscles
        : CatalogLabels(
            locale,
          ).equipment(trial!.bundle.variants[choice.variantId]!.equipmentKind);

    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          decoration: BoxDecoration(
            color: tokens.bg,
            border: Border(bottom: BorderSide(color: tokens.line)),
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
                      name,
                      maxLines: 2,
                      style: WorkoutType.body(
                        size: 16,
                        weight: FontWeight.w500,
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
                                weight: FontWeight.w400,
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
