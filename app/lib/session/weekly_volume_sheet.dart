import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/muscle_target_repository.dart';
import '../ui/today_labels.dart';
import '../data/stats_repository.dart';
import '../l10n/app_localizations.dart';
import '../store/local_store.dart';
import '../theme/alkion_icon.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/typography.dart';
import '../util/calendar_keys.dart';
import '../widgets/glyph_loading.dart';
import '../widgets/volume_bars.dart';
import 'active_session_controller.dart';
import 'live_weekly_volume.dart';

/// Opens the live workout's weekly volume: this week's finished sets plus
/// the workout in progress, updating while the sheet is open.
Future<void> showWeeklyVolumeSheet(
  BuildContext context, {
  required ActiveSessionController controller,
  required LocalDatabase? database,
}) {
  final tokens = context.tokens;
  // One week boundary and one subscription per open sheet, made here and
  // never in build (re-listen rule).
  final week = weekStart(DateTime.now());
  final volume = database == null
      ? null
      : StatsRepository.local(
          database,
        ).watchWeeklyVolumeByMuscle(weekStart: week);
  final targets = database == null
      ? null
      : MuscleTargetRepository.local(database).watchTargets();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: tokens.surface,
    barrierColor: tokens.overlay,
    sheetAnimationStyle: AnimationStyle(
      duration: Motion.of(context, Motion.base),
      reverseDuration: Motion.of(context, Motion.fast),
    ),
    builder: (_) => WeeklyVolumeSheet(
      controller: controller,
      weekStart: week,
      volume: volume,
      targets: targets,
    ),
  );
}

class WeeklyVolumeSheet extends StatefulWidget {
  const WeeklyVolumeSheet({
    super.key,
    required this.controller,
    required this.weekStart,
    required this.volume,
    required this.targets,
  });

  final ActiveSessionController controller;

  /// The Monday the [volume] stream counts from; the draft counts against it.
  final DateTime weekStart;

  /// The weekly stat and the targets. Null when no store is open: the sheet
  /// then says volume is unavailable.
  final Stream<WeeklyMuscleVolume>? volume;
  final Stream<List<MuscleTarget>>? targets;

  @override
  State<WeeklyVolumeSheet> createState() => _WeeklyVolumeSheetState();
}

class _WeeklyVolumeSheetState extends State<WeeklyVolumeSheet> {
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), t = context.tokens;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .9,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          key: const Key('weekly-volume-sheet'),
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l.todayWeeklyVolume,
                      style: WorkoutType.display(size: 22, color: t.text),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: l.commonDone,
                    onPressed: () => Navigator.pop(context),
                    icon: const AlkionIcon(AlkionGlyph.close),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              widget.volume == null || widget.targets == null
                  ? _message(l.todayVolumeUnavailable)
                  : StreamBuilder<WeeklyMuscleVolume>(
                      stream: widget.volume,
                      builder: (context, volume) =>
                          StreamBuilder<List<MuscleTarget>>(
                            stream: widget.targets,
                            builder: (context, targets) =>
                                _content(context, volume, targets),
                          ),
                    ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    AsyncSnapshot<WeeklyMuscleVolume> volume,
    AsyncSnapshot<List<MuscleTarget>> targets,
  ) {
    final l = AppLocalizations.of(context);
    if (volume.hasError || targets.hasError) {
      return _message(l.todayVolumeUnavailable);
    }
    if (!volume.hasData || !targets.hasData) {
      return Semantics(
        label: l.todayVolumeLoading,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: GlyphSkeleton.lines(
            widths: const [.9, .72, .8, .5],
            lineHeight: 10,
            gap: 10,
          ),
        ),
      );
    }
    final targetMap = {for (final t in targets.data!) t.muscle: t.targetSets};
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final draft = widget.controller.draftOrNull;
        final catalog = catalogVolumeAttribution(context);
        final attributed = volume.data!.attribute(catalog.targets);
        final combined = LiveWeeklyVolume.combine(
          volume: attributed.groups,
          unknownSets: attributed.unknownSets,
          targets: targetMap,
          draft: draft == null
              ? null
              : DraftVolume.of(
                  draft,
                  weekStart: widget.weekStart,
                  now: DateTime.now(),
                  targets: catalog.targets,
                ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (combined.unknownSets > 0) ...[
              _message(l.todayVolumeUnknown(combined.unknownSets)),
              const SizedBox(height: 10),
            ],
            if (combined.rows.isNotEmpty)
              VolumeBars(
                rows: [
                  for (final r in combined.rows)
                    (
                      muscle: volumeGroupLabel(
                        context,
                        r.muscle,
                        catalog.browse,
                      ),
                      sets: r.sets,
                      target: r.target,
                    ),
                ],
                live: combined.live,
              )
            else if (combined.unknownSets == 0)
              _message(l.todayNoSetsLogged),
          ],
        );
      },
    );
  }

  Widget _message(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: WorkoutType.body(size: 12, color: context.tokens.dim),
    ),
  );
}
