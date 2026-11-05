import 'package:alkion/shell/app_shell.dart';
import 'package:alkion/theme/alkion_icon.dart';
import 'package:alkion/theme/workout_canvas.dart';
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
    }
    await harness.unmount(tester);
    expect(tester.takeException(), isNull);
  });
}
