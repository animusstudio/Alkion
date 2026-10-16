import 'package:provider/provider.dart';
import 'package:flutter/material.dart';

import '../data/day_template_repository.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../util/dates.dart';
import '../widgets/dashed_border.dart';
import '../widgets/fit_label.dart';

/// The Split sub-tab: a list of training days in rotation.
///
/// [onOpenEditor] is called with the day id to edit (null = new day).
class SplitTab extends StatefulWidget {
  const SplitTab({super.key, required this.onOpenEditor});

  /// Called with the day id to edit (null = new day).
  final void Function(String? id) onOpenEditor;

  @override
  State<SplitTab> createState() => _SplitTabState();
}

class _SplitTabState extends State<SplitTab> {
  late final DayTemplateRepository _repo = DayTemplateRepository.local(
    context.read<LocalDatabase>(),
  );
  late final Stream<List<DayTemplate>> _daysStream = _repo.watchDays();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return StreamBuilder<List<DayTemplate>>(
      stream: _daysStream,
      builder: (context, snap) {
        final days = snap.data ?? [];

        return ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, bottomNavInset(context)),
          children: [
            // Day cards
            ...days.map(
              (day) => Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: SplitDayCard(
                  weekday: day.scheduledWeekday,
                  name: day.name,
                  focus: day.focus,
                  exerciseCount: day.slots.length,
                  onTap: () => widget.onOpenEditor(day.id),
                ),
              ),
            ),

            if (days.isNotEmpty) const SizedBox(height: 14),

            // "New training day" dashed button
            _NewDayButton(
              tokens: tokens,
              onTap: () => widget.onOpenEditor(null),
            ),
          ],
        );
      },
    );
  }
}

// ── Day card ──────────────────────────────────────────────────────────────────

/// A training-day row: weekday block, name, and "focus · N exercises" meta.
///
/// Public so it is directly widget-testable (see `test/ui/split_tab_test.dart`)
/// without mounting the PowerSync-backed [SplitTab].
class SplitDayCard extends StatelessWidget {
  const SplitDayCard({
    super.key,
    required this.weekday,
    required this.name,
    required this.focus,
    required this.exerciseCount,
    required this.onTap,
  });

  /// Monday-origin (0-6) scheduled weekday, or null if unscheduled.
  final int? weekday;
  final String name;
  final String? focus;
  final int exerciseCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);

    // Guard nullable weekday — weekdayShort is non-nullable and indexes an
    // unguarded array.
    final weekBadge = (weekday != null && weekday! >= 0 && weekday! <= 6)
        ? weekdayShort(
            weekday!,
            Localizations.localeOf(context).toLanguageTag(),
          )
        : '–';

    final focusText = focus?.trim() ?? '';
    // The count only (the "{focus} · " prefix stripped), localized.
    final countText = l
        .splitDayMeta('', exerciseCount)
        .replaceFirst(RegExp(r'^\s*·\s*'), '');
    final metaStyle = WorkoutType.mono(size: 11, color: tokens.faint);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: tokens.surface,
          border: Border.all(color: tokens.line),
          borderRadius: BorderRadius.circular(AppRadius.radius),
        ),
        child: Row(
          children: [
            // Weekday block — same width/divider style as History's date
            // block. Scales down rather than wrapping ("MIÉ" at 1.3x).
            SizedBox(
              width: 44,
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    weekBadge.toUpperCase(),
                    maxLines: 1,
                    style: WorkoutType.display(
                      size: 20,
                      weight: FontWeight.w700,
                      color: tokens.text,
                    ),
                  ),
                ),
              ),
            ),

            // Divider
            Container(
              width: 1,
              height: 44,
              color: tokens.line,
              margin: const EdgeInsets.symmetric(horizontal: 13),
            ),

            // Name + meta
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FitLabel(
                    name,
                    maxLines: 2,
                    style: WorkoutType.body(
                      size: 15.5,
                      weight: FontWeight.w600,
                      color: tokens.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // A long focus ellipsizes; the count keeps its own slot,
                  // capped at the row so at large text it shrinks, then
                  // ellipsizes, rather than overflowing.
                  LayoutBuilder(
                    builder: (context, constraints) => Row(
                      children: [
                        if (focusText.isNotEmpty)
                          Flexible(
                            child: Text(
                              focusText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: metaStyle,
                            ),
                          ),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth,
                          ),
                          child: FitLabel(
                            focusText.isNotEmpty ? ' · $countText' : countText,
                            style: metaStyle,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Chevron
            Icon(WIcons.chevron, size: 16, color: tokens.faint),
          ],
        ),
      ),
    );
  }
}

// ── New training day button ───────────────────────────────────────────────────

class _NewDayButton extends StatelessWidget {
  const _NewDayButton({required this.tokens, required this.onTap});

  final WorkoutTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 50,
        decoration: BoxDecoration(
          border: Border.all(
            color: tokens.lineStrong,
            style: BorderStyle.solid,
          ),
          borderRadius: BorderRadius.circular(AppRadius.radius),
          color: Colors.transparent,
        ),
        child: CustomPaint(
          painter: DashedBorderPainter(
            color: tokens.lineStrong,
            radius: AppRadius.radius,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(WIcons.plus, size: 16, color: tokens.dim),
              const SizedBox(width: 7),
              Flexible(
                child: FitLabel(
                  l.planNewDay,
                  style: WorkoutType.mono(
                    size: 13,
                    weight: FontWeight.w600,
                    color: tokens.dim,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
