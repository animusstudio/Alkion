import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import '../theme/tokens.dart';

/// The 5-slot bottom navigation bar with a center FAB.
///
/// Visual layout (left → right):
///   [Today] [Progress] [  FAB  ] [History] [Plan]
///
/// The FAB is NOT a tab — it calls [onStart] and does not emit an index.
/// [onTab] emits IndexedStack indices 0..3 (identity mapping):
///   Today=0, Progress=1, History=2, Plan=3.
///
/// Flat, opaque navigation surface with selected semantics and a separate
/// start-workout action. Labels respect system text scaling.
class WTabBar extends StatelessWidget {
  const WTabBar({
    super.key,
    required this.currentIndex,
    required this.onTab,
    required this.onStart,
  });

  /// The currently active IndexedStack index (0..3).
  final int currentIndex;

  /// Called with the new IndexedStack index when a tab is tapped.
  final ValueChanged<int> onTab;

  /// Called when the center FAB is tapped. Never emits an index.
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final bottomPad = 9 + viewPadding.bottom;

    final barHeight = math.max(
      64.0,
      MediaQuery.textScalerOf(context).scale(12) * 1.4 + 36,
    );
    final bar = Container(
      decoration: BoxDecoration(
        color: tokens.bg,
        border: Border(top: BorderSide(color: tokens.line)),
      ),
      padding: EdgeInsets.only(bottom: bottomPad, top: 4),
      child: Row(
        children: [
          _TabButton(
            icon: WIcons.home,
            label: l.navToday,
            active: currentIndex == 0,
            height: barHeight,
            onTap: () => onTab(0),
          ),
          _TabButton(
            icon: WIcons.chart,
            label: l.navProgress,
            active: currentIndex == 1,
            height: barHeight,
            onTap: () => onTab(1),
          ),
          Expanded(child: SizedBox(height: barHeight)),
          _TabButton(
            icon: WIcons.history,
            label: l.navHistory,
            active: currentIndex == 2,
            height: barHeight,
            onTap: () => onTab(2),
          ),
          _TabButton(
            icon: WIcons.plan,
            label: l.navPlan,
            active: currentIndex == 3,
            height: barHeight,
            onTap: () => onTab(3),
          ),
        ],
      ),
    );

    // The FAB overlay sits outside the clipped layer so its upward overhang
    // is not clipped. Stack.clipBehavior = Clip.none lets it draw above the bar.
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.topCenter,
      children: [
        bar,
        Transform.translate(
          offset: const Offset(0, -14),
          child: _FabButton(onStart: onStart),
        ),
      ],
    );
  }
}

// ── Tab button ────────────────────────────────────────────────────────────────

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    required this.height,
  });

  final IconData icon;
  final String label;
  final bool active;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final color = active ? tokens.text : tokens.dim;
    return Expanded(
      child: Semantics(
        button: true,
        selected: active,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            focusColor: tokens.focus.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(AppRadius.control),
            child: Container(
              height: height,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: active ? tokens.surface2 : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 23, color: color),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: FitLabel(
                      label,
                      textAlign: TextAlign.center,
                      style: WorkoutType.body(
                        size: 12,
                        weight: active ? FontWeight.w700 : FontWeight.w500,
                        color: color,
                      ),
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

// ── Center FAB ────────────────────────────────────────────────────────────────

class _FabButton extends StatelessWidget {
  const _FabButton({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final l = AppLocalizations.of(context);

    return Semantics(
      button: true,
      label: l.splitStartWorkout,
      excludeSemantics: true,
      onTap: onStart,
      child: SizedBox(
        width: 64,
        height: 64,
        child: FloatingActionButton(
          heroTag: null,
          onPressed: onStart,
          elevation: 0,
          backgroundColor: t.action,
          foregroundColor: t.onAction,
          focusColor: t.focus.withValues(alpha: 0.25),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          child: Icon(WIcons.bolt, size: 28, color: t.onAction),
        ),
      ),
    );
  }
}
