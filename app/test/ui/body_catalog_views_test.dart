import 'dart:io';
import 'dart:ui' as ui;
import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/data/body_workload.dart';
import 'package:alkion/data/catalog_execution_repository.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/ui/body_figure.dart';
import 'package:alkion/ui/character_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/app_fonts.dart';
import '../support/body_sheet_expect.dart';
import '../support/l10n_harness.dart';
import '../support/layout_expect.dart';

// Deliberately synthetic display fixture; parser/pin admission is tested separately.
CatalogMuscleProfile _profile(int revision) =>
    CatalogMuscleProfile.fromSnapshot({
      'sourceNamespace': 'synthetic',
      'sourceRevision': 'synthetic.$revision',
      'sourceBundleSha256': '$revision' * 64,
      'executionSha256': '0' * 64,
      'execution': {'variant_id': 'synthetic'},
      'profile': {
        'id': 'synthetic-profile',
        'revision': revision,
        'coverage': 'partial',
        'side_scope': 'unspecified',
        'human_review': {'status': 'pending'},
        'relationships': [
          for (final (node, kind, role) in [
            ('glutes', 'strength', 'primary'),
            ('core', 'strength', 'secondary'),
            ('forearms', 'strength', 'stabilizer'),
            ('deep', 'strength', 'stabilizer'),
            ('core', 'stretch_target', null),
            ('glutes', 'mobility_target', null),
            ('forearms', 'conditioning_participation', null),
          ])
            {
              'anatomy_node_id': node,
              'kind': kind,
              'role': role,
              'confidence': 'moderate',
              'evidence_basis': 'biomechanical_inference',
              'rationale': 'Synthetic mechanics and anatomy rationale.',
            },
        ],
      },
      'assessment': {'assessment_status': 'assessed'},
      'scopeDefinition': {'rationale': 'Synthetic predeclared scope.'},
      'anatomy': {
        'revision': 'synthetic-anatomy.1',
        'nodes': [
          for (final id in ['glutes', 'core', 'forearms', 'deep'])
            {
              'id': id,
              'names': {
                'en': 'Synthetic $id',
                'it': 'Sintetico $id',
                'de': 'Synthetisch $id',
                'es': 'Sintético $id',
              },
            },
        ],
      },
      'semanticMap': {
        'revision': 'synthetic-map.1',
        'regions': [
          for (final id in ['glutes', 'core', 'forearms']) {'id': id},
        ],
        'mappings': [
          for (final id in ['glutes', 'core', 'forearms'])
            {
              'anatomy_node_id': id,
              'render_region_ids': [id],
              'mapping_status': 'editorial_candidate',
            },
        ],
      },
      'claims': <dynamic>[],
      'sources': <dynamic>[],
    });
WorkoutWorkload _workload() => calculateWorkoutWorkload(
  mode: WorkoutWorkloadMode.saved,
  exercises: [
    WorkloadExerciseInput(
      muscleGroup: '',
      catalogBacked: true,
      resolution: CatalogMuscleResolution(
        profile: _profile(2),
        recordedProfile: _profile(2),
      ),
      sets: const [
        WorkloadSetInput(
          physicalId: 'synthetic-0',
          completed: true,
          isWarmup: false,
        ),
      ],
    ),
    const WorkloadExerciseInput(
      muscleGroup: '',
      catalogBacked: true,
      resolution: CatalogMuscleResolution(reason: 'synthetic_missing'),
      sets: [
        WorkloadSetInput(
          physicalId: 'unknown',
          completed: true,
          isWarmup: false,
        ),
      ],
    ),
    const WorkloadExerciseInput(
      muscleGroup: 'chest',
      sets: [
        WorkloadSetInput(
          physicalId: 'legacy',
          completed: true,
          isWarmup: false,
        ),
      ],
    ),
  ],
);

CatalogMuscleProfile _onlyProfile(
  String node,
  String kind, {
  bool mapped = true,
}) {
  final original = _profile(2);
  return CatalogMuscleProfile.fromSnapshot({
    ...original.snapshot,
    'profile': {
      ...original.profile,
      'relationships': [
        {
          'anatomy_node_id': node,
          'kind': kind,
          'role': kind == 'strength' ? 'primary' : null,
          'confidence': 'moderate',
          'evidence_basis': 'direct',
        },
      ],
    },
    if (!mapped)
      'semanticMap': {
        'revision': 'synthetic-map.2',
        'regions': <dynamic>[],
        'mappings': <dynamic>[],
      },
  });
}

WorkoutWorkload _singleProfile(CatalogMuscleProfile profile) =>
    calculateWorkoutWorkload(
      mode: WorkoutWorkloadMode.saved,
      exercises: [
        WorkloadExerciseInput(
          muscleGroup: '',
          catalogBacked: true,
          resolution: CatalogMuscleResolution(profile: profile),
          sets: const [
            WorkloadSetInput(
              physicalId: 'synthetic-one',
              completed: true,
              isWarmup: false,
            ),
          ],
        ),
      ],
    );

WorkoutWorkload _legacyOnly() => calculateWorkoutWorkload(
  mode: WorkoutWorkloadMode.saved,
  exercises: const [
    WorkloadExerciseInput(
      muscleGroup: 'chest',
      sets: [WorkloadSetInput(completed: true, isWarmup: false)],
    ),
  ],
);

void main() {
  setUpAll(preloadAppFonts);
  Future<void> open(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    WorkoutWorkload Function() workload = _workload,
    Listenable? changes,
  }) async {
    await tester.pumpWidget(
      wrapL10n(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showBodyWorkloadSheet(
              context,
              workload: workload,
              changes: changes,
            ),
            child: const Text('Open synthetic body'),
          ),
        ),
        locale: locale,
      ),
    );
    await tester.tap(find.text('Open synthetic body'));
    await tester.pumpAndSettle();
  }

  CharacterBody art(WidgetTester tester) =>
      tester.widget<CharacterBody>(find.byType(CharacterBody));
  String? count(WidgetTester tester, WorkloadMuscle muscle) => tester
      .widget<Text>(find.byKey(ValueKey('body-count-${muscle.name}')))
      .data;

  testWidgets('saved sheet shows the recorded strength view without choices', (
    tester,
  ) async {
    await open(tester);
    // All strength roles of the recorded profile; legacy chest is not mixed in.
    for (final region in [
      WorkloadMuscle.glutes,
      WorkloadMuscle.core,
      WorkloadMuscle.forearms,
    ]) {
      expect(art(tester).scores[region], .2);
      expect(count(tester, region), '1');
    }
    expect(art(tester).scores[WorkloadMuscle.chest], 0);
    expect(count(tester, WorkloadMuscle.chest), '0');
    for (final removed in [
      'body-recorded',
      'body-current',
      for (var i = 0; i < 8; i++) 'body-view-$i',
    ]) {
      expect(find.byKey(ValueKey(removed)), findsNothing);
    }
    expectWorkloadSheetSections(
      tester,
      lookupAppLocalizations(const Locale('en')),
      mode: 'Saved working sets',
    );
    await tester.pumpWidget(const SizedBox());
  });

  for (final (kind, region) in [
    ('strength', WorkloadMuscle.glutes),
    ('stretch_target', WorkloadMuscle.core),
    ('mobility_target', WorkloadMuscle.glutes),
    ('conditioning_participation', WorkloadMuscle.forearms),
  ]) {
    testWidgets('$kind-only work selects its own view automatically', (
      tester,
    ) async {
      await open(
        tester,
        workload: () => _singleProfile(_onlyProfile(region.name, kind)),
      );
      expect(art(tester).scores[region], .2);
      expect(count(tester, region), '1');
      for (final other in WorkloadMuscle.values.where((m) => m != region)) {
        expect(count(tester, other), '0');
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('legacy-only work selects the coarse legacy view', (
    tester,
  ) async {
    await open(tester, workload: _legacyOnly);
    expect(art(tester).scores[WorkloadMuscle.chest], .2);
    expect(count(tester, WorkloadMuscle.chest), '1');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('async loads keep following the automatic view', (tester) async {
    final source = ValueNotifier(
      WorkoutWorkload.loading(WorkoutWorkloadMode.saved),
    );
    addTearDown(source.dispose);
    await open(tester, workload: () => source.value, changes: source);
    // The counts placeholder is a static line skeleton that still settles.
    expect(find.byKey(const Key('body-workload-read-state')), findsOneWidget);
    expect(find.bySemanticsLabel('Loading workout counts…'), findsOneWidget);
    expect(find.byKey(const ValueKey('body-count-chest')), findsNothing);
    source.value = _legacyOnly();
    await tester.pumpAndSettle();
    expect(count(tester, WorkloadMuscle.chest), '1');
    source.value = _singleProfile(_onlyProfile('core', 'stretch_target'));
    await tester.pumpAndSettle();
    expect(count(tester, WorkloadMuscle.core), '1');
    expect(count(tester, WorkloadMuscle.chest), '0');
    source.value = _singleProfile(
      _onlyProfile('forearms', 'conditioning_participation'),
    );
    await tester.pumpAndSettle();
    expect(count(tester, WorkloadMuscle.forearms), '1');
    expect(count(tester, WorkloadMuscle.core), '0');
    // Deep-only participation still selects its kind: no region is claimed.
    source.value = _singleProfile(_onlyProfile('deep', 'stretch_target'));
    await tester.pumpAndSettle();
    for (final muscle in WorkloadMuscle.values) {
      expect(count(tester, muscle), '0');
    }
    await tester.pumpWidget(const SizedBox());
  });

  for (final language in ['en', 'it', 'de', 'es']) {
    testWidgets('trimmed sheet fits at 320dp 2x in $language', (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await open(tester, locale: Locale(language));
      final l = lookupAppLocalizations(Locale(language));
      expect(tester.takeException(), isNull);
      expectWorkloadSheetSections(tester, l, mode: l.bodySaved);
      expectNoSplitWords(tester, within: find.byType(BottomSheet));
      // Optional disposable visual proof, never writes to application storage.
      final capture = Platform.environment['ALKION_BODY_UI_CAPTURES'];
      if (capture != null) {
        for (final (stage, target) in [
          ('artwork', find.byType(CharacterBody)),
          ('counts', find.byKey(const Key('body-workload-counts'))),
        ]) {
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          RenderObject? object = tester.renderObject(find.byType(BottomSheet));
          while (object is! RenderRepaintBoundary) {
            object = object!.parent;
          }
          final boundary = object;
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(capture).create(recursive: true);
            await File(
              '$capture/body-$language-$stage.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
