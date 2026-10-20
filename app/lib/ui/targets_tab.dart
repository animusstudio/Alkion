import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/muscle_target_repository.dart';
import '../data/muscles.dart';
import '../data/exercise_repository.dart';
import '../l10n/app_localizations.dart';
import '../store/local_store.dart';
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
  late final MuscleTargetRepository _repo = MuscleTargetRepository.local(
    context.read<LocalDatabase>(),
  );
  late final Stream<List<MuscleTarget>> _targetsStream = _repo.watchTargets();
  final Map<String, PreparedDomainAction> _pending = {};
  bool _writing = false;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MuscleTarget>>(
      stream: _targetsStream,
      builder: (context, snap) {
        final byMuscle = {
          for (final t in snap.data ?? const <MuscleTarget>[]) t.muscle: t,
          for (final entry in _pending.entries)
            entry.key: MuscleTarget(
              id: entry.value.action.target.id,
              muscle: entry.key,
              targetSets: entry.value.input['sets'] as int,
              localRevision: entry.value.action.baseLocalRevision,
            ),
        };

        return Column(
          children: [
            if (byMuscle.isEmpty)
              TextButton(
                onPressed: () async {
                  try {
                    final revision = await _repo.initializationRevision();
                    await _repo.keepEmpty(observedStateRevision: revision);
                  } catch (e) {
                    if (context.mounted) await showWriteFailed(context, e);
                  }
                },
                child: Text(AppLocalizations.of(context).targetsKeepEmpty),
              ),
            Expanded(
              child: AbsorbPointer(
                absorbing: _writing,
                child: TargetsList(
                  writing: _writing,
                  targets: byMuscle,
                  onChanged: (muscle, sets) =>
                      _setTarget(muscle, sets, byMuscle[muscle]),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Persists a stepped target; a failed or refused write (e.g. while a
  /// data capture holds the source) is shown, never dropped silently.
  Future<void> _setTarget(
    String muscle,
    int sets,
    MuscleTarget? existing,
  ) async {
    if (_writing) return;
    _writing = true;
    try {
      if (existing == null && sets == 0) return;
      final intent = _pending.putIfAbsent(
        muscle,
        () =>
            _repo.prepareTarget(muscle: muscle, sets: sets, existing: existing),
      );
      if (mounted) setState(() {});
      await context.read<DomainRecovery?>()?.recover();
      await _repo.commitPrepared(intent);
      _pending.remove(muscle);
    } catch (e) {
      if (mounted) await showWriteFailed(context, e);
    } finally {
      _writing = false;
      if (mounted) setState(() {});
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
    this.writing = false,
  });

  final Map<String, MuscleTarget> targets;
  final bool writing;
  final void Function(String muscle, int sets) onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return ListView(
      padding: EdgeInsets.fromLTRB(16, 12, 16, bottomNavInset(context)),
      children: [
        for (final entry in {
          ...kMuscleLabels,
          for (final key in targets.keys) key: key,
        }.entries)
          _TargetRow(
            muscle: entry.key,
            writing: writing,
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
    required this.writing,
    required this.sets,
    required this.tokens,
    required this.onChanged,
  });

  final String muscle;
  final bool writing;
  final int sets;
  final WorkoutTokens tokens;
  final void Function(String muscle, int sets) onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final hasGoal = sets > 0;
    final labelColor = hasGoal ? tokens.text : tokens.faint;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: tokens.surface,
          border: Border.all(color: tokens.line),
          borderRadius: BorderRadius.circular(AppRadius.radius),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final labels = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                FitLabel(
                  localizedMuscle(context, muscle),
                  style: WorkoutType.body(
                    size: 15.5,
                    weight: FontWeight.w700,
                    color: labelColor,
                  ),
                ),
                const SizedBox(height: 2),
                FitLabel(
                  hasGoal ? l.targetsSetsPerWeek : l.targetsNoGoal,
                  maxLines: 2,
                  style: WorkoutType.body(size: 12, color: tokens.faint),
                ),
              ],
            );
            final stepper = SizedBox(
              width: _stepperWidth,
              child: WStepper(
                key: ValueKey('$muscle:$sets:$writing'),
                value: sets.toDouble(),
                step: 1,
                format: (v) => v.round() == 0 ? '—' : v.round().toString(),
                onChanged: (v) => onChanged(muscle, v.round().clamp(0, 40)),
                editable: true,
                allowDecimal: false,
                min: 0,
                max: 40,
                emptyValue: 0,
                formatForEdit: (v) =>
                    v.round() == 0 ? '' : v.round().toString(),
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
            return Row(
              children: [
                Expanded(child: labels),
                stepper,
              ],
            );
          },
        ),
      ),
    );
  }

  static const _stepperWidth = 168.0;
}
