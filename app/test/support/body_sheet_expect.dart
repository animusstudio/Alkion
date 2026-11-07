import 'package:alkion/data/body_workload.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/ui/character_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The open workload sheet shows exactly its header, mode line, body,
/// legend and region counts: every text belongs to one of those, and no
/// removed chooser, coverage or details section remains.
void expectWorkloadSheetSections(
  WidgetTester tester,
  AppLocalizations l, {
  required String mode,
}) {
  final sheet = find.byType(BottomSheet);
  expect(sheet, findsOneWidget);
  Finder inside(Finder of) =>
      find.descendant(of: sheet, matching: of, skipOffstage: false);
  expect(
    tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(const Key('body-workload-mode')),
            matching: find.byType(Text),
          ),
        )
        .data,
    mode,
  );
  expect(inside(find.byType(CharacterBody)), findsOneWidget);
  for (final bin in workloadCountBins) {
    expect(
      find.descendant(
        of: find.byKey(const Key('body-legend')),
        matching: find.text(bin),
      ),
      findsOneWidget,
    );
  }
  for (final muscle in WorkloadMuscle.values) {
    expect(
      find.descendant(
        of: find.byKey(const Key('body-workload-counts')),
        matching: find.byKey(ValueKey('body-count-${muscle.name}')),
      ),
      findsOneWidget,
    );
  }
  final sections = [
    find.byKey(const Key('body-workload-mode')),
    find.byKey(const Key('body-legend')),
    find.byKey(const Key('body-workload-counts')),
    find.byKey(const Key('body-artwork-retry')),
    find.byType(CharacterBody),
  ];
  for (final element in inside(find.byType(Text)).evaluate()) {
    final text = element.widget as Text;
    final owned = sections.any(
      (section) => find
          .descendant(
            of: section,
            matching: find.byElementPredicate((e) => e == element),
            skipOffstage: false,
          )
          .evaluate()
          .isNotEmpty,
    );
    expect(
      owned || text.data == l.bodyWorkload,
      isTrue,
      reason: 'unexpected sheet text "${text.data}"',
    );
  }
  // Close is the only icon action; Reload appears only after a failure.
  expect(inside(find.byType(IconButton)), findsOneWidget);
  expect(
    inside(find.byType(TextButton)).evaluate().length,
    inside(find.byKey(const Key('body-artwork-retry'))).evaluate().length,
  );
  expect(inside(find.byType(OutlinedButton)), findsNothing);
  expect(inside(find.byType(ExpansionTile)), findsNothing);
}
