import 'package:flutter/material.dart';

import '../data/body_workload.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import '../widgets/glyph_loading.dart';
import 'body_figure.dart';

typedef TopWorkloadMuscle = ({WorkloadMuscle muscle, int count});

/// The [limit] regions with the most working sets, in the view the body
/// figure shows ([workloadDisplayCounts]). Highest first; ties keep the
/// regions' fixed order. Regions with no sets are left out. Empty unless the
/// workload is ready. One set can count for several regions, so the counts are
/// never summed.
List<TopWorkloadMuscle> topWorkloadMuscles(
  WorkoutWorkload workload,
  int limit,
) {
  if (workload.availability != WorkloadAvailability.ready || limit < 1) {
    return const [];
  }
  final counts = workloadDisplayCounts(workload);
  final rows = <TopWorkloadMuscle>[
    for (final muscle in WorkloadMuscle.values)
      if ((counts[muscle]?.count ?? 0) > 0)
        (muscle: muscle, count: counts[muscle]!.count),
  ];
  rows.sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : a.muscle.index.compareTo(b.muscle.index);
  });
  return rows.take(limit).toList(growable: false);
}

/// The top regions as a short list, one "Chest 9" row each. Loading shows a
/// static skeleton and a failed read shows the unavailable line, never zeros.
class WorkloadTopMuscles extends StatelessWidget {
  const WorkloadTopMuscles({super.key, required this.workload, this.limit = 3});

  final WorkoutWorkload workload;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), t = context.tokens;
    switch (workload.availability) {
      case WorkloadAvailability.loading:
        return GlyphSkeleton.lines(
          key: const Key('workload-top-muscles-state'),
          widths: [for (var i = 0; i < limit; i++) .8 - i * .1],
          lineHeight: 14,
          gap: 12,
          active: false,
          semanticLabel: l.bodyLoading,
        );
      case WorkloadAvailability.unavailable:
        return Text(
          l.bodyReadUnavailable,
          key: const Key('workload-top-muscles-state'),
          style: WorkoutType.body(size: 14, color: t.dim),
        );
      case WorkloadAvailability.ready:
        break;
    }
    final rows = topWorkloadMuscles(workload, limit);
    if (rows.isEmpty) {
      return Text(
        l.bodyEmpty,
        key: const Key('workload-top-muscles-state'),
        style: WorkoutType.body(size: 14, color: t.dim),
      );
    }
    return Column(
      key: const Key('workload-top-muscles'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in rows)
          Padding(
            key: ValueKey('workload-top-${row.muscle.name}'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: FitLabel(
                    workloadRegionLabel(context, row.muscle),
                    maxLines: 2,
                    style: WorkoutType.body(size: 14, color: t.text),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${row.count}',
                  style: WorkoutType.mono(size: 14, color: t.text),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
