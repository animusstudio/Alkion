import 'dart:typed_data';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/resume.dart';
import 'package:alkion/domain/evidence.dart';
import 'dart:convert';
import 'dart:async';
import 'package:alkion/session/session_manager.dart';
import '../../support/screen_harness.dart' show RealZoneDatabase;
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';

Future<void> archiveOwned(Directory root) async {
  final archive = Platform.environment['ALKION_FIXTURE_ARCHIVE'];
  if (archive != null) {
    final dest = Directory(
      '$archive/${root.uri.pathSegments.where((s) => s.isNotEmpty).last}',
    );
    expect(await dest.exists(), isFalse);
    final files = <String, Object?>{};
    Future<void> copy(Directory from, Directory to) async {
      await to.create(recursive: true);
      await for (final item in from.list(followLinks: false)) {
        final name = item.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (item is Directory) {
          await copy(item, Directory('${to.path}/$name'));
        } else if (item is File) {
          final bytes = await item.readAsBytes();
          final target = await item.copy('${to.path}/$name');
          final written = await target.readAsBytes();
          expect(written, bytes);
          files[item.path.substring(root.path.length + 1)] = {
            'bytes': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
            'verified_archive_sha256': sha256.convert(written).toString(),
          };
        } else {
          throw StateError('Unexpected synthetic fixture artifact');
        }
      }
    }

    await copy(root, dest);
    await File(
      '${dest.path}/archive-verification.json',
    ).writeAsString(jsonEncode(files), flush: true);
  }
  expect(
    root.path.startsWith('${Directory.systemTemp.path}/alkion-workflow-'),
    isTrue,
  );
  await root.delete(recursive: true);
}

Future<void> checkpoint(LocalStore store, Directory root, String name) async {
  await File(
    '${root.path}/$name.inventory.json',
  ).writeAsString(jsonEncode(await store.inventory()), flush: true);
  await store.backupTo('${root.path}/$name.sqlite');
}

Future<void> seed(
  LocalStore store,
  RecordKind kind,
  String id,
  Map<String, Object?> fields,
) => store.writeTransaction((tx) async {
  final ref = LocalRef(tx.profileId, kind, id);
  final revision = await tx.writeRevision(
    ref,
    localBytes(fields),
    layer: 'sourceSelection',
  );
  await tx.putRecord(ref, revision, fields);
});
Future<LocalStore> reopen(AlkionProfile p) => LocalStore.open(
  profile: p,
  expectedProfileId: p.profileId,
  schema: workflowSchemaRegistry(),
);

SessionDraft rawResumeDraft(Exercise exercise, LoggedSet row) => SessionDraft(
  templateId: null,
  name: 'Synthetic',
  focus: 'legs',
  startedAt: DateTime.utc(2026, 10, 14, 10),
  sessionId: 'raw-workout',
  sessionDate: '2026-10-14',
  localRevision: 1,
  setBases: {'raw-set': 1},
  blocks: [
    BlockState(
      exercise: exercise,
      resolved: ResolvedSlot(
        exercise: exercise,
        workSets: 1,
        warmupSets: 0,
        repLow: 5,
        repHigh: 8,
        rirLow: 1,
        rirHigh: 2,
      ),
      warmupSets: [],
      workingSets: [loggedToSetState(row)],
      expanded: true,
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'stale history request stays bound to observed revision after concurrent edit and another read; tombstone requires explicit restore',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-workflow-history-',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      var store = await reopen(profile);
      try {
        await seed(store, RecordKind.exercise, 'e', {
          'name': 'Synthetic',
          'is_template': 0,
        });
        await seed(store, RecordKind.workout, 'w', {
          'date': '2026-10-14',
          'original_day_id': 'deleted-day',
          'day_template_id': null,
          'created_at': '2026-10-14T10:00:00Z',
        });
        await seed(store, RecordKind.workoutSet, 's', {
          'session_id': 'w',
          'exercise_id': 'e',
          'set_number': 1,
          'weight_kg': '80.125000000000000100',
          'reps': 5,
          'rir': 9,
          'is_warmup': 0,
          'is_top_set': 1,
          'is_pr': 1,
        });
        final editor = SessionRepository.local(store);
        final observed = (await editor.setsForSession('w')).single;
        final input = <String, Object?>{
          'mode': 'edit',
          'set': {
            'id': observed.id,
            'base': observed.localRevision,
            'fields': {'reps': 6},
          },
        };
        final stale = editor.prepareHistoryEdit(
          'w',
          observed.workoutRevision!,
          input,
          operationId: 'stale-editor',
        );
        final original = base64Encode(stale.action.bytes);
        input.clear();
        final newer = SessionRepository.local(store).prepareHistoryEdit(
          'w',
          1,
          {
            'mode': 'edit',
            'set': {
              'id': 's',
              'base': 1,
              'fields': {'reps': 7},
            },
          },
          operationId: 'newer-edit',
        );
        await SessionRepository.local(store).commitPrepared(newer);
        expect(
          (await editor.setsForSession('w')).single.reps,
          7,
          reason: 'an unrelated re-read updates its convenience cache',
        );
        final before = await store.inventory();
        await checkpoint(store, root, 'newer-before-stale-save');
        await expectLater(
          editor.commitPrepared(stale),
          throwsA(
            isA<StoreException>().having(
              (e) => e.category,
              'category',
              'revision_conflict',
            ),
          ),
        );
        expect(base64Encode(stale.action.bytes), original);
        expect(await store.inventory(), before);
        expect(
          (await store.get('SELECT * FROM sets'))['weight_kg'],
          '80.125000000000000100',
        );
        expect((await store.get('SELECT * FROM sets'))['rir'], 9);
        final deletion = editor.prepareDelete('w', 2);
        await editor.commitPrepared(deletion);
        final deleted = await store.inventory();
        await expectLater(
          editor.commitPrepared(
            editor.prepareHistoryEdit('w', 3, {
              'mode': 'edit',
              'set': {
                'id': 's',
                'base': 2,
                'fields': {'reps': 8},
              },
            }),
          ),
          throwsA(isA<StoreException>()),
        );
        expect(await store.inventory(), deleted);
        expect(await editor.sessionById('w'), isNull);
        await editor.commitPrepared(
          editor.prepareDelete('w', 3, restore: true),
        );
        expect((await editor.setsForSession('w')).single.id, 's');
        expect((await editor.sessionById('w'))!.date, '2026-10-14');
        await checkpoint(store, root, 'restored');
        final expected = await store.inventory();
        await store.close();
        for (var i = 0; i < 2; i++) {
          store = await reopen(profile);
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
  test(
    'untouched missing load and reps plus invalid RIR survive resumed controller refinish without factual zero or changed day',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-workflow-raw-resume-',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      var store = await reopen(profile);
      ActiveSessionController? controller;
      try {
        await seed(store, RecordKind.exercise, 'raw-exercise', {
          'name': 'Synthetic',
          'is_template': 0,
          'plate_step_kg': '2.50',
        });
        await seed(store, RecordKind.workout, 'raw-workout', {
          'date': '2026-10-14',
          'created_at': '2026-10-14T10:00:00',
          'original_day_id': 'deleted-day',
          'notes': 'preserved rich note',
          'user_id': 'captured-unbound-user',
        });
        await seed(store, RecordKind.workoutSet, 'raw-set', {
          'session_id': 'raw-workout',
          'exercise_id': 'raw-exercise',
          'set_number': 1,
          'weight_kg': null,
          'reps': null,
          'rir': 'uncertain',
          'is_warmup': 0,
          'is_top_set': null,
          'is_pr': null,
          'user_id': 'captured-unbound-user',
        });
        final row = (await SessionRepository.local(
          store,
        ).setsForSession('raw-workout')).single;
        final exercise = (await ExerciseRepository.local(store).all()).single;
        final draft = rawResumeDraft(exercise, row),
            draftStore = DraftStore.local(store);
        await draftStore.save(draft);
        controller = ActiveSessionController.fromDraft(
          (await draftStore.load())!,
          draftStore: draftStore,
        );
        final repo = WorkoutRepository.local(store),
            intent = controller.prepareFinish(
              repo,
              at: DateTime.utc(2026, 10, 15),
            );
        final set = (intent.input['sets'] as List).single as Map;
        expect(set['weight_kg'], isNull);
        expect(set['reps'], isNull);
        expect(set['rir'], 'uncertain');
        await controller.commitFinish(repo);
        final actual = await store.get('SELECT * FROM sets');
        expect(actual['weight_kg'], isNull);
        expect(actual['reps'], isNull);
        expect(actual['rir'], 'uncertain');
        expect(actual['is_top_set'], isNull);
        expect(actual['is_pr'], isNull);
        expect(actual['user_id'], 'captured-unbound-user');
        final session = await store.get('SELECT * FROM sessions');
        expect(session['date'], '2026-10-14');
        expect(session['created_at'], '2026-10-14T10:00:00');
        expect(session['original_day_id'], 'deleted-day');
        expect(session['notes'], 'preserved rich note');
        expect(session['user_id'], 'captured-unbound-user');
        controller.dispose();
        controller = null;
        await checkpoint(store, root, 'raw-refinished');
        final expected = await store.inventory();
        await store.close();
        for (var i = 0; i < 2; i++) {
          store = await reopen(profile);
          expect(await store.inventory(), expected);
          await checkpoint(store, root, 'reopen-$i');
          await store.close();
        }
      } finally {
        controller?.dispose();
        await store.close();
        await archiveOwned(root);
      }
    },
  );
  test(
    'review F4 unrelated workout delete preserves actual finished recovery bytes revision and resume snapshot',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-workflow-review-unrelated-delete-',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      var store = await reopen(profile);
      try {
        await seed(store, RecordKind.workout, 'A', {
          'date': '2026-10-14',
          'split_label': 'A',
        });
        final draft = SessionDraft(
          templateId: null,
          name: 'B',
          focus: '',
          startedAt: DateTime.now(),
          blocks: [],
        );
        final recovery = FinishedSession(
          sessionId: 'B',
          sessionDate: '2026-10-15',
          finishedAt: DateTime.now(),
          elapsedSeconds: 30,
          draft: draft,
        );
        await commitWorkflowState(
          store,
          PreparedWorkflowState(store, draft.toJson(), {
            'draftId': draft.draftId,
            'restTotal': 0,
          }, 0),
        );
        await WorkoutRepository.local(store).commitPrepared(
          WorkoutRepository.local(store).prepareFinish(
            write: const SessionWrite(id: 'B', dateIso: '2026-10-15', sets: []),
            baseRevision: 0,
            setBases: {},
            recovery: recovery.toJson(),
            draftRevision: 1,
            draftId: draft.draftId,
          ),
        );
        final before = await store.get(
          "SELECT * FROM local_state WHERE state_kind='finishedRecovery'",
        );
        await checkpoint(store, root, 'finished-B');
        final repo = SessionRepository.local(store);
        await repo.commitPrepared(repo.prepareDelete('A', 1));
        final after = await store.get(
          "SELECT * FROM local_state WHERE state_kind='finishedRecovery'",
        );
        final loaded = await FinishedSessionStore.local(store).load();
        await checkpoint(store, root, 'deleted-A');
        final inventory = await store.inventory();
        await store.close();
        for (var i = 0; i < 2; i++) {
          store = await reopen(profile);
          expect(await store.inventory(), inventory);
          await checkpoint(store, root, 'reopen-$i');
          await store.close();
        }
        expect(after, before);
        expect(loaded?.sessionId, 'B');
      } finally {
        await store.close();
        await archiveOwned(root);
      }
    },
  );
  test(
    'review F4 callback newer finished B survives old A memory check and delayed SQL clear',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-workflow-review-clear-race-',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      var store = await reopen(profile);
      final gate = RecoveryClearGate(store);
      final manager = SessionManager(
        finishedStore: FinishedSessionStore.local(gate),
      );
      try {
        final aDraft = SessionDraft(
          templateId: null,
          name: 'A',
          focus: '',
          startedAt: DateTime.now(),
          blocks: [],
        );
        await seed(store, RecordKind.workout, 'A', {
          'date': '2026-10-15',
          'split_label': 'A',
        });
        await manager.recordFinished(
          FinishedSession(
            sessionId: 'A',
            sessionDate: '2026-10-15',
            finishedAt: DateTime.now(),
            elapsedSeconds: 30,
            draft: aDraft,
          ),
        );
        gate.pause = true;
        final forgetting = manager.forgetFinished('A');
        await gate.entered.future.timeout(const Duration(seconds: 5));
        final draft = SessionDraft(
          templateId: null,
          name: 'B',
          focus: '',
          startedAt: DateTime.now(),
          blocks: [],
        );
        final recovery = FinishedSession(
          sessionId: 'B',
          sessionDate: '2026-10-15',
          finishedAt: DateTime.now(),
          elapsedSeconds: 30,
          draft: draft,
        );
        await commitWorkflowState(
          store,
          PreparedWorkflowState(store, draft.toJson(), {
            'draftId': draft.draftId,
            'restTotal': 0,
          }, 0),
        );
        await WorkoutRepository.local(store).commitPrepared(
          WorkoutRepository.local(store).prepareFinish(
            write: const SessionWrite(id: 'B', dateIso: '2026-10-15', sets: []),
            baseRevision: 0,
            setBases: {},
            recovery: recovery.toJson(),
            draftRevision: 1,
            draftId: draft.draftId,
          ),
        );
        final before = await store.get(
          "SELECT * FROM local_state WHERE state_kind='finishedRecovery'",
        );
        await checkpoint(store, root, 'B-before-old-clear');
        gate.release.complete();
        await forgetting.timeout(const Duration(seconds: 5));
        final after = await store.get(
          "SELECT * FROM local_state WHERE state_kind='finishedRecovery'",
        );
        final loaded = await FinishedSessionStore.local(store).load();
        await checkpoint(store, root, 'after-old-clear');
        final inventory = await store.inventory();
        await store.close();
        for (var i = 0; i < 2; i++) {
          store = await reopen(profile);
          expect(await store.inventory(), inventory);
          await checkpoint(store, root, 'reopen-$i');
          await store.close();
        }
        expect(
          after,
          before,
          reason: 'SQL target check must preserve newer B bytes and revision',
        );
        expect(loaded?.sessionId, 'B');
      } finally {
        if (!gate.release.isCompleted) gate.release.complete();
        manager.dispose();
        await store.close();
        await archiveOwned(root);
      }
    },
  );
  test(
    'F4 conditional clear preserves malformed structural evidence and matching clear is idempotent across two reopens',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-workflow-clear-evidence-',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      var store = await reopen(profile);
      try {
        final finished = FinishedSessionStore.local(store);
        for (final bytes in <List<int>>[
          utf8.encode('{"sessionId":"A"}'),
          utf8.encode('{"sessionId":7}'),
          utf8.encode('null'),
          [0xff, 0xfe],
        ]) {
          await store.writeTransaction((tx) async {
            final old = await tx.localState(
              LocalStateKind.finishedRecovery,
              'last',
            );
            await tx.putLocalState(
              LocalStateKind.finishedRecovery,
              'last',
              Uint8List.fromList(bytes),
              expectedRevision: old?['revision'] as int? ?? 0,
            );
          });
          final before = await store.inventory();
          await expectLater(
            finished.clearForSession('A'),
            throwsA(
              isA<StoreException>().having(
                (e) => e.category,
                'category',
                'malformed_recovery_preserved',
              ),
            ),
          );
          expect(await store.inventory(), before);
        }
        await checkpoint(store, root, 'malformed-evidence-preserved');
        final draft = SessionDraft(
          templateId: null,
          name: 'A',
          focus: '',
          startedAt: DateTime.utc(2026, 10, 15),
          blocks: [],
        );
        await finished.save(
          FinishedSession(
            sessionId: 'A',
            sessionDate: '2026-10-15',
            finishedAt: DateTime.utc(2026, 10, 15, 10),
            elapsedSeconds: 30,
            draft: draft,
          ),
        );
        final active = await store.get(
          "SELECT * FROM local_state WHERE state_kind='finishedRecovery'",
        );
        final beforeUnrelated = await store.inventory();
        await finished.clearForSession('B');
        expect(await store.inventory(), beforeUnrelated);
        await finished.clearForSession('A');
        final expired = await store.get(
          "SELECT * FROM local_state WHERE state_kind='finishedRecovery'",
        );
        expect(expired['payload_bytes'], active['payload_bytes']);
        expect(expired['revision'], (active['revision'] as int) + 1);
        expect(expired['status'], 'expired');
        final inventory = await store.inventory();
        await finished.clearForSession('A');
        expect(await store.inventory(), inventory);
        await checkpoint(store, root, 'matching-expiration');
        await store.close();
        for (var i = 0; i < 2; i++) {
          store = await reopen(profile);
          expect(await store.inventory(), inventory);
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

class RecoveryClearGate extends RealZoneDatabase {
  RecoveryClearGate(LocalDatabase database) : super(database, Zone.current);
  bool pause = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<T> writeTransaction<T>(
    Future<T> Function(LocalTransaction) callback, {
    StoreToken? expected,
  }) async {
    if (pause) {
      pause = false;
      entered.complete();
      await release.future;
    }
    return database.writeTransaction(callback, expected: expected);
  }
}
