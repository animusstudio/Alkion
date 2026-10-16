import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../theme/icons.dart';
import '../util/dates.dart';
import 'fit_label.dart';

/// A horizontal row of day chips showing the weekly rotation state.
///
/// Each chip shows the weekday label, the day name, and a status indicator:
///   • `isNext` → accent background + 'NEXT' label
///   • `done`   → surface-3 pill with a check icon
///   • else     → a 5px dot in `lineStrong`
///
/// The fill (accent background) follows the current selection, not `isNext`:
/// with no [selectedIndex] given it defaults to the `isNext` chip, matching
/// the previous non-interactive behaviour.
///
/// With [onSelect] null, the strip is purely informational (no Custom chip,
/// nothing tappable) — the same as before this became selectable. With
/// [onSelect] set, tapping a day chip calls it with that day's index, and a
/// trailing Custom chip calls it with `days.length`.
///
/// Visual spec: `screen-today.jsx` → `WeekStrip`.
class WeekStrip extends StatelessWidget {
  const WeekStrip({
    super.key,
    required this.days,
    this.selectedIndex,
    this.onSelect,
  });

  /// Each entry describes one chip in the strip.
  ///
  /// - [name]    — day template name
  /// - [weekday] — 0-based Monday-origin weekday (0=Mon…6=Sun); used via
  ///               [weekdayShort]. `null` → shows an empty string.
  /// - [isNext]  — the next day in rotation (carries the NEXT label)
  /// - [done]    — shows a check icon (this day was trained this week)
  final List<({String name, int? weekday, bool isNext, bool done})> days;

  /// The currently selected chip index, or `days.length` for Custom.
  /// Defaults to the `isNext` chip when null.
  final int? selectedIndex;

  /// Called with the tapped day's index, or `days.length` for Custom.
  /// `null` keeps the strip non-interactive (no Custom chip either).
  final ValueChanged<int>? onSelect;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final chipRadius = AppRadius.radius * 0.7;
    final filled = selectedIndex ?? days.indexWhere((d) => d.isNext);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < days.length; i++) ...[
            if (i > 0) const SizedBox(width: 7),
            Expanded(
              child: _DayChip(
                key: ValueKey('week-chip-$i'),
                day: days[i],
                filled: i == filled,
                onTap: onSelect == null ? null : () => onSelect!(i),
                tokens: tokens,
                chipRadius: chipRadius,
              ),
            ),
          ],
          if (onSelect != null) ...[
            const SizedBox(width: 7),
            _CustomChip(
              key: const ValueKey('week-chip-custom'),
              filled: filled == days.length,
              onTap: () => onSelect!(days.length),
              tokens: tokens,
              chipRadius: chipRadius,
            ),
          ],
        ],
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({
    super.key,
    required this.day,
    required this.filled,
    required this.onTap,
    required this.tokens,
    required this.chipRadius,
  });

  final ({String name, int? weekday, bool isNext, bool done}) day;
  final bool filled;
  final VoidCallback? onTap;
  final WorkoutTokens tokens;
  final double chipRadius;

  @override
  Widget build(BuildContext context) {
    final isDone = day.done;

    final bgColor = filled ? tokens.accent : tokens.surface;
    final borderColor = filled ? Colors.transparent : tokens.line;
    final weekdayLabel = day.weekday != null
        ? weekdayShort(
            day.weekday!,
            Localizations.localeOf(context).toLanguageTag(),
          )
        : '';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Container(
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(chipRadius),
            border: Border.all(color: borderColor),
          ),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Weekday label — a 2–3 letter code: scales down, never wraps.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  weekdayLabel,
                  maxLines: 1,
                  softWrap: false,
                  style: WorkoutType.mono(
                    size: 9.5,
                    color: filled
                        ? tokens.accentInk.withValues(alpha: 0.7)
                        : tokens.faint,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 4),
              // Day name — two lines, shrinks a little, then ellipsizes.
              FitLabel(
                day.name,
                maxLines: 2,
                textAlign: TextAlign.center,
                style: WorkoutType.display(
                  size: 13,
                  weight: FontWeight.w700,
                  color: filled ? tokens.accentInk : tokens.text,
                  letterSpacing: 0,
                ),
              ),
              // Status slot — 14 tall at 1.0×, growing with the text size so
              // NEXT is never clipped.
              SizedBox(
                height: MediaQuery.textScalerOf(context).scale(14),
                child: Center(
                  child: _StatusIndicator(
                    isNext: day.isNext,
                    isDone: isDone,
                    filled: filled,
                    tokens: tokens,
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

class _StatusIndicator extends StatelessWidget {
  const _StatusIndicator({
    required this.isNext,
    required this.isDone,
    required this.filled,
    required this.tokens,
  });

  final bool isNext;
  final bool isDone;
  final bool filled;
  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    if (isNext) {
      final next = Text(
        AppLocalizations.of(context).weekStripNext,
        maxLines: 1,
        softWrap: false,
        style: WorkoutType.mono(
          size: 9,
          weight: FontWeight.w700,
          color: filled ? tokens.accentInk : tokens.accentText,
          letterSpacing: 0.06 * 9,
        ),
      );
      // One line always: a narrow chip scales it down rather than wrapping.
      if (!isDone) return FittedBox(fit: BoxFit.scaleDown, child: next);
      // Both next and already done this week: NEXT plus a small check,
      // scaled down to fit a narrow chip (a long NEXT label, large text).
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            next,
            const SizedBox(width: 3),
            Icon(
              WIcons.check,
              size: 10,
              color: filled ? tokens.accentInk : tokens.accentText,
            ),
          ],
        ),
      );
    }
    if (isDone) {
      return Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: tokens.surface3,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Icon(WIcons.check, size: 11, color: tokens.accentText),
      );
    }
    // Idle dot
    return Container(
      width: 5,
      height: 5,
      decoration: BoxDecoration(
        color: tokens.lineStrong,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
    );
  }
}

class _CustomChip extends StatelessWidget {
  const _CustomChip({
    super.key,
    required this.filled,
    required this.onTap,
    required this.tokens,
    required this.chipRadius,
  });

  final bool filled;
  final VoidCallback onTap;
  final WorkoutTokens tokens;
  final double chipRadius;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: AppLocalizations.of(context).weekStripCustom,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 48,
          constraints: const BoxConstraints(minHeight: 48),
          decoration: BoxDecoration(
            color: filled ? tokens.accent : tokens.surface,
            borderRadius: BorderRadius.circular(chipRadius),
            border: Border.all(
              color: filled ? Colors.transparent : tokens.line,
            ),
          ),
          child: Icon(
            WIcons.plus,
            size: 20,
            color: filled ? tokens.accentInk : tokens.dim,
          ),
        ),
      ),
    );
  }
}
