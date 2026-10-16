import 'dart:ui';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import '../widgets/pressable.dart';

/// The 5-slot bottom navigation bar with a center FAB.
///
/// Visual layout (left → right):
///   [Today] [Progress] [  FAB  ] [History] [Plan]
///
/// The FAB is NOT a tab — it calls [onStart] and does not emit an index.
/// [onTab] emits IndexedStack indices 0..3 (identity mapping):
///   Today=0, Progress=1, History=2, Plan=3.
///
/// Rendered with a frosted-glass effect: ClipRect + BackdropFilter (blur 16)
/// over a semi-transparent bg container (alpha 0.88), with a top hairline border.
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

    // The frosted bar (clipped layer) — FAB slot is empty so no clipping occurs.
    final frostedBar = ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: BoxDecoration(
            color: tokens.bg.withValues(alpha: 0.88),
            border: Border(top: BorderSide(color: tokens.line, width: 1)),
          ),
          padding: EdgeInsets.only(bottom: bottomPad, top: 4),
          child: Row(
            children: [
              // Today (index 0)
              _TabButton(
                icon: WIcons.home,
                label: l.navToday,
                active: currentIndex == 0,
                onTap: () => onTab(0),
              ),
              // Progress (index 1)
              _TabButton(
                icon: WIcons.chart,
                label: l.navProgress,
                active: currentIndex == 1,
                onTap: () => onTab(1),
              ),
              // Center FAB slot — empty placeholder keeps column widths balanced.
              const Expanded(child: SizedBox(height: 64)),
              // History (index 2)
              _TabButton(
                icon: WIcons.history,
                label: l.navHistory,
                active: currentIndex == 2,
                onTap: () => onTab(2),
              ),
              // Plan (index 3)
              _TabButton(
                icon: WIcons.plan,
                label: l.navPlan,
                active: currentIndex == 3,
                onTap: () => onTab(3),
              ),
            ],
          ),
        ),
      ),
    );

    // The FAB overlay sits outside the clipped layer so its upward overhang
    // is not clipped. Stack.clipBehavior = Clip.none lets it draw above the bar.
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.topCenter,
      children: [
        frostedBar,
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
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final color = active ? tokens.accentText : tokens.faint;

    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: PressableScale(
          child: SizedBox(
            height: 64,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 23, color: color),
                const SizedBox(height: 3),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: FitLabel(
                    label,
                    textAlign: TextAlign.center,
                    style: WorkoutType.mono(
                      size: 9.5,
                      weight: FontWeight.w600,
                      color: color,
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
      child: GestureDetector(
        onTap: onStart,
        child: PressableScale(
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: t.accent,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: t.accent.withValues(alpha: 0.45),
                  blurRadius: 16,
                  spreadRadius: -2,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Icon(WIcons.bolt, size: 28, color: t.accentInk),
          ),
        ),
      ),
    );
  }
}
