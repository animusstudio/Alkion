import 'package:alkion/widgets/state_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('event progress is immediate, finite and cancels on background', (
    tester,
  ) async {
    var event = 0;
    var progress = 0.0;
    var taps = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, set) {
            update = set;
            return EventProgress(
              event: event,
              builder: (_, value) {
                progress = value;
                return GestureDetector(
                  onTap: () => taps++,
                  child: Text('Action $event'),
                );
              },
            );
          },
        ),
      ),
    );
    expect(progress, 1);
    update(() => event++);
    await tester.pump();
    expect(progress, 0);
    await tester.tap(find.text('Action 1'));
    expect(taps, 1);
    await tester.pump(const Duration(milliseconds: 60));
    expect(progress, inExclusiveRange(0, 1));
    update(() => event++);
    await tester.pump();
    expect(find.text('Action 2'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(progress, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(progress, 1);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'reduced motion and hidden subtree render final state without tickers',
    (tester) async {
      var event = 0;
      var reduced = true;
      var visible = true;
      var progress = 0.0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, set) {
              update = set;
              return MediaQuery(
                data: MediaQueryData(
                  size: const Size(800, 600),
                  disableAnimations: reduced,
                ),
                child: TickerMode(
                  enabled: visible,
                  child: EventProgress(
                    event: event,
                    onMount: true,
                    builder: (_, value) {
                      progress = value;
                      return const SizedBox(width: 40, height: 40);
                    },
                  ),
                ),
              );
            },
          ),
        ),
      );
      expect(progress, 1);
      expect(tester.binding.transientCallbackCount, 0);
      update(() {
        reduced = false;
        event++;
      });
      await tester.pump();
      expect(progress, 0);
      update(() => visible = false);
      await tester.pump();
      expect(progress, 1);
      update(() => visible = true);
      await tester.pump();
      expect(progress, 1);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('scroll-out cancels finite decoration rather than replaying it', (
    tester,
  ) async {
    var progress = 0.0;
    final scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          controller: scroll,
          child: Column(
            children: [
              EventProgress(
                event: 1,
                onMount: true,
                builder: (_, value) {
                  progress = value;
                  return const SizedBox(height: 100);
                },
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 30));
    expect(progress, lessThan(1));
    scroll.jumpTo(1000);
    await tester.pump();
    await tester.pump();
    expect(progress, 1);
    scroll.jumpTo(0);
    await tester.pump();
    expect(progress, 1);
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });
}
