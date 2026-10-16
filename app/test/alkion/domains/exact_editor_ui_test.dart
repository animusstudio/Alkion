import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/ui/exercise_editor.dart';
import 'package:alkion/ui/editor_guard.dart';
import 'package:alkion/ui/add_weight_sheet.dart';
import 'package:alkion/data/bodyweight_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/units/unit_service.dart';
import 'local_screen_harness.dart';
import 'measurements_targets_test.dart' show sourceMeasurement;

void main() {
  testWidgets(
    'untouched real editor/unit save retains source bytes, exact kg, NULL defaults and inverted RIR',
    (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      addTearDown(() => harness.unmount(tester));
      final raw = Uint8List.fromList(
        utf8.encode(
          '{"base_weight_kg":"80.125000000000000001","unknown":"retained"}',
        ),
      );
      await harness.open(
        tester,
        seed: (store) async {
          await store.writeTransaction((tx) async {
            await tx.putArtifact(
              id: 'source',
              bytes: raw,
              digest: sha256.convert(raw).toString(),
              parserVersion: 'synthetic-fields/1',
              format: 'synthetic-fields',
              disposition: 'selected',
            );
            await tx.mapOrigin(
              SourceOrigin(
                profileId: store.profileId,
                namespace: 'synthetic-A',
                sourceKind: 'exercises',
                externalId: 'original-uuid',
              ),
              LocalRef(store.profileId, RecordKind.exercise, 'source-exercise'),
            );
            await tx.execute(
              'INSERT INTO source_revisions VALUES(?,?,?,?,?,?,?,?,?,?,?)',
              [
                store.profileId,
                'source-revision',
                'synthetic-A',
                'exercises',
                'original-uuid',
                'source',
                sha256.convert(raw).toString(),
                raw,
                'synthetic-fields/1',
                null,
                OperationInstant.now().text,
              ],
            );
            final ref = LocalRef(
              store.profileId,
              RecordKind.exercise,
              'source-exercise',
            );
            final fields = {
              'name': 'Bench',
              'muscle_group': 'chest',
              'compound': 1,
              'equip': 'Panatta',
              'base_weight_kg': '80.125000000000000001',
              'plate_step_kg': '2.5000',
              'default_working_sets': null,
              'default_rir_low': 9,
              'default_rir_high': -1,
              'created_at': '2026-10-13T08:09:10',
            };
            final revision = await tx.writeRevision(
              ref,
              localBytes(fields),
              layer: 'sourceSelection',
              sourceRevisionId: 'source-revision',
            );
            await tx.putRecord(
              ref,
              revision,
              fields,
              sourceRevisionId: 'source-revision',
            );
          });
        },
      );
      final guard = EditorGuard();
      var closed = 0;
      await tester.pumpWidget(
        harness.wrap(
          Scaffold(
            body: ExerciseEditor(
              id: 'source-exercise',
              guard: guard,
              onBack: () => closed++,
            ),
          ),
        ),
      );
      await settleUntilFound(
        tester,
        find.byType(TextField),
        where: 'exact source editor',
      );
      expect(guard.isDirty(), isFalse);
      await tester.runAsync(() async {
        harness.units.setUnit(Unit.lb);
        await harness.units.flushPersistence();
      });
      await settleReal(tester, ticks: 3);
      expect(guard.isDirty(), isFalse);
      final save = find.text('Save exercise');
      await scrollIntoView(tester, find.byType(ExerciseEditor), save);
      await tester.runAsync(() => tester.tap(save));
      for (var i = 0; i < 100 && closed == 0; i++) {
        await settleReal(tester, ticks: 1);
      }
      expect(closed, 1);
      final rows = await tester.runAsync(
        () => harness.database.getAll('SELECT * FROM exercises'),
      );
      expect(rows!.single['base_weight_kg'], '80.125000000000000001');
      expect(rows.single['plate_step_kg'], '2.5000');
      expect(rows.single['default_working_sets'], isNull);
      expect(rows.single['default_rir_low'], 9);
      expect(rows.single['default_rir_high'], -1);
      expect(rows.single['created_at'], '2026-10-13T08:09:10');
      expect(rows.single['source_revision_id'], 'source-revision');
      final originals = await tester.runAsync(
        () => harness.database.getAll('SELECT raw_bytes FROM source_artifacts'),
      );
      expect(originals!.single['raw_bytes'], raw);
      final revisions = await tester.runAsync(
        () => harness.database.getAll(
          'SELECT layer FROM record_revisions ORDER BY revision',
        ),
      );
      expect(revisions!.map((r) => r['layer']), [
        'sourceSelection',
        'authored',
      ]);
    },
  );
  testWidgets(
    'chosen duplicate measurement untouched lb Save keeps exact kg and alternative',
    (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      addTearDown(() => harness.unmount(tester));
      await harness.open(
        tester,
        seed: (store) async {
          await sourceMeasurement(store, 'chosen', '82.449999999999999999');
          await sourceMeasurement(store, 'other', '82.4500');
        },
      );
      final selected = (await tester.runAsync(
        () => BodyweightRepository.local(harness.database).onDate('2026-10-13'),
      ))!.first;
      await tester.pumpWidget(
        harness.wrap(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    showAddWeightSheet(context, selected: selected),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() => tester.tap(find.text('open')));
      await settleUntilFound(
        tester,
        find.text('Save entry'),
        where: 'selected weight sheet',
      );
      await tester.runAsync(() async {
        harness.units.setUnit(Unit.lb);
        await harness.units.flushPersistence();
      });
      await settleReal(tester, ticks: 5);
      await tester.runAsync(() => tester.tap(find.text('Save entry')));
      for (
        var i = 0;
        i < 100 && find.text('Save entry').evaluate().isNotEmpty;
        i++
      ) {
        await settleReal(tester, ticks: 1);
      }
      expect(find.text('Save entry'), findsNothing);
      final rows = await tester.runAsync(
        () => harness.database.getAll(
          'SELECT * FROM bodyweight_logs ORDER BY id',
        ),
      );
      expect(rows, hasLength(2));
      expect(rows!.first['weight_kg'], '82.449999999999999999');
      expect(rows.last['weight_kg'], '82.4500');
    },
  );
  test('day snapshot includes authored note changes', () {
    final draft = DayDraft(name: 'Day', slots: [], notes: 'Original');
    final before = daySnapshot(draft);
    draft.notes = 'Correction';
    expect(daySnapshot(draft), isNot(before));
  });
}
