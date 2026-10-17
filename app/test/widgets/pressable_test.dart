import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/widgets/pressable.dart';

void main() {
  testWidgets('scales down on pointer-down and back up on release', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: PressableScale(child: SizedBox(width: 100, height: 40)),
        ),
      ),
    );
    double currentScale() =>
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;
    expect(currentScale(), 1.0);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PressableScale)),
    );
    await tester.pump();
    expect(currentScale(), lessThan(1.0));
    await gesture.up();
    await tester.pump();
    expect(currentScale(), 1.0);
  });

  testWidgets('reduced motion keeps the pressed control stationary', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Center(
            child: PressableScale(child: SizedBox(width: 100, height: 48)),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PressableScale)),
    );
    await tester.pump();
    final scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
    expect(scale.scale, 1);
    expect(scale.duration, Duration.zero);
    await gesture.up();
  });

  testWidgets('does not block the child own taps', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: PressableScale(
            // A real consumer's child is hittable (a button/row); a bare
            // SizedBox is not, so give the detector an opaque hit region.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => tapped = true,
              child: const SizedBox(width: 100, height: 40),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(PressableScale));
    expect(tapped, isTrue);
  });
}
