import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/ui/day_editor.dart';
import 'package:alkion/ui/exercise_editor.dart';
import 'package:alkion/ui/editor_guard.dart';
import 'package:alkion/widgets/plan_form.dart';
import 'package:alkion/store/local_store.dart';
import 'local_screen_harness.dart';
import 'prepared_intent_retry_test.dart' show FaultDatabase;
import 'prepared_ui_retry_test.dart' show observeDialog;

const exactKg = '80.125000000000000001';
final originalBytes = Uint8List.fromList(
  utf8.encode('{"kg":"$exactKg","unknown":"preserved"}'),
);
Future<void> seedEditors(LocalStore store) async {
  await store.writeTransaction((tx) async {
    await tx.putArtifact(
      id: 'source',
      bytes: originalBytes,
      digest: sha256.convert(originalBytes).toString(),
      parserVersion: 'synthetic/1',
      format: 'synthetic-fields',
      disposition: 'selected',
    );
    await tx.mapOrigin(
      SourceOrigin(
        profileId: store.profileId,
        namespace: 'synthetic-A',
        sourceKind: 'exercises',
        externalId: 'source-uuid',
      ),
      LocalRef(store.profileId, RecordKind.exercise, 'ex'),
    );
    await tx
        .execute('INSERT INTO source_revisions VALUES(?,?,?,?,?,?,?,?,?,?,?)', [
          store.profileId,
          'source-revision',
          'synthetic-A',
          'exercises',
          'source-uuid',
          'source',
          sha256.convert(originalBytes).toString(),
          originalBytes,
          'synthetic/1',
          null,
          OperationInstant.now().text,
        ]);
    final ref = LocalRef(store.profileId, RecordKind.exercise, 'ex');
    final fields = {
      'name': 'Bench',
      'muscle_group': 'chest',
      'compound': 1,
      'equip': 'barbell',
      'base_weight_kg': exactKg,
      'plate_step_kg': '2.5000',
      'default_working_sets': null,
      'default_rir_low': 9,
      'default_rir_high': -1,
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
  await seedExercise(store, 'other', 'Row');
  final action = prepareDomain(
    store,
    RecordKind.trainingDay,
    LocalActionKind.planCreate,
    'day',
    0,
    {
      'fields': {'name': 'Push', 'scheduled_weekday': 0},
      'slots': [
        for (var i = 0; i < 2; i++)
          {
            'id': 'day-i$i',
            'base': 0,
            'position': i + 1,
            'fields': {
              'exercise_id': i == 0 ? 'ex' : 'other',
              'target_working_sets': null,
              'target_rir_low': 9,
              'target_rir_high': -1,
            },
          },
      ],
    },
  );
  await DayTemplateRepository.local(store).commitPrepared(action);
}

// Diagnostics retain complete owned synthetic file evidence; production recovery is unchanged.
class EditorFaultDatabase extends FaultDatabase {
  int completed = 0;
  EditorFaultDatabase(
    super.store, {
    super.beforeCommit = false,
    super.afterCommit = false,
    super.closeRecovery = false,
    super.gate,
  });
  void snapshot(String phase) {
    final paths = {
      'main': store.path,
      'wal': '${store.path}-wal',
      'shm': '${store.path}-shm',
      'preserved': '${store.path}.test-preserved',
      'known_good': '${store.path}.known-good-test',
    };
    final files = <String, Object?>{};
    for (final entry in paths.entries) {
      final file = File(entry.value);
      if (!file.existsSync()) {
        files[entry.key] = null;
        continue;
      }
      final bytes = file.readAsBytesSync();
      files[entry.key] = {
        'path': file.absolute.path,
        'length': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
        if (bytes.length >= 100 && entry.key != 'wal' && entry.key != 'shm')
          'header_user_version': ByteData.sublistView(bytes).getUint32(60),
      };
    }
    debugPrintSynchronously(
      'EDITOR_FILE_DIAGNOSTIC ${jsonEncode({'phase': phase, 'admission': store.admission.name, 'pool_epoch': store.poolEpoch, 'files': files})}',
    );
  }

  @override
  Future<LocalActionResult> apply(
    LocalAction action,
    Future<Object?> Function(LocalTransaction) mutate, {
    StoreToken? expected,
  }) async {
    snapshot('before_apply');
    final subscription = store.recoveryEvents.listen(
      (phase) => snapshot(phase.name),
    );
    try {
      return await super.apply(action, mutate, expected: expected);
    } finally {
      snapshot('apply_returned');
      await subscription.cancel();
      completed++;
    }
  }

  @override
  Future<void> restorePreserved() async {
    snapshot('before_repair');
    expect(store.admission, StoreAdmission.closed);
    expect(File('${store.path}-wal').existsSync(), isFalse);
    expect(File('${store.path}-shm').existsSync(), isFalse);
    await File('${store.path}.known-good-test').copy(store.path);
    snapshot('after_repair');
  }
}

Finder input(String label) => find.descendant(
  of: find.ancestor(
    of: find.text(label.toUpperCase()),
    matching: find.byType(Field),
  ),
  matching: find.byType(TextField),
);
Future<void> until(
  WidgetTester tester,
  bool Function() condition,
  String phase,
) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await settleReal(tester, ticks: 1);
  }
  expect(condition(), isTrue, reason: phase);
}

Future<void> tapVisible(
  WidgetTester tester,
  Finder editor,
  Finder target, {
  bool blocked = false,
}) async {
  await scrollIntoView(tester, editor, target);
  await tester.tap(target.first, warnIfMissed: !blocked);
  await tester.pump();
}

Future<Map<String, Object?>> inventory(
  WidgetTester tester,
  ScreenHarness harness,
) async => (await tester.runAsync(harness.database.inventory))!;
void main() {
  for (final day in [false, true]) {
    for (final mode in ['deferred', 'uncertain', 'closed', 'delayed']) {
      testWidgets(
        '${day ? 'Day' : 'Exercise'} editor freezes focused and dependent controls through $mode save, retries exact intent',
        (tester) async {
          final harness = ScreenHarness();
          addTearDown(harness.close);
          addTearDown(() => harness.unmount(tester));
          await harness.open(
            tester,
            withWorkoutHistory: !day,
            seed: seedEditors,
          );
          setPhone(tester, width: 412);
          final before = await inventory(tester, harness);
          final gate = mode == 'delayed'
              ? (await tester.runAsync(() async => Completer<void>()))!
              : null;
          final fault = EditorFaultDatabase(
            harness.database,
            beforeCommit: mode == 'deferred',
            afterCommit: mode == 'uncertain',
            closeRecovery: mode == 'closed',
            gate: gate,
          );
          harness.overrideDatabase = fault;
          await tester.runAsync(
            () => harness.database.backupTo(
              '${harness.database.path}.known-good-test',
            ),
          );
          final guard = EditorGuard();
          var closed = 0;
          final editor = day
              ? find.byType(DayEditor)
              : find.byType(ExerciseEditor);
          await tester.pumpWidget(
            harness.wrap(
              Scaffold(
                body: day
                    ? DayEditor(id: 'day', guard: guard, onBack: () => closed++)
                    : ExerciseEditor(
                        id: 'ex',
                        guard: guard,
                        onBack: () => closed++,
                      ),
              ),
            ),
          );
          await settleUntilFound(
            tester,
            input(day ? 'Day name' : 'Exercise name'),
            where: 'editor loaded',
          );
          final name = input(day ? 'Day name' : 'Exercise name');
          await tester.enterText(name, 'Requested');
          expect(tester.testTextInput.hasAnyClients, isTrue);
          final save = find.text(day ? 'Save changes' : 'Save exercise');
          await scrollIntoView(tester, editor, save);
          expect(
            tester.testTextInput.hasAnyClients,
            isTrue,
            reason: 'input remains focused until first Save',
          );
          await tester.tap(save);
          await tester.pump();
          await until(
            tester,
            () => fault.actions.isNotEmpty,
            'prepared apply entered',
          );
          final original = fault.actions.single;
          expect(original.baseLocalRevision, 1);
          expect(original.target.id, day ? 'day' : 'ex');
          final frozenBytes = Uint8List.fromList(original.bytes);
          if (mode != 'delayed') {
            await observeDialog(tester, harness.database);
            await until(
              tester,
              () => fault.completed == fault.actions.length,
              'owned apply/fault lifecycle returned',
            );
            expect(closed, 0);
            if (mode != 'uncertain' && mode != 'closed') {
              expect(await inventory(tester, harness), before);
            }
            await tester.tap(find.text('OK'));
            await until(
              tester,
              () => find.text('OK').evaluate().isEmpty,
              'error dialog fully dismissed',
            );
            expect(
              guard.isDirty(),
              isTrue,
              reason:
                  'failed pending request requires explicit navigation/discard',
            );
          }
          // No keyboard client survives Save. A real pointer cannot reopen it.
          expect(tester.testTextInput.hasAnyClients, isFalse);
          await tapVisible(tester, editor, name, blocked: true);
          expect(tester.testTextInput.hasAnyClients, isFalse);
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(text: 'Later keyboard edit'),
          );
          await tester.pump();
          expect(tester.widget<TextField>(name).controller!.text, 'Requested');
          final chip = day ? find.text('Tue') : find.text('Back');
          await tapVisible(tester, editor, chip, blocked: true);
          if (day) {
            final selector = tester.widget<ChipSelect<int>>(
              find.byType(ChipSelect<int>),
            );
            expect(selector.selected, 0);
            final rows = tester
                .widgetList<DaySlotRow>(find.byType(DaySlotRow))
                .toList();
            expect(rows.map((r) => r.slot.exerciseId), ['ex', 'other']);
            expect(rows.every((r) => r.readOnly), isTrue);
            // A stale callback from an already-running drag cannot change order.
            tester
                .widget<ReorderableListView>(find.byType(ReorderableListView))
                .onReorderItem!(0, 1);
            rows.first.onChanged();
            rows.first.onRemove();
            await tester.pump();
            expect(
              tester
                  .widgetList<DaySlotRow>(find.byType(DaySlotRow))
                  .map((r) => r.slot.exerciseId),
              ['ex', 'other'],
            );
            await tapVisible(tester, editor, find.text('Bench'), blocked: true);
          } else {
            final selector = tester.widget<ChipSelect<String>>(
              find.byType(ChipSelect<String>),
            );
            expect(selector.selected, 'chest');
            final step = find.descendant(
              of: find.ancestor(
                of: find.text('START WEIGHT'),
                matching: find.byType(Field),
              ),
              matching: find.byKey(const Key('stepper-inc')),
            );
            await tapVisible(tester, editor, step, blocked: true);
          }
          // Cross-delete cannot replace the pending Save request or open confirmation.
          await tapVisible(
            tester,
            editor,
            find.text(day ? 'Delete day' : 'Delete exercise'),
          );
          expect(find.text('Delete'), findsNothing);
          expect(fault.actions, hasLength(1));
          if (mode == 'delayed') {
            await tester.runAsync(() async {
              gate!.complete();
            });
          } else {
            if (mode == 'closed') {
              await tapVisible(tester, editor, save);
              await observeDialog(tester, harness.database);
              await until(
                tester,
                () => fault.completed == fault.actions.length,
                'owned apply/fault lifecycle returned',
              );
              expect(fault.actions, hasLength(1));
              expect(closed, 0);
              await tester.tap(find.text('OK'));
              await until(
                tester,
                () => find.text('OK').evaluate().isEmpty,
                'error dialog fully dismissed',
              );
              await tester.runAsync(fault.restorePreserved);
            }
            await tapVisible(tester, editor, save);
          }
          await until(
            tester,
            () => closed == 1,
            'reconciled Save closes own route',
          );
          expect(fault.actions.map((a) => a.operationId).toSet(), {
            original.operationId,
          });
          expect(fault.actions.map((a) => a.hash).toSet(), {original.hash});
          expect(
            fault.actions.every(
              (a) => a.bytes.toString() == frozenBytes.toString(),
            ),
            isTrue,
          );
          final after = await inventory(tester, harness);
          final operations = after['operations'] as List;
          expect(operations.length, (before['operations'] as List).length + 1);
          final operation = operations.last as Map;
          expect(operation['operation_id'], original.operationId);
          expect(operation['input_bytes'], frozenBytes);
          final exercises = after['exercises'] as List;
          final ex = exercises.cast<Map>().firstWhere((r) => r['id'] == 'ex');
          expect(ex['base_weight_kg'], exactKg);
          expect(ex['plate_step_kg'], '2.5000');
          expect(ex['default_working_sets'], isNull);
          expect(ex['default_rir_low'], 9);
          expect(ex['default_rir_high'], -1);
          expect(ex['muscle_group'], 'chest');
          expect(after['source_artifacts'], before['source_artifacts']);
          expect(after['source_revisions'], before['source_revisions']);
          if (day) {
            final saved = (after['day_templates'] as List).cast<Map>().single;
            expect(saved['name'], 'Requested');
            expect(saved['scheduled_weekday'], 0);
            expect(saved['revision'], 2);
            final slots = (after['day_template_items'] as List).cast<Map>();
            expect(slots.map((r) => r['id']), ['day-i0', 'day-i1']);
            expect(slots.first['target_working_sets'], isNull);
            expect(slots.first['target_rir_low'], 9);
            expect(slots.first['target_rir_high'], -1);
            expect(after['exercises'], before['exercises']);
          } else {
            expect(ex['name'], 'Requested');
            expect(ex['revision'], 2);
            expect(after['day_templates'], before['day_templates']);
            expect(after['day_template_items'], before['day_template_items']);
          }
          final stable = await inventory(tester, harness);
          expect(
            stable,
            after,
            reason: 'full inventory stable after one saved action',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final mode in ['deferred', 'closed']) {
    testWidgets(
      'Day delete visibly handles $mode fault and recovers same prepared tombstone',
      (tester) async {
        final harness = ScreenHarness();
        addTearDown(harness.close);
        addTearDown(() => harness.unmount(tester));
        await harness.open(tester, seed: seedEditors);
        setPhone(tester, width: 412);
        final before = await inventory(tester, harness);
        final fault = EditorFaultDatabase(
          harness.database,
          beforeCommit: mode == 'deferred',
          closeRecovery: mode == 'closed',
        );
        harness.overrideDatabase = fault;
        await tester.runAsync(
          () => harness.database.backupTo(
            '${harness.database.path}.known-good-test',
          ),
        );
        var closed = 0;
        final guard = EditorGuard();
        final editor = find.byType(DayEditor);
        await tester.pumpWidget(
          harness.wrap(
            Scaffold(
              body: DayEditor(id: 'day', guard: guard, onBack: () => closed++),
            ),
          ),
        );
        await settleUntilFound(
          tester,
          input('Day name'),
          where: 'delete editor',
        );
        final remove = find.text('Delete day');
        await tapVisible(tester, editor, remove);
        await settleUntilFound(
          tester,
          find.text('Delete'),
          where: 'explicit delete confirmation',
        );
        await tester.tap(find.text('Delete'));
        await observeDialog(tester, harness.database);
        await until(
          tester,
          () => fault.completed == fault.actions.length,
          'owned apply/fault lifecycle returned',
        );
        expect(closed, 0);
        expect(fault.actions, hasLength(1));
        final original = fault.actions.single;
        expect(original.target.id, 'day');
        expect(original.baseLocalRevision, 1);
        expect(tester.takeException(), isNull);
        if (mode == 'deferred') {
          expect(await inventory(tester, harness), before);
        }
        await tester.tap(find.text('OK'));
        await until(
          tester,
          () => find.text('OK').evaluate().isEmpty,
          'error dialog fully dismissed',
        );
        expect(guard.isDirty(), isTrue);
        // Cross-save is unavailable while a delete request is owed.
        await tapVisible(
          tester,
          editor,
          find.text('Save changes'),
          blocked: true,
        );
        expect(fault.actions, hasLength(1));
        if (mode == 'closed') {
          await tapVisible(tester, editor, remove);
          await observeDialog(tester, harness.database);
          await until(
            tester,
            () => fault.completed == fault.actions.length,
            'owned apply/fault lifecycle returned',
          );
          expect(closed, 0);
          expect(fault.actions, hasLength(1));
          await tester.tap(find.text('OK'));
          await until(
            tester,
            () => find.text('OK').evaluate().isEmpty,
            'error dialog fully dismissed',
          );
          await tester.runAsync(fault.restorePreserved);
        }
        await tapVisible(tester, editor, remove);
        await until(tester, () => closed == 1, 'delete recovery succeeds');
        expect(fault.actions.map((a) => a.operationId).toSet(), {
          original.operationId,
        });
        expect(fault.actions.map((a) => a.hash).toSet(), {original.hash});
        final after = await inventory(tester, harness);
        final day = (after['day_templates'] as List).cast<Map>().single;
        expect(day['id'], 'day');
        expect(day['revision'], 2);
        expect(day['deleted'], 1);
        final slots = (after['day_template_items'] as List).cast<Map>();
        expect(slots.map((r) => r['id']), ['day-i0', 'day-i1']);
        expect(
          slots.every((r) => r['deleted'] == 1 && r['revision'] == 2),
          isTrue,
        );
        expect(after['exercises'], before['exercises']);
        expect(after['source_artifacts'], before['source_artifacts']);
        final operations = after['operations'] as List;
        expect(operations.length, (before['operations'] as List).length + 1);
        expect((operations.last as Map)['operation_id'], original.operationId);
        expect((operations.last as Map)['input_bytes'], original.bytes);
        expect(await inventory(tester, harness), after);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final day in [false, true]) {
    testWidgets(
      '${day ? 'Day' : 'Exercise'} focused stepper commits before immediate Save and freezes failed requested value',
      (tester) async {
        final harness = ScreenHarness();
        addTearDown(harness.close);
        addTearDown(() => harness.unmount(tester));
        await harness.open(tester, withWorkoutHistory: !day, seed: seedEditors);
        setPhone(tester, width: 412);
        final fault = EditorFaultDatabase(harness.database, beforeCommit: true);
        harness.overrideDatabase = fault;
        await tester.runAsync(
          () => harness.database.backupTo(
            '${harness.database.path}.known-good-test',
          ),
        );
        var closed = 0;
        final editor = day
            ? find.byType(DayEditor)
            : find.byType(ExerciseEditor);
        await tester.pumpWidget(
          harness.wrap(
            Scaffold(
              body: day
                  ? DayEditor(id: 'day', onBack: () => closed++)
                  : ExerciseEditor(id: 'ex', onBack: () => closed++),
            ),
          ),
        );
        await settleUntilFound(
          tester,
          input(day ? 'Day name' : 'Exercise name'),
          where: 'stepper editor',
        );
        if (day) {
          await tapVisible(tester, editor, find.text('Bench'));
        }
        final field = find.ancestor(
          of: find.text((day ? 'Working sets' : 'Rest').toUpperCase()),
          matching: find.byType(Field),
        );
        final value = find.descendant(
          of: field,
          matching: find.text(day ? '3' : 'Default'),
        );
        await tapVisible(tester, editor, value);
        await tester.enterText(
          find.descendant(of: field, matching: find.byType(TextField)),
          day ? '5' : '75',
        );
        expect(tester.testTextInput.hasAnyClients, isTrue);
        final save = find.text(day ? 'Save changes' : 'Save exercise');
        await scrollIntoView(tester, editor, save);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        await tester.tap(save);
        await observeDialog(tester, harness.database);
        await until(
          tester,
          () => fault.completed == fault.actions.length,
          'owned apply/fault lifecycle returned',
        );
        expect(fault.actions, hasLength(1));
        final original = fault.actions.single;
        expect(closed, 0);
        await tester.tap(find.text('OK'));
        await until(
          tester,
          () => find.text('OK').evaluate().isEmpty,
          'error dialog fully dismissed',
        );
        expect(tester.testTextInput.hasAnyClients, isFalse);
        final frozen = find.descendant(
          of: field,
          matching: find.text(day ? '5' : '75s'),
        );
        await tapVisible(tester, editor, frozen, blocked: true);
        expect(tester.testTextInput.hasAnyClients, isFalse);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(text: '99'),
        );
        await tester.pump();
        expect(frozen, findsOneWidget);
        await tapVisible(tester, editor, save);
        await until(tester, () => closed == 1, 'stepper save reconciled');
        expect(fault.actions.map((a) => a.hash).toSet(), {original.hash});
        final after = await inventory(tester, harness);
        final ex = (after['exercises'] as List).cast<Map>().firstWhere(
          (r) => r['id'] == 'ex',
        );
        expect(ex['base_weight_kg'], exactKg);
        expect(ex['default_rir_low'], 9);
        expect(ex['default_rir_high'], -1);
        if (day) {
          final slot = (after['day_template_items'] as List).cast<Map>().first;
          expect(slot['target_working_sets'], 5);
          expect(slot['target_rir_low'], 9);
          expect(slot['target_rir_high'], -1);
        } else {
          expect(ex['default_rest_seconds'], 75);
          expect(ex['default_working_sets'], isNull);
        }
      },
    );
  }
}
