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

// ── Shared progress controls ─────────────────────────────────────────────────

/// Label and exact value, with a separate unit slot.
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FitLabel(
          label.toUpperCase(),
          maxLines: 2,
          style: WorkoutType.body(
            size: 12,
            weight: FontWeight.w500,
            color: tokens.dim,
            letterSpacing: .72,
          ),
        ),
        const SizedBox(height: 8),
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
                maxLines: 1,
                softWrap: false,
                style: WorkoutType.mono(
                  size: 22,
                  weight: FontWeight.w400,
                  color: accent ? tokens.accentText : tokens.text,
                ),
              ),
              if (unit != null) ...[
                const SizedBox(width: 4),
                Text(
                  unit!,
                  style: WorkoutType.mono(size: 12, color: tokens.dim),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Existing stat plates reflow at larger system text sizes.
class ProgressStatRow extends StatelessWidget {
  const ProgressStatRow({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns =
          constraints.maxWidth < MediaQuery.textScalerOf(context).scale(240)
          ? 1
          : 3;
      final width = (constraints.maxWidth - 8 * (columns - 1)) / columns;
      return Wrap(
        spacing: 8,
        runSpacing: 12,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}

/// Existing exercise/measurement selection, styled as a flat tonal plate.
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
    return Material(
      color: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.panel),
        side: BorderSide(color: tokens.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        focusColor: tokens.focus.withValues(alpha: .16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, color: tokens.text, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FitLabel(
                      title,
                      maxLines: 2,
                      style: WorkoutType.body(
                        size: 16,
                        weight: FontWeight.w400,
                        color: tokens.text,
                      ),
                    ),
                    const SizedBox(height: 4),
                    FitLabel(
                      subtitle,
                      maxLines: 2,
                      style: WorkoutType.body(size: 12, color: tokens.dim),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      AppLocalizations.of(context).progressChange,
                      style: WorkoutType.body(
                        size: 12,
                        weight: FontWeight.w500,
                        color: tokens.text,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(WIcons.chevron, color: tokens.dim, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// Metric selection stays neutral; the plotted workout data carries color.
class MetricTabs extends StatelessWidget {
  const MetricTabs({super.key, required this.selected, required this.onSelect});
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked =
            constraints.maxWidth < MediaQuery.textScalerOf(context).scale(240);
        final count = stacked ? 2 : 4;
        final width = (constraints.maxWidth - 8 * (count - 1)) / count;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final metric in kMetrics)
              SizedBox(
                width: width,
                child: _MetricSegment(
                  metric: metric,
                  isSelected: metric.id == selected,
                  tokens: context.tokens,
                  onTap: () => onSelect(metric.id),
                ),
              ),
          ],
        );
      },
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
    return Semantics(
      selected: isSelected,
      button: true,
      child: Material(
        color: isSelected ? tokens.surface2 : tokens.sunken,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
          side: BorderSide(color: isSelected ? tokens.lineStrong : tokens.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          focusColor: tokens.focus.withValues(alpha: .16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Center(
                child: FitLabel(
                  metricShort(AppLocalizations.of(context), metric.id),
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  style: WorkoutType.body(
                    size: 14,
                    weight: FontWeight.w500,
                    color: isSelected ? tokens.text : tokens.dim,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
