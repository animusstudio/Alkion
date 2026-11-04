import 'dart:io';
import 'dart:convert';

import 'package:alkion/files/document_access.dart';
import 'package:alkion/history_test/history_mapping.dart';
import 'package:alkion/history_test/history_mapping_label.dart';
import 'package:alkion/ui/reps_import_screen.dart';
import 'package:alkion/transfer/reps_import.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:alkion/main.dart' show openAlkionStore;
import 'package:alkion/store/local_store.dart';
import 'package:alkion/history_test/retired_history_workspace.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/session/exercise_picker_sheet.dart';
import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_picker.dart';
import 'package:alkion/catalog_ui/catalog_trial_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/screen_harness.dart' show setPhone, settleReal;
import '../catalog/catalog_fixture.dart';

class OwnedTestCatalog extends CatalogTrialState {
  OwnedTestCatalog(super.bundle, this.owned);
  final List<Exercise> owned;
  @override
  List<Exercise> get ownedExercises => owned;
}

class PickDocuments implements DocumentAccess {
  final picks = <DocumentFile?>[];
  @override
  Future<DocumentFile?> open({
    required int maxBytes,
    List<String> mimeTypes = const ['application/octet-stream'],
  }) async => picks.removeAt(0);
  @override
  Future<DocumentSave?> save(
    File source, {
    required String filename,
    required int maxBytes,
    String mimeType = 'application/octet-stream',
  }) => throw UnimplementedError();
}

void main() {
  setUpAll(preloadAppFonts);
  Future<(Directory, LocalStore)> openStore(WidgetTester tester) async {
    late Directory directory;
    late LocalStore store;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp(
        'alkion-normal-import-ui-',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${directory.path}/dev.animusstudio.alkion.dev'),
      );
      store = await openAlkionStore(profile);
    });
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });
    return (directory, store);
  }

  testWidgets(
    'picker cancellation uses current profile and creates no extra storage',
    (tester) async {
      final (_, store) = await openStore(tester);
      await tester.pumpWidget(
        wrapL10n(
          RepsImportScreen(
            database: store,
            documents: PickDocuments()..picks.add(null),
            onImport: (_, _, {required applySettings}) async =>
                fail('cancel imported data'),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('reps-import-choose')));
      await tester.pump();
      expect(
        RetiredHistoryWorkspace.containerFor(store.profile).existsSync(),
        isFalse,
      );
      expect(find.byKey(const Key('reps-import-confirm')), findsNothing);
      expect(find.textContaining('test profile'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'real preview stays unselected, invalid mapping blocks import, and shows provider filename',
    (tester) async {
      setPhone(tester, width: 320, textScale: 2);
      final (directory, store) = await openStore(tester);
      late File source, invalid;
      await tester.runAsync(() async {
        source = File('${directory.path}/source.complete');
        await source.writeAsBytes(
          await File(
            'test/fixtures/alkion/history-synthetic-v1.json',
          ).readAsBytes(),
        );
        invalid = File('${directory.path}/invalid.json');
        await invalid.writeAsString('{}');
      });
      final documents = PickDocuments()
        ..picks.addAll([
          DocumentFile(
            path: source.path,
            name: 'Chosen synthetic history.json',
            length: source.lengthSync(),
            sha256: 'unused',
          ),
          DocumentFile(
            path: invalid.path,
            name: 'Invalid mapping.json',
            length: 2,
            sha256: 'unused',
          ),
        ]);
      await tester.pumpWidget(
        wrapL10n(
          RepsImportScreen(
            database: store,
            documents: documents,
            onImport: (_, _, {required applySettings}) async =>
                fail('invalid mapping imported'),
          ),
        ),
      );
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('reps-import-choose'))),
      );
      await settleReal(tester, ticks: 10);
      expect(find.text('Chosen synthetic history.json'), findsOneWidget);
      expect(find.text('source.complete'), findsNothing);
      expect(
        find.text('3 workouts · 3 exercise blocks · 4 sets'),
        findsOneWidget,
      );
      final confirm = find.byKey(const Key('reps-import-confirm'));
      await tester.scrollUntilVisible(confirm, 120);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.scrollUntilVisible(
        find.byKey(const Key('reps-import-mapping')),
        -120,
      );
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('reps-import-mapping'))),
      );
      await settleReal(tester, ticks: 8);
      await tester.scrollUntilVisible(
        find.byKey(const Key('reps-import-error')),
        -120,
      );
      expect(find.byKey(const Key('reps-import-error')), findsOneWidget);
      await tester.scrollUntilVisible(confirm, 120);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      expect(find.textContaining('FormatException'), findsNothing);
      await tester.runAsync(() async {
        expect(await store.getAll('SELECT * FROM sessions'), isEmpty);
      });
      expect(
        RetiredHistoryWorkspace.containerFor(store.profile).existsSync(),
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleReal(tester, ticks: 8);
    },
  );

  testWidgets(
    'explicit history import writes current profile without switch controls',
    (tester) async {
      setPhone(tester, width: 412);
      final (_, store) = await openStore(tester);
      final profileId = store.profileId, root = store.profile.root.path;
      final file = File('test/fixtures/alkion/history-synthetic-v1.json');
      var imported = false;
      await tester.pumpWidget(
        wrapL10n(
          RepsImportScreen(
            database: store,
            documents: PickDocuments()
              ..picks.add(
                DocumentFile(
                  path: file.absolute.path,
                  name: 'Synthetic history.json',
                  length: file.lengthSync(),
                  sha256: 'unused',
                ),
              ),
            onImport: (preview, review, {required applySettings}) async {
              expect(applySettings, isFalse);
              final service = RepsImportService(store, profileId: profileId);
              expect(
                (await service.importPreview(preview)).status,
                ImportStatus.selected,
              );
              await service.selectMappings(preview, review);
              imported = true;
            },
          ),
        ),
      );
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('reps-import-choose'))),
      );
      await settleReal(tester, ticks: 8);
      expect(imported, isFalse);
      final confirm = find.byKey(const Key('reps-import-confirm'));
      await tester.scrollUntilVisible(confirm, 120);
      await tester.runAsync(() => tester.tap(confirm));
      await settleReal(tester, ticks: 8);
      expect(imported, isTrue);
      expect(find.byKey(const Key('reps-import-success')), findsOneWidget);
      expect(find.textContaining('workspace'), findsNothing);
      expect(find.textContaining('normal profile'), findsNothing);
      await tester.runAsync(() async {
        expect(await store.getAll('SELECT * FROM sessions'), hasLength(3));
        expect(await HistoryMappingStore(store).byExerciseId(), isNotEmpty);
      });
      expect(store.profileId, profileId);
      expect(store.profile.root.path, root);
      expect(
        RetiredHistoryWorkspace.containerFor(store.profile).existsSync(),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await settleReal(tester, ticks: 8);
    },
  );

  testWidgets(
    'full preview offers exported preferences as an unchecked option',
    (tester) async {
      setPhone(tester, width: 320, textScale: 2);
      final (_, store) = await openStore(tester);
      final file = File('test/fixtures/alkion/full-rich-synthetic-v1.json');
      bool? applied;
      await tester.pumpWidget(
        wrapL10n(
          RepsImportScreen(
            database: store,
            documents: PickDocuments()
              ..picks.add(
                DocumentFile(
                  path: file.absolute.path,
                  name: 'Synthetic full.json',
                  length: file.lengthSync(),
                  sha256: 'unused',
                ),
              ),
            onImport: (_, _, {required applySettings}) async =>
                applied = applySettings,
          ),
        ),
      );
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('reps-import-choose'))),
      );
      await settleReal(tester, ticks: 8);
      final settings = find.byKey(const Key('reps-import-settings'));
      await tester.scrollUntilVisible(settings, 160);
      expect(tester.widget<CheckboxListTile>(settings).value, isFalse);
      await tester.tap(settings);
      await tester.pump();
      expect(tester.widget<CheckboxListTile>(settings).value, isTrue);
      final confirm = find.byKey(const Key('reps-import-confirm'));
      await tester.scrollUntilVisible(confirm, 120);
      await tester.runAsync(() => tester.tap(confirm));
      await settleReal(tester, ticks: 8);
      expect(applied, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

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
