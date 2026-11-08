import 'dart:convert';
import 'dart:io';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/catalog_ui/catalog_trial_scope.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/data/stats_repository.dart';
import 'package:alkion/data/volume_attribution.dart';
import 'package:alkion/main.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/live_weekly_volume.dart';
import 'package:alkion/shell/session_launcher.dart';
import 'package:alkion/util/calendar_keys.dart';
import 'package:alkion/ui/today_labels.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../catalog/catalog_fixture.dart';
import '../support/l10n_harness.dart';
import '../support/screen_harness.dart';

const _source =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Map<String, Object> _group(String key, String kind, String name) => {
  'key': key,
  'kind': kind,
  'names': {
    for (final locale in CatalogBrowse.locales) locale: '$name ($locale)',
  },
  'synonyms': {for (final locale in CatalogBrowse.locales) locale: <String>[]},
};

/// The synthetic catalog with a reviewed browse classification:
/// - variant 0: one target (biceps), forearms only secondary;
/// - variant 1: two targets (shoulders, triceps);
/// - variant 2: unresolved;
/// - the rest: activity only (mobility), so no target group.
CatalogBundle browseBundle() {
  final bytes = utf8.encode(jsonEncode(syntheticCatalog()));
  final plain = CatalogBundle.fromBytes(bytes);
  final variants = plain.variants.values.toList();
  Map<String, Object> member(
    int index,
    String status, {
    List<String> target = const [],
    List<String> secondary = const [],
    List<String> activity = const [],
  }) => {
    'variant_id': variants[index].id,
    'variant_revision': variants[index].revision,
    'status': status,
    'target_groups': target,
    'secondary_groups': secondary,
    'activity_groups': activity,
  };
  final browse = jsonEncode({
    'format': 'alkion-catalog-browse',
    'schema_version': 1,
    'classification_revision': 'synthetic.volume',
    'source_sha256': _source,
    'catalog_revision': plain.catalogRevision,
    'projection_sha256': plain.digest,
    'groups': [
      _group('biceps', 'muscle', 'Biceps'),
      _group('forearms', 'muscle', 'Forearms'),
      _group('shoulders', 'muscle', 'Shoulders'),
      _group('triceps', 'muscle', 'Triceps'),
      _group('glutes', 'muscle', 'Glutes'),
      _group('mobility', 'activity', 'Mobility'),
    ],
    'variants': [
      member(0, 'reviewed', target: ['biceps'], secondary: ['forearms']),
      member(1, 'reviewed', target: ['shoulders', 'triceps']),
      member(2, 'unresolved'),
      for (var i = 3; i < variants.length; i++)
        member(i, 'reviewed', activity: ['mobility']),
    ],
  });
  final bundle = CatalogBundle.fromBytes(
    bytes,
    browseBytes: utf8.encode(browse),
    browseSha256: catalogHash(browse),
    browseRevision: 'synthetic.volume',
    sourceSha256: _source,
  );
  expect(bundle.browse, isNotNull, reason: '${bundle.browseUnavailableReason}');
  return bundle;
}

String _metricValue(String metric) => switch (metric) {
  'reported_load' => '40',
  'repetitions' => '8',
  'duration' => '60',
  'distance' => '100',
  _ => throw StateError(metric),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CatalogBundle bundle;
  late List<CatalogVariant> variants;
  setUpAll(() {
    bundle = browseBundle();
    variants = bundle.variants.values.toList();
  });

  group('reviewedTargetGroups', () {
    test('one target; secondary groups never count', () {
      expect(reviewedTargetGroups(bundle.browse, variants[0].id), {'biceps'});
    });
    test('two targets', () {
      expect(reviewedTargetGroups(bundle.browse, variants[1].id), {
        'shoulders',
        'triceps',
      });
    });
    test('unreviewed, activity-only, unknown or missing give none', () {
      expect(reviewedTargetGroups(bundle.browse, variants[2].id), isEmpty);
      expect(reviewedTargetGroups(bundle.browse, variants[3].id), isEmpty);
      expect(reviewedTargetGroups(bundle.browse, 'not-a-variant'), isEmpty);
      expect(reviewedTargetGroups(bundle.browse, null), isEmpty);
      expect(reviewedTargetGroups(null, variants[0].id), isEmpty);
    });
    test('a passed variant wins over the exercise link', () {
      final targets = catalogVolumeTargets(
        bundle.browse,
        variantOf: (id) => id == 'linked' ? variants[1].id : null,
      );
      expect(targets('linked', null), {'shoulders', 'triceps'});
      expect(targets('linked', variants[0].id), {'biceps'});
      expect(targets('unlinked', null), isEmpty);
    });
  });

  testWidgets('labels: legacy names, catalog names, custom fallback', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      wrapL10n(
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
        locale: const Locale('it'),
      ),
    );
    // A catalog key matching a legacy key keeps the app's own name.
    expect(volumeGroupLabel(context, 'biceps', bundle.browse), 'Bicipiti');
    expect(volumeGroupLabel(context, 'glutes', bundle.browse), 'Glutes (it)');
    expect(volumeGroupLabel(context, 'glutes', null), 'Glutes');
    expect(volumeGroupLabel(context, 'custom', bundle.browse), 'Custom');
  });

  group('WeeklyMuscleVolume.attribute', () {
    test('legacy groups stay; catalog targets merge with them', () {
      final volume = WeeklyMuscleVolume(
        groups: [(muscle: 'biceps', sets: 3), (muscle: 'chest', sets: 2)],
        unknownSets: 9,
        unlabeled: [
          (exerciseId: 'curl', variantId: variants[0].id, sets: 2),
          (exerciseId: 'press', variantId: variants[1].id, sets: 4),
          (exerciseId: 'open', variantId: variants[2].id, sets: 1),
          (exerciseId: 'plain', variantId: null, sets: 2),
        ],
      );
      final attributed = volume.attribute(catalogVolumeTargets(bundle.browse));
      expect(attributed.groups.toSet(), {
        (muscle: 'biceps', sets: 5),
        (muscle: 'chest', sets: 2),
        (muscle: 'shoulders', sets: 4),
        (muscle: 'triceps', sets: 4),
      });
      // Unreviewed and unlinked sets: the unknown note, never a blank row.
      expect(attributed.unknownSets, 3);
      expect(attributed.groups.map((g) => g.muscle), isNot(contains('')));
      expect(attributed.unlabeled.map((r) => r.exerciseId), ['open', 'plain']);
    });
  });

  group('real store', () {
    late Directory dir;
    late FixtureDatabase db;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('alkion-volume-attr-');
      db = await FixtureDatabase.open(dir);
    });
    tearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });

    test('blank, missing and legacy labels; no blank row', () async {
      await seedExercise(db, 'legacy', 'Legacy press', muscle: 'chest');
      await seedExercise(db, 'blank', 'Blank label', muscle: '');
      await seedExercise(db, 'spaces', 'Spaces label', muscle: '  ');
      await seedSession(
        db,
        'week',
        date: DateTime.now(),
        label: 'Synthetic',
        sets: [
          ('legacy', 20, 8, 1, false),
          ('legacy', 20, 8, null, true),
          ('blank', 20, 8, 1, false),
          ('blank', 20, 8, 1, false),
          ('spaces', 20, 8, 1, false),
        ],
      );
      final raw = await StatsRepository.local(
        db,
      ).watchWeeklyVolumeByMuscle(weekStart: weekStart(DateTime.now())).first;
      expect(raw.groups, [(muscle: 'chest', sets: 1)]);
      expect(raw.unknownSets, 3);
      expect(raw.unlabeled.toSet(), {
        (exerciseId: 'blank', variantId: null, sets: 2),
        (exerciseId: 'spaces', variantId: null, sets: 1),
      });
      // The exercise's catalog link (here from the catalog state's map).
      final linked = raw.attribute(
        catalogVolumeTargets(
          bundle.browse,
          variantOf: (id) => id == 'blank' ? variants[1].id : null,
        ),
      );
      expect(linked.groups.toSet(), {
        (muscle: 'chest', sets: 1),
        (muscle: 'shoulders', sets: 2),
        (muscle: 'triceps', sets: 2),
      });
      expect(linked.unknownSets, 1);
    });
  });

  group('durable catalog workout', () {
    late Directory temporary;
    AlkionRuntime? runtime;
    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('alkion-volume-rt-');
    });
    tearDown(() async {
      await runtime?.close();
      runtime = null;
      await temporary.delete(recursive: true);
    });

    test('sets show under the same groups before and after finish', () async {
      runtime = await AlkionRuntime.open(
        Directory('${temporary.path}/dev.animusstudio.alkion.dev'),
        catalogBundle: bundle,
      );
      final state = runtime!.catalog!, store = runtime!.store;
      final controller = ActiveSessionController(
        draftStore: runtime!.sessions.draftStore,
      )..seedEmpty(name: 'Catalog volume', focus: '');
      runtime!.sessions.register(controller);
      for (final index in [0, 1, 2]) {
        final choice = CatalogChoice.variant(variants[index].id);
        final exercise = await state.materialize(
          choice,
          ExerciseRepository.local(store),
          locale: 'en',
        );
        // Catalog definitions carry no legacy group.
        expect(exercise.muscleGroup, '');
        await controller.addCatalogBlock(
          exercise,
          state.selectionFor(choice)!,
          sessionRepo: SessionRepository.local(store),
          allowRepeat: true,
        );
        final set = controller.draft.blocks.last.workingSets.single;
        for (final metric in set.catalog!.selection.profile.requiredMetrics) {
          controller.updateCatalogMetric(set, metric, _metricValue(metric));
        }
        controller.focusSet(set);
        controller.logLiveSet();
      }
      final week = weekStart(DateTime.now());
      final targets = catalogVolumeTargets(
        state.bundle.browse,
        variantOf: (id) => state.exercises[id]?.variantId,
      );
      final live = DraftVolume.of(
        controller.draft,
        weekStart: week,
        now: DateTime.now(),
        targets: targets,
      );
      const expected = {'biceps': 1, 'shoulders': 1, 'triceps': 1};
      expect(live.live, expected);
      expect(live.pending, isEmpty);
      expect(live.unknownLive, 1); // the unresolved choice

      await finishWorkout(
        controller,
        runtime!.sessions,
        repository: WorkoutRepository.local(store),
      );
      final stats = StatsRepository.local(store);
      final raw = await stats.watchWeeklyVolumeByMuscle(weekStart: week).first;
      // The saved tracking contexts carry each exercise's variant, so the
      // finished stat needs no in-memory link.
      for (final source in [
        targets,
        catalogVolumeTargets(state.bundle.browse),
      ]) {
        final finished = raw.attribute(source);
        expect({for (final g in finished.groups) g.muscle: g.sets}, expected);
        expect(finished.unknownSets, 1);
      }
    });
  });
}
