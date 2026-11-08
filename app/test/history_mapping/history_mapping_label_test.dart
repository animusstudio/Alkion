import 'dart:convert';

import 'package:alkion/history_mapping/history_mapping.dart';
import 'package:alkion/history_mapping/history_mapping_label.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/session/exercise_picker_sheet.dart';
import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_picker.dart';
import '../support/memory_catalog_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/screen_harness.dart' show setPhone;
import '../catalog/catalog_fixture.dart';

/// Stored mappings are display metadata only: they label the original
/// exercise and steer new choices toward the mapped catalog variant.
class OwnedTestCatalog extends MemoryCatalogState {
  OwnedTestCatalog(super.bundle, this.owned);
  final List<Exercise> owned;
  @override
  List<Exercise> get ownedExercises => owned;
}

void main() {
  setUpAll(preloadAppFonts);
  for (final locale in ['en', 'it', 'de', 'es']) {
    testWidgets(
      'History attribution retains source and approximation in details at 320dp in $locale',
      (tester) async {
        setPhone(tester, width: 320, textScale: 2);
        final mapping = HistoryMapping(
          sourceName: 'Synthetic Original Row',
          status: 'approximate',
          rationale: 'Reviewed substitute, original evidence preserved.',
          variantId: 'synthetic',
          variantRevision: 1,
          displayName: 'Synthetic mapped variant',
          measurementProfile: 'load_reps',
        );
        await tester.pumpWidget(
          wrapL10n(
            HistoryMappingScope(
              mappings: {'exercise': mapping},
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Synthetic Original Row'),
                  HistoryMappingLabel(exerciseId: 'exercise'),
                ],
              ),
            ),
            locale: Locale(locale),
          ),
        );
        expect(find.text('Synthetic Original Row'), findsOneWidget);
        expect(find.textContaining('Synthetic mapped variant'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'fallback workout picker keeps original mapped occurrences when canonical catalog is unavailable',
    (tester) async {
      Exercise exercise(String id, String name) => Exercise(
        id: id,
        name: name,
        slug: id,
        muscleGroup: '',
        compound: false,
        plateStepKg: 2.5,
        isTemplate: false,
      );
      final originals = [
        exercise('source-1', 'Repeated original'),
        exercise('source-2', 'Repeated original'),
        exercise('unresolved', 'Unresolved source'),
        exercise('native', 'Native choice'),
      ];
      final reviewed = HistoryMapping(
        sourceName: 'Repeated original',
        status: 'approximate',
        rationale: 'Reviewed test substitution',
        variantId: 'variant',
        variantRevision: 1,
        displayName: 'Canonical target',
        measurementProfile: 'load_reps',
      );
      final unresolved = HistoryMapping(
        sourceName: 'Unresolved source',
        status: 'unresolved',
        rationale: 'No compatible catalog variant',
      );
      await tester.pumpWidget(
        wrapL10n(
          HistoryMappingScope(
            mappings: {
              'source-1': reviewed,
              'source-2': reviewed,
              'unresolved': unresolved,
            },
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showExercisePicker(context, exercises: originals),
                child: const Text('Pick'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      expect(find.text('Repeated original'), findsNWidgets(2));
      expect(find.text('Unresolved source'), findsOneWidget);
      expect(find.text('Native choice'), findsOneWidget);
      expect(originals.map((e) => e.id), [
        'source-1',
        'source-2',
        'unresolved',
        'native',
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'canonical catalog picker hides repeated mapped source choices, keeps unresolved, and offers the mapped variant',
    (tester) async {
      final bundle = CatalogBundle.fromJsonString(
        jsonEncode(syntheticCatalog()),
      );
      final variant = bundle.variants.values.first;
      Exercise exercise(String id, String name) => Exercise(
        id: id,
        name: name,
        slug: id,
        muscleGroup: '',
        compound: false,
        plateStepKg: 2.5,
        isTemplate: false,
      );
      final originals = [
        exercise('source-1', 'Repeated original'),
        exercise('source-2', 'Repeated original'),
        exercise('unresolved', 'Unresolved source'),
      ];
      final state = OwnedTestCatalog(bundle, originals);
      addTearDown(state.dispose);
      final reviewed = HistoryMapping(
        sourceName: 'Repeated original',
        status: 'approximate',
        rationale: 'Reviewed test substitution',
        variantId: variant.id,
        variantRevision: variant.revision,
        displayName: variant.names['en'],
        measurementProfile: variant.measurementProfileKey,
      );
      await tester.pumpWidget(
        wrapL10n(
          HistoryMappingScope(
            mappings: {'source-1': reviewed, 'source-2': reviewed},
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => showCatalogPicker(
                  context,
                  state: state,
                  immediateSelection: true,
                ),
                child: const Text('Pick'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      final search = find.byKey(const Key('catalog-search'));
      await tester.enterText(search, 'Repeated original');
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(CatalogPickerRow),
          matching: find.text('Repeated original'),
        ),
        findsNothing,
      );
      await tester.enterText(search, 'Unresolved source');
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(CatalogPickerRow),
          matching: find.text('Unresolved source'),
        ),
        findsOneWidget,
      );
      await tester.enterText(search, variant.names['en']!);
      await tester.pumpAndSettle();
      expect(find.byType(CatalogPickerRow), findsWidgets);
      expect(state.ownedExercises.length, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
