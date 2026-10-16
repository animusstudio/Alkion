import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/ui/plan_screen.dart';
import 'package:alkion/ui/profile_screen.dart';

import '../support/layout_expect.dart';
import '../support/pump_until.dart';
import '../support/screen_harness.dart';
import '../alkion/domains/local_screen_harness.dart' as local;

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  testWidgets('the Plan sub-tab reads "Exercises" whole at 2.0x (412dp)', (
    tester,
  ) async {
    final harness = local.ScreenHarness();
    addTearDown(harness.close);
    await harness.open(tester);
    setPhone(tester, width: 412, textScale: 2.0);
    await tester.pumpWidget(harness.wrap(const Scaffold(body: PlanScreen())));
    final label = find.text('Exercises');
    await pumpUntilFound(tester, label);
    await settleReal(tester, ticks: 5);
    expectNoSplitWords(tester, within: label);
    expectOneLine(tester, label);
    expect(
      tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
      isFalse,
    );
    await harness.unmount(tester);
  });

  testWidgets('Profile row titles never split a word at 320dp', (tester) async {
    await harness.open(tester);
    setPhone(tester, width: 320);
    await tester.pumpWidget(
      harness.wrap(
        ProfileScreen(onClose: () {}, onLogout: () async {}, auth: Object()),
      ),
    );
    await settleReal(tester);
    final title = find.text('Compound rest');
    await scrollIntoView(tester, find.byType(ProfileScreen), title);
    expectNoSplitWords(tester, within: title);
    await harness.unmount(tester);
  });
}
