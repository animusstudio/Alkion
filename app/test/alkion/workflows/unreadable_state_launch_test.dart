import 'dart:convert';
import 'dart:io';

import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/data/workflow_state_quarantine.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/main.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/shell/session_launcher.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/widgets/kept_data_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../data/workflow_state_quarantine_test.dart'
    show canonicalRows, evidence, expectedId, reviews, row, seed, sqlType;
import '../../session/session_manager_test.dart' show FakeWorkoutNotification;
import '../../support/app_fonts.dart';
import '../../support/layout_expect.dart';
import '../acceptance/acceptance_support.dart'
    show act, mountReal, realSettle, settleUntil, settleWhile;

const _packageInfo = MethodChannel('dev.fluttercommunity.plus/package_info');

final _draft = SessionDraft(
  templateId: null,
  name: 'Synthetic workout',
  focus: '',
  startedAt: DateTime(2026, 9, 23, 9),
  blocks: const [],
  identity: 'draft-synthetic',
);

Map<String, dynamic> get _draftJson =>
    jsonDecode(jsonEncode(_draft.toJson())) as Map<String, dynamic>;

Uint8List _text(String text) => Uint8List.fromList(utf8.encode(text));

Map<String, Object?> _finished({Object? draft}) => {
  ...FinishedSession(
    sessionId: 'finished-synthetic',
    sessionDate: '2026-09-23',
    // Recent, so a readable snapshot is still adopted for undo.
    finishedAt: DateTime.now(),
    elapsedSeconds: 3600,
    draft: _draft,
  ).toJson(),
  'draft': ?draft,
};

Future<void> _seedDraft(LocalDatabase db, Object payload) async {
  await seed(db, LocalStateKind.draft, 'active', payload);
  await seed(db, LocalStateKind.timer, 'active', localBytes(_draft.timerJson));
}

Future<void> _seedFinished(LocalDatabase db, Object payload) =>
    seed(db, LocalStateKind.finishedRecovery, 'last', payload);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late Directory root;
  final versionCalls = <String>[];
  // PackageInfo caches only a successful read, so the call-counting tests
  // below (declared first) refuse it and are never masked by a cached value.
  var versionAvailable = true;
  final opened = <AlkionRuntime>[];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('alkion-workflow-unreadable-');
    root = Directory('${temp.path}/${AlkionIdentity.applicationId}');
    versionCalls.clear();
    versionAvailable = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_packageInfo, (call) async {
          versionCalls.add(call.method);
          if (!versionAvailable) {
            throw PlatformException(code: 'synthetic_unavailable');
          }
          return <String, dynamic>{
            'appName': 'Alkion Dev',
            'packageName': 'dev.animusstudio.alkion.dev',
            'version': '9.8.7',
            'buildNumber': '42',
            'buildSignature': '',
          };
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_packageInfo, null);
    for (final runtime in opened) {
      if (runtime.store.admission != StoreAdmission.closed) {
        await runtime.close();
      }
    }
    opened.clear();
    await temp.delete(recursive: true);
  });

  /// Seeds the selected profile's store directly, before any runtime owns it.
  Future<void> seedStore(Future<void> Function(LocalStore store) write) async {
    final profile = await AlkionProfile.open(supportRoot: root);
    final store = await openAlkionStore(profile);
    try {
      await write(store);
    } finally {
      await store.close();
    }
  }

  Future<AlkionRuntime> open() async {
    final runtime = await AlkionRuntime.open(
      root,
      notifications: FakeWorkoutNotification(),
    );
    opened.add(runtime);
    return runtime;
  }

  Future<void> close(AlkionRuntime runtime) async {
    await runtime.close();
    opened.remove(runtime);
  }

  test('a clean launch quarantines nothing and asks for no version', () async {
    versionAvailable = false;
    await seedStore((store) async {
      await _seedDraft(store, localBytes(_draftJson));
      await _seedFinished(store, localBytes(_finished()));
    });
    final runtime = await open();
    expect(runtime.sessions.hasActive, isTrue);
    expect(runtime.sessions.lastFinished?.sessionId, 'finished-synthetic');
    expect(await reviews(runtime.store), isEmpty);
    expect(runtime.workflowNotices.value, isEmpty);
    expect(versionCalls, isEmpty);
  });

  test(
    'a damaged launch asks for the version once and records unknown when unavailable',
    () async {
      versionAvailable = false;
      await seedStore((store) async {
        await _seedDraft(store, _text('not json'));
        await _seedFinished(store, _text('not json'));
      });
      final runtime = await open();
      expect(versionCalls, hasLength(1));
      final kept = await reviews(runtime.store);
      expect(kept, hasLength(2));
      for (final review in kept) {
        final decoder = evidence(review)['decoder'] as Map;
        expect(decoder['app_version'], 'unknown');
        expect(decoder['build_number'], 'unknown');
      }
      await close(runtime);
      // A relaunch finds nothing left to keep and asks for nothing.
      await close(await open());
      expect(versionCalls, hasLength(1));
    },
  );

  group('A1 a malformed draft opens without the workout', () {
    final cases = <String, (Object, String)>{
      'invalid JSON': (_text('{"name":'), 'json'),
      'invalid UTF-8': (Uint8List.fromList([0x7b, 0xff, 0xfe, 0x7d]), 'utf8'),
      'a wrong-typed field': (localBytes({..._draftJson, 'name': 7}), 'shape'),
      'a TEXT payload': (jsonEncode(_draftJson), 'blob'),
    };
    for (final MapEntry(key: name, value: (payload, step)) in cases.entries) {
      test(name, () async {
        late Map<String, dynamic> draft, timer;
        late String draftType;
        late Map<String, Object?> history;
        await seedStore((store) async {
          await _seedDraft(store, payload);
          draft = (await row(store, LocalStateKind.draft))!;
          timer = (await row(store, LocalStateKind.timer))!;
          draftType = await sqlType(store, LocalStateKind.draft);
          history = Map.of(await store.inventory())..remove('local_state');
        });
        final runtime = await open();
        final store = runtime.store;
        expect(runtime.sessions.hasActive, isFalse);
        expect(runtime.sessions.lastFinished, isNull);
        final review = (await reviews(store)).single;
        expect(review['review_id'], expectedId('draft', [draft, timer]));
        expect(review['category'], workflowQuarantineCategory);
        final kept = evidence(review);
        expect(kept['kind'], 'draft');
        expect(kept['reason'], 'draft_unreadable');
        expect(kept['rows'], canonicalRows([draft, timer]));
        final decoder = kept['decoder'] as Map;
        expect(decoder['failed_step'], step);
        expect(decoder['app_version'], '9.8.7');
        expect(decoder['build_number'], '42');

        final retired = (await row(store, LocalStateKind.draft))!;
        expect(retired['status'], 'quarantined');
        expect(retired['payload_bytes'], draft['payload_bytes']);
        expect(await sqlType(store, LocalStateKind.draft), draftType);
        final timerAfter = (await row(store, LocalStateKind.timer))!;
        expect(timerAfter['status'], 'quarantined');
        expect(timerAfter['payload_bytes'], timer['payload_bytes']);
        // Nothing outside the workflow rows and the review changed.
        expect(
          Map.of(await store.inventory())
            ..remove('local_state')
            ..remove('reviews'),
          Map.of(history)..remove('reviews'),
        );

        final notices = runtime.workflowNotices.value;
        expect(notices.single.reviewId, review['review_id']);
        expect(keptDataNotice(notices)!.variant, KeptDataNoticeVariant.draft);
      });
    }
  });

  group('A4 a malformed finish snapshot opens without undo', () {
    final cases = <String, (Object, String)>{
      'invalid JSON': (_text('{"sessionId":'), 'finished_recovery_unreadable'),
      'a TEXT payload': (
        jsonEncode(_finished()),
        'finished_recovery_unreadable',
      ),
      'an unsupported embedded draft': (
        localBytes(
          _finished(draft: {..._draftJson, 'version': 3, 'futureField': true}),
        ),
        'finished_recovery_unsupported_format',
      ),
    };
    for (final MapEntry(key: name, value: (payload, reason)) in cases.entries) {
      test(name, () async {
        late Map<String, dynamic> finished;
        late List<Map<String, dynamic>> sessions;
        await seedStore((store) async {
          await _seedFinished(store, payload);
          finished = (await row(store, LocalStateKind.finishedRecovery))!;
          sessions = await store.getAll('SELECT * FROM sessions');
        });
        final runtime = await open();
        final store = runtime.store;
        expect(runtime.sessions.lastFinished, isNull);
        expect(runtime.sessions.hasActive, isFalse);
        final review = (await reviews(store)).single;
        expect(review['review_id'], expectedId('finishedRecovery', [finished]));
        expect(evidence(review)['reason'], reason);
        expect(evidence(review)['rows'], canonicalRows([finished]));
        final retired = (await row(store, LocalStateKind.finishedRecovery))!;
        expect(retired['status'], 'quarantined');
        expect(retired['payload_bytes'], finished['payload_bytes']);
        expect(await FinishedSessionStore.local(store).load(), isNull);
        expect(await store.getAll('SELECT * FROM sessions'), sessions);
        expect(
          keptDataNotice(runtime.workflowNotices.value)!.variant,
          KeptDataNoticeVariant.finished,
        );
      });
    }
  });

  test(
    'A5 damage in both groups keeps two reviews and the combined notice',
    () async {
      await seedStore((store) async {
        await _seedDraft(store, _text('not json'));
        await _seedFinished(store, _text('not json'));
      });
      final runtime = await open();
      final kept = await reviews(runtime.store);
      expect(kept, hasLength(2));
      expect(
        {for (final review in kept) evidence(review)['kind']},
        {'draft', 'finishedRecovery'},
      );
      expect(runtime.sessions.hasActive, isFalse);
      expect(runtime.sessions.lastFinished, isNull);
      final notice = keptDataNotice(runtime.workflowNotices.value)!;
      expect(notice.variant, KeptDataNoticeVariant.both);
      expect(notice.reviewIds.toSet(), {
        for (final review in kept) review['review_id'],
      });
    },
  );

  test(
    'A9 later opens write nothing; the notice repeats until acknowledged',
    () async {
      await seedStore((store) => _seedDraft(store, _text('not json')));
      var runtime = await open();
      final first = await runtime.store.inventory();
      final ids = [
        for (final notice in runtime.workflowNotices.value) notice.reviewId,
      ];
      expect(ids, hasLength(1));
      await close(runtime);

      for (var i = 0; i < 2; i++) {
        runtime = await open();
        expect(await runtime.store.inventory(), first);
        expect([
          for (final notice in runtime.workflowNotices.value) notice.reviewId,
        ], ids);
        await close(runtime);
      }

      runtime = await open();
      // A double tap joins the first acknowledgement.
      await Future.wait([
        runtime.acknowledgeWorkflowNotices(ids),
        runtime.acknowledgeWorkflowNotices(ids),
      ]);
      expect(runtime.workflowNotices.value, isEmpty);
      final decisions = await runtime.store.getAll(
        'SELECT * FROM review_decisions',
      );
      expect(decisions.single['review_id'], ids.single);
      expect(decisions.single['decision_id'], workflowNoticeDecision);
      expect(
        jsonDecode(
          utf8.decode((decisions.single['decision_bytes'] as List).cast<int>()),
        ),
        {
          'format': workflowQuarantineDecisionFormat,
          'decision': 'notice_acknowledged',
        },
      );
      await close(runtime);

      runtime = await open();
      expect(runtime.workflowNotices.value, isEmpty);
      expect(await reviews(runtime.store), hasLength(1));
      expect(
        await runtime.store.getAll('SELECT * FROM review_decisions'),
        decisions,
      );
    },
  );

  test(
    'A16 a failed acknowledgement hides the notice for this run only',
    () async {
      await seedStore((store) => _seedDraft(store, _text('not json')));
      var runtime = await open();
      final ids = [
        for (final notice in runtime.workflowNotices.value) notice.reviewId,
      ];
      // A synthetic fault: the store is gone, so the decision write refuses.
      await runtime.store.close();
      await runtime.acknowledgeWorkflowNotices(ids);
      expect(runtime.workflowNotices.value, isEmpty);
      await runtime.close(closeStore: () async {});
      opened.remove(runtime);

      runtime = await open();
      expect([
        for (final notice in runtime.workflowNotices.value) notice.reviewId,
      ], ids);
      expect(
        await runtime.store.getAll('SELECT * FROM review_decisions'),
        isEmpty,
      );
    },
  );

  test(
    'an unrecognised kept kind shows no notice and is never acknowledged',
    () async {
      await seedStore(
        (store) => store.writeTransaction(
          (tx) => tx.addReview(
            id: 'wq-synthetic-unknown-kind',
            category: workflowQuarantineCategory,
            evidence: localBytes({
              'format': workflowQuarantineFormat,
              'kind': 'futureKind',
              'rows': const [],
            }),
          ),
        ),
      );
      final runtime = await open();
      final pending = runtime.workflowNotices.value;
      expect(pending.single.kind, KeptWorkflowKind.unknown);
      expect(keptDataNotice(pending), isNull);
    },
  );

  test(
    'A13 a new workout autosaves, finishes and resumes over retired rows',
    () async {
      await seedStore((store) async {
        await _seedDraft(store, _text('not json'));
        await _seedFinished(store, _text('not json'));
      });
      final runtime = await open();
      final store = runtime.store;
      final kept = await reviews(store);
      expect(kept, hasLength(2));
      final retired = (await row(store, LocalStateKind.draft))!;

      final controller = ActiveSessionController(
        draftStore: runtime.sessions.draftStore,
      );
      addTearDown(controller.dispose);
      controller.seedEmpty(name: 'Synthetic later workout', focus: '');
      runtime.sessions.register(controller);
      await runtime.flushPersistence();
      final saved = (await row(store, LocalStateKind.draft))!;
      expect(saved['status'], 'active');
      expect(saved['revision'], greaterThan(retired['revision'] as int));
      expect(await reviews(store), kept);

      final sessionId = await finishWorkout(
        controller,
        runtime.sessions,
        repository: WorkoutRepository.local(store),
      );
      expect(runtime.sessions.lastFinished?.sessionId, sessionId);
      expect(
        (await row(store, LocalStateKind.finishedRecovery))!['status'],
        'active',
      );
      expect(await reviews(store), kept);

      runtime.sessions.clear();
      final resumed = await prepareResume(
        runtime.sessions,
        sessionId,
        sessionRepo: SessionRepository.local(store),
        exerciseRepo: ExerciseRepository.local(store),
        draftStore: runtime.sessions.draftStore!,
      );
      expect(resumed, isNotNull);
      addTearDown(resumed!.dispose);
      expect(resumed.draft.sessionId, sessionId);
      expect(await reviews(store), kept);
      runtime.sessions.clear();
    },
  );
  testWidgets(
    'A16 the real app shows the notice, yields to the storage banner and records OK once',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(640, 1830);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final notice = find.byKey(const Key('kept-data-notice'));
      final banner = find.byKey(const Key('storage-recovery-banner'));
      final ok = find.byKey(const Key('kept-data-notice-ok'));
      void expectOneOverlay() => expect(
        notice.evaluate().length + banner.evaluate().length,
        lessThanOrEqualTo(1),
      );
      AlkionRuntime? runtime;
      try {
        await tester.runAsync(() async {
          await preloadAppFonts();
          await seedStore((store) async {
            await _seedDraft(store, _text('not json'));
            await _seedFinished(store, _text('not json'));
          });
          runtime = await open();
        });
        await mountReal(tester, AlkionApp(runtime: runtime!));
        await settleUntil(tester, notice);
        expect(
          find.text(
            "Your unfinished workout and the undo for your last finished workout couldn't be opened. Their saved data is kept and included in backups. Workouts in History are not affected.",
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        expectNoSplitWords(tester, within: notice, where: '320dp 2x');
        expect(tester.getRect(ok).right, lessThanOrEqualTo(320));

        // A storage error takes the top slot; the notice waits for Retry.
        runtime!.persistenceFailure.value = const StoreException(
          'synthetic_owed',
        );
        await realSettle(tester, ticks: 2);
        expect(banner, findsOneWidget);
        expect(notice, findsNothing);
        expectOneOverlay();
        await act(
          tester,
          () => tester.tap(find.byKey(const Key('storage-recovery-retry'))),
        );
        await settleUntil(tester, notice);
        expect(banner, findsNothing);
        expect(runtime!.persistenceFailure.value, isNull);
        expectOneOverlay();

        await act(tester, () async {
          await tester.tap(ok);
          await tester.tap(ok, warnIfMissed: false);
        });
        await settleWhile(tester, () => notice.evaluate().isNotEmpty);
        late List<Map<String, dynamic>> decisions;
        await tester.runAsync(() async {
          decisions = await runtime!.store.getAll(
            'SELECT * FROM review_decisions ORDER BY review_id',
          );
          expect(decisions, hasLength(2));
          expect(
            {for (final d in decisions) d['decision_id']},
            {workflowNoticeDecision},
          );
        });

        // The next runtime shows no notice and writes nothing more.
        await mountReal(tester, const SizedBox());
        await tester.runAsync(() async {
          await close(runtime!);
          runtime = await open();
        });
        await mountReal(tester, AlkionApp(runtime: runtime!));
        await realSettle(tester, ticks: 6);
        expect(notice, findsNothing);
        await tester.runAsync(() async {
          expect(
            await runtime!.store.getAll(
              'SELECT * FROM review_decisions ORDER BY review_id',
            ),
            decisions,
          );
          expect(await reviews(runtime!.store), hasLength(2));
        });
        expect(tester.takeException(), isNull);
      } finally {
        await mountReal(tester, const SizedBox());
        await realSettle(tester, ticks: 3);
        await tester.runAsync(() async {
          if (runtime case final r? when opened.contains(r)) await close(r);
        });
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
