import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/ui/plan_screen.dart';

import '../support/l10n_harness.dart';

/// Renders [planEyebrow] for [count] in [locale] and returns the text.
Future<String> _eyebrow(
  WidgetTester tester,
  int? count, {
  Locale locale = const Locale('en'),
}) async {
  late String out;
  await tester.pumpWidget(
    wrapL10n(
      Builder(
        builder: (context) {
          out = planEyebrow(AppLocalizations.of(context), count);
          return const SizedBox.shrink();
        },
      ),
      locale: locale,
    ),
  );
  return out;
}

void main() {
  testWidgets('one training day is singular', (tester) async {
    expect(await _eyebrow(tester, 1), '1 training day');
    expect(
      await _eyebrow(tester, 1, locale: const Locale('de')),
      '1 Trainingstag',
    );
  });

  testWidgets('four training days are plural', (tester) async {
    expect(await _eyebrow(tester, 4), '4 training days');
    expect(
      await _eyebrow(tester, 4, locale: const Locale('de')),
      '4 Trainingstage',
    );
  });

  testWidgets('no count yet shows nothing, not "0 training days"', (
    tester,
  ) async {
    expect(await _eyebrow(tester, null), '');
  });
}
