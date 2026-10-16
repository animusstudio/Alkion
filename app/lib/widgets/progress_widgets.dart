import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../theme/icons.dart';
import 'fit_label.dart';

// ── Metric model + const list ─────────────────────────────────────────────────

/// Describes a progress metric tab.
///
/// [id] is used for selection state and routing.
/// [label] is the full display name (used in section headers and trend titles).
/// [short] is the abbreviated tab label (used in [MetricTabs] segments).
/// [wt] — values are weights (convert via UnitService).
/// [reps] — values include a rep count (e.g. 'Top set' shows '×8' suffix).
/// [pr] — PR dots are rendered on the chart for this metric.
class Metric {
  final String id;
  final bool wt;
  final bool reps;
  final bool pr;

  const Metric(this.id, {this.wt = false, this.reps = false, this.pr = false});
}

/// The four progress metrics in display order. Display names are localized via
/// [metricLabel] (section titles / trend headings) and [metricShort] (tab
/// segments), keyed by [Metric.id].
const kMetrics = [
  Metric('top', wt: true, reps: true, pr: true),
  Metric('e1rm', wt: true),
  Metric('volume', wt: true),
  Metric('reps'),
];

/// Localized full label for a metric (section headers, trend titles).
String metricLabel(AppLocalizations l, String id) {
  switch (id) {
    case 'e1rm':
      return l.progressMetricEst1rm;
    case 'volume':
      return l.progressMetricVolume;
    case 'reps':
      return l.progressMetricTopReps;
    case 'top':
    default:
      return l.progressMetricTopSet;
  }
}

/// Localized short label for a metric (the [MetricTabs] segments).
String metricShort(AppLocalizations l, String id) {
  switch (id) {
    case 'e1rm':
      return l.progressMetricEst1rm;
    case 'volume':
      return l.progressMetricVolume;
    case 'reps':
      return l.progressMetricReps;
    case 'top':
    default:
      return l.progressMetricTopSet;
  }
}

// ── BigStat ───────────────────────────────────────────────────────────────────

/// A compact stat display: mono uppercase label above a large value + optional
/// unit in a baseline-aligned row.
///
/// Visual spec: `docs/design_handoff_workout_tracker/design/app/screen-progress.jsx`.
class BigStat extends StatelessWidget {
  const BigStat({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.accent = false,
  });

  final String label;
  final String value;
  final String? unit;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final valueColor = accent ? tokens.accentText : tokens.text;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Mono 9.5 uppercase faint label, mb6. A third of a narrow phone at
        // large text is too small for "BESTWERT": shrink, then ellipsize.
        FitLabel(
          label.toUpperCase(),
          style: WorkoutType.mono(
            size: 9.5,
            color: tokens.faint,
            letterSpacing: 0.06 * 9.5,
          ),
        ),
        const SizedBox(height: 6),
        // Baseline-aligned row: display value + optional mono unit. Scales
        // down rather than overflowing a third-of-a-narrow-phone card at
        // large text sizes.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: WorkoutType.display(
                  size: 22,
                  weight: FontWeight.w700,
                  color: valueColor,
                ),
              ),
              if (unit != null) ...[
                const SizedBox(width: 3),
                Text(
                  unit!,
                  style: WorkoutType.mono(size: 11, color: tokens.dim),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ── ProgressSelectorRow ───────────────────────────────────────────────────────

/// A tappable card row for selecting the current exercise or target.
///
/// Shows a 38×38 surface3 icon tile on the left, a title + subtitle in the
/// centre, and a 'CHANGE' label + chevron on the right.
///
/// Visual spec: `docs/design_handoff_workout_tracker/design/app/screen-progress.jsx`.
class ProgressSelectorRow extends StatelessWidget {
  const ProgressSelectorRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(15),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              // pad 13/12/13/12 → top 13, right 12, bottom 13, left 12
              padding: const EdgeInsets.fromLTRB(12, 13, 12, 13),
              child: Row(
                children: [
                  // 38×38 surface3 tile with centred accent icon, radius 7.5
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: tokens.surface3,
                      borderRadius: BorderRadius.circular(7.5),
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon, color: tokens.accentText, size: 20),
                  ),
                  const SizedBox(width: 12),
                  // Title + subtitle
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: WorkoutType.body(
                            size: 16,
                            weight: FontWeight.w600,
                            color: tokens.text,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: WorkoutType.mono(
                            size: 11,
                            color: tokens.faint,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 'CHANGE' + chevron
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        AppLocalizations.of(context).progressChange,
                        style: WorkoutType.mono(
                          size: 10,
                          weight: FontWeight.w700,
                          color: tokens.dim,
                          letterSpacing: 0.06 * 10,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(WIcons.chevron, color: tokens.faint, size: 16),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── MetricTabs ────────────────────────────────────────────────────────────────

/// A segmented tab row for switching between the four progress metrics.
///
/// Each segment is labelled by [Metric.short]. The selected segment shows a
/// surface3 background with a 1 px [WorkoutTokens.lineStrong] inner ring;
/// unselected segments are transparent with a 1 px [WorkoutTokens.line] border.
///
/// Visual spec: `docs/design_handoff_workout_tracker/design/app/screen-progress.jsx`.
class MetricTabs extends StatelessWidget {
  const MetricTabs({super.key, required this.selected, required this.onSelect});

  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return Row(
      children: [
        for (var i = 0; i < kMetrics.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: _MetricSegment(
              metric: kMetrics[i],
              isSelected: kMetrics[i].id == selected,
              tokens: tokens,
              onTap: () => onSelect(kMetrics[i].id),
            ),
          ),
        ],
      ],
    );
  }
}

class _MetricSegment extends StatelessWidget {
  const _MetricSegment({
    required this.metric,
    required this.isSelected,
    required this.tokens,
    required this.onTap,
  });

  final Metric metric;
  final bool isSelected;
  final WorkoutTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bgColor = isSelected ? tokens.surface3 : Colors.transparent;
    final borderColor = isSelected ? tokens.lineStrong : tokens.line;
    final textColor = isSelected ? tokens.text : tokens.faint;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: borderColor),
        ),
        alignment: Alignment.center,
        child: Text(
          metricShort(AppLocalizations.of(context), metric.id),
          style: WorkoutType.mono(
            size: 11.5,
            weight: FontWeight.w700,
            color: textColor,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
