import 'dart:math';
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../util/dates.dart';
import 'fit_label.dart';

// ── DaySlide ──────────────────────────────────────────────────────────────────

/// One page of the split-picker pager showing a single day template.
///
/// [index] is the slide's position among all slides (0-based).
/// [nextIndex] is the rotation target so the eyebrow can be keyed off it.
class DaySlide extends StatelessWidget {
  const DaySlide({
    super.key,
    required this.day,
    required this.exerciseCount,
    required this.lastAgo,
    required this.index,
    required this.nextIndex,
  });

  final DayTemplate day;
  final int exerciseCount;
  final String lastAgo;

  /// Position of this slide within the full slides list.
  final int index;

  /// Index of the rotation target (passed through from [SplitCard]).
  final int nextIndex;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;

    // Eyebrow keyed off the rotation target, NOT literal index 0.
    final isNext = index == nextIndex;
    final eyebrow = isNext
        ? l.splitNextInRotation
        : l.splitSwitchTo(
            (day.scheduledWeekday != null
                    ? weekdayShort(
                        day.scheduledWeekday!,
                        Localizations.localeOf(context).toLanguageTag(),
                      )
                    : day.name)
                .toUpperCase(),
          );

    // Estimated time: max(20, (exerciseCount * 9 + 10).round())m
    final est = max(20, exerciseCount * 9 + 10);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FitLabel(
          day.name,
          maxLines: 2,
          style: WorkoutType.display(
            size: 28,
            weight: FontWeight.w700,
            color: tokens.text,
          ),
        ),
        const SizedBox(height: 8),
        FitLabel(
          eyebrow,
          style: WorkoutType.body(
            size: 12,
            weight: FontWeight.w700,
            color: tokens.accentText,
          ),
        ),
        if (day.focus != null && day.focus!.isNotEmpty) ...[
          const SizedBox(height: 8),
          FitLabel(
            day.focus!,
            maxLines: 2,
            style: WorkoutType.body(size: 16, color: tokens.dim),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _StatCol(
                value: '$exerciseCount',
                label: l.splitExercises,
                valueColor: tokens.text,
                labelColor: tokens.dim,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCol(
                value: l.splitEstTimeValue(est),
                label: l.splitEstTime,
                valueColor: tokens.text,
                labelColor: tokens.dim,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCol(
                value: lastAgo.isEmpty ? '—' : lastAgo,
                label: l.splitLast,
                valueColor: tokens.text,
                labelColor: tokens.dim,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StatCol extends StatelessWidget {
  const _StatCol({
    required this.value,
    required this.label,
    required this.valueColor,
    required this.labelColor,
  });

  final String value;
  final String label;
  final Color valueColor;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: WorkoutType.mono(
              size: 16,
              weight: FontWeight.w700,
              color: valueColor,
            ),
          ),
        ),
        const SizedBox(height: 4),
        FitLabel(
          label.toUpperCase(),
          maxLines: 2,
          style: WorkoutType.body(size: 12, color: labelColor),
        ),
      ],
    );
  }
}

// ── CustomSlide ───────────────────────────────────────────────────────────────

/// The final page of the split-picker pager for a free-form custom session.
class CustomSlide extends StatelessWidget {
  const CustomSlide({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;
    final textColor = tokens.text;
    final dimColor = tokens.dim;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FitLabel(
          l.todayCustomSession,
          maxLines: 2,
          style: WorkoutType.display(
            size: 28,
            weight: FontWeight.w700,
            color: textColor,
          ),
        ),
        const SizedBox(height: 8),
        FitLabel(
          l.splitNoTemplate,
          style: WorkoutType.body(
            size: 12,
            weight: FontWeight.w700,
            color: dimColor,
          ),
        ),
        const SizedBox(height: 4),
        // Sub
        FitLabel(
          l.splitBuildAsYouGo,
          maxLines: 2,
          style: WorkoutType.body(size: 16, color: dimColor),
        ),
        const SizedBox(height: 18),
        // Hint row — the hint takes the rest of the row, two lines at most.
        Row(
          children: [
            Icon(WIcons.plus, size: 17, color: dimColor),
            const SizedBox(width: 9),
            Flexible(
              child: FitLabel(
                l.splitAddExercisesLive,
                maxLines: 2,
                style: WorkoutType.body(
                  size: 12,
                  weight: FontWeight.w600,
                  color: dimColor,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── SplitCard ─────────────────────────────────────────────────────────────────

/// The hero split-picker pager on the Today dashboard.
///
/// Renders a [PageView] of [DaySlide]s plus a final [CustomSlide].
/// The card body animates between accent (day slides) and surface (custom slide).
/// A fixed Start button sits below the pager inside the card.
/// The pager responds to both swipes and outside selection control.
class SplitCard extends StatefulWidget {
  const SplitCard({
    super.key,
    required this.days,
    required this.nextIndex,
    required this.onStart,
    this.selectedIndex,
    this.onSelectedChanged,
  });

  /// Day slides data. Each entry carries the template, exercise count, and
  /// a human-readable "last trained" label (e.g. '3d ago' or '—').
  final List<({DayTemplate day, int exerciseCount, String lastAgo})> days;

  /// Index (within [days]) of the rotation target.
  ///
  /// The pager opens on this slide. The eyebrow on the matching slide reads
  /// 'NEXT IN ROTATION'; all others read 'SWITCH TO · {WEEKDAY}'.
  final int nextIndex;

  /// Called when the user taps Start.
  ///
  /// Receives the selected [DayTemplate], or `null` if the Custom slide is
  /// active (meaning the user wants an empty free-form session).
  final void Function(DayTemplate?) onStart;

  /// The page to show, from the parent (index `days.length` is Custom).
  ///
  /// `null` keeps the pager self-driven from `nextIndex`.
  final int? selectedIndex;

  /// Called when the user swipes to a page.
  final ValueChanged<int>? onSelectedChanged;

  @override
  State<SplitCard> createState() => _SplitCardState();
}

class _SplitCardState extends State<SplitCard> {
  late PageController _pageController;
  late int _currentPage;

  /// The page a programmatic [_goTo] is currently driving the pager toward,
  /// or null when the pager isn't being driven (idle, or mid-swipe).
  ///
  /// While set: `onPageChanged` swallows reports for every intermediate page
  /// the animation crosses (only the target page gets reported), and
  /// `_onStart` treats this as the "current" page so a tap that lands mid
  /// animation launches the destination day, not whatever page the pager
  /// happened to be passing through.
  int? _driveTarget;

  @override
  void initState() {
    super.initState();
    _currentPage = (widget.selectedIndex ?? widget.nextIndex).clamp(
      0,
      widget.days.length,
    );
    _pageController = PageController(initialPage: _currentPage);
  }

  @override
  void didUpdateWidget(SplitCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sel = widget.selectedIndex;
    // `sel != _currentPage` breaks the parent round-trip: a swipe already
    // reports the new page via onSelectedChanged, the parent's setState
    // feeds it straight back as `selectedIndex`, and by the time this widget
    // rebuilds `_currentPage` already matches `sel` — re-driving here would
    // needlessly re-animate the pager back to the page it just settled on.
    if (sel != null && sel != oldWidget.selectedIndex && sel != _currentPage) {
      _goTo(sel);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  int get _totalSlides => widget.days.length + 1; // days + Custom

  bool get _isCustom => _currentPage >= widget.days.length;

  void _goTo(int page) {
    final target = page.clamp(0, _totalSlides - 1);
    final duration = Motion.of(context, Motion.slow);
    _driveTarget = target;
    if (duration == Duration.zero) {
      // A synchronous jumpToPage here would fire onPageChanged during THIS
      // build (didUpdateWidget runs mid-build), which calls the parent's
      // setState mid-build too. Defer to a post-frame callback instead.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pageController.hasClients) return;
        _pageController.jumpToPage(target);
        if (_driveTarget == target) _driveTarget = null;
      });
      return;
    }
    _pageController
        .animateToPage(target, duration: duration, curve: Motion.curve)
        .then((_) {
          if (_driveTarget == target) _driveTarget = null;
        });
  }

  void _onStart() {
    final page = _driveTarget ?? _currentPage;
    if (page >= widget.days.length) {
      widget.onStart(null);
    } else {
      widget.onStart(widget.days[page].day);
    }
  }

  // Reserve the tallest slide at this width, so paging never moves Start.
  // Labels may fit smaller through FitLabel, but never need more height.
  double _pagerHeight(BuildContext context, double width) {
    final l = AppLocalizations.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    double labelHeight(String text, TextStyle style, int lines, double space) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: lines,
      )..layout(maxWidth: max(1, space));
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final title = WorkoutType.display(size: 28, weight: FontWeight.w700);
    final body = WorkoutType.body(size: 16);
    final caption = WorkoutType.body(size: 12);
    final statWidth = (width - 24) / 3;
    final statHeight =
        scaler.scale(16) * 1.4 +
        4 +
        [l.splitExercises, l.splitEstTime, l.splitLast]
            .map(
              (text) => labelHeight(text.toUpperCase(), caption, 2, statWidth),
            )
            .reduce(max);
    var tallest =
        labelHeight(l.todayCustomSession, title, 2, width) +
        8 +
        labelHeight(l.splitNoTemplate, caption, 1, width) +
        4 +
        labelHeight(l.splitBuildAsYouGo, body, 2, width) +
        18 +
        max(17, labelHeight(l.splitAddExercisesLive, caption, 2, width - 26));
    for (final entry in widget.days) {
      final focus = entry.day.focus;
      final height =
          labelHeight(entry.day.name, title, 2, width) +
          8 +
          scaler.scale(12) * 1.4 +
          (focus != null && focus.isNotEmpty
              ? 8 + labelHeight(focus, body, 2, width)
              : 0) +
          16 +
          statHeight;
      tallest = max(tallest, height);
    }
    return tallest.ceilToDouble() + 4;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;

    // A neutral plate keeps day identity and the Start action distinct.
    final cardBg = tokens.surface;

    // Start button colours
    final btnBg = tokens.action;
    final btnInk = tokens.onAction;
    final btnIcon = _isCustom ? WIcons.plus : WIcons.bolt;
    final btnLabel = _isCustom ? l.splitStartEmpty : l.splitStartWorkout;

    return Column(
      children: [
        // ── Card body ────────────────────────────────────────────────────────
        AnimatedContainer(
          duration: Motion.of(context, Motion.base),
          curve: Motion.curve,
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(AppRadius.radius),
            border: Border.all(color: tokens.line),
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.pad),
                child: LayoutBuilder(
                  builder: (context, box) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── Pager ────────────────────────────────────────────────
                      SizedBox(
                        height: _pagerHeight(context, box.maxWidth),
                        child: ClipRect(
                          child: PageView.builder(
                            controller: _pageController,
                            itemCount: _totalSlides,
                            onPageChanged: (page) {
                              setState(() => _currentPage = page);
                              // While a programmatic _goTo is driving the
                              // pager, PageView reports every intermediate
                              // page the animation crosses — swallow those so
                              // the strip/parent only ever hear about the
                              // final target.
                              if (_driveTarget != null &&
                                  page != _driveTarget) {
                                return;
                              }
                              widget.onSelectedChanged?.call(page);
                            },
                            itemBuilder: (context, i) {
                              if (i < widget.days.length) {
                                final entry = widget.days[i];
                                return DaySlide(
                                  day: entry.day,
                                  exerciseCount: entry.exerciseCount,
                                  lastAgo: entry.lastAgo,
                                  index: i,
                                  nextIndex: widget.nextIndex,
                                );
                              }
                              return const CustomSlide();
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      // ── Start button ─────────────────────────────────────────
                      FilledButton(
                        onPressed: _onStart,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(double.infinity, 52),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          backgroundColor: btnBg,
                          foregroundColor: btnInk,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              AppRadius.control,
                            ),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(btnIcon, size: 20, color: btnInk),
                            const SizedBox(width: 8),
                            Flexible(
                              child: FitLabel(
                                btnLabel,
                                maxLines: 2,
                                style: WorkoutType.body(
                                  size: 16,
                                  weight: FontWeight.w700,
                                  color: btnInk,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
