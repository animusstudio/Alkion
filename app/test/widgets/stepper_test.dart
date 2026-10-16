import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/widgets/stepper.dart';

import '../support/l10n_harness.dart';

void main() {
  testWidgets('WStepper increments by step, clamps at >= 0', (tester) async {
    double value = 2.0;
    await tester.pumpWidget(
      wrapL10n(
        StatefulBuilder(
          builder: (c, setState) => WStepper(
            value: value,
            step: 2.5,
            format: (v) => v.toStringAsFixed(1),
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('stepper-inc')));
    await tester.pump();
    expect(value, 4.5);
    await tester.tap(find.byKey(const Key('stepper-dec'))); // 4.5 -> 2.0
    await tester.tap(
      find.byKey(const Key('stepper-dec')),
    ); // 2.0 -> 0 (clamp, not -0.5)
    await tester.pump();
    expect(value, 0.0);
  });
}
