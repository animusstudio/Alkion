import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/icons.dart';
import 'package:alkion/ui/exercise_sheet.dart';

import '../support/l10n_harness.dart';

const _bench = Exercise(
  id: 'bench',
  name: 'Bench Press',
  slug: 'bench',
  muscleGroup: 'chest',
  compound: true,
  plateStepKg: 2.5,
  isTemplate: false,
);

const _curl = Exercise(
  id: 'curl',
  name: 'Curl',
  slug: 'curl',
  muscleGroup: 'arms',
  compound: false,
  plateStepKg: 2.5,
  isTemplate: false,
);

/// Opens the sheet the same way callers do — via `showExerciseSheet` behind a
/// button — so the real modal route is exercised.
Widget host({required String? current, bool showBodyweight = true}) => wrapL10n(
  Builder(
    builder: (context) => ElevatedButton(
      key: const Key('open-sheet'),
      onPressed: () => showExerciseSheet(
        context,
        exercises: const [_bench, _curl],
        current: current,
        showBodyweight: showBodyweight,
      ),
      child: const Text('open'),
    ),
  ),
);

void main() {
  testWidgets(
    'the current exercise row shows a trailing check; others do not',
    (tester) async {
      await tester.pumpWidget(host(current: 'bench'));
      await tester.tap(find.byKey(const Key('open-sheet')));
      await tester.pumpAndSettle();

      // Bench (current) row: a check icon, the accent border and the selected
      // semantics flag.
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Bench Press'),
            matching: find.byType(GestureDetector),
          ),
          matching: find.byIcon(WIcons.check),
        ),
        findsOneWidget,
      );

      final accent = tester.element(find.text('Bench Press')).tokens.accent;
      expect(_rowBorderColor(tester, 'Bench Press'), accent);
      expect(_isSelected(tester, 'Bench Press'), isTrue);

      // Curl (not current) row: no check icon, no accent border.
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Curl'),
            matching: find.byType(GestureDetector),
          ),
          matching: find.byIcon(WIcons.check),
        ),
        findsNothing,
      );
      expect(_rowBorderColor(tester, 'Curl'), isNot(accent));
      expect(_isSelected(tester, 'Curl'), isFalse);
    },
  );

  testWidgets('no leading compound dot is rendered', (tester) async {
    await tester.pumpWidget(host(current: null));
    await tester.tap(find.byKey(const Key('open-sheet')));
    await tester.pumpAndSettle();

    // The old leading dot was a bare 6x6 circular Container with no
    // decoration image/child; assert no such shape decoration exists at all
    // by checking there is no Container with a BoxShape.circle decoration
    // among the row's direct children (the row itself uses no circular dot).
    final decoratedBoxes = tester.widgetList<Container>(find.byType(Container));
    final hasDot = decoratedBoxes.any((c) {
      final decoration = c.decoration;
      return decoration is BoxDecoration && decoration.shape == BoxShape.circle;
    });
    expect(hasDot, isFalse);
  });

  testWidgets(
    'the bodyweight tracking row counts as current when current is the bodyweight id',
    (tester) async {
      await tester.pumpWidget(host(current: kBodyweightSentinel));
      await tester.tap(find.byKey(const Key('open-sheet')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Bodyweight'),
            matching: find.byType(GestureDetector),
          ),
          matching: find.byIcon(WIcons.check),
        ),
        findsOneWidget,
      );
      final accent = tester.element(find.text('Bodyweight')).tokens.accent;
      expect(_rowBorderColor(tester, 'Bodyweight'), accent);
      expect(_isSelected(tester, 'Bodyweight'), isTrue);

      // Exercise rows are unmarked when the bodyweight row is current.
      for (final name in ['Bench Press', 'Curl']) {
        expect(_rowBorderColor(tester, name), isNot(accent));
        expect(_isSelected(tester, name), isFalse);
        expect(
          find.descendant(
            of: find.ancestor(
              of: find.text(name),
              matching: find.byType(GestureDetector),
            ),
            matching: find.byIcon(WIcons.check),
          ),
          findsNothing,
        );
      }
    },
  );
}

/// The border colour of the nearest bordered container around [text] — the
/// picker row itself.
Color _rowBorderColor(WidgetTester tester, String text) {
  final row = tester
      .widgetList<Container>(
        find.ancestor(of: find.text(text), matching: find.byType(Container)),
      )
      .firstWhere(
        (c) =>
            c.decoration is BoxDecoration &&
            (c.decoration! as BoxDecoration).border != null,
      );
  final border = (row.decoration! as BoxDecoration).border! as Border;
  return border.top.color;
}

/// Whether any semantics wrapper around [text] marks it selected.
bool _isSelected(WidgetTester tester, String text) => tester
    .widgetList<Semantics>(
      find.ancestor(of: find.text(text), matching: find.byType(Semantics)),
    )
    .any((s) => s.properties.selected == true);
