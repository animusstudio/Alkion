import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'resume_history_test.dart' show archiveOwned, checkpoint;
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';

void main() {
  test(
    'actual deferred COMMIT failure preserves prior draft recovery and timer; original immutable finish retry commits once',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-workflow-commit-',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      var store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: prescriptionSchemaRegistry(),
      );
      try {
        await ExerciseRepository.local(store).commitPrepared(
          prepareDomain(
            store,
            RecordKind.exercise,
            LocalActionKind.definitionCreate,
            'exercise',
            0,
            {
              'fields': {
                'name': 'Synthetic',
                'plate_step_kg': '2.50',
                'is_template': 0,
              },
            },
          ),
        );
        await commitWorkflowState(
          store,
          PreparedWorkflowState(
            store,
            {'draftId': 'draft', 'planned': 7},
            {'draftId': 'draft', 'restTotal': 120},
            0,
          ),
        );
        await store.writeTransaction(
          (tx) => tx.putLocalState(
            LocalStateKind.finishedRecovery,
            'last',
            localBytes({'good': 'prior'}),
            expectedRevision: 0,
          ),
        );
        await checkpoint(store, root, 'prior-good');
        final before = await store.inventory();
        final repo = WorkoutRepository.local(store);
        final intent = repo.prepareFinish(
          write: const SessionWrite(
            id: 'workout',
            dateIso: '2026-10-15',
            sets: [
              SetWrite(
                id: 'set',
                exerciseId: 'exercise',
                setNumber: 1,
                weightKg: '80.12500000000000100',
                reps: 5,
                rir: null,
                isWarmup: false,
              ),
            ],
          ),
          baseRevision: 0,
          setBases: {},
          recovery: {'new': 'recovery'},
          draftRevision: 1,
          draftId: 'draft',
          dependencies: [
            OperationDependency(
              store.profileId,
              GrantFamily.workouts,
              'dependency',
            ),
          ],
        );
        final frozen = base64Encode(intent.action.bytes),
            hash = intent.action.hash;
        var statementsCompleted = false;
        await expectLater(
          store.apply(intent.action, (tx) async {
            final result = await repo.executePreparedInTransaction(tx, intent);
            statementsCompleted = true;
            return result;
          }, expected: intent.token),
          throwsA(
            isA<sqlite.SqliteException>().having(
              (e) => e.extendedResultCode,
              'deferred FK COMMIT',
              787,
            ),
          ),
        );
        expect(
          statementsCompleted,
          isTrue,
          reason: 'COMMIT must fail after all production SQL succeeds',
        );
        expect(store.admission, StoreAdmission.open);
        expect(await store.inventory(), before);
        await checkpoint(store, root, 'failed-commit-prior-retained');
        expect(
          (await store.get(
            'SELECT * FROM local_state WHERE state_kind=\'finishedRecovery\'',
          ))['payload_bytes'],
          localBytes({'good': 'prior'}),
        );
        await ExerciseRepository.local(store).commitPrepared(
          prepareDomain(
            store,
            RecordKind.exercise,
            LocalActionKind.definitionCreate,
            'dependency-exercise',
            0,
            {
              'fields': {'name': 'Dependency', 'is_template': 0},
            },
            operationId: 'dependency',
          ),
        );
        expect(base64Encode(intent.action.bytes), frozen);
        expect(intent.action.hash, hash);
        await repo.commitPrepared(intent);
        await repo.commitPrepared(intent);
        expect(
          (await store.getAll(
            'SELECT * FROM operations WHERE target_id=\'workout\'',
          )).length,
          1,
        );
        await checkpoint(store, root, 'committed');
        final expected = await store.inventory();
        await store.close();
        for (var i = 0; i < 2; i++) {
          store = await LocalStore.open(
            profile: profile,
            expectedProfileId: profile.profileId,
            schema: prescriptionSchemaRegistry(),
          );
          expect(await store.inventory(), expected);
          await checkpoint(store, root, 'reopen-$i');
          await store.close();
        }
      } finally {
        await store.close();
        await archiveOwned(root);
      }
    },
  );
}
