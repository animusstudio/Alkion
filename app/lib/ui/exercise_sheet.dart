import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/muscles.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';

/// The sentinel value returned when the user picks the Bodyweight option.
const String kBodyweightSentinel = '__bodyweight__';

/// Shows a searchable, muscle-grouped exercise picker sheet.
///
/// Returns:
/// - an exercise id string when the user taps an exercise row,
/// - [kBodyweightSentinel] (`'__bodyweight__'`) when the user picks Bodyweight,
/// - `null` when the user taps "Done" or dismisses without selecting.
///
/// Visual spec: `docs/design_handoff_workout_tracker/design/app/screen-progress.jsx`
/// `ExerciseSheet`.
Future<String?> showExerciseSheet(
  BuildContext context, {
  required List<Exercise> exercises,
  required String? current,
  bool showBodyweight = true,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: context.tokens.overlay,
    useSafeArea: true,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (_) => _ExerciseSheet(
      exercises: exercises,
      current: current,
      showBodyweight: showBodyweight,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────

class _ExerciseSheet extends StatefulWidget {
  const _ExerciseSheet({
    required this.exercises,
    required this.current,
    required this.showBodyweight,
  });

  final List<Exercise> exercises;
  final String? current;
  final bool showBodyweight;

  @override
  State<_ExerciseSheet> createState() => _ExerciseSheetState();
}

class _ExerciseSheetState extends State<_ExerciseSheet> {
  String _query = '';
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // Whether the Bodyweight row is visible given the current query.
  bool get _showBodyweight {
    if (_query.isEmpty) return true;
    final q = _query.trim().toLowerCase();
    return 'bodyweight'.contains(q) || 'weight'.contains(q);
  }

  // Filter exercises by name or muscle label.
  List<Exercise> get _filtered {
    if (_query.isEmpty) return widget.exercises;
    final q = _query.trim().toLowerCase();
    return widget.exercises
        .where(
          (e) =>
              e.name.toLowerCase().contains(q) ||
              muscleLabel(e.muscleGroup).toLowerCase().contains(q),
        )
        .toList();
  }

  // Group filtered exercises by muscleGroup.
  Map<String, List<Exercise>> _group(List<Exercise> exercises) {
    final result = <String, List<Exercise>>{};
    for (final ex in exercises) {
      final key = ex.muscleGroup.isEmpty ? 'other' : ex.muscleGroup;
      (result[key] ??= []).add(ex);
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;
    final filtered = _filtered;
    final grouped = _group(filtered);
    final muscles = orderedMuscles(grouped.keys);

    // Whether the pinned Bodyweight block is shown at all.
    final showBodyweight = widget.showBodyweight && _showBodyweight;

    // Count matching exercise rows (not bodyweight).
    final exerciseCount = muscles.fold<int>(
      0,
      (n, m) => n + grouped[m]!.length,
    );
    final hasResults = exerciseCount > 0 || showBodyweight;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.84,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, scrollController) {
          return Container(
            decoration: BoxDecoration(
              color: tokens.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadius.sheet),
              ),
              border: Border(
                top: BorderSide(color: tokens.lineStrong, width: 1),
              ),
            ),
            clipBehavior: Clip.hardEdge,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Fixed header (grabber + title + search) ──────────────
                _SheetHeader(
                  tokens: tokens,
                  controller: _searchController,
                  query: _query,
                  onQueryChanged: (v) => setState(() => _query = v),
                  onClearQuery: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                  onDone: () => Navigator.of(context).pop(),
                ),

                // ── Scrollable list ──────────────────────────────────────
                Flexible(
                  child: ListView(
                    controller: scrollController,
                    padding: EdgeInsets.fromLTRB(
                      16,
                      8,
                      16,
                      16 + MediaQuery.viewPaddingOf(context).bottom,
                    ),
                    children: [
                      if (!hasResults)
                        _EmptyState(query: _query.trim(), tokens: tokens),

                      // Bodyweight pinned row
                      if (showBodyweight) ...[
                        _SectionLabel(
                          label: l.exerciseSheetTracking,
                          tokens: tokens,
                        ),
                        _BodyweightRow(
                          selected: widget.current == kBodyweightSentinel,
                          tokens: tokens,
                          onTap: () =>
                              Navigator.of(context).pop(kBodyweightSentinel),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Exercise groups
                      for (final muscle in muscles) ...[
                        _SectionLabel(
                          label: localizedMuscle(context, muscle).toUpperCase(),
                          tokens: tokens,
                        ),
                        for (final ex in grouped[muscle]!) ...[
                          _ExerciseRow(
                            exercise: ex,
                            selected: ex.id == widget.current,
                            tokens: tokens,
                            onTap: () => Navigator.of(context).pop(ex.id),
                          ),
                          const SizedBox(height: 6),
                        ],
                        const SizedBox(height: 16),
                      ],
                    ],
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

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.tokens,
    required this.controller,
    required this.query,
    required this.onQueryChanged,
    required this.onClearQuery,
    required this.onDone,
  });

  final WorkoutTokens tokens;
  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClearQuery;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Grabber
          Container(
            width: 38,
            height: 4,
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: tokens.lineStrong,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),

          // Title row
          Row(
            children: [
              Expanded(
                child: FitLabel(
                  l.exerciseSheetTitle,
                  maxLines: 2,
                  style: WorkoutType.display(size: 22, color: tokens.text),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: onDone, child: Text(l.commonDone)),
            ],
          ),
          const SizedBox(height: 12),

          // Search field
          Container(
            constraints: const BoxConstraints(minHeight: 48),
            decoration: BoxDecoration(
              color: tokens.surface3,
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(WIcons.search, size: 18, color: tokens.faint),
                const SizedBox(width: 9),
                Expanded(
                  child: TextField(
                    controller: controller,
                    autofocus: false,
                    style: WorkoutType.body(size: 15, color: tokens.text),
                    decoration: InputDecoration(
                      hintText: l.exerciseSheetSearchHint,
                      hintStyle: WorkoutType.body(
                        size: 15,
                        color: tokens.faint,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onChanged: onQueryChanged,
                  ),
                ),
                if (query.isNotEmpty)
                  IconButton(
                    onPressed: onClearQuery,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).clearButtonTooltip,
                    icon: Icon(Icons.close, size: 20, color: tokens.dim),
                  )
                else
                  const SizedBox(width: 12),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, required this.tokens});

  final String label;
  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 8),
      child: Text(
        label.toUpperCase(),
        style: WorkoutType.body(
          size: 12,
          weight: FontWeight.w500,
          color: tokens.faint,
          letterSpacing: 0.06 * 12,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _BodyweightRow extends StatelessWidget {
  const _BodyweightRow({
    required this.selected,
    required this.tokens,
    required this.onTap,
  });

  final bool selected;
  final WorkoutTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final row = GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(AppRadius.panel),
          border: Border.all(
            color: selected ? tokens.lineStrong : tokens.line,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(WIcons.scale, size: 20, color: tokens.text),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FitLabel(
                    l.exerciseSheetBodyweight,
                    maxLines: 2,
                    style: WorkoutType.body(
                      size: 14.5,
                      weight: FontWeight.w500,
                      color: tokens.text,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    l.exerciseSheetBodyweightSub,
                    style: WorkoutType.body(size: 12, color: tokens.faint),
                  ),
                ],
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 8),
              Icon(WIcons.check, size: 16, color: tokens.text),
            ],
          ],
        ),
      ),
    );
    return selected ? Semantics(selected: true, child: row) : row;
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _ExerciseRow extends StatelessWidget {
  const _ExerciseRow({
    required this.exercise,
    required this.selected,
    required this.tokens,
    required this.onTap,
  });

  final Exercise exercise;
  final bool selected;
  final WorkoutTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    // Subtitle: '{equip}{compound ? ' · compound' : ''}'
    final equip = exercise.equip ?? '';
    final subtitle = exercise.compound
        ? (equip.isNotEmpty
              ? '$equip · ${l.exerciseCompound}'
              : l.exerciseCompound)
        : equip;

    final row = GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(AppRadius.panel),
          border: Border.all(
            color: selected ? tokens.lineStrong : tokens.line,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            // Name + subtitle
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FitLabel(
                    exercise.name,
                    maxLines: 2,
                    style: WorkoutType.body(
                      size: 14.5,
                      weight: FontWeight.w500,
                      color: tokens.text,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    FitLabel(
                      subtitle,
                      maxLines: 2,
                      style: WorkoutType.body(size: 12, color: tokens.faint),
                    ),
                  ],
                ],
              ),
            ),

            // Check icon when this is the current exercise
            if (selected) ...[
              const SizedBox(width: 8),
              Icon(WIcons.check, size: 16, color: tokens.text),
            ],
          ],
        ),
      ),
    );
    return selected ? Semantics(selected: true, child: row) : row;
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.query, required this.tokens});

  final String query;
  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Text(
          l.exerciseSheetEmpty(query),
          textAlign: TextAlign.center,
          style: WorkoutType.body(size: 13, color: tokens.faint),
        ),
      ),
    );
  }
}
