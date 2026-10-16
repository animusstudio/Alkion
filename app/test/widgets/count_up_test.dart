import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/motion.dart';

void main() {
  testWidgets('settles on the exact formatted final value', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: CountUp(value: 42, builder: (v) => Text('$v sets'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('42 sets'), findsOneWidget);
  });
  testWidgets('animates from 0 (mid-flight value below final)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: CountUp(value: 100, builder: (v) => Text('$v'))),
    );
    await tester.pump(const Duration(milliseconds: 60));
    final mid = int.parse((tester.widget<Text>(find.byType(Text))).data!);
    expect(mid, lessThan(100));
    await tester.pumpAndSettle();
    expect(find.text('100'), findsOneWidget);
  });
}
