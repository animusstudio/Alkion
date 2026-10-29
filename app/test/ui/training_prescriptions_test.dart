import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/ui/day_editor.dart';
import 'package:alkion/ui/editor_guard.dart';
import 'package:alkion/ui/exercise_editor.dart';
import 'package:alkion/ui/export_failure.dart';
import 'package:alkion/ui/split_tab.dart';
import 'package:alkion/ui/training_preferences_sheet.dart';
import 'package:alkion/util/prescription_format.dart';
import 'package:alkion/widgets/plan_form.dart';
import '../alkion/domains/local_screen_harness.dart';
import '../support/layout_expect.dart';
import '../alkion/domains/prepared_intent_retry_test.dart' show FaultDatabase;

Future<void> tap(WidgetTester tester, Finder host, String text) async {
  await scrollIntoView(tester, host, find.text(text));
  await tester.tap(find.text(text));
  await settleReal(tester, ticks: 4);
}

Finder input(String label) => find.descendant(
  of: find.ancestor(
    of: find.text(label.toUpperCase()),
    matching: find.byType(Field),
  ),
  matching: find.byType(TextField),
);

Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
  final dir = Platform.environment['ALKION_T2_CAPTURE_DIR'];
  if (dir == null) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final img = (await tester.runAsync(() => boundary.toImage()))!;
  final bytes = (await tester.runAsync(
    () => img.toByteData(format: ui.ImageByteFormat.png),
  ))!;
  await tester.runAsync(() async {
    await Directory(dir).create(recursive: true);
    await File('$dir/$name.png').writeAsBytes(bytes.buffer.asUint8List());
  });
  img.dispose();
}

class RefusingPreferences extends RealZoneDatabase {
  RefusingPreferences(super.database, super.zone);
  bool refuse = true;
  @override
  Future<T> writeTransaction<T>(
    Future<T> Function(LocalTransaction) callback, {
    StoreToken? expected,
  }) => refuse
      ? Future.error(const StoreException('synthetic_write_failure'))
      : super.writeTransaction(callback, expected: expected);
}

void main() {
  const ex = Exercise(
    id: 'e',
    name: 'Bench',
    slug: 'bench',
    muscleGroup: 'chest',
    compound: false,
    plateStepKg: 2.5,
    isTemplate: false,
  );
  test(
    'rep qualification uses whole pairs and never repairs evidence implicitly',
    () {
      expect(resolveRepPair(const Slot(exerciseId: 'e', position: 1), ex), (
        low: 8,
        high: 8,
      ));
      for (final pair in [(null, 12), (12, 8), (0, 8), (8, 100)]) {
        expect(qualifiedRepPair(pair.$1, pair.$2), isNull);
        expect(
          resolveRepPair(
            Slot(
              exerciseId: 'e',
              position: 1,
              repLow: pair.$1,
              repHigh: pair.$2,
            ),
            ex,
          ),
          isNull,
        );
      }
      expect(
        qualifiedRepPair(8, 8, rawFields: const {'target_rep_high': '8'}),
        isNull,
      );
      expect(formatPrescription(workSets: 3, reps: (low: 8, high: 8)), '3×8');
      expect(
        formatPrescription(
          workSets: 3,
          reps: (low: 8, high: 12),
          rirLow: 0,
          rirHigh: 1,
        ),
        '3×8–12 · RIR 0–1',
      );
    },
  );
  test(
    'compatibility refusal explains native backup in all supported languages',
    () {
      for (final code in ['en', 'de', 'es', 'it']) {
        final l = lookupAppLocalizations(Locale(code));
        for (final category in [
          'compat_export_rir_policy_requires_native_backup',
          'compat_export_day_activation_requires_native_backup',
        ]) {
          expect(
            compatibilityExportRefusalMessage(l, StoreException(category)),
            l.trainingCompatExportRefused,
          );
        }
        expect(
          compatibilityExportRefusalMessage(l, const StoreException('other')),
          isNull,
        );
      }
    },
  );

  testWidgets(
    'new exercise identity saves absent optional values; disclosure is clean',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      setPhone(tester, width: 412);
      final guard = EditorGuard();
      var closed = 0;
      await tester.pumpWidget(
        h.wrap(
          Scaffold(
            body: ExerciseEditor(
              id: null,
              onBack: () => closed++,
              guard: guard,
            ),
          ),
        ),
      );
      await settleReal(tester);
      expect(find.text('START WEIGHT'), findsNothing);
      await tap(tester, find.byType(ExerciseEditor), 'Advanced');
      expect(guard.isDirty(), isFalse);
      await tap(tester, find.byType(ExerciseEditor), 'Advanced');
      expect(guard.isDirty(), isFalse);
      await scrollIntoView(
        tester,
        find.byType(ExerciseEditor),
        find.text('EXERCISE NAME'),
      );
      await tester.enterText(input('Exercise name'), 'Simple');
      await tap(tester, find.byType(ExerciseEditor), 'Create exercise');
      expect(closed, 1);
      final saved = (await tester.runAsync(
        () => ExerciseRepository.local(h.database).all(),
      ))!.singleWhere((e) => e.name == 'Simple');
      expect([
        saved.baseWeightKg,
        saved.defaultRepLow,
        saved.defaultRepHigh,
        saved.defaultWorkingSets,
        saved.defaultWarmupSets,
        saved.defaultRirLow,
        saved.defaultRirHigh,
        saved.defaultRestSeconds,
      ], everyElement(isNull));
      await h.unmount(tester);
    },
  );

  testWidgets(
    'optional defaults clear independently and saved zero warmups survive disclosure',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      setPhone(tester, width: 412);
      await tester.runAsync(() async {
        final repo = ExerciseRepository.local(h.database);
        final old = (await repo.byId('ex3'))!;
        await repo.updateExercise(
          'ex3',
          ExerciseDraft(
            name: old.name,
            muscleGroup: old.muscleGroup,
            compound: old.compound,
            plateStepKg: old.plateStepKg,
            baseWeightKg: 20,
            defaultRepLow: 8,
            defaultRepHigh: 12,
            defaultWarmupSets: 0,
            defaultWorkingSets: 3,
            defaultRirLow: 1,
            defaultRirHigh: 2,
            localRevision: old.localRevision,
          ),
        );
      });
      final guard = EditorGuard();
      await tester.pumpWidget(
        h.wrap(
          Scaffold(
            body: ExerciseEditor(id: 'ex3', onBack: () {}, guard: guard),
          ),
        ),
      );
      await settleReal(tester);
      await tap(tester, find.byType(ExerciseEditor), 'Advanced');
      expect(guard.isDirty(), isFalse);
      await tap(tester, find.byType(ExerciseEditor), 'Remove Reps');
      expect(guard.isDirty(), isTrue);
      await tap(tester, find.byType(ExerciseEditor), 'Remove RIR target');
      await tap(tester, find.byType(ExerciseEditor), 'Save exercise');
      final saved = (await tester.runAsync(
        () => ExerciseRepository.local(h.database).byId('ex3'),
      ))!;
      expect(saved.defaultRepLow, isNull);
      expect(saved.defaultRepHigh, isNull);
      expect(saved.defaultRirLow, isNull);
      expect(saved.defaultWarmupSets, 0);
      expect(saved.defaultWorkingSets, 3);
      expect(saved.baseWeightKg, 20);
      await h.unmount(tester);
    },
  );

  testWidgets(
    'weekday reveal is clean; add change remove are explicit and null saves',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      setPhone(tester, width: 412);
      final guard = EditorGuard();
      await tester.pumpWidget(
        h.wrap(
          Scaffold(
            body: DayEditor(id: 'd1', onBack: () {}, guard: guard),
          ),
        ),
      );
      await settleReal(tester);
      await tap(tester, find.byType(DayEditor), 'Add weekday');
      expect(guard.isDirty(), isFalse);
      expect(
        tester
            .widgetList<Semantics>(find.byType(Semantics))
            .where((w) => w.properties.selected == true),
        isEmpty,
      );
      await tester.binding.handlePopRoute();
      await settleReal(tester);
      expect(guard.isDirty(), isFalse);
      await tap(tester, find.byType(DayEditor), 'Add weekday');
      await tester.tap(find.text('Tue'));
      await settleReal(tester);
      expect(guard.isDirty(), isTrue);
      expect(find.text('Change weekday'), findsOneWidget);
      await tap(tester, find.byType(DayEditor), 'Remove weekday');
      expect(guard.isDirty(), isFalse);
      await tap(tester, find.byType(DayEditor), 'Save changes');
      expect(
        (await tester.runAsync(
          () => DayTemplateRepository.local(h.database).byId('d1'),
        ))!.scheduledWeekday,
        isNull,
      );
      await h.unmount(tester);
    },
  );

  testWidgets(
    'preferences persist and an open day captures creation defaults',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      setPhone(tester, width: 412);
      await tester.runAsync(() async {
        await ExerciseRepository.local(h.database).createExercise(
          ExerciseDraft(
            name: 'Plain',
            muscleGroup: 'chest',
            compound: false,
            plateStepKg: 2.5,
          ),
        );
      });
      await tester.pumpWidget(
        h.wrap(Scaffold(body: DayEditor(id: null, onBack: () {}))),
      );
      await settleReal(tester);
      await tester.runAsync(() async {
        await h.settings.setRepEntry(RepEntry.range);
        await h.settings.setRirControls(RirControls.show);
      });
      await tap(tester, find.byType(DayEditor), 'Add exercise');
      await tester.tap(find.text('Plain'));
      await settleReal(tester);
      final slot = tester
          .widget<DaySlotRow>(find.byType(DaySlotRow))
          .slot
          .draft;
      expect(
        (slot.repLow, slot.repHigh, slot.rirPolicy),
        (8, 8, RirPolicy.off),
      );
      await h.unmount(tester);
      await tester.pumpWidget(
        h.wrap(Scaffold(body: TrainingPreferencesSheet(settings: h.settings))),
      );
      await settleReal(tester);
      await tester.tap(find.text('Fixed reps'));
      await settleReal(tester);
      await tester.runAsync(() async {
        final settings = SettingsService.local(h.database);
        await settings.load();
        expect(settings.repEntry, RepEntry.fixed);
        expect(settings.rirControls, RirControls.show);
        settings.dispose();
      });
      await h.unmount(tester);
    },
  );

  testWidgets(
    'inactive days retain edit access and all-disabled has direct enable',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      setPhone(tester, width: 412);
      await tester.runAsync(() async {
        final r = DayTemplateRepository.local(h.database);
        for (final day in await r.allDays()) {
          await r.commitPrepared(
            r.prepareSetActive(day.id, day.localRevision!, false),
          );
        }
      });
      String? edited;
      await tester.pumpWidget(
        h.wrap(Scaffold(body: SplitTab(onOpenEditor: (id) => edited = id))),
      );
      await settleReal(tester);
      expect(find.text('Inactive (2)'), findsOneWidget);
      expect(find.text('Enable'), findsNWidgets(2));
      await tester.tap(find.text('Pull'));
      expect(edited, 'd2');
      await tester.tap(find.text('Enable').first);
      await settleReal(tester, ticks: 12);
      final days = (await tester.runAsync(
        () => DayTemplateRepository.local(h.database).allDays(),
      ))!;
      expect(days.map((d) => d.id), ['d1', 'd2']);
      expect(days.where((d) => d.isActive).length, 1);
      expect(find.text('Enabled $longDay'), findsOneWidget);
      expect(find.text('Inactive (1)'), findsOneWidget);
      await h.unmount(tester);
    },
  );

  testWidgets(
    'RIR policy and fixed reps survive save/reopen; untouched target remains separate',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      setPhone(tester, width: 412);
      final guard = EditorGuard();
      await tester.pumpWidget(
        h.wrap(
          Scaffold(
            body: DayEditor(id: 'd2', onBack: () {}, guard: guard),
          ),
        ),
      );
      await settleReal(tester);
      await tap(tester, find.byType(DayEditor), 'Bench Press');
      await tap(tester, find.byType(DayEditor), 'Fixed reps');
      expect(guard.isDirty(), isTrue);
      await tap(tester, find.byType(DayEditor), 'Remove RIR target');
      await tap(tester, find.byType(DayEditor), 'Save changes');
      final saved = (await tester.runAsync(
        () => DayTemplateRepository.local(h.database).byId('d2'),
      ))!;
      expect(
        (
          saved.slots.single.repLow,
          saved.slots.single.repHigh,
          saved.slots.single.rirPolicy,
        ),
        (6, 6, RirPolicy.off),
      );
      await h.unmount(tester);
      await tester.pumpWidget(
        h.wrap(
          Scaffold(
            body: DayEditor(id: 'd2', onBack: () {}),
          ),
        ),
      );
      await settleReal(tester);
      expect(find.textContaining('3×6'), findsOneWidget);
      expect(find.textContaining('RIR 1'), findsNothing);
      await tap(tester, find.byType(DayEditor), 'Bench Press');
      await tap(tester, find.byType(DayEditor), 'More options');
      await tap(tester, find.byType(DayEditor), 'Use exercise default');
      expect(find.textContaining('RIR 1–2'), findsOneWidget);
      await tap(tester, find.byType(DayEditor), 'Remove RIR target');
      await tap(tester, find.byType(DayEditor), 'Add RIR target');
      await h.unmount(tester);
    },
  );

  testWidgets(
    'failed day status retries the exact prepared action and retains content',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      setPhone(tester, width: 412);
      final before = (await tester.runAsync(
        () => DayTemplateRepository.local(h.database).byId('d1'),
      ))!;
      final fault = FaultDatabase(h.database, beforeCommit: true);
      h.overrideDatabase = fault;
      await tester.pumpWidget(
        h.wrap(Scaffold(body: SplitTab(onOpenEditor: (_) {}))),
      );
      await settleReal(tester);
      await tester.tap(find.byIcon(Icons.more_horiz).first);
      await settleReal(tester);
      await tester.tap(find.text('Disable'));
      await settleReal(tester, ticks: 12);
      expect(find.text("Couldn't save"), findsOneWidget);
      expect(find.text('Disabled $longDay'), findsNothing);
      await tester.tap(find.text('OK'));
      await settleReal(tester);
      await tester.tap(find.byIcon(Icons.more_horiz).first);
      await settleReal(tester);
      await tester.tap(find.text('Retry'));
      await settleReal(tester, ticks: 12);
      expect(fault.actions.length, 2);
      expect(fault.actions[1].operationId, fault.actions[0].operationId);
      expect(fault.actions[1].bytes, fault.actions[0].bytes);
      final after = (await tester.runAsync(
        () => DayTemplateRepository.local(h.database).byId('d1'),
      ))!;
      expect(after.active, false);
      expect(after.position, before.position);
      expect(after.slots.map((s) => s.id), before.slots.map((s) => s.id));
      expect(
        after.slots.map((s) => (s.repLow, s.repHigh, s.rirLow, s.rirHigh)),
        before.slots.map((s) => (s.repLow, s.repHigh, s.rirLow, s.rirHigh)),
      );
      await h.unmount(tester);
    },
  );

  testWidgets(
    'preferences show owed save failure and retry it without losing the other choice',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      setPhone(tester, width: 412);
      late RefusingPreferences db;
      late SettingsService settings;
      await tester.runAsync(() async {
        db = RefusingPreferences(h.database, Zone.current);
        settings = SettingsService.local(db);
        await settings.load();
      });
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        h.wrap(Scaffold(body: TrainingPreferencesSheet(settings: settings))),
      );
      await settleReal(tester);
      await tester.tap(find.text('Rep range'));
      await settleReal(tester);
      expect(find.text("Couldn't save"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      db.refuse = false;
      await tester.tap(find.text('Retry'));
      await settleReal(tester, ticks: 12);
      await tester.runAsync(() async {
        final loaded = SettingsService.local(h.database);
        await loaded.load();
        expect(loaded.repEntry, RepEntry.range);
        expect(loaded.rirControls, RirControls.off);
        loaded.dispose();
      });
      expect(find.text("Couldn't save"), findsNothing);
      await h.unmount(tester);
    },
  );
  testWidgets(
    'unknown rep/RIR text remains unavailable and raw-preserved on unrelated save',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(
        tester,
        seed: (store) async {
          await seedLong(store);
          await store.writeTransaction((tx) async {
            final ref = LocalRef(
              store.profileId,
              RecordKind.exercise,
              'unknown',
            );
            final fields = <String, Object?>{
              'name': 'Unknown evidence',
              'muscle_group': 'chest',
              'compound': 0,
              'plate_step_kg': '2.50',
              'default_rep_low': 'unknown',
              'default_rep_high': 'unknown',
              'default_rir_low': 'unknown',
              'default_rir_high': 1,
            };
            final revision = await tx.writeRevision(
              ref,
              localBytes(fields),
              layer: 'sourceSelection',
            );
            await tx.putRecord(ref, revision, fields);
          });
        },
      );
      setPhone(tester, width: 412);
      final guard = EditorGuard();
      final unknown = (await tester.runAsync(
        () => ExerciseRepository.local(h.database).byId('unknown'),
      ))!;
      expect(unknown.defaultRepLow, isNull);
      expect(unknown.rawFields['default_rep_low'], 'unknown');
      expect(
        resolveRepPair(const Slot(exerciseId: 'unknown', position: 1), unknown),
        isNull,
      );
      final mapped = Slot.fromRow({
        'id': 'slot',
        'exercise_id': 'unknown',
        'target_rep_low': 'unknown',
        'target_rep_high': 12,
      });
      expect(mapped.repLow, isNull);
      expect(mapped.rawFields['target_rep_low'], 'unknown');
      await tester.pumpWidget(
        h.wrap(
          Scaffold(
            body: ExerciseEditor(id: 'unknown', onBack: () {}, guard: guard),
          ),
        ),
      );
      await settleReal(tester);
      await tap(tester, find.byType(ExerciseEditor), 'Advanced');
      expect(guard.isDirty(), isFalse);
      await tap(tester, find.byType(ExerciseEditor), 'Advanced');
      await scrollIntoView(
        tester,
        find.byType(ExerciseEditor),
        find.text('EXERCISE NAME'),
      );
      await tester.enterText(input('Exercise name'), 'Renamed unknown');
      await tap(tester, find.byType(ExerciseEditor), 'Save exercise');
      final after = (await tester.runAsync(
        () => ExerciseRepository.local(h.database).byId('unknown'),
      ))!;
      expect(after.rawFields['default_rep_low'], 'unknown');
      expect(after.rawFields['default_rep_high'], 'unknown');
      expect(after.rawFields['default_rir_low'], 'unknown');
      expect(after.rawFields['default_rir_high'], 1);
      await h.unmount(tester);
      final clearGuard = EditorGuard();
      await tester.pumpWidget(
        h.wrap(
          Scaffold(
            body: ExerciseEditor(
              id: 'unknown',
              onBack: () {},
              guard: clearGuard,
            ),
          ),
        ),
      );
      await settleReal(tester);
      await tap(tester, find.byType(ExerciseEditor), 'Advanced');
      expect(clearGuard.isDirty(), isFalse);
      await tap(tester, find.byType(ExerciseEditor), 'Remove Reps');
      expect(
        clearGuard.isDirty(),
        isTrue,
        reason:
            'both parsed bounds were null but raw evidence was explicitly cleared',
      );
      await tap(tester, find.byType(ExerciseEditor), 'Save exercise');
      final cleared = (await tester.runAsync(
        () => ExerciseRepository.local(h.database).byId('unknown'),
      ))!;
      expect(cleared.rawFields['default_rep_low'], isNull);
      expect(cleared.rawFields['default_rep_high'], isNull);
      expect(cleared.rawFields['default_rir_low'], 'unknown');
      await h.unmount(tester);
    },
  );
  testWidgets(
    'editor, preferences and retained-day surfaces hold across representative native conditions',
    (tester) async {
      final h = ScreenHarness();
      addTearDown(h.close);
      await h.open(tester);
      for (final condition in [
        (Brightness.dark, 320.0, 2.0),
        (Brightness.light, 412.0, 1.0),
      ]) {
        final (brightness, width, scale) = condition;
        setPhone(tester, width: width, textScale: scale);
        final key = GlobalKey();
        final stem = '${brightness.name}-${width.toInt()}-${scale}x';
        Future<void> mount(Widget child) async {
          await h.unmount(tester);
          await tester.pumpWidget(
            h.wrap(
              Theme(
                data: buildTheme(brightness, defaultWorkoutAccent),
                child: RepaintBoundary(
                  key: key,
                  child: Scaffold(body: child),
                ),
              ),
            ),
          );
          await settleReal(tester);
        }

        Future<void> check(String name) async {
          expect(tester.takeException(), isNull);
          expectNoSplitWords(tester);
          await capture(tester, key, '$name-$stem');
        }

        await mount(ExerciseEditor(id: 'ex3', onBack: () {}));
        await check('advanced-closed');
        await tap(tester, find.byType(ExerciseEditor), 'Advanced');
        await scrollIntoView(
          tester,
          find.byType(ExerciseEditor),
          find.text('REP ENTRY'),
        );
        await check('advanced-open');
        await mount(DayEditor(id: 'd2', onBack: () {}));
        await check('weekday-none');
        await tap(tester, find.byType(DayEditor), 'Add weekday');
        await tester.tap(find.text('Wed'));
        await settleReal(tester);
        await check('weekday-assigned');
        await tap(tester, find.byType(DayEditor), 'Bench Press');
        await tap(tester, find.byType(DayEditor), 'Fixed reps');
        await tap(tester, find.byType(DayEditor), 'Remove RIR target');
        await scrollIntoView(tester, find.byType(DayEditor), find.text('REPS'));
        await check('fixed-rir-off');
        await mount(TrainingPreferencesSheet(settings: h.settings));
        await check('preferences');
        await tester.runAsync(() async {
          final r = DayTemplateRepository.local(h.database);
          for (final day in await r.allDays()) {
            if (day.isActive) {
              await r.commitPrepared(
                r.prepareSetActive(day.id, day.localRevision!, false),
              );
            }
          }
        });
        await mount(SplitTab(onOpenEditor: (_) {}));
        await check('inactive-retained');
      }
      await h.unmount(tester);
    },
  );
  for (final code in ['en', 'de', 'es', 'it']) {
    for (final brightness in [Brightness.dark, Brightness.light]) {
      testWidgets(
        'prescription controls preserve layout/semantics $code ${brightness.name}',
        (tester) async {
          final h = ScreenHarness();
          addTearDown(h.close);
          await h.open(tester);
          final key = GlobalKey();
          final slot = DaySlotState(
            draft: SlotDraft(
              exerciseId: 'e',
              workSets: 3,
              repLow: 8,
              repHigh: 12,
              rirPolicy: RirPolicy.target,
              rirLow: 0,
              rirHigh: 1,
            ),
          );
          for (final width in [320.0, 412.0]) {
            setPhone(tester, width: width, textScale: 2);
            await tester.pumpWidget(
              h.wrap(
                Theme(
                  data: buildTheme(brightness, defaultWorkoutAccent),
                  child: RepaintBoundary(
                    key: key,
                    child: Scaffold(
                      body: SingleChildScrollView(
                        child: Builder(
                          builder: (context) => DaySlotRow(
                            index: 0,
                            reorderIndex: 0,
                            total: 1,
                            slot: slot,
                            exercise: ex,
                            tokens: context.tokens,
                            expanded: true,
                            onToggle: () {},
                            onRemove: () {},
                            onChanged: () {},
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                locale: Locale(code),
              ),
            );

            await settleReal(tester);
            expect(tester.takeException(), isNull);
            expectNoSplitWords(tester);
            if (code == 'en') {
              await capture(
                tester,
                key,
                'slot-${brightness.name}-${width.toInt()}-2x',
              );
            }
          }
          await h.unmount(tester);
        },
      );
    }
  }
}
