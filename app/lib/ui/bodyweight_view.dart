import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../data/bodyweight_repository.dart';
import '../data/models.dart';
import '../settings/bodyweight_goal.dart';
import '../settings/settings_service.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/typography.dart';
import '../units/unit_format.dart';
import '../units/unit_service.dart';
import '../util/dates.dart';
import '../widgets/card.dart';
import '../widgets/line_chart.dart';
import '../widgets/progress_widgets.dart';
import '../widgets/section_label.dart';
import 'add_weight_sheet.dart';
import 'progress_change.dart';

/// Bodyweight progress view — rendered inside [ProgressScreen] when the
/// target is the `__bodyweight__` sentinel.
///
/// Shows a trend chart, Current / 30-day-delta / Lowest stats,
/// a "Log today's weight" button, and a scrollable history of the last 24 entries
/// with signed deltas, accent-coloured only when they move toward the Profile goal
/// (cut: loss, bulk: gain, maintain: never).
class BodyweightView extends StatefulWidget {
  const BodyweightView({super.key, required this.onOpenPicker});

  /// Called when the user taps the selector row (to switch back to a lift).
  final VoidCallback onOpenPicker;

  @override
  State<BodyweightView> createState() => _BodyweightViewState();
}

class _BodyweightViewState extends State<BodyweightView> {
  late final BodyweightRepository _bwRepo;
  late final Stream<List<BodyweightEntry>> _seriesStream = _bwRepo
      .watchSeriesAsc();

  @override
  void initState() {
    super.initState();
    _bwRepo = BodyweightRepository.local(context.read<LocalDatabase>());
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild on unit change.
    final unitService = context.watch<UnitService>();
    final goal = context.watch<SettingsService>().bodyweightGoal;
    final l = AppLocalizations.of(context);

    return StreamBuilder<List<BodyweightEntry>>(
      stream: _seriesStream,
      builder: (context, snap) {
        final allEntries = snap.data ?? <BodyweightEntry>[];
        final entries = allEntries.where((e) => e.weightKg != null).toList();
        final unit = unitService.uLabel;

        // Map to display-unit values.
        final series = entries
            .map(
              (e) => (
                date: e.date,
                value: UnitService.fromKg(e.weightKg!, unitService.unit),
                reps: 0,
                isPr: false,
              ),
            )
            .toList();

        return ListView(
          // Status-bar inset, mirroring the Progress screen's list padding.
          padding: EdgeInsets.fromLTRB(
            16,
            8 + MediaQuery.paddingOf(context).top,
            16,
            96,
          ),
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.progressProgression,
                    style: WorkoutType.mono(
                      size: 11.5,
                      color: context.tokens.faint,
                      letterSpacing: 0.06 * 11.5,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    l.bodyweightTrend,
                    style: WorkoutType.display(
                      size: 28,
                      weight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),

            // Selector row
            ProgressSelectorRow(
              icon: WIcons.scale,
              title: l.bodyweightTitle,
              subtitle: l.bodyweightDailyLog(entries.length),
              onTap: widget.onOpenPicker,
            ),
            const SizedBox(height: 14),

            // Chart
            WCard(
              padding: const EdgeInsets.fromLTRB(8, 16, 8, 10),
              child: LineChart(
                key: ValueKey('bw-$unit'),
                series: series,
                height: 210,
                unit: unit,
                showReps: false,
                formatValue: fmtBodyweight,
              ),
            ),
            const SizedBox(height: 14),

            if (allEntries.any((entry) => !entry.dateAvailable))
              Text(
                l.alkionBodyweightDateCoverage(
                  allEntries.where((entry) => entry.dateAvailable).length,
                  allEntries.length,
                ),
                style: WorkoutType.mono(size: 11, color: context.tokens.faint),
              ),
            // BigStat cards
            _BwStatRow(
              series: series,
              unit: unit,
              goal: goal,
              currentAvailable:
                  allEntries.isNotEmpty &&
                  allEntries.last.weightKg != null &&
                  allEntries.every((entry) => entry.dateAvailable),
            ),
            const SizedBox(height: 14),

            // Log today's weight button
            _LogTodayButton(repo: _bwRepo),
            const SizedBox(height: 22),

            for (final entry in allEntries.where((e) => e.weightKg == null))
              Text(
                '${entry.date} · ${l.bodyweightUnavailable}',
                style: WorkoutType.mono(size: 12, color: context.tokens.faint),
              ),
            // History section
            SectionLabel(
              label: l.bodyweightHistory,
              action: Text(
                l.bodyweightEntriesCount(allEntries.length),
                style: WorkoutType.mono(size: 11, color: context.tokens.dim),
              ),
            ),
            const SizedBox(height: 8),
            if (series.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Text(
                    l.bodyweightEmpty,
                    style: WorkoutType.mono(
                      size: 13,
                      color: context.tokens.faint,
                    ),
                  ),
                ),
              )
            else
              BodyweightHistoryCard(series: series, unit: unit, goal: goal),
          ],
        );
      },
    );
  }
}

// ── BwStatRow ─────────────────────────────────────────────────────────────────

class _BwStatRow extends StatelessWidget {
  const _BwStatRow({
    required this.series,
    required this.unit,
    required this.goal,
    required this.currentAvailable,
  });

  final List<({String date, double value, int reps, bool isPr})> series;
  final String unit;
  final BodyweightGoal goal;
  final bool currentAvailable;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (series.isEmpty) {
      return Row(
        children: [
          Expanded(
            child: WCard(
              padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
              child: BigStat(
                label: l.bodyweightStatCurrent,
                value: '—',
                unit: unit,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: WCard(
              padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
              child: BigStat(
                label: l.bodyweightStat30Day,
                value: '—',
                unit: unit,
                accent: false,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: WCard(
              padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
              child: BigStat(
                label: l.bodyweightStatLowest,
                value: '—',
                unit: unit,
              ),
            ),
          ),
        ],
      );
    }

    // Rounded to what the cards show, so the delta is the change they read.
    final last = roundBodyweight(series.last.value);
    final lowest = roundBodyweight(
      series.map((s) => s.value).reduce((a, b) => a < b ? a : b),
    );

    // 30-day: earliest entry within the last 30 days.
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(days: 30));
    final month30 = series.firstWhere((s) {
      try {
        final d = qualifiedCalendarDate(s.date);
        return d != null && (d.isAfter(cutoff) || d.isAtSameMomentAs(cutoff));
      } catch (_) {
        return false;
      }
    }, orElse: () => series.first);
    final delta30 = last - roundBodyweight(month30.value);
    final delta30Label = signedChange(delta30, fmtBodyweight, l);

    return Row(
      children: [
        Expanded(
          child: WCard(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
            child: UnitSwap(
              unitKey: unit,
              child: BigStat(
                label: l.bodyweightStatCurrent,
                value: currentAvailable ? fmtBodyweight(last) : '—',
                unit: unit,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: WCard(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
            child: UnitSwap(
              unitKey: unit,
              child: BigStat(
                label: l.bodyweightStat30Day,
                value: currentAvailable ? delta30Label : '—',
                unit: delta30Label == l.progressSame ? null : unit,
                accent:
                    currentAvailable &&
                    bodyweightDeltaTone(
                          displayedBodyweightDelta(delta30),
                          goal,
                        ) ==
                        DeltaTone.good,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: WCard(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
            child: UnitSwap(
              unitKey: unit,
              child: BigStat(
                label: l.bodyweightStatLowest,
                value: fmtBodyweight(lowest),
                unit: unit,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── LogTodayButton ────────────────────────────────────────────────────────────

class _LogTodayButton extends StatelessWidget {
  const _LogTodayButton({required this.repo});

  final BodyweightRepository repo;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: TextButton(
        style: TextButton.styleFrom(
          backgroundColor: tokens.accent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          padding: EdgeInsets.zero,
        ),
        onPressed: () => showAddWeightSheet(context),
        child: Text(
          AppLocalizations.of(context).bodyweightLogToday,
          style: WorkoutType.display(
            size: 15,
            weight: FontWeight.w700,
            color: tokens.accentInk,
          ),
        ),
      ),
    );
  }
}

// ── HistoryCard ───────────────────────────────────────────────────────────────

class BodyweightHistoryCard extends StatelessWidget {
  const BodyweightHistoryCard({
    super.key,
    required this.series,
    required this.unit,
    required this.goal,
  });

  final List<({String date, double value, int reps, bool isPr})> series;
  final String unit;
  final BodyweightGoal goal;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final localeName = Localizations.localeOf(context).toLanguageTag();
    // Newest first, capped at 24.
    final items = series.reversed.take(24).toList();

    return WCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: List.generate(items.length, (i) {
          final entry = items[i];
          // items[i] is series[series.length - 1 - i]; the entry just before
          // it chronologically is series[seriesIndex - 1], which may lie
          // outside the capped-at-24 `items` window for the oldest visible
          // row. Only the very first entry overall has no predecessor.
          final seriesIndex = series.length - 1 - i;
          // Both ends rounded to what the rows show, so the delta is the
          // change between the two displayed weights.
          final value = roundBodyweight(entry.value);
          final prevValue = seriesIndex > 0
              ? roundBodyweight(series[seriesIndex - 1].value)
              : null;
          final diff = prevValue != null ? value - prevValue : 0.0;
          final isLast = i == items.length - 1;

          return Container(
            decoration: BoxDecoration(
              border: isLast
                  ? null
                  : Border(bottom: BorderSide(color: tokens.line, width: 1)),
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                // Date with weekday
                SizedBox(
                  width: 92,
                  child: Text(
                    fmtDate(entry.date, localeName, weekday: true),
                    style: WorkoutType.mono(size: 12, color: tokens.dim),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ),
                const SizedBox(width: 12),
                // Weight value
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: fmtBodyweight(value),
                        style: WorkoutType.mono(
                          size: 14,
                          weight: FontWeight.w700,
                          color: tokens.text,
                        ),
                      ),
                      TextSpan(
                        text: unit,
                        style: WorkoutType.mono(size: 10, color: tokens.faint),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                // Signed, and accent only when it moves the way the goal wants.
                if (prevValue != null)
                  Text(
                    signedChange(diff, fmtBodyweight, l),
                    style: WorkoutType.mono(
                      size: 11.5,
                      weight: FontWeight.w600,
                      color:
                          bodyweightDeltaTone(
                                displayedBodyweightDelta(diff),
                                goal,
                              ) ==
                              DeltaTone.good
                          ? tokens.accentText
                          : tokens.dim,
                    ),
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }
}
