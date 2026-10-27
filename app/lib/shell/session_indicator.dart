import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/typography.dart';
import '../util/clock_format.dart';
import '../theme/tokens.dart';
import '../l10n/app_localizations.dart';

/// Compact "workout in progress" pill, top-right on non-Today tabs. Shows live
/// elapsed (accent rest countdown while resting). Tap → reopen the session.
class SessionIndicator extends StatefulWidget {
  const SessionIndicator({
    super.key,
    required this.startedAt,
    required this.restStart,
    required this.restTotal,
    required this.onTap,
  });
  final DateTime startedAt;
  final DateTime? restStart;
  final int restTotal;
  final VoidCallback onTap;

  @override
  State<SessionIndicator> createState() => _SessionIndicatorState();
}

class _SessionIndicatorState extends State<SessionIndicator> {
  Timer? _ticker;
  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final now = DateTime.now();
    var restRemaining = 0;
    final rs = widget.restStart;
    if (rs != null) {
      restRemaining = widget.restTotal - now.difference(rs).inSeconds;
      if (restRemaining < 0) restRemaining = 0;
    }
    final resting = restRemaining > 0;
    return Reveal(
      child: Semantics(
        button: true,
        label: AppLocalizations.of(context).todayResumeWorkout,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(AppRadius.control),
            focusColor: tokens.focus.withValues(alpha: 0.25),
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: tokens.surface2,
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(WIcons.dumbbell, size: 18, color: tokens.accentText),
                  const SizedBox(width: 7),
                  Text(
                    resting
                        ? fmtClock(Duration(seconds: restRemaining))
                        : fmtClock(now.difference(widget.startedAt)),
                    style: WorkoutType.mono(
                      size: 12,
                      weight: FontWeight.w400,
                      color: resting ? tokens.accentText : tokens.dim,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
