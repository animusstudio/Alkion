import 'dart:math' as math;
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
///   • `isNext` → coral 'NEXT' label
///   • `done`   → surface-3 pill with a check icon
///   • else     → a 5px dot in `lineStrong`
///
/// The neutral selected surface follows the current selection, not `isNext`:
/// with no [selectedIndex] given it defaults to the `isNext` chip, matching
/// the previous non-interactive behaviour.
///
/// With [onSelect] null, the strip is purely informational (no Custom chip,
/// nothing tappable) — the same as before this became selectable. With
/// [onSelect] set, tapping a day chip calls it with that day's index, and a
/// trailing Custom chip calls it with `days.length`.
///
/// Visual spec: `screen-today.jsx` → `WeekStrip`.
class WeekStrip extends StatefulWidget {
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
  State<WeekStrip> createState() => _WeekStripState();
}

class _WeekStripState extends State<WeekStrip> {
  final _scroll = ScrollController();
  (int, double, double, int)? _reveal;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final filled =
        widget.selectedIndex ?? widget.days.indexWhere((d) => d.isNext);
    return LayoutBuilder(
      builder: (context, box) {
        final width = math.max(
          64.0,
          MediaQuery.textScalerOf(context).scale(52),
        );
        final count = widget.days.length + (widget.onSelect == null ? 0 : 1);
        final total =
            widget.days.length * width +
            (widget.onSelect == null ? 0 : 48) +
            math.max(0, count - 1) * 8;
        final overflow = total > box.maxWidth;
        final signature = (filled, box.maxWidth, width, count);
        if (overflow && _reveal != signature) {
          _reveal = signature;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted ||
                !_scroll.hasClients ||
                _reveal != signature ||
                filled < 0) {
              return;
            }
            final selectedWidth = filled == widget.days.length ? 48.0 : width;
            final offset =
                filled * (width + 8) + selectedWidth / 2 - box.maxWidth / 2;
            _scroll.jumpTo(offset.clamp(0.0, _scroll.position.maxScrollExtent));
          });
        } else if (!overflow) {
          _reveal = null;
        }
        final children = <Widget>[
          for (var i = 0; i < widget.days.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            if (overflow)
              SizedBox(
                width: width,
                child: _DayChip(
                  key: ValueKey('week-chip-$i'),
                  day: widget.days[i],
                  filled: i == filled,
                  onTap: widget.onSelect == null
                      ? null
                      : () => widget.onSelect!(i),
                  tokens: tokens,
                  chipRadius: AppRadius.control,
                ),
              )
            else
              Expanded(
                child: _DayChip(
                  key: ValueKey('week-chip-$i'),
                  day: widget.days[i],
                  filled: i == filled,
                  onTap: widget.onSelect == null
                      ? null
                      : () => widget.onSelect!(i),
                  tokens: tokens,
                  chipRadius: AppRadius.control,
                ),
              ),
          ],
          if (widget.onSelect != null) ...[
            if (widget.days.isNotEmpty) const SizedBox(width: 8),
            _CustomChip(
              key: const ValueKey('week-chip-custom'),
              filled: filled == widget.days.length,
              onTap: () => widget.onSelect!(widget.days.length),
              tokens: tokens,
              chipRadius: AppRadius.control,
            ),
          ],
        ];
        final row = IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        );
        return overflow
            ? SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                child: row,
              )
            : row;
      },
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

    final bgColor = tokens.bg;
    final borderColor = filled ? tokens.text : Colors.transparent;
    final weekdayLabel = day.weekday == null
        ? ''
        : day.weekday! >= 0 && day.weekday! <= 6
        ? weekdayShort(
            day.weekday!,
            Localizations.localeOf(context).toLanguageTag(),
          )
        : '—';

    return Semantics(
      button: onTap != null,
      selected: filled,
      child: GestureDetector(
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
                    style: WorkoutType.body(size: 12, color: tokens.dim),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 4),
                // Day name — two lines, shrinks a little, then ellipsizes.
                FitLabel(
                  day.name,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  style: WorkoutType.body(
                    size: 14,
                    weight: FontWeight.w500,
                    color: tokens.text,
                    letterSpacing: 0,
                  ),
                ),
                // Status slot — 14 tall at 1.0×, growing with the text size so
                // NEXT is never clipped.
                SizedBox(
                  height: MediaQuery.textScalerOf(context).scale(18),
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
        style: WorkoutType.body(
          size: 12,
          weight: FontWeight.w500,
          color: tokens.accentText,
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
            Icon(WIcons.check, size: 12, color: tokens.accentText),
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
        child: Icon(WIcons.check, size: 12, color: tokens.accentText),
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
      selected: filled,
      label: AppLocalizations.of(context).weekStripCustom,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 48,
          constraints: const BoxConstraints(minHeight: 48),
          decoration: BoxDecoration(
            color: tokens.bg,
            borderRadius: BorderRadius.circular(chipRadius),
            border: Border.all(
              color: filled ? tokens.text : Colors.transparent,
            ),
          ),
          child: Icon(WIcons.plus, size: 20, color: tokens.dim),
        ),
      ),
    );
  }
}
