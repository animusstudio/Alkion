import 'package:alkion/shell/app_shell.dart';
import 'package:alkion/theme/alkion_icon.dart';
import 'package:alkion/theme/workout_canvas.dart';
import 'package:alkion/ui/split_tab.dart';
import 'package:alkion/ui/day_editor.dart';
import 'package:alkion/ui/day_view.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/screen_harness.dart';

void main() {
  testWidgets('only Today and Plan opt in to the ambient canvas', (
    tester,
  ) async {
    final harness = ScreenHarness();
    await harness.open(tester);
    addTearDown(harness.close);
    await tester.pumpWidget(harness.wrap(const AppShell()));
    await settleReal(tester);
    bool ambient() =>
        tester.widget<WorkoutCanvas>(find.byType(WorkoutCanvas)).ambient;
    expect(ambient(), isTrue);
    for (final (tab, expected) in [
      (AlkionGlyph.progress, false),
      (AlkionGlyph.history, false),
      (AlkionGlyph.plan, true),
      (AlkionGlyph.profile, false),
      (AlkionGlyph.home, true),
    ]) {
      await openTab(tester, tab);
      expect(ambient(), expected, reason: tab.name);
      if (tab == AlkionGlyph.plan) {
        final day = find.byWidgetPredicate(
          (widget) => widget is SplitDayCard && widget.name == longDay,
        );
        // The split overview sits above the day cards.
        await scrollIntoView(tester, find.byType(SplitTab), day);
        await tester.tap(day);
        await settleUntilFound(
          tester,
          find.byType(DayView),
          where: 'Plan day view',
        );
        expect(ambient(), isFalse, reason: 'Opaque view hides the canvas');
        tester.widget<DayView>(find.byType(DayView)).onEdit();
        await settleUntilFound(
          tester,
          find.byType(DaySlotRow),
          where: 'Plan editor',
        );
        expect(ambient(), isFalse, reason: 'Opaque editor hides the canvas');
        await tester.tap(find.byTooltip('Back'));
        await settleReal(tester);
        expect(find.byType(DayView), findsOneWidget);
        expect(
          ambient(),
          isFalse,
          reason: 'Back from the editor shows the view',
        );
        await tester.tap(find.byTooltip('Back'));
        await settleReal(tester);
        expect(
          ambient(),
          isTrue,
          reason: 'Returning to the list reveals margins',
        );
      }
    }
    await harness.unmount(tester);
    expect(tester.takeException(), isNull);
  });
}
