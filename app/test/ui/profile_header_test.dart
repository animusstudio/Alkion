import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/ui/profile_screen.dart';

import '../support/screen_harness.dart';

/// Two owned training days.
Future<void> seedTwoDays(FixtureDatabase d) async {
  await seedDay(d, 'd1', 'Upper', position: 0);
  await seedDay(d, 'd2', 'Lower', position: 1);
}

/// Two finished workouts on fixed dates, inserted latest first; the first
/// one is in March 2026.
Future<void> seedTwoSessions(FixtureDatabase d) async {
  await seedSession(
    d,
    's2',
    date: DateTime(2026, 5, 2),
    label: 'Lower',
    sets: const [],
  );
  await seedSession(
    d,
    's1',
    date: DateTime(2026, 3, 14),
    label: 'Upper',
    sets: const [],
  );
}

Future<void> seedDaysAndSessions(FixtureDatabase d) async {
  await seedTwoDays(d);
  await seedTwoSessions(d);
}

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  final line = find.byKey(const Key('profile-training-line'));
  String lineText(WidgetTester tester) => tester.widget<Text>(line).data!;

  Future<void> pumpProfile(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      harness.wrap(
        ProfileScreen(onClose: () {}, onLogout: () async {}, auth: Object()),
        locale: locale,
      ),
    );
  }

  testWidgets('shows the first workout month and the number of training days', (
    tester,
  ) async {
    await harness.open(tester, seed: seedDaysAndSessions);
    await pumpProfile(tester);
    await settleUntilFound(tester, line, where: 'Profile en');
    expect(lineText(tester), 'Training since Mar 2026 · 2-\u2060day split');
    await harness.unmount(tester);
  });

  testWidgets('reads in the UI language', (tester) async {
    await harness.open(tester, seed: seedDaysAndSessions);
    await pumpProfile(tester, locale: const Locale('de'));
    await settleUntilFound(tester, line, where: 'Profile de');
    expect(lineText(tester), 'Training seit März 2026 · 2-\u2060Tage-Split');
    await harness.unmount(tester);
  });

  testWidgets('a fresh install shows no line, and no made-up one', (
    tester,
  ) async {
    await harness.open(tester, seed: (_) async {});
    await pumpProfile(tester);
    await settleReal(tester);
    expect(line, findsNothing);
    expect(find.textContaining('Training since'), findsNothing);
    // The line is live, not stalled: the first training day brings it in.
    await tester.runAsync(
      () => seedDay(harness.database, 'd1', 'Upper', position: 0),
    );
    await settleUntilFound(tester, line, where: 'after the first day');
    expect(lineText(tester), '1-\u2060day split');
    await harness.unmount(tester);
  });

  testWidgets('training days without a workout show the split alone', (
    tester,
  ) async {
    await harness.open(tester, seed: seedTwoDays);
    await pumpProfile(tester);
    await settleUntilFound(tester, line, where: 'days only');
    expect(lineText(tester), '2-\u2060day split');
    await harness.unmount(tester);
  });

  testWidgets('workouts without a training day show "since" alone', (
    tester,
  ) async {
    await harness.open(tester, seed: seedTwoSessions);
    await pumpProfile(tester);
    await settleUntilFound(tester, line, where: 'sessions only');
    expect(lineText(tester), 'Training since Mar 2026');
    await harness.unmount(tester);
  });

  testWidgets('deleting the first workout moves "since" forward', (
    tester,
  ) async {
    await harness.open(tester, seed: seedDaysAndSessions);
    await pumpProfile(tester);
    await settleUntilFound(
      tester,
      find.text('Training since Mar 2026 · 2-\u2060day split'),
      where: 'before the delete',
    );
    await tester.runAsync(
      () => harness.database.execute("DELETE FROM sessions WHERE id = 's1'"),
    );
    await settleUntilFound(
      tester,
      find.text('Training since May 2026 · 2-\u2060day split'),
      where: 'after the delete',
    );
    await harness.unmount(tester);
  });

  // At 320dp with large text the line wraps before the split. The count must start the
  // second line with its noun, never end the first as a dangling "3-".
  testWidgets('a wrapped line keeps the day count with its noun at 320dp', (
    tester,
  ) async {
    await harness.open(
      tester,
      seed: (d) async {
        await seedDay(d, 'd1', 'Push', position: 0);
        await seedDay(d, 'd2', 'Pull', position: 1);
        await seedDay(d, 'd3', 'Legs', position: 2);
        await seedSession(
          d,
          's1',
          date: DateTime(2026, 9, 14),
          label: 'Push',
          sets: const [],
        );
      },
    );
    setPhone(tester, width: 320, textScale: 2.0);
    await pumpProfile(tester);
    await settleUntilFound(tester, line, where: 'Profile 320dp');
    final p = tester.renderObject<RenderParagraph>(
      find.descendant(of: line, matching: find.byType(RichText)),
    );
    expect(
      p.size.height,
      greaterThan(p.getFullHeightForCaret(const TextPosition(offset: 0)) * 1.5),
      reason: 'the line should wrap here',
    );
    final text = p.text.toPlainText();
    final digit = text.indexOf('3-');
    expect(digit, isNonNegative, reason: '"$text" has no "3-day" split');
    var letter = digit + 2;
    while (!RegExp(r'\p{L}', unicode: true).hasMatch(text[letter])) {
      letter++;
    }
    double top(int i) => p
        .getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + 1))
        .first
        .top;
    expect(
      top(digit),
      top(letter),
      reason: '"$text" breaks between the count and its noun',
    );
    await harness.unmount(tester);
  });

  testWidgets('editing the name hides the line, and saving brings it back', (
    tester,
  ) async {
    await harness.open(tester, seed: seedDaysAndSessions);
    await pumpProfile(tester);
    await settleUntilFound(tester, line, where: 'before editing');
    await tester.tap(find.text('Athlete'));
    await settleReal(tester, ticks: 2);
    expect(line, findsNothing);
    await tester.tap(find.text('Save'));
    // No new query: the line comes back from the value already held.
    await settleReal(tester, ticks: 2);
    expect(lineText(tester), 'Training since Mar 2026 · 2-\u2060day split');
    await harness.unmount(tester);
  });
}
