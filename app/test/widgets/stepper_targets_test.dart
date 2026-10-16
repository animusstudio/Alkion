import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/widgets/stepper.dart';

import '../support/l10n_harness.dart';

void main() {
  testWidgets('the increment button hit box is 48x48', (tester) async {
    await tester.pumpWidget(
      wrapL10n(
        WStepper(
          value: 10,
          step: 1,
          format: (v) => v.round().toString(),
          onChanged: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(tester.getSize(find.byKey(const Key('stepper-inc'))), Size(48, 48));
  });

  testWidgets('a semanticLabel produces "Increase <label>"', (tester) async {
    await tester.pumpWidget(
      wrapL10n(
        WStepper(
          value: 10,
          step: 1,
          format: (v) => v.round().toString(),
          onChanged: (_) {},
          semanticLabel: 'Rest',
        ),
      ),
    );
    await tester.pump();

    expect(find.bySemanticsLabel('Increase Rest'), findsOneWidget);
  });

  testWidgets('no semanticLabel produces the generic "Increase"', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapL10n(
        WStepper(
          value: 10,
          step: 1,
          format: (v) => v.round().toString(),
          onChanged: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(find.bySemanticsLabel('Increase'), findsOneWidget);
  });

  testWidgets(
    'a scaled-up long value in a 168-wide stepper does not throw and is '
    'wrapped in a FittedBox',
    (tester) async {
      await tester.pumpWidget(
        wrapL10n(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: SizedBox(
              width: 168,
              child: WStepper(
                value: 180,
                step: 15,
                format: (v) => '${v.round()}s',
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(FittedBox), findsOneWidget);
    },
  );

  testWidgets(
    'a scaled-up long value in a 144-wide stepper (profile rest rows) does '
    'not throw and is wrapped in a FittedBox',
    (tester) async {
      await tester.pumpWidget(
        wrapL10n(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: SizedBox(
              width: 144,
              child: WStepper(
                value: 180,
                step: 15,
                format: (v) => '${v.round()}s',
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(FittedBox), findsOneWidget);
    },
  );

  testWidgets('StepperButton is a 48x48 labelled target that fires onTap', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      wrapL10n(
        Center(
          child: StepperButton(
            key: const Key('btn'),
            icon: Icons.add,
            semanticLabel: 'Increase Bodyweight',
            onTap: () => taps++,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.getSize(find.byKey(const Key('btn'))), const Size(48, 48));
    expect(find.bySemanticsLabel('Increase Bodyweight'), findsOneWidget);

    await tester.tap(find.byKey(const Key('btn')));
    expect(taps, 1);
    handle.dispose();
  });
}
