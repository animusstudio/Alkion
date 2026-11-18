import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/session/catalog_set_values_editor.dart';
import 'package:alkion/session/set_values_editor.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/units/unit_service.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';

CatalogSetEvidence evidence({
  String profile = 'reps_duration_optional_load',
  Map<String, CatalogMetricEvidence> metrics = const {},
}) => CatalogSetEvidence(
  selection: CatalogSelectionEvidence(
    exerciseId: 'synthetic',
    contextId: 'dumbbell',
    contextRevision: 1,
    profile: CatalogMeasurementProfileEvidence.forKey(profile),
    displayLabel: 'Synthetic dumbbell sit-up',
  ),
  metrics: metrics,
);

void main() {
  setUpAll(preloadAppFonts);
  final changes = <(String, String, String)>[];
  setUp(changes.clear);
  Widget host(CatalogSetEvidence value) => wrapL10n(
    SingleChildScrollView(
      child: CatalogSetValuesEditor(
        evidence: value,
        unit: UnitService(),
        onMetricChanged: (metric, text, unit) =>
            changes.add((metric, text, unit)),
      ),
    ),
  );
  Finder ruler(String metric) => find.byKey(ValueKey('catalog-ruler-$metric'));

  testWidgets(
    'primary reps/load stay visible; one accessible disclosure opens empty optional duration without authoring values',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final value = evidence(
          metrics: {
            'repetitions': CatalogMetricEvidence.fromInput(
              '004',
              metric: 'repetitions',
              unit: 'count',
            ),
            'reported_load': CatalogMetricEvidence.fromInput(
              '003.125000',
              metric: 'reported_load',
              unit: 'kg',
            ),
          },
        );
        final before = value.toJson();
        await tester.pumpWidget(host(value));
        expect(ruler('repetitions'), findsOneWidget);
        expect(ruler('reported_load'), findsOneWidget);
        expect(ruler('duration'), findsNothing);
        final more = find.byKey(const Key('catalog-more-measurements'));
        expect(tester.getSize(more).height, greaterThanOrEqualTo(48));
        expect(
          tester.getSemantics(more).flagsCollection.isExpanded,
          Tristate.isFalse,
        );
        await tester.tap(more);
        await tester.pumpAndSettle();
        expect(ruler('duration'), findsOneWidget);
        expect(
          tester.getSemantics(more).flagsCollection.isExpanded,
          Tristate.isTrue,
        );
        await tester.tap(more);
        await tester.pumpAndSettle();
        expect(ruler('duration'), findsNothing);
        expect(changes, isEmpty);
        expect(value.toJson(), before);
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final quantity in [
    CatalogMetricEvidence.fromInput(
      '00065.250000',
      metric: 'duration',
      unit: 's',
    ),
    CatalogMetricEvidence.fromInput('-1', metric: 'duration', unit: 's'),
    const CatalogMetricEvidence(
      state: ValueState.unknown,
      raw: 'retained unknown',
      unit: 's',
    ),
  ]) {
    testWidgets(
      'stored optional ${quantity.state.name} stays visible and exact',
      (tester) async {
        final value = evidence(metrics: {'duration': quantity});
        final before = value.toJson();
        await tester.pumpWidget(host(value));
        expect(ruler('duration'), findsOneWidget);
        expect(find.text('More measurements'), findsNothing);
        expect(changes, isEmpty);
        expect(value.toJson(), before);
      },
    );
  }

  testWidgets(
    'empty optional distance is reachable while required duration remains visible',
    (tester) async {
      final value = evidence(profile: 'duration_distance_optional');
      await tester.pumpWidget(host(value));
      expect(ruler('duration'), findsOneWidget);
      expect(ruler('distance'), findsNothing);
      await tester.tap(find.text('More measurements'));
      await tester.pumpAndSettle();
      expect(ruler('distance'), findsOneWidget);
      expect(changes, isEmpty);
      expect(value.metrics, isEmpty);
    },
  );

  Finder caption(String name) => find.ancestor(
    of: find.textContaining(name, findRichText: true),
    matching: find.byType(SetFieldGuide),
  );
  String unitOf(WidgetTester tester, Finder guide) => tester
      .widget<Text>(
        find.descendant(
          of: guide,
          matching: find.byKey(const Key('set-field-unit')),
        ),
      )
      .data!;

  testWidgets(
    'captions split the name from its unit, drawn in the accent, with no painted guide',
    (tester) async {
      final value = evidence(
        metrics: {
          'reported_load': CatalogMetricEvidence.fromInput(
            '20',
            metric: 'reported_load',
            unit: 'kg',
          ),
        },
      );
      await tester.pumpWidget(host(value));
      await tester.tap(find.text('More measurements'));
      await tester.pumpAndSettle();
      expect(find.byType(SetFieldGuide), findsNWidgets(3));
      expect(
        find.descendant(
          of: find.byType(SetFieldGuide),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
      expect(unitOf(tester, caption('REPETITIONS')), 'reps');
      expect(unitOf(tester, caption('LOAD · OPTIONAL')), 'kg');
      expect(unitOf(tester, caption('DURATION · OPTIONAL')), 's');
      expect(
        find.descendant(
          of: find.byType(SetFieldGuide),
          matching: find.textContaining('('),
        ),
        findsNothing,
        reason: 'the unit is no longer inside the name',
      );
      final tokens = tester.element(find.byType(SetFieldGuide).first).tokens;
      for (final unit
          in find
              .byKey(const Key('set-field-unit'))
              .evaluate()
              .map((e) => e.widget as Text)) {
        expect(unit.style!.color, tokens.accentText);
      }
      // The modal title still names the unit.
      await tester.tap(
        find.descendant(
          of: ruler('reported_load'),
          matching: find.byKey(const Key('ruler-centre')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Load (kg)'), findsOneWidget);
      expect(changes, isEmpty);
    },
  );

  testWidgets('a distance caption shows metres in its unit slot', (
    tester,
  ) async {
    await tester.pumpWidget(host(evidence(profile: 'distance_duration')));
    expect(unitOf(tester, caption('DISTANCE')), 'm');
    expect(unitOf(tester, caption('DURATION')), 's');
  });

  for (final code in ['en', 'de', 'it']) {
    testWidgets('catalog captions fit without splitting at 320dp 2x $code', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 1600);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        wrapL10n(
          SingleChildScrollView(
            child: CatalogSetValuesEditor(
              evidence: evidence(),
              unit: UnitService(),
              onMetricChanged: (metric, text, unit) {},
            ),
          ),
          locale: Locale(code),
        ),
      );
      await tester.tap(find.byKey(const Key('catalog-more-measurements')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final guides = find.byType(SetFieldGuide);
      expect(guides, findsNWidgets(3));
      for (var i = 0; i < 3; i++) {
        final guide = guides.at(i);
        expectNoSplitWords(tester, within: guide, where: '$code caption $i');
        final unit = find.descendant(
          of: guide,
          matching: find.byKey(const Key('set-field-unit')),
        );
        expect(tester.getRect(unit).right, lessThanOrEqualTo(320 - 16 + 0.01));
      }
      if (code == 'de') {
        final word = find.text('WIEDERHOLUNGEN');
        expect(word, findsOneWidget);
        expectOneLine(tester, word);
        expect(unitOf(tester, caption('WIEDERHOLUNGEN')), 'Wdh.');
      }
    });
  }
}
