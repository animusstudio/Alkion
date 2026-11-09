import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../catalog_ui/catalog_set_format.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/alkion_icon.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../widgets/fit_label.dart';
import 'active_session_controller.dart';

/// "Next · …" for the header rest row, classic and catalog alike: the next
/// set ("Set 3" or "Warm-up") and its values, or finishing. The exercise
/// leads only when the next set's block has no logged set yet, i.e. when the
/// next set moves to another exercise. A catalog set shows its compact values
/// ([catalogSetCompact]) and none when it has no valid value; a classic set
/// whose stored values are unavailable says so.
String restNextLabel(AppLocalizations l, UnitService unit, LiveSet? live) {
  if (live == null) {
    return l.sessionRestNext(l.sessionFinishWorkout);
  }
  final block = live.block;
  final s = live.set;
  final evidence = s.catalog;
  final values = evidence != null
      ? catalogSetCompact(evidence, l)
      : s.weightAvailable && s.repsAvailable
      ? '${unit.fmtWt(s.weightKg)}${unit.uLabel} × ${s.reps}'
      : l.alkionValuesUnavailable;
  return l.sessionRestNext(
    [
      if (!block.allSets.any((set) => set.done))
        evidence?.selection.displayLabel ?? block.exercise.name,
      s.isWarmup
          ? l.sessionNextWarmup
          : l.sessionNextSet(block.workingSets.indexOf(s) + 1),
      values,
    ].where((part) => part.isNotEmpty).join(' · '),
  );
}

/// The live workout's sticky header: minimize, title and set count, the ⋯
/// menu and elapsed time; under it a calibrated remaining-time scale while
/// resting, with a rest row (countdown, what is
/// next, +30s / Skip). The rest row appears with the first logged set and then
/// stays, switching between the countdown and a "rested" count-up of the same
/// height so the list below never moves on its own. Replaces the old floating
/// rest card, so nothing ever covers the exercise list.
class SessionHeader extends StatelessWidget {
  const SessionHeader({
    super.key,
    required this.draft,
    required this.elapsed,
    required this.doneWork,
    required this.totalWork,
    required this.prCount,
    required this.restStart,
    required this.restTotal,
    required this.showRestRow,
    this.restEndedAt,
    required this.nextLabel,
    required this.onMinimize,
    required this.onMenu,
    required this.onAdd30s,
    required this.onSkip,
    this.restExtensionAvailable = true,
  });

  final SessionDraft draft;
  final Duration elapsed;
  final int doneWork;
  final int totalWork;
  final int prCount;
  final DateTime? restStart;
  final int restTotal;

  /// Keep the rest row even when not resting (a set has been logged).
  final bool showRestRow;

  /// When the last rest ended, for the rested count-up; null when unknown.
  final DateTime? restEndedAt;
  final String nextLabel;
  final VoidCallback onMinimize;
  final VoidCallback onMenu;
  final VoidCallback onAdd30s;
  final VoidCallback onSkip;

  /// False while the workout waits for a save (a Finish not yet committed,
  /// or a notification's rest action being saved): +30s and Skip are shown
  /// as unavailable, do nothing, and the line under the row says why.
  final bool restExtensionAvailable;

  /// The rested count-up stops here.
  static const _restedCap = 99 * 60 + 59;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final prText = prCount > 0 ? l.sessionPrCount(prCount) : '';
    final setsText = '${l.sessionSetsProgress(doneWork, totalWork)}$prText';
    final mm = elapsed.inMinutes;
    final ss = elapsed.inSeconds % 60;

    final start = restStart;
    final remaining = start == null
        ? 0
        : (restTotal - DateTime.now().difference(start).inSeconds).clamp(
            0,
            restTotal,
          );
    final resting = start != null && remaining > 0;
    final showRow = resting || showRestRow;
    // Rested since the end the controller recorded; in the second before the
    // screen ticker stops a finished countdown, since that countdown's end.
    final restedFrom =
        restEndedAt ??
        (start != null && !resting
            ? start.add(Duration(seconds: restTotal))
            : null);
    final rested = restedFrom == null
        ? null
        : DateTime.now().difference(restedFrom).inSeconds.clamp(0, _restedCap);
    String clock(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
    final progress = totalWork > 0 ? doneWork / totalWork : 0.0;
    final barFraction = resting
        ? (restTotal > 0 ? remaining / restTotal : 0.0)
        : progress.clamp(0.0, 1.0);

    Widget circleButton({
      required Key key,
      required String label,
      required VoidCallback onTap,
      required Widget icon,
    }) => Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: IconButton(
        key: key,
        onPressed: onTap,
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          fixedSize: const Size(48, 48),
          backgroundColor: tokens.surface2,
          foregroundColor: tokens.dim,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          focusColor: tokens.focus.withValues(alpha: 0.25),
        ),
        icon: icon,
      ),
    );

    return Container(
      color: tokens.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: MediaQuery.of(context).padding.top + 4),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Column(
              children: [
                Row(
                  children: [
                    circleButton(
                      key: const Key('session-minimize'),
                      label: l.sessionMinimize,
                      onTap: onMinimize,
                      icon: AlkionIcon(
                        AlkionGlyph.chevronDown,
                        size: 18,
                        color: tokens.dim,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FitLabel.rich(
                        key: const Key('session-title'),
                        TextSpan(
                          style: WorkoutType.display(
                            size: 22,
                            weight: FontWeight.w500,
                            color: tokens.text,
                          ),
                          children: [
                            TextSpan(text: draft.name),
                            if (draft.focus.isNotEmpty)
                              TextSpan(
                                text: ' · ${draft.focus}',
                                style: WorkoutType.body(
                                  size: 16,
                                  color: tokens.dim,
                                ),
                              ),
                          ],
                        ),
                        maxLines: 2,
                      ),
                    ),
                    const SizedBox(width: 12),
                    circleButton(
                      key: const Key('session-menu'),
                      label: l.sessionWorkoutOptions,
                      onTap: onMenu,
                      icon: AlkionIcon(
                        AlkionGlyph.more,
                        size: 18,
                        color: tokens.dim,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 60),
                  child: Row(
                    children: [
                      Expanded(
                        child: FitLabel(
                          key: const Key('session-progress'),
                          setsText,
                          maxLines: 2,
                          style: WorkoutType.body(size: 12, color: tokens.dim),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '$mm:${ss.toString().padLeft(2, '0')}',
                        style: WorkoutType.mono(
                          size: 18,
                          weight: FontWeight.w500,
                          color: tokens.dim,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: FitLabel(
                          l.sessionElapsed,
                          maxLines: 2,
                          style: WorkoutType.body(size: 12, color: tokens.dim),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (showRow)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LayoutBuilder(
                    builder: (context, row) {
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // The chips keep their natural width; the label and
                          // clock take what is left and scale down to fit when
                          // it runs out, so the widest labels at large text
                          // scale never overflow the row.
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    resting ? l.restLabel : l.restRestedLabel,
                                    style: WorkoutType.body(
                                      size: 12,
                                      color: tokens.dim,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  // Keep the visible readout neutral. The rest
                                  // scale owns its combined remaining/total
                                  // accessibility value while counting down.
                                  ExcludeSemantics(
                                    excluding: resting,
                                    child: Text(
                                      resting
                                          ? clock(remaining)
                                          : rested == null
                                          ? ''
                                          : clock(rested),
                                      key: const Key('rest-clock'),
                                      style: WorkoutType.mono(
                                        size: 24,
                                        color: resting
                                            ? tokens.text
                                            : tokens.dim,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // The chip pair sits flush right at natural width,
                          // capped at 60% of the row so the label and clock
                          // always keep room. Only past that cap (narrow
                          // screens, large text, long translations) does Skip
                          // shrink, keeping its ellipsis as a floor; +30s is
                          // short in every locale.
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: row.maxWidth * 0.6,
                            ),
                            // After rest the chips are gone but keep their
                            // space, so the row does not change height.
                            child: Visibility(
                              visible: resting,
                              maintainSize: true,
                              maintainAnimation: true,
                              maintainState: true,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _RestChip(
                                    key: const Key('rest-add'),
                                    label: l.restAdd30s,
                                    accentPlus: true,
                                    tokens: tokens,
                                    onTap: restExtensionAvailable
                                        ? onAdd30s
                                        : null,
                                    unavailableLabel:
                                        l.restUnavailableUntilSaved,
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: _RestChip(
                                      key: const Key('rest-skip'),
                                      label: l.commonSkip,
                                      accentPlus: false,
                                      tokens: tokens,
                                      onTap: restExtensionAvailable
                                          ? onSkip
                                          : null,
                                      unavailableLabel:
                                          l.restUnavailableUntilSaved,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 4),
                  FitLabel(
                    resting && !restExtensionAvailable
                        ? l.restChangesWaitForSave
                        : nextLabel,
                    maxLines: 2,
                    style: WorkoutType.body(size: 12, color: tokens.dim),
                  ),
                ],
              ),
            ),
          // Remaining seconds and the calibrated endpoints share one inset.
          // Outside a rest, retain workout-set progress as the fallback.
          if (resting)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Semantics(
                label: l.restLabel,
                key: const Key('rest-remaining-value'),
                value: '${clock(remaining)} / ${clock(restTotal)}',
                child: Column(
                  children: [
                    _RestRemainingLine(
                      start: start,
                      total: restTotal,
                      stepped: barFraction,
                      track: tokens.surface3,
                      fill: tokens.accentText,
                    ),
                    SizedBox(
                      key: const Key('rest-scale'),
                      height: 8,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: _RestScalePainter(
                          total: restTotal,
                          color: tokens.lineStrong,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    ExcludeSemantics(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '0:00',
                            style: WorkoutType.mono(
                              size: 12,
                              color: tokens.dim,
                            ),
                          ),
                          Text(
                            clock(restTotal),
                            key: const Key('rest-total'),
                            style: WorkoutType.mono(
                              size: 12,
                              color: tokens.dim,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (showRow)
            // Reserve the same scale height after rest; no new rest is implied.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                children: [
                  _RemainingLine(
                    fraction: barFraction,
                    track: tokens.surface3,
                    fill: tokens.accentText,
                  ),
                  const SizedBox(height: 12),
                  Opacity(
                    opacity: 0,
                    child: ExcludeSemantics(
                      child: Text(' ', style: WorkoutType.mono(size: 12)),
                    ),
                  ),
                ],
              ),
            )
          else
            _RemainingLine(
              fraction: barFraction,
              track: tokens.surface3,
              fill: tokens.accentText,
            ),
          Container(height: 1, color: tokens.line),
        ],
      ),
    );
  }
}

class _RestChip extends StatelessWidget {
  const _RestChip({
    super.key,
    required this.label,
    required this.accentPlus,
    required this.tokens,
    required this.onTap,
    this.unavailableLabel,
  });

  final String label;
  final bool accentPlus;
  final WorkoutTokens tokens;

  /// Null: unavailable, drawn faint and announced with [unavailableLabel].
  final VoidCallback? onTap;
  final String? unavailableLabel;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      enabled: enabled,
      hint: enabled ? null : unavailableLabel,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          minimumSize: const Size(56, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          backgroundColor: tokens.surface2,
          foregroundColor: tokens.text,
          disabledForegroundColor: tokens.faint,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
        ),
        child: FitLabel.rich(
          TextSpan(
            children: [
              if (accentPlus && label.startsWith('+')) ...[
                TextSpan(
                  text: '+',
                  style: WorkoutType.body(
                    size: 14,
                    weight: FontWeight.w500,
                    color: enabled ? tokens.accentText : tokens.faint,
                  ),
                ),
                TextSpan(text: label.substring(1)),
              ] else
                TextSpan(text: label),
            ],
          ),
          maxLines: 2,
          textAlign: TextAlign.center,
          style: WorkoutType.body(
            size: 14,
            weight: FontWeight.w500,
            color: enabled ? tokens.text : tokens.faint,
          ),
        ),
      ),
    );
  }
}

/// The rest's remaining-time line. With animations on, a ticker moves the
/// fill every frame from the rest's real start and end (`start + total`), read
/// against the wall clock, so +30s and Skip retarget it at once and no fixed
/// animation duration is involved. The countdown text and the semantics
/// value still change once per second in the header. Under reduced motion,
/// outside [TickerMode] (a covered route) or once the rest has run out, no
/// ticker runs and the line shows the header's per-second [stepped] fraction.
class _RestRemainingLine extends StatefulWidget {
  const _RestRemainingLine({
    required this.start,
    required this.total,
    required this.stepped,
    required this.track,
    required this.fill,
  });

  final DateTime start;
  final int total;

  /// The header's per-second fraction, shown whenever the ticker is off.
  final double stepped;
  final Color track;
  final Color fill;

  @override
  State<_RestRemainingLine> createState() => _RestRemainingLineState();
}

class _RestRemainingLineState extends State<_RestRemainingLine>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final ValueNotifier<double> _fraction;

  // The ticker's frame clock interpolates between wall-clock anchors. The
  // header rebuilds every second, which re-anchors on [DateTime.now], so a
  // clock that stalled while the phone slept cannot drift the line.
  DateTime _anchorWall = DateTime.now();
  Duration _anchorElapsed = Duration.zero;
  Duration _lastElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _fraction = ValueNotifier<double>(widget.stepped);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_RestRemainingLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    _anchor();
    _sync();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _fraction.dispose();
    super.dispose();
  }

  void _anchor() {
    _anchorWall = DateTime.now();
    _anchorElapsed = _lastElapsed;
  }

  /// The continuous remaining fraction at [now].
  double _fractionAt(DateTime now) {
    if (widget.total <= 0) return 0;
    final totalMs = widget.total * 1000;
    final remainingMs = totalMs - now.difference(widget.start).inMilliseconds;
    return (remainingMs / totalMs).clamp(0.0, 1.0);
  }

  /// Starts or stops the ticker for the current rest, motion setting and
  /// ticker mode, and sets the fraction shown now.
  void _sync() {
    final fluid =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    final now = DateTime.now();
    final fraction = fluid ? _fractionAt(now) : widget.stepped;
    final run = fluid && fraction > 0;
    if (run && !_ticker.isActive) {
      _anchorWall = now;
      _anchorElapsed = _lastElapsed = Duration.zero;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
    _fraction.value = fraction;
  }

  void _onTick(Duration elapsed) {
    _lastElapsed = elapsed;
    final fraction = _fractionAt(_anchorWall.add(elapsed - _anchorElapsed));
    _fraction.value = fraction;
    if (fraction <= 0) _ticker.stop();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: _fraction,
    builder: (context, fraction, _) => _RemainingLine(
      fraction: fraction,
      track: widget.track,
      fill: widget.fill,
    ),
  );
}

/// A flat two-pixel instrument line. No interpolated animation changes what
/// the timer's current second reports.
class _RemainingLine extends StatelessWidget {
  const _RemainingLine({
    required this.fraction,
    required this.track,
    required this.fill,
  });
  final double fraction;
  final Color track;
  final Color fill;
  @override
  Widget build(BuildContext context) => SizedBox(
    key: const Key('rest-remaining-track'),
    height: 2,
    child: ColoredBox(
      color: track,
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: fraction.clamp(0.0, 1.0),
          heightFactor: 1,
          child: ColoredBox(color: fill),
        ),
      ),
    ),
  );
}

class _RestScalePainter extends CustomPainter {
  const _RestScalePainter({required this.total, required this.color});
  final int total;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0 || size.width < 1) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    // Keep 15-second calibration for ordinary rests; long custom rests use
    // whole multiples of 15 so the marks remain individually readable.
    final step =
        15 *
        (total / 15 / (size.width / 8).clamp(1, double.infinity))
            .ceil()
            .clamp(1, total)
            .toInt();
    void tick(int seconds) {
      final x = (seconds / total * size.width).clamp(0.5, size.width - 0.5);
      final height = seconds == 0 || seconds == total || seconds % 60 == 0
          ? 7.0
          : 4.0;
      canvas.drawLine(Offset(x, 0), Offset(x, height), paint);
    }

    for (var second = 0; second < total; second += step) {
      tick(second);
    }
    tick(total);
  }

  @override
  bool shouldRepaint(_RestScalePainter oldDelegate) =>
      oldDelegate.total != total || oldDelegate.color != color;
}
