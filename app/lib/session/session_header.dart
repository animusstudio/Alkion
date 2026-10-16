import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import 'active_session_controller.dart';

/// "Next · …" for the header rest row: the live set, or finishing.
String restNextLabel(AppLocalizations l, UnitService unit, LiveSet? live) {
  if (live == null) {
    return l.sessionRestNext(l.sessionFinishWorkout);
  }
  final s = live.set;
  if (!s.weightAvailable || !s.repsAvailable) {
    return l.sessionRestNext(
      '${live.block.exercise.name} · ${l.alkionValuesUnavailable}',
    );
  }
  final weight = '${unit.fmtWt(s.weightKg)}${unit.uLabel}';
  final name = live.block.exercise.name;
  return l.sessionRestNext(
    s.isWarmup
        ? l.sessionNextWarmup(name, weight, s.reps)
        : l.sessionNextSet(
            name,
            live.block.workingSets.indexOf(s) + 1,
            weight,
            s.reps,
          ),
  );
}

/// The live workout's sticky header: minimize, title and set count, the ⋯
/// menu and elapsed time; under it the progress bar, which becomes a thicker
/// draining rest countdown while resting, with a rest row (countdown, what is
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

  /// False while a data capture holds the source: +30s is shown as
  /// unavailable, does nothing, and the line under the row says why.
  final bool restExtensionAvailable;

  /// Threshold (inclusive) for the final-seconds accent.
  static const _finalThreshold = 5;

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
      child: GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tokens.surface,
                border: Border.all(color: tokens.line),
              ),
              alignment: Alignment.center,
              child: icon,
            ),
          ),
        ),
      ),
    );

    return Container(
      color: tokens.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: MediaQuery.of(context).padding.top + 4),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 12, 8),
            child: Row(
              children: [
                circleButton(
                  key: const Key('session-minimize'),
                  label: l.sessionMinimize,
                  onTap: onMinimize,
                  icon: Transform.rotate(
                    angle: 1.5708,
                    child: Icon(WIcons.chevron, size: 18, color: tokens.dim),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          style: WorkoutType.display(
                            size: 18,
                            weight: FontWeight.w700,
                            color: tokens.text,
                          ),
                          children: [
                            TextSpan(text: draft.name),
                            if (draft.focus.isNotEmpty)
                              TextSpan(
                                text: ' · ${draft.focus}',
                                style: WorkoutType.display(
                                  size: 18,
                                  weight: FontWeight.w600,
                                  color: tokens.faint,
                                ),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        setsText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WorkoutType.mono(size: 11, color: tokens.faint),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '$mm:${ss.toString().padLeft(2, '0')}',
                      style: WorkoutType.mono(
                        size: 18,
                        weight: FontWeight.w700,
                        color: tokens.accentText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l.sessionElapsed,
                      style: WorkoutType.mono(
                        size: 9,
                        color: tokens.faint,
                        letterSpacing: 0.06 * 9,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
                circleButton(
                  key: const Key('session-menu'),
                  label: l.sessionWorkoutOptions,
                  onTap: onMenu,
                  icon: Icon(WIcons.more, size: 18, color: tokens.dim),
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
                                    style: WorkoutType.mono(
                                      size: 10,
                                      color: tokens.faint,
                                      letterSpacing: 0.08 * 10,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  // Always laid out (empty when the rested time is unknown)
                                  // so both states keep one height.
                                  AnimatedDefaultTextStyle(
                                    duration: Motion.of(context, Motion.base),
                                    curve: Motion.curve,
                                    style:
                                        WorkoutType.display(
                                          size: 18,
                                          weight: FontWeight.w700,
                                          color: !resting
                                              ? tokens.dim
                                              : remaining <= _finalThreshold
                                              ? tokens.accentText
                                              : tokens.text,
                                        ).copyWith(
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                    child: Text(
                                      resting
                                          ? clock(remaining)
                                          : rested == null
                                          ? ''
                                          : clock(rested),
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
                                    filled: false,
                                    tokens: tokens,
                                    onTap: restExtensionAvailable
                                        ? onAdd30s
                                        : null,
                                    unavailableLabel:
                                        l.alkionStoreRecoveryTitle,
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: _RestChip(
                                      key: const Key('rest-skip'),
                                      label: l.commonSkip,
                                      filled: true,
                                      tokens: tokens,
                                      onTap: restExtensionAvailable
                                          ? onSkip
                                          : null,
                                      unavailableLabel:
                                          l.alkionStoreRecoveryTitle,
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
                  Text(
                    resting && !restExtensionAvailable
                        ? l.captureRestUnavailable
                        : nextLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WorkoutType.mono(size: 11, color: tokens.dim),
                  ),
                ],
              ),
            ),
          // Progress bar: 6dp whenever the rest row shows. It drains while
          // resting (fraction gliding linearly between the one-second ticks)
          // and otherwise shows workout progress.
          AnimatedContainer(
            duration: Motion.of(context, Motion.base),
            curve: Motion.curve,
            height: showRow ? 6 : 3,
            color: tokens.surface3,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: barFraction),
              duration: Motion.of(context, const Duration(seconds: 1)),
              curve: Curves.linear,
              builder: (_, value, __) => FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: value.clamp(0.0, 1.0),
                child: Container(color: tokens.accentText),
              ),
            ),
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
    required this.filled,
    required this.tokens,
    required this.onTap,
    this.unavailableLabel,
  });

  final String label;
  final bool filled;
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
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 48,
          constraints: const BoxConstraints(minWidth: 56),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          // Skip is secondary to the log bar, the screen's one lime action:
          // a quiet filled chip, not an accent one.
          decoration: BoxDecoration(
            color: filled ? tokens.surface3 : null,
            border: filled
                ? null
                : Border.all(color: enabled ? tokens.lineStrong : tokens.line),
            borderRadius: BorderRadius.circular(AppRadius.radius * 0.5),
          ),
          // widthFactor 1 sizes the chip to its label; a Container `alignment`
          // would instead stretch it across all the width its Flexible offers.
          // Longer translations (German "Überspringen") ellipsize rather than
          // overflow at small widths / large text scale.
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WorkoutType.mono(
                size: 12,
                weight: FontWeight.w700,
                color: !enabled
                    ? tokens.faint
                    : filled
                    ? tokens.text
                    : tokens.dim,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
