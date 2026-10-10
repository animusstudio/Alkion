import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/muscle_target_repository.dart';
import '../data/muscles.dart';
import '../identity/identity_service.dart';
import '../l10n/app_localizations.dart';
import '../sync/db.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import '../widgets/stepper.dart';
import '../widgets/w_dialog.dart';

/// The Targets sub-tab: edit weekly per-muscle set goals.
///
/// Streams [MuscleTargetRepository.watchTargets], keys rows by muscle, and
/// renders a presentational [TargetsList]. Edits persist live via
/// [MuscleTargetRepository.setTarget] (0 = no goal / deletes the row).
class TargetsTab extends StatefulWidget {
  const TargetsTab({super.key});

  @override
  State<TargetsTab> createState() => _TargetsTabState();
}

class _TargetsTabState extends State<TargetsTab> {
  late final MuscleTargetRepository _repo = MuscleTargetRepository(db);
  late final Stream<List<MuscleTarget>> _targetsStream = _repo.watchTargets();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MuscleTarget>>(
      stream: _targetsStream,
      builder: (context, snap) {
        final byMuscle = {
          for (final t in snap.data ?? const <MuscleTarget>[]) t.muscle: t,
        };

        return TargetsList(
          targets: byMuscle,
          onChanged: (muscle, sets) =>
              _setTarget(muscle, sets, byMuscle[muscle]),
        );
      },
    );
  }

  /// Persists a stepped target; a failed or refused write (e.g. while a
  /// data capture holds the source) is shown, never dropped silently.
  Future<void> _setTarget(
      String muscle, int sets, MuscleTarget? existing) async {
    final userId = context.read<IdentityService>().currentUserId;
    try {
      await _repo.setTarget(
        muscle: muscle,
        sets: sets,
        userId: userId,
        existing: existing,
      );
    } catch (e) {
      if (mounted) await showWriteFailed(context, e);
    }
  }
}

/// Presentational list of weekly muscle targets — one row per canonical muscle.
///
/// [targets] maps muscle key → its current [MuscleTarget] (absent = no goal).
/// [onChanged] reports `(muscle, newSets)` on each stepper change.
class TargetsList extends StatelessWidget {
  const TargetsList({
    super.key,
    required this.targets,
    required this.onChanged,
  });

  final Map<String, MuscleTarget> targets;
  final void Function(String muscle, int sets) onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return ListView(
      padding: EdgeInsets.fromLTRB(16, 12, 16, bottomNavInset(context)),
      children: [
        for (final entry in kMuscleLabels.entries)
          _TargetRow(
            muscle: entry.key,
            sets: targets[entry.key]?.targetSets ?? 0,
            tokens: tokens,
            onChanged: onChanged,
          ),
      ],
    );
  }
}

class _TargetRow extends StatelessWidget {
  const _TargetRow({
    required this.muscle,
    required this.sets,
    required this.tokens,
    required this.onChanged,
  });

  final String muscle;
  final int sets;
  final WorkoutTokens tokens;
  final void Function(String muscle, int sets) onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final hasGoal = sets > 0;
    final labelColor = hasGoal ? tokens.text : tokens.faint;

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: tokens.surface,
          border: Border.all(color: tokens.line),
          borderRadius: BorderRadius.circular(AppRadius.radius),
        ),
        child: LayoutBuilder(builder: (context, constraints) {
          final labels = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              FitLabel(
                localizedMuscle(context, muscle),
                style: WorkoutType.body(
                  size: 15.5,
                  weight: FontWeight.w600,
                  color: labelColor,
                ),
              ),
              const SizedBox(height: 2),
              FitLabel(
                hasGoal ? l.targetsSetsPerWeek : l.targetsNoGoal,
                maxLines: 2,
                style: WorkoutType.mono(size: 11, color: tokens.faint),
              ),
            ],
          );
          final stepper = SizedBox(
            width: _stepperWidth,
            child: WStepper(
              value: sets.toDouble(),
              step: 1,
              format: (v) => v.round() == 0 ? '—' : v.round().toString(),
              onChanged: (v) => onChanged(muscle, v.round().clamp(0, 40)),
              editable: true,
              allowDecimal: false,
              min: 0,
              max: 40,
              emptyValue: 0,
              formatForEdit: (v) => v.round() == 0 ? '' : v.round().toString(),
              semanticLabel: localizedMuscle(context, muscle),
            ),
          );
          // Beside the stepper a narrow phone at large text leaves the name
          // room for a few letters only: put the stepper under it instead.
          final nameRoom = constraints.maxWidth - _stepperWidth;
          final stacked =
              nameRoom < MediaQuery.textScalerOf(context).scale(15.5) * 5;
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labels, const SizedBox(height: 8), stepper],
            );
          }
          return Row(children: [Expanded(child: labels), stepper]);
        }),
      ),
    );
  }

  static const _stepperWidth = 168.0;
}
