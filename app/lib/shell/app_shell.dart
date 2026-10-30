import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../theme/app_theme.dart';
import '../ui/history_screen.dart';
import '../ui/plan_screen.dart';
import '../ui/profile_screen.dart';
import '../ui/progress_screen.dart';
import '../ui/today_screen.dart';
import '../session/session_manager.dart';
import '../theme/motion.dart';
import '../theme/workout_canvas.dart';
import 'back_dispatch.dart';
import 'session_launcher.dart' as launcher;
import 'session_indicator.dart';
import 'w_tab_bar.dart';

/// The five destination shell. Today remains the home index so Android Back
/// and the Plan editor guard retain their existing priority.
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.onLogout, this.auth});

  /// Called (awaited) when the user logs out via the Profile screen.
  final Future<void> Function()? onLogout;

  /// The authenticated user store — forwarded to ProfileScreen for email display.
  final Object? auth;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  bool _profileOpened = false;
  String? _progressTarget;

  final _planKey = GlobalKey<PlanScreenState>();

  /// Today hero Start button: start the given (or custom) session; return to Today.
  Future<void> _start(DayTemplate? day) async {
    await launcher.startSession(context, template: day);
    if (mounted) {
      setState(() => _index = 0);
    }
  }

  /// Switches to the Progress tab with the given exercise or bodyweight target.
  void _openExercise(String exId) {
    setState(() {
      _progressTarget = exId;
      _index = 1;
    });
  }

  /// The avatar and bottom destination share the same Profile tab.
  void _openProfile() => _selectTab(4);

  void _selectTab(int index) => setState(() {
    _index = index;
    if (index == 4) _profileOpened = true;
  });

  /// Back on Today while a Plan editor holds unsaved edits: shows the
  /// editor and asks, and finishes the exit only if the edits are discarded.
  Future<void> _confirmExit() async {
    setState(() => _index = 3);
    final closed = await _planKey.currentState?.requestClose() ?? false;
    if (!mounted) {
      return;
    }
    if (closed) {
      SystemNavigator.pop();
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<SessionManager>();
    final reserveIndicator =
        manager.active != null && !manager.screenOpen && _index != 0;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        final tabHandled =
            _index == 3 && (_planKey.currentState?.handleBack() ?? false);
        switch (decideBack(
          tabHandled: tabHandled,
          tabIndex: _index,
          // The hidden tab's typed values are already committed: it lost
          // focus when it was left.
          planEditsAtRisk: _planKey.currentState?.hasUnsavedEdits ?? false,
        )) {
          case BackAction.none:
            break;
          case BackAction.goHome:
            setState(() => _index = 0);
          case BackAction.confirmExit:
            unawaited(_confirmExit());
          case BackAction.exit:
            SystemNavigator.pop();
        }
      },
      child: Scaffold(
        extendBody: true,
        body: WorkoutCanvas(
          child: Stack(
            children: [
              _TabFade(
                index: _index,
                child: Padding(
                  padding: EdgeInsets.only(top: reserveIndicator ? 60 : 0),
                  child: IndexedStack(
                    index: _index,
                    children: [
                      TodayScreen(
                        visible: _index == 0,
                        onStart: _start,
                        onOpenExercise: _openExercise,
                        onOpenProfile: _openProfile,
                        onResume: () {
                          final m = context.read<SessionManager>();
                          launcher.openActiveSession(context, m);
                        },
                        auth: widget.auth,
                      ),
                      ProgressScreen(
                        key: ValueKey(_progressTarget),
                        initialTarget: _progressTarget,
                      ),
                      HistoryScreen(onOpenProfile: _openProfile),
                      PlanScreen(key: _planKey),
                      if (_profileOpened)
                        ProfileScreen(
                          embedded: true,
                          onClose: () => _selectTab(0),
                          onLogout: widget.onLogout,
                          auth: widget.auth,
                        )
                      else
                        const SizedBox.shrink(),
                    ],
                  ),
                ),
              ),
              // An opaque strip under the status bar, so scrolled content
              // doesn't run behind the clock and icons.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: MediaQuery.paddingOf(context).top,
                child: IgnorePointer(
                  child: ColoredBox(
                    key: const Key('status-bar-scrim'),
                    color: context.tokens.bg,
                  ),
                ),
              ),
              // Workout-in-progress indicator: compact, top-right, on every tab
              // EXCEPT Today (index 0), where the resume hero covers it.
              Builder(
                builder: (context) {
                  final manager = context.watch<SessionManager>();
                  final c = manager.active;
                  if (c == null || manager.screenOpen || _index == 0) {
                    return const SizedBox.shrink();
                  }
                  return Positioned(
                    top: MediaQuery.paddingOf(context).top + 8,
                    right: 16,
                    child: SessionIndicator(
                      startedAt: c.draft.startedAt,
                      restStart: c.restStart,
                      restTotal: c.restTotal,
                      onTap: () => launcher.openActiveSession(context, manager),
                    ),
                  );
                },
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: WTabBar(currentIndex: _index, onTab: _selectTab),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Soft-cut between tabs: quickly fades the (state-preserving) IndexedStack
/// back in whenever the index changes.
class _TabFade extends StatefulWidget {
  const _TabFade({required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  State<_TabFade> createState() => _TabFadeState();
}

class _TabFadeState extends State<_TabFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.fast,
    value: 1.0,
  );

  @override
  void didUpdateWidget(_TabFade old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index &&
        !MediaQuery.of(context).disableAnimations) {
      _c.forward(from: 0.35);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _c, child: widget.child);
}
