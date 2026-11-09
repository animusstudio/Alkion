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

  /// Per muscle, the prepared write not yet acknowledged: running, or left
  /// by a failure. Shown over the stored value until it lands or a newer
  /// explicit change replaces it.
  final Map<String, PreparedDomainAction> _pending = {};

  /// Muscles whose write is running. The lock is per muscle: other rows stay
  /// editable.
  final Set<String> _writing = {};

  /// The latest value tapped for a muscle while its write was running; it is
  /// written next, so no tap is dropped.
  final Map<String, int> _queued = {};

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
          for (final entry in _queued.entries)
            entry.key: MuscleTarget(
              id: _pending[entry.key]?.action.target.id ?? '',
              muscle: entry.key,
              targetSets: entry.value,
            ),
        };

        return Column(
          children: [
            Expanded(
              child: TargetsList(
                writing: _writing.isNotEmpty,
                targets: byMuscle,
                onChanged: _setTarget,
              ),
            ),
          ],
        );
      },
    );
  }

  /// The stored target for [muscle], read fresh (the row the watch shows):
  /// after an uncertain COMMIT the store, not a lagging watch, says whether
  /// the earlier write landed.
  Future<MuscleTarget?> _stored(String muscle) async {
    final row = await _repo.db.getOptional(
      'SELECT * FROM muscle_targets WHERE profile_id=? AND muscle=? AND deleted=0 ORDER BY id DESC LIMIT 1',
      [_repo.db.profileId, muscle],
    );
    return row == null ? null : MuscleTarget.fromRow(row);
  }

  /// Persists a stepped target; a failed or refused write (e.g. while the
  /// store needs recovery) is shown, never dropped silently.
  ///
  /// A value equal to the failed one retries that exact prepared write. A
  /// different value is a new explicit change: it replaces the failed write
  /// (never registered as owed) and is prepared against the stored row, so
  /// an earlier COMMIT that did land is built on rather than duplicated.
  Future<void> _setTarget(String muscle, int sets) async {
    if (_writing.contains(muscle)) {
      setState(() => _queued[muscle] = sets);
      return;
    }
    setState(() => _writing.add(muscle));
    final recovery = context.read<DomainRecovery?>();
    try {
      await recovery?.recover();
      var intent = _pending[muscle];
      if (intent == null || intent.input['sets'] != sets) {
        final existing = await _stored(muscle);
        if (existing == null && sets == 0) {
          _pending.remove(muscle);
          return;
        }
        intent = _repo.prepareTarget(
          muscle: muscle,
          sets: sets,
          existing: existing,
        );
        _pending[muscle] = intent;
        if (mounted) setState(() {});
      }
      await _repo.commitPrepared(intent);
      if (identical(_pending[muscle], intent)) _pending.remove(muscle);
    } catch (e) {
      if (mounted) await showWriteFailed(context, e);
    } finally {
      _writing.remove(muscle);
      final next = _queued.remove(muscle);
      if (mounted) {
        setState(() {});
        if (next != null) await _setTarget(muscle, next);
      }
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
      padding: EdgeInsets.zero,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: tokens.bg,
          border: Border(bottom: BorderSide(color: tokens.line)),
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
                    weight: FontWeight.w500,
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
