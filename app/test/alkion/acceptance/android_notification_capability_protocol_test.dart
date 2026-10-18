import 'dart:convert';
import 'dart:io';

import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/bodyweight_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/files/private_directory.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../integration_test/android_lifecycle_test.dart' as lifecycle;
import '../../../integration_test/android_notification_capability_test.dart'
    as capability;

const run = '12345678123456781234567812345678';
final oldSource = 'a' * 40, newSource = 'b' * 40;

Future<LocalStore> open(Directory root) async {
  final profile = (await AlkionProfile.existing(supportRoot: root))!;
  return LocalStore.open(
    profile: profile,
    expectedProfileId: profile.profileId,
    schema: workflowSchemaRegistry(),
  );
}

Future<Map<String, dynamic>> baseline(Directory root) async {
  final a2 = await lifecycle.seedUpdateState(root);
  await lifecycle.prepareLifecycleState(root, a2, run);
  var store = await open(root);
  var drafts = DraftStore.local(store);
  var controller = ActiveSessionController.fromDraft(
    (await drafts.load())!,
    draftStore: drafts,
  );
  try {
    await controller.applyNotificationAction(
      (await drafts.notificationAction())!,
    );
    await controller.applyNotificationAction(
      (await drafts.notificationAction())!,
    );
    await controller.flushPersistence();
  } finally {
    controller.dispose();
    await store.close();
  }
  final rest = await lifecycle.captureUpdateState(root);
  store = await open(root);
  drafts = DraftStore.local(store);
  controller = ActiveSessionController.fromDraft(
    (await drafts.load())!,
    draftStore: drafts,
  );
  try {
    expect(controller.logLiveSet()!.newlyDone, isTrue);
    controller.startRest(600);
    await controller.flushPersistence();
    await controller.commitFinish(WorkoutRepository.local(store));
  } finally {
    controller.dispose();
    await store.close();
  }
  return lifecycle.verifyLifecycleFinish(root, rest);
}

/// Model the accepted host receipt around real closed SQLite lifecycle output.
/// This is a host protocol fixture, never evidence of native taps or delivery.
Map<String, dynamic> predecessor(Map<String, dynamic> snapshot) => {
  'format': 'alkion-android-run/1',
  'run_id': run,
  'source_commit': oldSource,
  'phase': 'lifecycle-initial',
  'overall': 'IN_PROGRESS',
  'initial_lifecycle_phase': 'PASS',
  'installed': {
    for (final variant in AlkionVariant.values)
      variant.applicationId: {'version_code': 77},
  },
  'lifecycle': {
    for (final variant in AlkionVariant.values)
      variant.applicationId: {
        'initial_lifecycle': 'PASS',
        'finish': {
          'format': 'alkion-android-lifecycle-checkpoint/1',
          'phase': 'finish',
          'run_id': run,
          'application_id': variant.applicationId,
          'closed': true,
          'complete': true,
          'result': 'PASS',
          'profile_id': snapshot['profile_id'],
          'generation': snapshot['generation'],
          'state_digest': lifecycle.updateDigest(snapshot),
        },
      },
  },
};

capability.CapabilityStep step(
  Map<String, dynamic> prior,
  Map<String, dynamic> snapshot,
  String caseId,
  String phase, {
  Map<String, dynamic> changes = const {},
}) {
  final raw = jsonEncode(prior);
  final values = <String, dynamic>{
    'run': run,
    'source': newSource,
    'priorSource': prior['source_commit'],
    'variant': AlkionIdentity.current.name,
    'case': caseId,
    'phase': phase,
    'priorVersion': prior['version_code'] ?? 77,
    'floor': (prior['version_code'] as int? ?? 77) + 23,
    'version': (prior['version_code'] as int? ?? 77) + 24,
    'profile': snapshot['profile_id'],
    'generation': snapshot['generation'],
    'report': sha256.convert(utf8.encode(raw)).toString(),
    'state': lifecycle.updateDigest(snapshot),
    ...changes,
  };
  return capability.CapabilityStep(
    run: values['run'] as String,
    source: values['source'] as String,
    priorSource: values['priorSource'] as String,
    variant: values['variant'] as String,
    caseId: values['case'] as String,
    phase: values['phase'] as String,
    version: values['version'] as int,
    priorVersion: values['priorVersion'] as int,
    consumedFloor: values['floor'] as int,
    profileId: values['profile'] as String,
    generation: values['generation'] as int,
    priorReportDigest: values['report'] as String,
    priorStateDigest: values['state'] as String,
  );
}

Future<Map<String, dynamic>> checkpoint(
  Directory root,
  Map<String, dynamic> prior,
  Map<String, dynamic> snapshot,
  String caseId,
  String phase, {
  Map<String, dynamic> changes = const {},
}) => capability.capabilityCheckpoint(
  root,
  step(prior, snapshot, caseId, phase, changes: changes),
  jsonEncode(prior),
  snapshot,
);

Future<void> log(
  Directory root, {
  bool resetRest = true,
  bool wrongWeight = false,
}) async {
  final store = await open(root);
  final drafts = DraftStore.local(store);
  final controller = ActiveSessionController.fromDraft(
    (await drafts.load())!,
    draftStore: drafts,
  );
  final manager = SessionManager(draftStore: drafts);
  manager.register(controller);
  try {
    await manager.flushPersistence();
    final logged = controller.logLiveSet()!;
    expect(logged.newlyDone, isTrue);
    if (wrongWeight) {
      logged.set.weightKg = 999;
      controller.markChanged();
    }
    if (resetRest) controller.startRest(600);
    await manager.flushPersistence();
    await drafts.notificationAction();
  } finally {
    manager.dispose();
    controller.dispose();
    await store.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch, root;
  late Map<String, dynamic> state, prior;
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp(
      'alkion-capability-protocol-',
    );
    root = Directory('${scratch.path}/${AlkionIdentity.applicationId}');
    state = await baseline(root);
    prior = predecessor(state);
  });
  tearDown(() => scratch.delete(recursive: true));

  Future<void> refuses(Future<Object?> Function() attempt) async {
    final before = lifecycle.updateDigest(
      await lifecycle.captureUpdateState(root),
    );
    await expectLater(attempt(), throwsStateError);
    expect(
      lifecycle.updateDigest(await lifecycle.captureUpdateState(root)),
      before,
      reason: 'refusal must never repair or rewrite the store',
    );
  }

  test(
    'real closed stores retain completed workout, originals and outbox through every capability case',
    () async {
      final original = lifecycle.updateDigest(state);
      var current = state;
      var report = prior;
      for (final caseId in ['denied', 'revoked', 'exact', 'inexact']) {
        report = await checkpoint(root, report, current, caseId, 'prepare');
        current = Map<String, dynamic>.from(report['snapshot'] as Map);
        expect((report['fixture_delta'] as Map).keys.toSet(), {
          'draft/active',
          'timer/active',
          'timer/notification-action',
        });
        expect(report['native_proof'], startsWith('UNRUN'));
        expect(
          report['version_code'],
          greaterThan(report['consumed_version_floor'] as int),
        );
        expect(report['source_commit'], newSource);
        expect(
          report['prior_source_commit'],
          caseId == 'denied' ? oldSource : newSource,
        );
        final prepared = lifecycle.updateDigest(current);
        report = await checkpoint(root, report, current, caseId, 'preserve');
        current = Map<String, dynamic>.from(report['snapshot'] as Map);
        expect(report['observed_delta'], isEmpty);
        expect(lifecycle.updateDigest(current), prepared);
        if (['denied', 'revoked'].contains(caseId)) {
          await log(root);
          report = await checkpoint(root, report, current, caseId, 'logged');
          current = Map<String, dynamic>.from(report['snapshot'] as Map);
          expect((report['observed_delta'] as Map).keys.toSet(), {
            'draft/active',
            'timer/active',
            'timer/notification-action',
          });
        }
        for (final table in preservedTables.where(
          (value) => value != 'local_state',
        )) {
          expect(
            current['inventory'][table],
            state['inventory'][table],
            reason: table,
          );
        }
        expect(current['identity_bytes'], state['identity_bytes']);
        expect(current['original_bytes'], state['original_bytes']);
      }
      expect(lifecycle.updateDigest(state), original);
      expect((current['inventory']['operations'] as List).length, 3);
      expect((current['inventory']['sessions'] as List).length, 1);
      expect((current['inventory']['sets'] as List).length, 3);
    },
  );

  test(
    'compile-bound provenance, consumed versions and input hashes refuse before the fixture writer',
    () async {
      for (final change in <Map<String, dynamic>>[
        {'run': 'f' * 32},
        {'source': 'unreviewed'},
        {'priorSource': 'c' * 40},
        {'variant': 'supported'},
        {'case': 'revoked'},
        {'phase': 'logged'},
        {'profile': 'f' * 36},
        {'generation': 99},
        {'version': 100},
        {'floor': 101},
        {'priorVersion': 76},
        {'report': '0' * 64},
        {'state': '0' * 64},
      ]) {
        await refuses(
          () => checkpoint(
            root,
            prior,
            state,
            'denied',
            'prepare',
            changes: change,
          ),
        );
      }
    },
  );

  test(
    'failed, incomplete and foreign host lifecycle predecessors never authorize a fixture',
    () async {
      for (final field in [
        'run_id',
        'source_commit',
        'phase',
        'initial_lifecycle_phase',
        'overall',
        'error',
      ]) {
        final altered = Map<String, dynamic>.from(
          jsonDecode(jsonEncode(prior)) as Map,
        );
        altered[field] = 'foreign-or-failed';
        await refuses(
          () => checkpoint(
            root,
            altered,
            state,
            'denied',
            'prepare',
            changes: {'priorSource': oldSource},
          ),
        );
      }
      final incomplete = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(prior)) as Map,
      );
      incomplete['lifecycle'][AlkionVariant
              .supported
              .applicationId]['finish']['closed'] =
          false;
      await refuses(
        () => checkpoint(root, incomplete, state, 'denied', 'prepare'),
      );
    },
  );

  test(
    'real current-state drift fails preflight without opening a fixture writer',
    () async {
      final store = await open(root);
      try {
        await store.writeTransaction(
          (tx) => tx.putLocalState(
            LocalStateKind.timer,
            'unexpected',
            localBytes({'unreported': true}),
            expectedRevision: 0,
          ),
        );
      } finally {
        await store.close();
      }
      await refuses(() => checkpoint(root, prior, state, 'denied', 'prepare'));
    },
  );

  for (final kind in [
    'original',
    'outbox',
    'completed-workout',
    'timer',
    'unreported-local-state',
  ]) {
    test(
      'read-only preservation rejects changed $kind bytes and retains the fault',
      () async {
        final prepared = await checkpoint(
          root,
          prior,
          state,
          'denied',
          'prepare',
        );
        final snapshot = Map<String, dynamic>.from(prepared['snapshot'] as Map);
        if (kind == 'original') {
          await File(
            '${root.path}/original-source.bin',
          ).writeAsBytes([99], flush: true);
        } else if (kind == 'outbox') {
          var store = await open(root);
          try {
            await expectLater(
              store.writeTransaction(
                (tx) => tx.execute(
                  "UPDATE operations SET input_bytes=X'00' WHERE rowid=1",
                ),
              ),
              throwsA(
                predicate(
                  (Object error) =>
                      error.toString().contains('immutable_evidence'),
                ),
              ),
            );
          } finally {
            await store.close();
          }
          final unchanged = await checkpoint(
            root,
            prepared,
            snapshot,
            'denied',
            'preserve',
          );
          expect(unchanged['state_digest'], prepared['state_digest']);
          store = await open(root);
          try {
            final repository = BodyweightRepository.local(store);
            await repository.commitPrepared(
              repository.prepareMeasurement(
                dateIso: '2026-10-18',
                kg: const DecimalEvidence(ValueState.valid, '72.0000'),
                operationId: 'unreported-capability-operation',
              ),
            );
          } finally {
            await store.close();
          }
          final appended = await lifecycle.captureUpdateState(root);
          expect(
            (appended['inventory']['operations'] as List).length,
            (snapshot['inventory']['operations'] as List).length + 1,
          );
        } else {
          final store = await open(root);
          try {
            await store.writeTransaction((tx) async {
              if (kind == 'completed-workout') {
                await tx.execute(
                  "UPDATE sets SET weight_kg='999' WHERE rowid=1",
                );
              } else {
                final row = await tx.localState(LocalStateKind.timer, 'active');
                await tx.putLocalState(
                  LocalStateKind.timer,
                  kind == 'timer' ? 'active' : 'unexpected',
                  localBytes({
                    'draftId': 'changed',
                    'restStart': null,
                    'restTotal': 0,
                  }),
                  expectedRevision: kind == 'timer'
                      ? row!['revision'] as int
                      : 0,
                );
              }
            });
          } finally {
            await store.close();
          }
        }
        await refuses(
          () => checkpoint(root, prepared, snapshot, 'denied', 'preserve'),
        );
      },
    );
  }

  for (final error in ['missing-reset', 'wrong-weight', 'action-extension']) {
    test(
      'logging oracle rejects $error instead of accepting broad mutable-row changes',
      () async {
        var report = await checkpoint(root, prior, state, 'denied', 'prepare');
        var snapshot = Map<String, dynamic>.from(report['snapshot'] as Map);
        report = await checkpoint(root, report, snapshot, 'denied', 'preserve');
        snapshot = Map<String, dynamic>.from(report['snapshot'] as Map);
        if (error == 'action-extension') {
          final store = await open(root);
          final drafts = DraftStore.local(store);
          final c = ActiveSessionController.fromDraft(
            (await drafts.load())!,
            draftStore: drafts,
          );
          try {
            await c.applyNotificationAction(
              (await drafts.notificationAction())!,
            );
            await c.flushPersistence();
          } finally {
            c.dispose();
            await store.close();
          }
        } else {
          await log(
            root,
            resetRest: error != 'missing-reset',
            wrongWeight: error == 'wrong-weight',
          );
        }
        await refuses(
          () => checkpoint(root, report, snapshot, 'denied', 'logged'),
        );
      },
    );
  }

  test(
    'checkpoint order and a changed capability receipt cannot authorize another writer',
    () async {
      final report = await checkpoint(root, prior, state, 'denied', 'prepare');
      final snapshot = Map<String, dynamic>.from(report['snapshot'] as Map);
      await refuses(
        () => checkpoint(root, report, snapshot, 'revoked', 'prepare'),
      );
      await refuses(
        () => checkpoint(root, report, snapshot, 'denied', 'logged'),
      );
      for (final field in [
        'variant',
        'complete',
        'closed',
        'state_digest',
        'case_id',
      ]) {
        final altered = Map<String, dynamic>.from(report)
          ..[field] = field == 'closed' || field == 'complete'
              ? false
              : 'foreign';
        await refuses(
          () => checkpoint(root, altered, snapshot, 'denied', 'preserve'),
        );
      }
    },
  );

  test(
    'closed SQL report publishes atomically and cannot replace a retained terminal receipt',
    () async {
      final report = await checkpoint(root, prior, state, 'denied', 'prepare');
      final directory = claimPrivateDirectory('${scratch.path}/report-output');
      await capability.publishCapabilityReport(directory, report);
      final terminal = File('${directory.path}/report.json');
      final bytes = await terminal.readAsBytes();
      final received = jsonDecode(utf8.decode(bytes)) as Map;
      expect(received['complete'], isTrue);
      expect(received['closed'], isTrue);
      expect(
        received['state_digest'],
        lifecycle.updateDigest(await lifecycle.captureUpdateState(root)),
      );
      expect(
        await File('${directory.path}/report.partial').readAsBytes(),
        bytes,
      );
      await expectLater(
        capability.publishCapabilityReport(directory, report),
        throwsStateError,
      );
      expect(await terminal.readAsBytes(), bytes);
    },
  );
}
