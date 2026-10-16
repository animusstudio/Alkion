import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/day_template_repository.dart';
import '../data/models.dart';
import '../widgets/w_dialog.dart';
import '../data/session_repository.dart';
import '../theme/app_theme.dart';
import '../store/local_store.dart';
import '../ui/history_screen.dart';
import '../ui/plan_screen.dart';
import '../ui/profile_screen.dart';
import '../ui/progress_screen.dart';
import '../ui/today_screen.dart';
import '../session/session_manager.dart';
import '../theme/motion.dart';
import 'back_dispatch.dart';
import 'session_launcher.dart' as launcher;
import 'session_indicator.dart';
import 'w_tab_bar.dart';

/// The top-level 5-tab shell of the app.
///
/// Layout:
///   - [Scaffold] with `extendBody: true` so the tab bar is overlaid by the
///     body content via a [Stack].
///   - [IndexedStack] (index 0..3) for Today / Progress / History / Plan.
///   - [WTabBar] pinned at the bottom centre of the stack.
///
/// Tab index mapping is identity (no FAB offset):
///   Today=0, Progress=1, History=2, Plan=3.
///
/// The FAB calls [launcher.startSession] with the next-in-rotation template
/// (null → custom session) and resets to the Today tab on return.
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
  String? _progressTarget;

  final _planKey = GlobalKey<PlanScreenState>();

  late final DayTemplateRepository _dayRepo;
  late final SessionRepository _sessionRepo;

  @override
  void initState() {
    super.initState();
    _dayRepo = DayTemplateRepository.local(context.read<LocalDatabase>());
    _sessionRepo = SessionRepository.local(context.read<LocalDatabase>());
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  /// FAB: resolve next-in-rotation and start a session; return to Today.
  Future<void> _fabStart() async {
    try {
      final t = await launcher.nextInRotation(_dayRepo, _sessionRepo);
      if (!mounted) {
        return;
      }
      await launcher.startSession(context, template: t);
      if (mounted) {
        setState(() => _index = 0);
      }
    } on HistoryOrderReview catch (review) {
      if (!mounted) {
        return;
      }
      final chosen = await launcher.chooseHistoryOrder(context, review);
      if (chosen == null) {
        return;
      }
      await _sessionRepo.resolveOrder(review, chosen);
      if (mounted) {
        await _fabStart();
      }
    } catch (error) {
      if (mounted) {
        await showWriteFailed(context, error);
      }
    }
  }

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

  /// Opens the Profile & Settings screen as a root-navigator overlay.
  Future<void> _openProfile() async {
    await Navigator.of(context, rootNavigator: true).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 250),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, __, ___) => ProfileScreen(
          onClose: () => Navigator.of(context, rootNavigator: true).pop(),
          onLogout: widget.onLogout,
          auth: widget.auth,
        ),
        transitionsBuilder: (_, anim, __, child) {
          final curved = CurvedAnimation(parent: anim, curve: Motion.curve);
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, 0.06),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

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
        body: Stack(
          children: [
            _TabFade(
              index: _index,
              child: IndexedStack(
                index: _index,
                children: [
                  TodayScreen(
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
                  const HistoryScreen(),
                  PlanScreen(key: _planKey),
                ],
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
              child: WTabBar(
                currentIndex: _index,
                onTab: (i) => setState(() => _index = i),
                onStart: _fabStart,
              ),
            ),
          ],
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
