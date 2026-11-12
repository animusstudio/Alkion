import 'dart:ui' show SemanticsAction;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/shell/app_shell.dart';
import 'package:alkion/shell/session_indicator.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/ui/body_figure.dart';
import 'package:alkion/ui/day_view.dart';
import 'package:alkion/ui/history_screen.dart';
import 'package:alkion/ui/exercise_library_tab.dart';
import 'package:alkion/ui/plan_screen.dart';
import 'package:alkion/ui/progress_screen.dart';
import 'package:alkion/ui/profile_screen.dart';
import 'package:alkion/ui/split_tab.dart';
import 'package:alkion/ui/split_volume_card.dart';
import 'package:alkion/ui/targets_tab.dart';
import 'package:alkion/ui/today_screen.dart';
import 'package:alkion/theme/alkion_icon.dart';

import '../support/screen_harness.dart';

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  testWidgets(
    'Today profile avatar semantic tap opens the shared Profile destination',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await harness.open(tester);
        setPhone(tester, width: 320, textScale: 2);
        await tester.pumpWidget(harness.wrap(const AppShell()));
        await settleReal(tester, ticks: 5);
        final avatar = find.descendant(
          of: find.byType(TodayScreen),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.label ==
                    lookupAppLocalizations(const Locale('en')).profileTitle,
          ),
        );
        final node = tester.getSemantics(avatar);
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
          reason: node.getSemanticsData().toString(),
        );
        node.owner!.performAction(node.id, SemanticsAction.tap);
        await settleUntilFound(
          tester,
          find.byType(ProfileScreen),
          where: 'Profile from semantic tap',
        );
        expect(find.byType(ProfileScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
        await harness.unmount(tester);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'active workout resume target leaves the tab heading clear at 320dp 2x',
    (tester) async {
      await harness.open(tester);
      setPhone(tester, width: 320, textScale: 2);
      harness.manager.register(
        ActiveSessionController()..seedForTest(longDraft()),
      );
      const locale = Locale('es');
      final l = lookupAppLocalizations(locale);
      await tester.pumpWidget(harness.wrap(const AppShell(), locale: locale));
      await settleReal(tester, ticks: 5);
      await openTab(tester, AlkionGlyph.plan);
      final indicator = find.byType(SessionIndicator);
      final title = find.descendant(
        of: find.byType(PlanScreen),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              widget.data == l.planTitle &&
              widget.style?.fontSize == 28,
        ),
      );
      expect(indicator, findsOneWidget);
      expect(tester.getSize(indicator).height, greaterThanOrEqualTo(48));
      expect(
        tester.getRect(indicator).bottom,
        lessThanOrEqualTo(tester.getRect(title).top),
      );
      expect(tester.takeException(), isNull);
      await harness.unmount(tester);
    },
  );

  for (final c in [
    ...layoutConditions,
    (width: 320.0, textScale: 2.0, locale: const Locale('es')),
  ]) {
    final name = describeCondition(c);
    testWidgets('Today, Progress, History and Plan hold at $name', (
      tester,
    ) async {
      await harness.open(tester);
      setPhone(tester, width: c.width, textScale: c.textScale);
      final l = lookupAppLocalizations(c.locale);
      await tester.pumpWidget(
        harness.wrap(
          AppShell(onLogout: () async {}, auth: Object()),
          locale: c.locale,
        ),
      );
      await settleUntilFound(
        tester,
        textWithAnyOf(find.byType(TodayScreen), [longDay, 'Pull']),
        where: 'Today $name',
      );
      // Rotation may select Pull. At large text the WeekStrip containing the
      // other long day is below the first viewport, so build it by scrolling
      // before asserting the complete screen's layout.
      await scrollIntoView(
        tester,
        find.byType(TodayScreen),
        textWithAnyOf(find.byType(TodayScreen), [longDay]),
      );
      await expectLayoutHoldsWhileScrolling(
        tester,
        find.byType(TodayScreen),
        'Today $name',
      );
      // One body renderer in the whole shell: Today's. The Split overview
      // behind it (kept mounted by the IndexedStack) holds none.
      final figures = find.byType(BodyFigure, skipOffstage: false);
      expect(figures, findsOneWidget);
      expect(
        find.descendant(of: find.byType(TodayScreen), matching: figures),
        findsOneWidget,
      );

      await openTab(tester, AlkionGlyph.progress);
      await settleUntilFound(
        tester,
        textWithAnyOf(find.byType(ProgressScreen), [
          longExercise,
          longExercise2,
          'Bench Press',
          'Brand New Movement',
        ]),
        where: 'Progress $name',
      );
      await expectLayoutHoldsWhileScrolling(
        tester,
        find.byType(ProgressScreen),
        'Progress $name',
      );

      await openTab(tester, AlkionGlyph.history);
      await expectLayoutHoldsWhileScrolling(
        tester,
        find.byType(HistoryScreen),
        'History $name',
      );
      final cards = find.descendant(
        of: find.byType(HistoryScreen),
        matching: find.byType(SessionCard),
      );
      // The stacked 4-week band can push the first card past the built range.
      await scrollIntoView(tester, find.byType(HistoryScreen), cards);
      final card = cards.first;
      await tester.ensureVisible(card);
      await tester.tap(card, warnIfMissed: false);
      await settleReal(tester, ticks: 15);
      await expectLayoutHoldsWhileScrolling(
        tester,
        find.byType(HistoryScreen),
        'History expanded $name',
      );

      await tester.runAsync(
        () => harness.settings.setMuscleTargetsEnabled(true),
      );
      await openTab(tester, AlkionGlyph.plan);
      await settleUntilFound(
        tester,
        find.descendant(
          of: find.byType(SplitVolumeCard),
          matching: find.byKey(const Key('workload-top-muscles')),
        ),
        where: 'Plan split overview $name',
      );
      // The overview's figure is now the only one: Today's is unmounted.
      expect(
        find.descendant(of: find.byType(PlanScreen), matching: figures),
        findsOneWidget,
      );
      expect(figures, findsOneWidget);
      await expectLayoutHoldsWhileScrolling(
        tester,
        find.byType(PlanScreen),
        'Plan split $name',
      );
      // A day card opens the day's view inside Plan; Back returns.
      final longDayCard = find.byWidgetPredicate(
        (w) => w is SplitDayCard && w.name == longDay,
      );
      await scrollIntoView(tester, find.byType(SplitTab), longDayCard);
      await tester.tap(longDayCard);
      await settleUntilFound(
        tester,
        find.byType(DayView),
        where: 'Plan day view $name',
      );
      await settleReal(tester, ticks: 6);
      // The view's own body is swept by its own tests.
      expectLayoutHolds(tester, 'Plan day view $name');
      expect(find.byType(SplitVolumeCard, skipOffstage: false), findsNothing);
      expect(figures, findsOneWidget);
      await tester.tap(find.byKey(const Key('plan-editor-back')));
      await settleUntilFound(
        tester,
        find.byType(SplitTab),
        where: 'Plan split after the view $name',
      );
      await settleReal(tester, ticks: 6);
      for (final (label, where, marker) in [
        (
          l.planTabExercises,
          'Plan exercises',
          textWithAnyOf(find.byType(PlanScreen), [longExercise]),
        ),
        // Targets lists every muscle whether or not any is seeded.
        (l.planTabTargets, 'Plan targets', find.byType(TargetsList)),
      ]) {
        await tester.tap(
          find
              .descendant(
                of: find.byType(PlanScreen),
                matching: find.text(label),
              )
              .first,
        );
        if (where == 'Plan exercises') {
          await settleUntilFound(
            tester,
            find.byType(LibraryTab),
            where: '$where $name',
          );
          await settleReal(tester, ticks: 6);
          await scrollIntoView(tester, find.byType(PlanScreen), marker);
        }
        await settleUntilFound(tester, marker, where: '$where $name');
        await settleReal(tester, ticks: 6);
        await expectLayoutHoldsWhileScrolling(
          tester,
          find.byType(PlanScreen),
          '$where $name',
        );
        expect(figures, findsNothing);
      }

      await harness.unmount(tester);
    });
  }
}
