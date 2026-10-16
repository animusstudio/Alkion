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
import 'dashed_border.dart';
import 'fit_label.dart';
import 'pressable.dart';

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

    final accentInk = tokens.accentInk;
    // Sub-accent: accentInk @ ~58% (matching cd: color-mix(in srgb, accent-ink 58%))
    final accentDim = accentInk.withValues(alpha: 0.58);

    return Stack(
      children: [
        // Content column
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Eyebrow — one line: a long day name shrinks, then ellipsizes.
            FitLabel(
              eyebrow,
              style: WorkoutType.mono(
                size: 11,
                weight: FontWeight.w700,
                color: accentDim,
                letterSpacing: 11 * 0.1,
              ),
            ),
            const SizedBox(height: 10),
            // Name
            Text(
              day.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WorkoutType.display(
                size: 40,
                weight: FontWeight.w700,
                color: accentInk,
                letterSpacing: 40 * -0.03,
              ),
            ),
            // Focus
            if (day.focus != null && day.focus!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                day.focus!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WorkoutType.display(
                  size: 19,
                  weight: FontWeight.w600,
                  color: accentDim,
                  letterSpacing: 19 * -0.025,
                ),
              ),
            ],
            const SizedBox(height: 16),
            // Stats row — scales down as a unit rather than overflowing a
            // narrow card at large text.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _StatCol(
                    value: '$exerciseCount',
                    label: l.splitExercises,
                    valueColor: accentInk,
                    labelColor: accentDim,
                  ),
                  const SizedBox(width: 18),
                  _StatCol(
                    value: l.splitEstTimeValue(est),
                    label: l.splitEstTime,
                    valueColor: accentInk,
                    labelColor: accentDim,
                  ),
                  const SizedBox(width: 18),
                  _StatCol(
                    value: lastAgo.isEmpty ? '—' : lastAgo,
                    label: l.splitLast,
                    valueColor: accentInk,
                    labelColor: accentDim,
                  ),
                ],
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
        Text(
          value,
          style: WorkoutType.mono(
            size: 16,
            weight: FontWeight.w700,
            color: valueColor,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label.toUpperCase(),
          style: WorkoutType.mono(
            size: 9.5,
            color: labelColor,
            letterSpacing: 9.5 * 0.06,
          ),
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
        // Eyebrow
        FitLabel(
          l.splitNoTemplate,
          style: WorkoutType.mono(
            size: 11,
            weight: FontWeight.w700,
            color: dimColor,
            letterSpacing: 11 * 0.1,
          ),
        ),
        const SizedBox(height: 10),
        // Name
        FitLabel(
          l.todayCustomSession,
          style: WorkoutType.display(
            size: 40,
            weight: FontWeight.w700,
            color: textColor,
            letterSpacing: 40 * -0.03,
          ),
        ),
        const SizedBox(height: 4),
        // Sub
        FitLabel(
          l.splitBuildAsYouGo,
          style: WorkoutType.display(
            size: 19,
            weight: FontWeight.w600,
            color: dimColor,
            letterSpacing: 19 * -0.025,
          ),
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
                style: WorkoutType.mono(
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;

    // Animated card theming: accent bg (day) ↔ surface bg (custom)
    final cardBg = _isCustom ? tokens.surface : tokens.accent;

    // Start button colours
    final btnBg = _isCustom ? tokens.accent : tokens.accentInk;
    final btnInk = _isCustom ? tokens.accentInk : tokens.accent;
    final btnIcon = _isCustom ? WIcons.plus : WIcons.bolt;
    final btnLabel = _isCustom ? l.splitStartEmpty : l.splitStartWorkout;

    return Column(
      children: [
        // ── Card body ────────────────────────────────────────────────────────
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.ease,
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(AppRadius.radius),
            // Custom slide shows a dashed border; day slides have no border.
          ),
          child: Stack(
            children: [
              // Dashed border overlay for Custom slide
              if (_isCustom)
                Positioned.fill(
                  child: CustomPaint(
                    painter: DashedBorderPainter(
                      color: tokens.lineStrong,
                      radius: AppRadius.radius,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.pad + 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── Pager ────────────────────────────────────────────────
                    SizedBox(
                      // Fixed height to keep the card stable as slides
                      // scroll; the text part grows with the user's text
                      // size (180 at 1.0×) so a slide never overflows.
                      height: 32 + MediaQuery.textScalerOf(context).scale(148),
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
                            if (_driveTarget != null && page != _driveTarget) {
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
                    PressableScale(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.ease,
                        height: 52,
                        decoration: BoxDecoration(
                          color: btnBg,
                          borderRadius: BorderRadius.circular(
                            AppRadius.radius * 0.8,
                          ),
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _onStart,
                            borderRadius: BorderRadius.circular(
                              AppRadius.radius * 0.8,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(btnIcon, size: 18, color: btnInk),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: FitLabel(
                                    btnLabel,
                                    style: WorkoutType.display(
                                      size: 17,
                                      weight: FontWeight.w700,
                                      color: btnInk,
                                      letterSpacing: 17 * 0.01,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
