import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import '../theme/tokens.dart';

/// Five equal destinations, in the accepted visual order. The emitted indices
/// retain the shell's existing home and editor identities: Today=0,
/// Progress=1, History=2, Plan=3, Profile=4.
class WTabBar extends StatelessWidget {
  const WTabBar({super.key, required this.currentIndex, required this.onTab});

  final int currentIndex;
  final ValueChanged<int> onTab;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final l = AppLocalizations.of(context);
    final destinations = [
      (index: 1, glyph: WDestinationGlyph.progress, label: l.navProgress),
      (index: 2, glyph: WDestinationGlyph.history, label: l.navHistory),
      (index: 0, glyph: WDestinationGlyph.today, label: l.navToday),
      (index: 3, glyph: WDestinationGlyph.plan, label: l.navPlan),
      (index: 4, glyph: WDestinationGlyph.profile, label: l.profileTitle),
    ];
    var labelHeight = 0.0;
    for (final destination in destinations) {
      final painter = TextPainter(
        text: TextSpan(
          text: destination.label,
          style: WorkoutType.body(
            size: 12,
            weight: currentIndex == destination.index
                ? FontWeight.w500
                : FontWeight.w400,
          ),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      labelHeight = math.max(labelHeight, painter.height);
      painter.dispose();
    }
    // Use the bundled face's actual rounded metrics. A font-size multiplier
    // misses fractional line rounding at large text; keep 4dp breathing room
    // above and below the 40dp icon and 4dp label gap.
    final height = math.max(68.0, labelHeight.ceilToDouble() + 52);
    return Container(
      decoration: BoxDecoration(
        color: t.bg,
        border: Border(top: BorderSide(color: t.line)),
      ),
      padding: EdgeInsets.only(
        top: 4,
        bottom: 9 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Row(
        children: [
          for (final destination in destinations)
            Expanded(
              child: Semantics(
                button: true,
                selected: currentIndex == destination.index,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: ValueKey('destination-${destination.index}'),
                    onTap: () => onTab(destination.index),
                    focusColor: t.focus.withValues(alpha: .25),
                    borderRadius: BorderRadius.circular(AppRadius.control),
                    child: SizedBox(
                      height: height,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: currentIndex == destination.index
                                  ? t.surface2
                                  : Colors.transparent,
                            ),
                            alignment: Alignment.center,
                            child: WDestinationIcon(
                              destination.glyph,
                              color: currentIndex == destination.index
                                  ? t.text
                                  : t.dim,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: FitLabel(
                              destination.label,
                              textAlign: TextAlign.center,
                              style: WorkoutType.body(
                                size: 12,
                                weight: currentIndex == destination.index
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                                color: currentIndex == destination.index
                                    ? t.text
                                    : t.dim,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
