import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/ui/today_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/layout_expect.dart';
import '../../support/screen_harness.dart' show longDraft;
import '../domains/local_screen_harness.dart';

/// Mirrors the live workout screen: open after its first frame, closed from
/// dispose, which runs inside finalizeTree while the build is locked.
class _ScreenOpenOwner extends StatefulWidget {
  const _ScreenOpenOwner(this.phases);
  final List<SchedulerPhase> phases;
  @override
  State<_ScreenOpenOwner> createState() => _ScreenOpenOwnerState();
}

class _ScreenOpenOwnerState extends State<_ScreenOpenOwner> {
  late final SessionManager _manager;
  @override
  void initState() {
    super.initState();
    _manager = context.read<SessionManager>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _manager.screenOpen = true;
    });
  }

  @override
  void dispose() {
    widget.phases.add(SchedulerBinding.instance.schedulerPhase);
    _manager.screenOpen = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets(
    'T7 fix 1: closing the session screen from dispose reports no exception and listeners observe it after the frame',
    (tester) async {
      final manager = SessionManager();
      final phases = <SchedulerPhase>[];
      final observed = <bool>[];
      Widget app({required bool open}) =>
          ChangeNotifierProvider<SessionManager>.value(
            value: manager,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Builder(
                builder: (context) {
                  observed.add(context.watch<SessionManager>().screenOpen);
                  return open ? _ScreenOpenOwner(phases) : const SizedBox();
                },
              ),
            ),
          );
      await tester.pumpWidget(app(open: true));
      await tester.pump();
      expect(manager.screenOpen, isTrue);
      expect(observed.last, isTrue);
      await tester.pumpWidget(app(open: false));
      expect(phases, [
        SchedulerPhase.persistentCallbacks,
      ], reason: 'dispose ran while the tree was locked');
      expect(tester.takeException(), isNull);
      expect(manager.screenOpen, isFalse, reason: 'the value changes at once');
      await tester.pump();
      expect(observed.last, isFalse, reason: 'listeners rebuilt next frame');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      manager.dispose();
    },
  );

  testWidgets(
    'T7 fix 1: the Today resume hero keeps a long single-word workout name whole at 320dp and 2x text',
    (tester) async {
      final h = ScreenHarness();
      await h.open(tester, seed: (_) async {});
      final controller = ActiveSessionController()..seedForTest(longDraft());
      try {
        setPhone(tester, width: 320, textScale: 2);
        h.manager.register(controller);
        for (final code in const ['en', 'de', 'es', 'it']) {
          await tester.pumpWidget(
            h.wrap(
              Scaffold(
                body: TodayScreen(
                  onStart: (_) {},
                  onOpenExercise: (_) {},
                  onOpenProfile: () {},
                  onResume: () {},
                ),
              ),
              locale: Locale(code),
            ),
          );
          await settleReal(tester, ticks: 8);
          expect(tester.takeException(), isNull, reason: code);
          expect(find.text(longDay), findsWidgets, reason: 'full name kept');
          expectNoSplitWords(
            tester,
            within: find.byType(TodayScreen),
            where: 'resume hero $code',
          );
        }
        await h.unmount(tester);
      } finally {
        h.manager.clear();
        controller.dispose();
        await h.close();
      }
    },
  );
}
