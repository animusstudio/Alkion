import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/widgets/pressable.dart';

void main() {
  for (final reducedMotion in [false, true]) {
    testWidgets(
      'pressed controls stay fixed (reduced motion: $reducedMotion)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reducedMotion),
              child: Center(
                child: PressableScale(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: const SizedBox(width: 100, height: 48),
                  ),
                ),
              ),
            ),
          ),
        );
        final before = tester.getRect(find.byType(PressableScale));
        final gesture = await tester.startGesture(before.center);
        await tester.pump();
        expect(tester.getRect(find.byType(PressableScale)), before);
        expect(find.byType(AnimatedScale), findsNothing);
        await gesture.up();
      },
    );
  }

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
