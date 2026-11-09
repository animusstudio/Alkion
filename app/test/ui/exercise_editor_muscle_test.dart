import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_scope.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/main.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/ui/exercise_editor.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/widgets/plan_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../catalog/catalog_fixture.dart';
import '../support/screen_harness.dart';

final _l = lookupAppLocalizations(const Locale('en'));

Future<void> _seed(FixtureDatabase d) async {
  await seedExercise(d, 'blank', 'Blank Group', muscle: '');
  await seedExercise(d, 'bench', 'Bench');
}

Future<void> _settleEditor(WidgetTester tester) => settleUntilFound(
  tester,
  find.descendant(
    of: find.byType(ExerciseEditor),
    matching: find.byType(ListView),
  ),
  where: 'exercise editor',
);

Future<void> _open(WidgetTester tester, ScreenHarness h, String id) async {
  setPhone(tester, width: 412);
  await tester.pumpWidget(
    h.wrap(
      Scaffold(
        body: ExerciseEditor(id: id, onBack: () {}),
      ),
    ),
  );
  await _settleEditor(tester);
}

/// The label of every muscle chip the editor shows.
List<String> _chipLabels(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(
      of: find.byType(ChipSelect<String>),
      matching: find.byType(Text),
    ),
  ))
    text.data ?? '',
];

void main() {
  final harness = ScreenHarness();
  tearDown(harness.close);

  testWidgets(
    'a catalog exercise shows a note instead of chips; saving keeps its group',
    (tester) async {
      late Directory temporary;
      late AlkionRuntime runtime;
      late RealZoneDatabase database;
      late String id;
      await tester.runAsync(() async {
        temporary = await Directory.systemTemp.createTemp('alkion-editor-');
        runtime = await AlkionRuntime.open(
          Directory('${temporary.path}/dev.animusstudio.alkion.dev'),
          catalogBundle: CatalogBundle.fromJsonString(
            jsonEncode(syntheticCatalog()),
          ),
        );
        database = RealZoneDatabase(runtime.store, Zone.current);
        final catalog = runtime.catalog!;
        final exercise = await catalog.materialize(
          CatalogChoice.variant(catalog.bundle.variants.values.first.id),
          ExerciseRepository.local(database),
          locale: 'en',
        );
        expect(exercise.muscleGroup, '');
        id = exercise.id;
      });
      setPhone(tester, width: 412);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<LocalDatabase>.value(value: database),
            ChangeNotifierProvider<UnitService>.value(value: runtime.units),
            ChangeNotifierProvider<SessionManager>.value(
              value: runtime.sessions,
            ),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, accents[0]),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ExerciseEditor(id: id, onBack: () {}),
            ),
          ),
        ),
      );
      await _settleEditor(tester);
      expect(find.byType(ChipSelect<String>), findsNothing);
      expect(
        find.byKey(const Key('exercise-editor-catalog-groups')),
        findsOneWidget,
      );
      expect(find.text(_l.exerciseEditorCatalogGroups), findsOneWidget);

      await tester.enterText(
        find
            .descendant(
              of: find.byType(ExerciseEditor),
              matching: find.byType(TextField),
            )
            .first,
        'Renamed catalog exercise',
      );
      await tester.pump();
      final save = find.text(_l.exerciseEditorSave);
      await scrollIntoView(tester, find.byType(ExerciseEditor), save);
      await tester.tap(save);
      await settleReal(tester, ticks: 10);
      late Map<String, dynamic> row;
      await tester.runAsync(() async {
        row = await database.get(
          'SELECT name, muscle_group, execution_definition_bytes '
          'FROM exercises WHERE id=?',
          [id],
        );
      });
      expect(row['name'], 'Renamed catalog exercise');
      expect(row['muscle_group'], '');
      expect(row['execution_definition_bytes'], isNotNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await settleReal(tester, ticks: 5);
      await tester.runAsync(() async {
        await runtime.close();
        await temporary.delete(recursive: true);
      });
    },
  );

  testWidgets('a classic exercise with a blank group gets no empty chip', (
    tester,
  ) async {
    await harness.open(tester, seed: _seed);
    await _open(tester, harness, 'blank');
    expect(find.byType(ChipSelect<String>), findsOneWidget);
    final labels = _chipLabels(tester);
    expect(labels, hasLength(8));
    expect(labels.where((t) => t.trim().isEmpty), isEmpty);
    expect(
      tester
          .widget<ChipSelect<String>>(find.byType(ChipSelect<String>))
          .selected,
      '',
    );
    await harness.unmount(tester);
  });

  testWidgets('a classic exercise keeps its 8 muscle chips', (tester) async {
    await harness.open(tester, seed: _seed);
    await _open(tester, harness, 'bench');
    expect(find.byType(ChipSelect<String>), findsOneWidget);
    expect(_chipLabels(tester), [
      'Chest',
      'Back',
      'Shoulders',
      'Quads',
      'Hamstrings',
      'Calves',
      'Biceps',
      'Triceps',
    ]);
    expect(
      find.byKey(const Key('exercise-editor-catalog-groups')),
      findsNothing,
    );
    await harness.unmount(tester);
  });
}
