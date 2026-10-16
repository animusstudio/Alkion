import 'resume_history_test.dart' show archiveOwned, checkpoint;
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';

void main() {
  test(
    'real finish commits draft timer recovery exact sets and immutable outbox once through two reopens',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-workflow-finish-',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      LocalStore store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: workflowSchemaRegistry(),
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
        final state = PreparedWorkflowState(
          store,
          {'draftId': 'draft', 'planned': 'retained', 'focus': 'legs'},
          {
            'draftId': 'draft',
            'restStart': '2026-10-15T10:00:00Z',
            'restTotal': 90,
          },
          0,
        );
        expect(await commitWorkflowState(store, state), 1);
        final repo = WorkoutRepository.local(store);
        final recovery = <String, Object?>{
          'sessionId': 'workout',
          'draft': {'draftId': 'draft', 'planned': 'retained'},
        };
        final intent = repo.prepareFinish(
          write: const SessionWrite(
            id: 'workout',
            dateIso: '2026-10-15',
            dayTemplateId: 'deleted-day',
            sets: [
              SetWrite(
                id: 'set',
                exerciseId: 'exercise',
                setNumber: 1,
                weightKg: '80.12500000000000000100',
                reps: 5,
                rir: 9,
                isWarmup: false,
                isTopSet: true,
              ),
            ],
          ),
          baseRevision: 0,
          setBases: {},
          recovery: recovery,
          draftRevision: 1,
          draftId: 'draft',
        );
        recovery['sessionId'] = 'mutated-after-prepare';
        await repo.commitPrepared(intent);
        expect((await repo.commitPrepared(intent)).replayed, isTrue);
        expect(
          (await store.get('SELECT * FROM sets'))['weight_kg'],
          '80.12500000000000000100',
        );
        expect((await store.get('SELECT * FROM sets'))['rir'], 9);
        expect(
          (await store.get('SELECT * FROM sessions'))['original_day_id'],
          'deleted-day',
        );
        expect(
          (await store.get('SELECT * FROM sessions'))['day_template_id'],
          isNull,
        );
        expect(
          (await store.get(
            'SELECT * FROM reps_compat1_legacy_local',
          ))['legacy_local_top'],
          1,
        );
        expect((await store.get('SELECT * FROM sets'))['is_top_set'], 0);
        await checkpoint(store, root, 'committed');
        final expected = await store.inventory();
        await store.close();
        for (var i = 0; i < 2; i++) {
          store = await LocalStore.open(
            profile: profile,
            expectedProfileId: profile.profileId,
            schema: workflowSchemaRegistry(),
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
