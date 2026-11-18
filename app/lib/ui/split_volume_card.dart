import 'package:flutter/material.dart';

import '../data/body_workload.dart';
import '../data/planned_workload.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import '../widgets/split_card.dart';
import 'body_figure.dart';
import 'workload_top_muscles.dart';

/// The Split tab's overview: the planned working sets of one rotation (or one
/// week, when the schedule proves it) as the top five muscles beside exactly
/// one body figure. The figure's pill opens the sheet with every region.
///
/// [workload] is the caller's [plannedSplitWorkload]; loading shows the
/// skeleton and an unavailable read the unavailable line, never zeros.
class SplitVolumeCard extends StatelessWidget {
  const SplitVolumeCard({
    super.key,
    required this.workload,
    required this.basis,
  });

  final WorkoutWorkload workload;
  final SplitBasis basis;

  /// The muscles listed beside the figure.
  static const topLimit = 5;

  /// "Planned sets per rotation · 4 days", or "per week".
  static String basisLabel(AppLocalizations l, SplitBasis basis) =>
      '${basis.perWeek ? l.splitVolumePerWeek : l.splitVolumePerRotation}'
      ' · ${l.splitVolumeDays(basis.activeDays)}';

  /// What TalkBack reads as one node: title, basis and the top muscles (or
  /// the loading, unavailable or empty state).
  static String summary(
    BuildContext context,
    WorkoutWorkload workload,
    SplitBasis basis,
  ) {
    final l = AppLocalizations.of(context);
    final String state = switch (workload.availability) {
      WorkloadAvailability.loading => l.bodyLoading,
      WorkloadAvailability.unavailable => l.bodyReadUnavailable,
      WorkloadAvailability.ready => switch (topWorkloadMuscles(
        workload,
        topLimit,
      )) {
        final rows when rows.isEmpty => l.bodyEmpty,
        final rows =>
          rows
              .map(
                (r) => '${workloadRegionLabel(context, r.muscle)} ${r.count}',
              )
              .join(', '),
      },
    };
    return [l.splitVolumeTitle, basisLabel(l, basis), state].join('. ');
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), t = context.tokens;
    // A tab the shell keeps mounted but hidden (IndexedStack) must not hold a
    // second native renderer behind the visible one.
    final shown = Visibility.of(context);
    return Container(
      key: const Key('split-volume-card'),
      padding: const EdgeInsets.all(AppSpacing.pad),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.line),
        borderRadius: BorderRadius.circular(AppRadius.panel),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            key: const Key('split-volume-summary'),
            container: true,
            excludeSemantics: true,
            label: summary(context, workload, basis),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                FitLabel(
                  l.splitVolumeTitle,
                  maxLines: 2,
                  style: WorkoutType.display(size: 20, color: t.text),
                ),
                const SizedBox(height: 4),
                FitLabel(
                  basisLabel(l, basis),
                  key: const Key('split-volume-basis'),
                  maxLines: 3,
                  style: WorkoutType.body(size: 12, color: t.accentText),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          LayoutBuilder(
            builder: (context, box) {
              final stacked = splitOverviewStacked(context, box.maxWidth);
              final width = splitFigureWidth(context, box.maxWidth);
              // The summary above already speaks these rows.
              final muscles = ExcludeSemantics(
                child: WorkloadTopMuscles(workload: workload, limit: topLimit),
              );
              final figure = shown
                  ? BodyFigure(
                      introKey: SplitVolumeCard,
                      width: width,
                      workload: workload,
                    )
                  : SizedBox(
                      key: const Key('split-volume-figure-hidden'),
                      width: width,
                      height: BodyFigure.heightFor(width),
                    );
              if (stacked) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    muscles,
                    const SizedBox(height: AppSpacing.md),
                    Center(child: figure),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: muscles),
                  const SizedBox(width: AppSpacing.md),
                  figure,
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
