import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../data/bodyweight_repository.dart';
import '../data/models.dart';
import '../settings/bodyweight_goal.dart';
import '../settings/settings_service.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/alkion_icon.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
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
/// a "Log today's weight" button, and the history: the newest 24 entries, then
/// "Show all N", with signed deltas, accent-coloured only when they move
/// toward the Profile goal (cut: loss, bulk: gain, maintain: never). Every row
/// with an available date opens the sheet to edit or delete that entry.
class BodyweightView extends StatefulWidget {
  const BodyweightView({super.key, required this.onOpenPicker, this.now});

  /// Called when the user taps the selector row (to switch back to a lift).
  final VoidCallback onOpenPicker;

  /// The day the 30-day window ends on; defaults to [DateTime.now] (tests
  /// fix it).
  final DateTime? now;

  @override
  State<BodyweightView> createState() => _BodyweightViewState();
}

class _BodyweightViewState extends State<BodyweightView> {
  late final BodyweightRepository _bwRepo;
  late final Stream<List<BodyweightEntry>> _seriesStream = _bwRepo
      .watchSeriesAsc();

  /// "Show all N" was tapped. Held here, not on the card, so the lazy list
  /// recycling the card cannot collapse it again.
  bool _showAll = false;

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
            bottomNavInset(context),
          ),
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.bodyweightTrend,
                    style: WorkoutType.display(
                      size: 28,
                      weight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),

            // Selector row
            ProgressSelectorRow(
              icon: AlkionGlyph.scale,
              title: l.bodyweightTitle,
              // One count everywhere: every stored entry, readable or not.
              subtitle: l.bodyweightDailyLog(allEntries.length),
              onTap: widget.onOpenPicker,
            ),
            const SizedBox(height: 16),

            // Chart
            WCard(
              padding: const EdgeInsets.fromLTRB(8, 16, 8, 10),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  LineChart(
                    key: ValueKey('bw-$unit'),
                    series: series,
                    height: 210,
                    unit: unit,
                    showReps: false,
                    formatValue: fmtBodyweight,
                  ),
                  if (series.length < 2)
                    Text(
                      allEntries.isEmpty
                          ? l.bodyweightEmpty
                          : series.isEmpty
                          ? l.bodyweightUnavailable
                          : l.progressTrendNeedsMore,
                      textAlign: TextAlign.center,
                      style: WorkoutType.body(
                        size: 14,
                        color: context.tokens.dim,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            if (allEntries.any((entry) => !entry.dateAvailable))
              Text(
                l.alkionBodyweightDateCoverage(
                  allEntries.where((entry) => entry.dateAvailable).length,
                  allEntries.length,
                ),
                style: WorkoutType.body(size: 12, color: context.tokens.faint),
              ),
            // BigStat cards
            _BwStatRow(
              series: series,
              unit: unit,
              goal: goal,
              now: widget.now,
              currentAvailable:
                  allEntries.isNotEmpty &&
                  allEntries.last.weightKg != null &&
                  allEntries.every((entry) => entry.dateAvailable),
            ),
            const SizedBox(height: 16),

            // Log today's weight button
            _LogTodayButton(repo: _bwRepo),
            const SizedBox(height: 24),

            // History section
            SectionLabel(
              label: l.bodyweightHistory,
              action: Text(
                l.bodyweightEntriesCount(allEntries.length),
                style: WorkoutType.mono(size: 12, color: context.tokens.dim),
              ),
            ),
            const SizedBox(height: 8),
            if (allEntries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Text(
                    l.bodyweightEmpty,
                    style: WorkoutType.body(
                      size: 14,
                      color: context.tokens.faint,
                    ),
                  ),
                ),
              )
            else
              BodyweightHistoryCard(
                entries: allEntries,
                unit: unitService.unit,
                goal: goal,
                expanded: _showAll,
                onShowAll: () => setState(() => _showAll = true),
                onEdit: (entry) => showAddWeightSheet(context, selected: entry),
              ),
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
    this.now,
  });

  final List<({String date, double value, int reps, bool isPr})> series;
  final String unit;
  final BodyweightGoal goal;
  final bool currentAvailable;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    Widget tile(
      String label,
      String value,
      String? shownUnit, {
      bool accent = false,
    }) => WCard(
      padding: const EdgeInsets.all(16),
      child: UnitSwap(
        unitKey: shownUnit ?? '',
        child: BigStat(
          label: label,
          value: value,
          unit: shownUnit,
          accent: accent,
        ),
      ),
    );
    if (series.isEmpty) {
      return ProgressStatRow(
        children: [
          tile(l.bodyweightStatCurrent, '—', unit),
          tile(l.bodyweightStat30Day, '—', unit),
          tile(l.bodyweightStatLowest, '—', unit),
        ],
      );
    }

    // Rounded to what the cards show, so the delta is the change they read.
    final last = roundBodyweight(series.last.value);
    final lowest = roundBodyweight(
      series.map((s) => s.value).reduce((a, b) => a < b ? a : b),
    );

    final baseline = bodyweightMonthBaseline(series, now: now);
    final delta30 = baseline == null
        ? null
        : last - roundBodyweight(baseline.value);
    final delta30Label = delta30 == null
        ? '—'
        : signedChange(delta30, fmtBodyweight, l);
    final delta30Shown = currentAvailable && delta30 != null;

    return ProgressStatRow(
      children: [
        tile(
          l.bodyweightStatCurrent,
          currentAvailable ? fmtBodyweight(last) : '—',
          unit,
        ),
        tile(
          l.bodyweightStat30Day,
          delta30Shown ? delta30Label : '—',
          delta30Shown && delta30Label != l.progressSame ? unit : null,
          accent:
              delta30Shown &&
              bodyweightDeltaTone(displayedBodyweightDelta(delta30), goal) ==
                  DeltaTone.good,
        ),
        tile(l.bodyweightStatLowest, fmtBodyweight(lowest), unit),
      ],
    );
  }
}

/// The 30-day change's baseline: the earliest entry of [series] (ascending by
/// date) dated within the 30 calendar days up to [now], other than the
/// current one (`series.last`). Null when there is none, so the change reads
/// "—" instead of reaching outside the window. [now] defaults to
/// [DateTime.now].
({String date, double value, int reps, bool isPr})? bodyweightMonthBaseline(
  List<({String date, double value, int reps, bool isPr})> series, {
  DateTime? now,
}) {
  final clock = now ?? DateTime.now();
  final today = DateTime(clock.year, clock.month, clock.day);
  // Calendar arithmetic, not a 30 × 24 h Duration, so DST cannot move it.
  final cutoff = DateTime(today.year, today.month, today.day - 30);
  for (var i = 0; i < series.length - 1; i++) {
    final day = qualifiedCalendarDate(series[i].date);
    if (day == null || day.isBefore(cutoff) || day.isAfter(today)) continue;
    return series[i];
  }
  return null;
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
      child: TextButton(
        style: TextButton.styleFrom(
          backgroundColor: tokens.action,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          minimumSize: const Size(48, 52),
        ),
        onPressed: () => showAddWeightSheet(context),
        child: Text(
          AppLocalizations.of(context).bodyweightLogToday,
          style: WorkoutType.body(
            size: 16,
            weight: FontWeight.w500,
            color: tokens.onAction,
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
    required this.entries,
    required this.unit,
    required this.goal,
    this.expanded = false,
    this.onShowAll,
    this.onEdit,
  });

  /// Rows shown before "Show all N".
  static const collapsedRows = 24;

  /// Every stored entry, oldest first, readable or not.
  final List<BodyweightEntry> entries;
  final Unit unit;
  final BodyweightGoal goal;

  /// Shows every row instead of the newest [collapsedRows].
  final bool expanded;
  final VoidCallback? onShowAll;

  /// Opens an entry for editing. Rows whose date is unavailable stay
  /// read-only: the store cannot address them by day.
  final ValueChanged<BodyweightEntry>? onEdit;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final localeName = Localizations.localeOf(context).toLanguageTag();
    final unitLabel = unit == Unit.lb ? 'lb' : 'kg';

    // Rounded to what the rows show, so a delta is the change between two
    // displayed weights. Each readable row compares with the previous
    // readable entry, which may lie outside the visible rows.
    final shown = <double?>[];
    final previous = <double?>[];
    double? last;
    for (final entry in entries) {
      final kg = entry.weightKg;
      final value = kg == null
          ? null
          : roundBodyweight(UnitService.fromKg(kg, unit));
      shown.add(value);
      previous.add(last);
      if (value != null) last = value;
    }

    // Newest first.
    final collapsed = !expanded && entries.length > collapsedRows;
    final count = collapsed ? collapsedRows : entries.length;
    final rows = <Widget>[];
    for (var i = 0; i < count; i++) {
      final index = entries.length - 1 - i;
      rows.add(
        _row(
          context,
          entry: entries[index],
          value: shown[index],
          prevValue: previous[index],
          unitLabel: unitLabel,
          localeName: localeName,
          divider: i < count - 1 || collapsed,
          tokens: tokens,
          l: l,
        ),
      );
    }

    return Material(
      color: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.panel),
        side: BorderSide(color: tokens.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...rows,
          if (collapsed)
            TextButton(
              key: const Key('bodyweight-show-all'),
              onPressed: onShowAll,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                shape: const RoundedRectangleBorder(),
              ),
              child: Text(
                l.bodyweightShowAll(entries.length),
                style: WorkoutType.body(
                  size: 14,
                  weight: FontWeight.w500,
                  color: tokens.text,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required BodyweightEntry entry,
    required double? value,
    required double? prevValue,
    required String unitLabel,
    required String localeName,
    required bool divider,
    required WorkoutTokens tokens,
    required AppLocalizations l,
  }) {
    final diff = value != null && prevValue != null ? value - prevValue : null;
    final editable =
        onEdit != null &&
        entry.dateAvailable &&
        entry.id != null &&
        entry.localRevision != null;
    final content = Container(
      constraints: const BoxConstraints(minHeight: 48),
      decoration: BoxDecoration(
        border: divider
            ? Border(bottom: BorderSide(color: tokens.line, width: 1))
            : null,
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            fmtDate(entry.date, localeName, weekday: true),
            style: WorkoutType.mono(size: 12, color: tokens.dim),
            maxLines: 1,
            softWrap: false,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: value == null ? '—' : fmtBodyweight(value),
                          style: WorkoutType.mono(
                            size: 14,
                            weight: FontWeight.w400,
                            color: tokens.text,
                          ),
                        ),
                        if (value != null)
                          TextSpan(
                            text: unitLabel,
                            style: WorkoutType.mono(
                              size: 12,
                              color: tokens.faint,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              if (value == null)
                Flexible(
                  child: Text(
                    l.bodyweightUnavailable,
                    textAlign: TextAlign.end,
                    style: WorkoutType.body(size: 12, color: tokens.faint),
                  ),
                )
              else if (diff != null)
                Text(
                  signedChange(diff, fmtBodyweight, l),
                  style: WorkoutType.mono(
                    size: 12,
                    weight: FontWeight.w400,
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
        ],
      ),
    );
    if (!editable) return content;
    return MergeSemantics(
      child: Semantics(
        button: true,
        onTapHint: l.bodyweightEditTitle,
        child: InkWell(
          onTap: () => onEdit!(entry),
          focusColor: tokens.focus.withValues(alpha: .16),
          child: content,
        ),
      ),
    );
  }
}
