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
import '../support/l10n_harness.dart';

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
WorkoutWorkload _workload({int count = 1, bool current = false}) =>
    calculateWorkoutWorkload(
      mode: WorkoutWorkloadMode.saved,
      exercises: [
        WorkloadExerciseInput(
          muscleGroup: '',
          catalogBacked: true,
          resolution: CatalogMuscleResolution(
            profile: _profile(current ? 3 : 2),
            recordedProfile: _profile(2),
            currentAssessment: current,
          ),
          sets: [
            for (var i = 0; i < count; i++)
              WorkloadSetInput(
                physicalId: 'synthetic-$i',
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

void main() {
  setUpAll(preloadAppFonts);
  Future<void> open(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      wrapL10n(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showBodyWorkloadSheet(
              context,
              workload: () => _workload(),
              currentWorkload: () => _workload(count: 3, current: true),
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

  testWidgets(
    'recorded default, explicit current, roles, participation and legacy stay separate',
    (tester) async {
      await open(tester);
      CharacterBody art() =>
          tester.widget<CharacterBody>(find.byType(CharacterBody));
      expect(art().scores[WorkloadMuscle.glutes], .2);
      expect(
        tester
                .getSemantics(find.byKey(const Key('body-recorded')))
                .flagsCollection
                .isSelected ==
            ui.Tristate.isTrue,
        isTrue,
      );
      for (final (view, region) in [
        (1, WorkloadMuscle.glutes),
        (2, WorkloadMuscle.core),
        (3, WorkloadMuscle.forearms),
        (4, WorkloadMuscle.core),
        (5, WorkloadMuscle.glutes),
        (6, WorkloadMuscle.forearms),
        (7, WorkloadMuscle.chest),
      ]) {
        await tester.ensureVisible(find.byKey(ValueKey('body-view-$view')));
        await tester.tap(find.byKey(ValueKey('body-view-$view')));
        await tester.pumpAndSettle();
        expect(art().scores[region], .2);
        expect(
          art().scores[region == WorkloadMuscle.chest
              ? WorkloadMuscle.glutes
              : WorkloadMuscle.chest],
          0,
        );
      }
      await tester.ensureVisible(find.byKey(const Key('body-view-1')));
      await tester.tap(find.byKey(const Key('body-view-1')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('body-current')));
      await tester.tap(find.byKey(const Key('body-current')));
      await tester.pumpAndSettle();
      expect(art().scores[WorkloadMuscle.glutes], .4);
      expect(_workload().muscles[WorkloadMuscle.glutes]!.count, 1);
      await tester.ensureVisible(find.byKey(const Key('body-recorded')));
      await tester.tap(find.byKey(const Key('body-recorded')));
      await tester.pumpAndSettle();
      expect(art().scores[WorkloadMuscle.glutes], .2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final (kind, view) in [
    ('stretch_target', 4),
    ('conditioning_participation', 6),
  ]) {
    testWidgets(
      'async deep $kind selects its text view until an explicit choice',
      (tester) async {
        final source = ValueNotifier(
          WorkoutWorkload.loading(WorkoutWorkloadMode.saved),
        );
        addTearDown(source.dispose);
        await tester.pumpWidget(
          wrapL10n(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showBodyWorkloadSheet(
                  context,
                  workload: () => source.value,
                  changes: source,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('body-workload-read-state')),
          findsOneWidget,
        );
        source.value = _singleProfile(_onlyProfile('deep', kind));
        await tester.pumpAndSettle();
        expect(
          tester
                  .getSemantics(find.byKey(ValueKey('body-view-$view')))
                  .flagsCollection
                  .isSelected ==
              ui.Tristate.isTrue,
          isTrue,
        );
        expect(find.textContaining('Synthetic deep'), findsOneWidget);
        expect(find.textContaining('No supported surface'), findsOneWidget);
        await tester.ensureVisible(find.byKey(const Key('body-view-0')));
        await tester.tap(find.byKey(const Key('body-view-0')));
        await tester.pumpAndSettle();
        source.value = _singleProfile(_onlyProfile('deep', kind));
        await tester.pumpAndSettle();
        expect(
          tester
                  .getSemantics(find.byKey(const Key('body-view-0')))
                  .flagsCollection
                  .isSelected ==
              ui.Tristate.isTrue,
          isTrue,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'async legacy default and recorded/current automatic defaults follow selected snapshot',
    (tester) async {
      final source = ValueNotifier(
        WorkoutWorkload.loading(WorkoutWorkloadMode.saved),
      );
      addTearDown(source.dispose);
      await tester.pumpWidget(
        wrapL10n(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showBodyWorkloadSheet(
                context,
                workload: () => source.value,
                currentWorkload: () => _singleProfile(
                  _onlyProfile('deep', 'conditioning_participation'),
                ),
                changes: source,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      source.value = calculateWorkoutWorkload(
        mode: WorkoutWorkloadMode.saved,
        exercises: const [
          WorkloadExerciseInput(
            muscleGroup: 'chest',
            sets: [WorkloadSetInput(completed: true, isWarmup: false)],
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(
        tester
                .getSemantics(find.byKey(const Key('body-view-7')))
                .flagsCollection
                .isSelected ==
            ui.Tristate.isTrue,
        isTrue,
      );
      source.value = _singleProfile(_onlyProfile('deep', 'stretch_target'));
      await tester.pumpAndSettle();
      expect(
        tester
                .getSemantics(find.byKey(const Key('body-view-4')))
                .flagsCollection
                .isSelected ==
            ui.Tristate.isTrue,
        isTrue,
      );
      await tester.ensureVisible(find.byKey(const Key('body-current')));
      await tester.tap(find.byKey(const Key('body-current')));
      await tester.pumpAndSettle();
      expect(
        tester
                .getSemantics(find.byKey(const Key('body-view-6')))
                .flagsCollection
                .isSelected ==
            ui.Tristate.isTrue,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('a partially mapped anatomy node does not claim no surface', (
    tester,
  ) async {
    final workload = calculateWorkoutWorkload(
      mode: WorkoutWorkloadMode.saved,
      exercises: [
        for (final (index, mapped) in [true, false].indexed)
          WorkloadExerciseInput(
            muscleGroup: '',
            catalogBacked: true,
            resolution: CatalogMuscleResolution(
              profile: _onlyProfile('glutes', 'strength', mapped: mapped),
            ),
            sets: [
              WorkloadSetInput(
                physicalId: 'mixed-$index',
                completed: true,
                isWarmup: false,
              ),
            ],
          ),
      ],
    );
    await tester.pumpWidget(
      wrapL10n(
        SingleChildScrollView(child: BodyWorkloadCounts(workload: workload)),
      ),
    );
    expect(find.textContaining('Incomplete surface mapping'), findsOneWidget);
    expect(find.textContaining('No supported surface'), findsNothing);
    expect(find.text('Whole-workout coverage'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  for (final language in ['en', 'it', 'de', 'es']) {
    testWidgets(
      'catalog coverage and provenance wrap at 320dp 2x in $language',
      (tester) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await open(tester, locale: Locale(language));
        final l = lookupAppLocalizations(Locale(language));
        for (final key in [
          'body-recorded',
          'body-current',
          for (var i = 0; i < 8; i++) 'body-view-$i',
        ]) {
          final control = find.byKey(ValueKey(key));
          final text = find
              .descendant(of: control, matching: find.byType(Text))
              .first;
          final bounds = tester.getRect(control).inflate(.1);
          final label = tester.getRect(text);
          expect(
            bounds.contains(label.topLeft) &&
                bounds.contains(label.bottomRight),
            isTrue,
            reason: '$language $key must contain every line',
          );
          expect(tester.getSize(control).height, greaterThanOrEqualTo(48));
          expect(
            tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
            isFalse,
          );
        }
        expect(find.text('${l.bodyPartialProfiles}: 1'), findsOneWidget);
        expect(find.text('${l.bodyUnknownProfiles}: 1'), findsOneWidget);
        expect(find.text('${l.bodyLegacySets}: 1'), findsOneWidget);
        expect(find.textContaining(l.bodySideMeaning), findsOneWidget);
        expect(find.textContaining('deep'), findsOneWidget);
        expect(find.textContaining(l.bodyNoSurface), findsOneWidget);
        await tester.ensureVisible(find.text(l.bodyEvidenceDetails));
        await tester.tap(find.text(l.bodyEvidenceDetails));
        await tester.pumpAndSettle();
        expect(
          find.text('${l.bodySurfaceProjection}: alkion-surface-2'),
          findsOneWidget,
        );
        expect(find.textContaining(l.bodyHumanReview), findsOneWidget);
        expect(find.textContaining(l.bodyInference), findsNWidgets(7));
        expect(tester.takeException(), isNull);
        // Optional disposable visual proof, never writes to application storage.
        final capture = Platform.environment['ALKION_BODY_UI_CAPTURES'];
        if (capture != null) {
          for (final (stage, target) in [
            ('controls', find.byKey(const Key('body-recorded'))),
            ('artwork', find.byType(CharacterBody)),
            ('coverage', find.text('${l.bodyPartialProfiles}: 1')),
            (
              'evidence',
              find.text('${l.bodySurfaceProjection}: alkion-surface-2'),
            ),
          ]) {
            await tester.ensureVisible(target);
            await tester.pumpAndSettle();
            RenderObject? object = tester.renderObject(
              find.byType(BottomSheet),
            );
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
      },
    );
  }
}
