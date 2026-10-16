import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/widgets/progress_widgets.dart';

import '../support/l10n_harness.dart';

void main() {
  testWidgets('three BigStats fit a 320dp row at 1.3x in German', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 800),
          textScaler: TextScaler.linear(1.3),
        ),
        child: wrapL10n(
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: BigStat(label: 'Aktuell', value: '+1 rep'),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: BigStat(label: 'Bestwert', value: '−2 reps'),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: BigStat(
                    label: '12-Wochen-Δ',
                    value: '102.5',
                    unit: 'kg',
                  ),
                ),
              ],
            ),
          ),
          locale: const Locale('de'),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('−2 reps'), findsOneWidget);
  });
}
