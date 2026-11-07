import 'dart:math';
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../data/body_workload.dart';
import '../ui/body_figure.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
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
    this.workload,
    this.bodyVisible = true,
  });

  final WorkoutWorkload? workload;
  final bool bodyVisible;
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

    // Eyebrow keyed off the rotation target, NOT literal index 0.
    final isNext = index == nextIndex;
    final eyebrow = isNext
        ? l.splitNextInRotation
        : l.splitSwitchTo(
            (day.scheduledWeekday != null &&
                        day.scheduledWeekday! >= 0 &&
                        day.scheduledWeekday! <= 6
                    ? weekdayShort(
                        day.scheduledWeekday!,
                        Localizations.localeOf(context).toLanguageTag(),
                      )
                    : day.name)
                .toUpperCase(),
          );

    // Estimated time: max(20, (exerciseCount * 9 + 10).round())m
    final est = max(20, exerciseCount * 9 + 10);

    return _SlideLayout(
      workload: workload,
      bodyVisible: bodyVisible,
      title: day.name,
      contextLabel: eyebrow,
      focus: day.focus,
      details: [
        (label: l.splitExercises, value: '$exerciseCount'),
        (label: l.splitEstTime, value: l.splitEstTimeValue(est)),
        (label: l.splitLast, value: lastAgo.isEmpty ? '—' : lastAgo),
      ],
    );
  }
}

/// Workout metadata remains separate from the selected workload artwork.
/// Large text stacks the figure below the real workout metadata.
class _SlideLayout extends StatelessWidget {
  const _SlideLayout({
    required this.title,
    required this.contextLabel,
    this.focus,
    this.details = const [],
    this.hint,
    this.workload,
    this.bodyVisible = true,
  });

  final WorkoutWorkload? workload;
  final bool bodyVisible;
  final String title;
  final String contextLabel;
  final String? focus;
  final String? hint;
  final List<({String label, String value})> details;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return LayoutBuilder(
      builder: (context, box) {
        final stacked = splitOverviewStacked(context, box.maxWidth);
        final width = splitFigureWidth(context, box.maxWidth);
        final figure = bodyVisible
            ? BodyFigure(
                width: width,
                workload:
                    workload ??
                    WorkoutWorkload.loading(WorkoutWorkloadMode.planned),
              )
            : SizedBox(width: width, height: BodyFigure.heightFor(width));
        final information = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (focus?.isNotEmpty == true) ...[
              FitLabel(
                focus!,
                maxLines: 3,
                style: WorkoutType.body(size: 16, color: t.dim),
              ),
              const SizedBox(height: 16),
            ],
            for (final detail in details) ...[
              FitLabel(
                detail.label,
                maxLines: 2,
                style: WorkoutType.body(size: 12, color: t.dim),
              ),
              const SizedBox(height: 2),
              FitLabel(
                detail.value,
                maxLines: 2,
                style: WorkoutType.mono(size: 12, color: t.text),
              ),
              const SizedBox(height: 12),
            ],
            if (hint != null)
              FitLabel(
                hint!,
                maxLines: 3,
                style: WorkoutType.body(size: 12, color: t.dim),
              ),
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            FitLabel(
              title,
              maxLines: 2,
              style: WorkoutType.display(size: 28, color: t.text),
            ),
            const SizedBox(height: 8),
            FitLabel(
              contextLabel,
              maxLines: 1,
              style: WorkoutType.body(size: 12, color: t.accentText),
            ),
            const SizedBox(height: 12),
            if (stacked) ...[
              information,
              const SizedBox(height: 12),
              Center(child: figure),
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: information),
                  const SizedBox(width: _figureGap),
                  figure,
                ],
              ),
          ],
        );
      },
    );
  }
}

/// Whether a slide [width] wide stacks the figure under its info.
bool splitOverviewStacked(BuildContext context, double width) =>
    width < 240 || MediaQuery.textScalerOf(context).scale(12) > 18;

const _figureGap = 12.0;

/// The info column keeps at least this width beside the figure.
const _minInfoWidth = 140.0;

/// The body figure's width on a slide [width] wide. Beside the info it takes
/// what the info column leaves, from [BodyFigure.compactWidth] up to
/// [BodyFigure.largeWidth]; stacked under the info it is full size, centred.
double splitFigureWidth(BuildContext context, double width) {
  if (splitOverviewStacked(context, width)) {
    return min(BodyFigure.largeWidth, width);
  }
  return (width - _figureGap - _minInfoWidth).clamp(
    BodyFigure.compactWidth,
    BodyFigure.largeWidth,
  );
}

typedef SplitDayEntry = ({DayTemplate day, int exerciseCount, String lastAgo});

/// The card's padding and border on each side.
const _cardInset = AppSpacing.pad + 1;
const _startGap = 18.0;

double _labelHeight(
  BuildContext context,
  String text,
  TextStyle style,
  int lines,
  double space,
) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: DefaultTextStyle.of(context).style.merge(style),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: lines,
  )..layout(maxWidth: max(1, space));
  final height = painter.height;
  painter.dispose();
  return height;
}

/// The pager height for slides [width] wide: the tallest of the Custom slide
/// and every day in [days], so paging never moves Start. Labels may fit
/// smaller through FitLabel, but never need more height.
double splitPagerHeight(
  BuildContext context,
  double width,
  List<SplitDayEntry> days,
) {
  final l = AppLocalizations.of(context);
  final scaler = MediaQuery.textScalerOf(context);
  double labelHeight(String text, TextStyle style, int lines, double space) =>
      _labelHeight(context, text, style, lines, space);

  final title = WorkoutType.display(size: 28);
  final body = WorkoutType.body(size: 16);
  final caption = WorkoutType.body(size: 12);
  final mono = WorkoutType.mono(size: 12);
  final stacked = splitOverviewStacked(context, width);
  final figureWidth = splitFigureWidth(context, width);
  final figureHeight = BodyFigure.heightFor(figureWidth);
  final infoWidth = stacked ? width : width - figureWidth - _figureGap;
  double focusHeight(String? focus) => focus?.isNotEmpty == true
      ? labelHeight(focus!, body, 3, infoWidth) + 16
      : 0;
  double totalHeight(
    String name,
    String? focus,
    List<({String label, String value})> details,
    String? hint,
  ) {
    final infoHeight =
        focusHeight(focus) +
        details.fold<double>(
          0,
          (sum, detail) =>
              sum +
              labelHeight(detail.label, caption, 2, infoWidth) +
              2 +
              labelHeight(detail.value, mono, 2, infoWidth) +
              12,
        ) +
        (hint == null ? 0 : labelHeight(hint, caption, 3, infoWidth));
    return labelHeight(name, title, 2, width) +
        8 +
        scaler.scale(12) * 1.4 +
        12 +
        (stacked
            ? infoHeight + 12 + figureHeight
            : max(infoHeight, figureHeight));
  }

  var tallest = totalHeight(
    l.todayCustomSession,
    l.splitBuildAsYouGo,
    [],
    l.splitAddExercisesLive,
  );
  for (final entry in days) {
    final est = max(20, entry.exerciseCount * 9 + 10);
    tallest = max(
      tallest,
      totalHeight(entry.day.name, entry.day.focus, [
        (label: l.splitExercises, value: '${entry.exerciseCount}'),
        (label: l.splitEstTime, value: l.splitEstTimeValue(est)),
        (
          label: l.splitLast,
          value: entry.lastAgo.isEmpty ? '—' : entry.lastAgo,
        ),
      ], null),
    );
  }
  return tallest.ceilToDouble() + 4;
}

/// The Start button's height for a card [width] wide showing [label].
double _startHeight(BuildContext context, double width, String label) {
  final density = Theme.of(context).visualDensity.baseSizeAdjustment.dy;
  final text = _labelHeight(
    context,
    label,
    WorkoutType.body(size: 16, weight: FontWeight.w500),
    2,
    width - 2 * _cardInset - 32,
  );
  return max(56.0, text + 24) + density;
}

/// The whole card's height at [width] (outer) for [days], opened on a day
/// slide (or on Custom when [days] is empty). Shared with Today's skeleton.
double splitCardHeight(
  BuildContext context,
  double width,
  List<SplitDayEntry> days,
) {
  final l = AppLocalizations.of(context);
  return 2 * _cardInset +
      splitPagerHeight(context, width - 2 * _cardInset, days) +
      _startGap +
      _startHeight(
        context,
        width,
        days.isEmpty ? l.splitStartEmpty : l.splitStartWorkout,
      );
}

/// The card height Today reserves while its rotation loads, before any day
/// is known: the Custom slide and one reference day with a one-line name and
/// focus, through the same measure as the card. A loaded day whose name or
/// focus needs more lines than that grows the card by exactly those lines
/// when it reveals; the days are not known any earlier.
double splitCardLoadingHeight(BuildContext context, double width) {
  return splitCardHeight(context, width, [
    (
      day: DayTemplate(
        id: '',
        name: 'A',
        focus: 'A',
        position: 0,
        slots: const [],
      ),
      exerciseCount: 5,
      lastAgo: '—',
    ),
  ]);
}

// ── CustomSlide ───────────────────────────────────────────────────────────────

/// The final page of the split-picker pager for a free-form custom session.
class CustomSlide extends StatelessWidget {
  const CustomSlide({super.key, this.bodyVisible = true, this.workload});
  final bool bodyVisible;
  final WorkoutWorkload? workload;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return _SlideLayout(
      bodyVisible: bodyVisible,
      workload:
          workload ??
          calculateWorkoutWorkload(
            mode: WorkoutWorkloadMode.planned,
            exercises: const [],
          ),
      title: l.todayCustomSession,
      contextLabel: l.splitNoTemplate,
      focus: l.splitBuildAsYouGo,
      hint: l.splitAddExercisesLive,
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
    this.workload,
    this.visible = true,
  });

  final WorkoutWorkload? workload;
  final bool visible;

  /// Day slides data. Each entry carries the template, exercise count, and
  /// a human-readable "last trained" label (e.g. '3d ago' or '—').
  final List<SplitDayEntry> days;

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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;

    // A neutral plate keeps day identity and the Start action distinct.
    final cardBg = tokens.surface;

    // Start button colours
    final btnBg = tokens.action;
    final btnInk = tokens.onAction;
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
                        height: splitPagerHeight(
                          context,
                          box.maxWidth,
                          widget.days,
                        ),
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
                                  workload: widget.workload,
                                  bodyVisible:
                                      widget.visible &&
                                      i == _currentPage &&
                                      (_driveTarget == null ||
                                          i == _driveTarget),
                                  day: entry.day,
                                  exerciseCount: entry.exerciseCount,
                                  lastAgo: entry.lastAgo,
                                  index: i,
                                  nextIndex: widget.nextIndex,
                                );
                              }
                              return CustomSlide(
                                workload: widget.workload,
                                bodyVisible:
                                    widget.visible &&
                                    i == _currentPage &&
                                    (_driveTarget == null || i == _driveTarget),
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: _startGap),
                      // ── Start button ─────────────────────────────────────────
                      FilledButton(
                        key: const Key('today-start'),
                        onPressed: _onStart,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(double.infinity, 56),
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
                            Flexible(
                              child: FitLabel(
                                btnLabel,
                                maxLines: 2,
                                style: WorkoutType.body(
                                  size: 16,
                                  weight: FontWeight.w500,
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
