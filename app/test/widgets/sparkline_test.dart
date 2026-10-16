import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/widgets/sparkline.dart';

void main() {
  testWidgets('Sparkline with 3 values renders a CustomPaint', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Sparkline(values: [1, 2, 3])),
        ),
      ),
    );
    // The Sparkline widget itself wraps a SizedBox containing a CustomPaint.
    // Verify the Sparkline widget is present in the tree.
    expect(find.byType(Sparkline), findsOneWidget);
    // And that its child tree contains at least one CustomPaint (the painter).
    expect(
      find.descendant(
        of: find.byType(Sparkline),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Sparkline with 1 value renders zero-size SizedBox', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Sparkline(values: [1])),
        ),
      ),
    );
    // With <2 values, Sparkline returns SizedBox.shrink() — no CustomPaint inside it.
    expect(find.byType(Sparkline), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(Sparkline),
        matching: find.byType(CustomPaint),
      ),
      findsNothing,
    );
    // The Sparkline renders as a zero-size widget.
    final sparklineElement = tester.element(find.byType(Sparkline));
    final renderBox = sparklineElement.renderObject as RenderBox;
    expect(renderBox.size, Size.zero);
  });
}
