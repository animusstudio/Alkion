import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/motion.dart';

void main() {
  // Scope to the Reveal subtree — MaterialApp's route transitions can hold
  // their own FadeTransitions.
  Finder revealFade() => find.descendant(
    of: find.byType(Reveal),
    matching: find.byType(FadeTransition),
  );

  testWidgets('Reveal fades child in on mount and settles fully visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Reveal(child: Text('row'))),
    );
    // Mid-animation: opacity < 1.
    await tester.pump(const Duration(milliseconds: 50));
    final fade = tester.widget<FadeTransition>(revealFade());
    expect(fade.opacity.value, lessThan(1.0));
    // Settled: fully visible.
    await tester.pumpAndSettle();
    final settled = tester.widget<FadeTransition>(revealFade());
    expect(settled.opacity.value, 1.0);
    expect(find.text('row'), findsOneWidget);
  });

  testWidgets('Reveal does not replay when the parent rebuilds', (
    tester,
  ) async {
    final notifier = ValueNotifier(0);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<int>(
          valueListenable: notifier,
          builder: (_, v, __) =>
              Reveal(key: const ValueKey('stable'), child: Text('build $v')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    notifier.value = 1; // parent rebuild, same key
    await tester.pump();
    final fade = tester.widget<FadeTransition>(revealFade());
    expect(fade.opacity.value, 1.0); // no replay
    expect(find.text('build 1'), findsOneWidget);
  });

  testWidgets('Reveal renders child directly under reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(home: Reveal(child: Text('row'))),
      ),
    );
    await tester.pump();
    expect(revealFade(), findsNothing);
    expect(find.text('row'), findsOneWidget);
  });
}
