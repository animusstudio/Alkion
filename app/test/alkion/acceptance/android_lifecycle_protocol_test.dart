import 'dart:convert';
import 'dart:io';

import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../integration_test/android_lifecycle_test.dart' as protocol;

const runId = '11111111111111111111111111111111';

Future<LocalStore> open(Directory root) async {
  final profile = (await AlkionProfile.existing(supportRoot: root))!;
  return LocalStore.open(
    profile: profile,
    expectedProfileId: profile.profileId,
    schema: workflowSchemaRegistry(),
  );
}

Future<Map<String, dynamic>> actions(Directory root) async {
  final store = await open(root);
  final drafts = DraftStore.local(store);
  final c = ActiveSessionController.fromDraft(
    (await drafts.load())!,
    draftStore: drafts,
  );
  try {
    final first = (await drafts.notificationAction())!;
    expect(await c.applyNotificationAction(first), isTrue);
    final second = (await drafts.notificationAction())!;
    expect(first.token, isNot(second.token));
    final beforeReplay = await store.inventory();
    await c.applyNotificationAction(first);
    expect(await store.inventory(), beforeReplay);
    expect(await c.applyNotificationAction(second), isTrue);
    await c.flushPersistence();
    return {
      'actual_actions': [first.toJson(), second.toJson()],
      'visible_tap': true,
      'cold_tap': true,
      'native_replay_and_fences': true,
      'ordinary_kill_pid_changed': true,
    };
  } finally {
    c.dispose();
    await store.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch, root;
  late Map<String, dynamic> a2;
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp(
      'alkion-lifecycle-protocol-',
    );
    root = Directory('${scratch.path}/dev.animusstudio.alkion.dev');
    a2 = await protocol.seedUpdateState(root);
  });
  tearDown(() => scratch.delete(recursive: true));

  test(
    'same helpers preserve A2 through actions, logging, finish and two reopens',
    () async {
      final prepared = await protocol.prepareLifecycleState(root, a2, runId);
      final evidence = await actions(root);
      final rest = await protocol.verifyLifecycleRest(root, prepared, evidence);
      final store = await open(root);
      final drafts = DraftStore.local(store);
      final c = ActiveSessionController.fromDraft(
        (await drafts.load())!,
        draftStore: drafts,
      );
      try {
        final logged = c.logLiveSet()!;
        expect(logged.set.id, 'workflow-planned');
        expect(logged.newlyDone, isTrue);
        c.startRest(600);
        await c.flushPersistence();
        await c.commitFinish(WorkoutRepository.local(store));
      } finally {
        c.dispose();
        await store.close();
      }
      final finished = await protocol.verifyLifecycleFinish(root, rest);
      for (var attempt = 0; attempt < 2; attempt++) {
        expect(
          protocol.updateDigest(
            await protocol.verifyLifecycleFinish(root, rest),
          ),
          protocol.updateDigest(finished),
        );
      }
      expect((finished['inventory']['operations'] as List).length, 3);
    },
  );

  for (final field in [
    'identity_bytes',
    'original_bytes',
    'generation',
    'profile_id',
  ]) {
    test('changed A2 $field refuses before profile/store mutation', () async {
      final changed = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(a2)) as Map,
      );
      changed[field] = field.endsWith('bytes')
          ? [99]
          : field == 'generation'
          ? 99
          : 'foreign';
      final before = await protocol.captureUpdateState(root);
      await expectLater(
        protocol.prepareLifecycleState(root, changed, runId),
        throwsStateError,
      );
      expect(
        protocol.updateDigest(await protocol.captureUpdateState(root)),
        protocol.updateDigest(before),
      );
    });
  }

  test(
    'actual changed timer is refused and retained without a writer reopen',
    () async {
      final prepared = await protocol.prepareLifecycleState(root, a2, runId);
      final evidence = await actions(root);
      final store = await open(root);
      try {
        await store.writeTransaction((tx) async {
          final timer = await tx.localState(LocalStateKind.timer, 'active');
          final payload = protocol.lifecyclePayload(timer!);
          payload['restTotal'] = 690;
          await tx.putLocalState(
            LocalStateKind.timer,
            'active',
            localBytes(payload),
            expectedRevision: timer['revision'] as int,
          );
        });
      } finally {
        await store.close();
      }
      final before = await protocol.captureUpdateState(root);
      await expectLater(
        protocol.verifyLifecycleRest(root, prepared, evidence),
        throwsStateError,
      );
      expect(
        protocol.updateDigest(await protocol.captureUpdateState(root)),
        protocol.updateDigest(before),
      );
    },
  );

  test(
    'missing, duplicate and foreign native bindings cannot qualify committed rest',
    () async {
      final prepared = await protocol.prepareLifecycleState(root, a2, runId);
      final evidence = await actions(root);
      final first = (evidence['actual_actions'] as List).first;
      for (final changed in [
        {...evidence, 'cold_tap': false},
        {
          ...evidence,
          'actual_actions': [first, first],
        },
        {
          ...evidence,
          'actual_actions': [
            {...first as Map, 'application_id': 'foreign'},
            (evidence['actual_actions'] as List).last,
          ],
        },
      ]) {
        final before = await protocol.captureUpdateState(root);
        await expectLater(
          protocol.verifyLifecycleRest(root, prepared, changed),
          throwsStateError,
        );
        expect(
          protocol.updateDigest(await protocol.captureUpdateState(root)),
          protocol.updateDigest(before),
        );
      }
    },
  );

  for (final extraWorkout in [false, true]) {
    test(
      '${extraWorkout ? 'additional workout' : 'changed logged value'} fails the closed finish checkpoint without repair',
      () async {
        final prepared = await protocol.prepareLifecycleState(root, a2, runId);
        final evidence = await actions(root);
        final rest = await protocol.verifyLifecycleRest(
          root,
          prepared,
          evidence,
        );
        final store = await open(root);
        final drafts = DraftStore.local(store);
        final c = ActiveSessionController.fromDraft(
          (await drafts.load())!,
          draftStore: drafts,
        );
        try {
          final logged = c.logLiveSet()!;
          if (!extraWorkout) {
            logged.set.weightKg = 83;
            c.markChanged();
          }
          await c.flushPersistence();
          await c.commitFinish(WorkoutRepository.local(store));
          if (extraWorkout) {
            await drafts.load();
            final another = ActiveSessionController(draftStore: drafts);
            try {
              another.seedEmpty(name: 'Unexpected second workout', focus: '');
              await another.addBlock(
                (await ExerciseRepository.local(store).all()).single,
                sessionRepo: SessionRepository.local(store),
              );
              final block = another.draft.blocks.single;
              another.toggleDone(block, block.workingSets.first);
              await another.flushPersistence();
              await another.commitFinish(WorkoutRepository.local(store));
            } finally {
              another.dispose();
            }
          }
        } finally {
          c.dispose();
          await store.close();
        }
        final before = await protocol.captureUpdateState(root);
        await expectLater(
          protocol.verifyLifecycleFinish(root, rest),
          throwsStateError,
        );
        expect(
          protocol.updateDigest(await protocol.captureUpdateState(root)),
          protocol.updateDigest(before),
        );
      },
    );
  }
}
