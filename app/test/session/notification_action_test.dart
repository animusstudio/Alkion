import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/notification_action.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/screen_harness.dart';

class ActionDatabase extends RealZoneDatabase {
  ActionDatabase(LocalDatabase database) : super(database, Zone.current);
  bool fail = false, afterCommit = false, gate = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<T> writeTransaction<T>(
    Future<T> Function(LocalTransaction) callback, {
    StoreToken? expected,
  }) async {
    if (gate && !release.isCompleted) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    final result = await super.writeTransaction((tx) async {
      final value = await callback(tx);
      if (fail && !afterCommit) throw StateError('refused COMMIT');
      return value;
    }, expected: expected);
    if (fail && afterCommit) throw StateError('forwarded COMMIT failure');
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late FixtureDatabase db;
  late ActionDatabase actions;
  late DraftStore drafts;
  late ActiveSessionController c;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('alkion-notification-action-');
    db = await FixtureDatabase.open(temp);
    actions = ActionDatabase(db);
    drafts = DraftStore.local(actions);
    c = ActiveSessionController(draftStore: drafts);
    c.seedEmpty(name: 'Synthetic workout', focus: '');
    c.startRest(600);
    await c.flushPersistence();
  });
  tearDown(() async {
    c.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });

  test(
    'one token commits once; refreshed token works; controller autosave retains committed rest',
    () async {
      final action = (await drafts.notificationAction())!;
      expect((await drafts.notificationAction())!.token, action.token);
      expect(await c.applyNotificationAction(action), isTrue);
      expect(c.restTotal, 630);
      final committed = await db.store.inventory();
      expect(await c.applyNotificationAction(action), isTrue);
      expect(await db.store.inventory(), committed);
      final refreshed = (await drafts.notificationAction())!;
      expect(refreshed.token, isNot(action.token));
      expect(await c.applyNotificationAction(refreshed), isTrue);
      expect(c.restTotal, 660);
      c.addRestTime(1);
      await c.flushPersistence();
      expect((await drafts.load())!.restTotal, 661);
      final after = await db.store.inventory();
      expect(await consumeNotificationAction(actions, action), isNull);
      expect(await db.store.inventory(), after);
      expect(await db.getAll('SELECT * FROM operations'), isEmpty);
    },
  );

  test(
    'variant/profile/generation/draft/rest/revision/token fences are exact no-ops',
    () async {
      final action = (await drafts.notificationAction())!;
      for (final entry in {
        'application_id': 'dev.animusstudio.alkion',
        'profile_id': 'foreign-profile',
        'generation': action.generation + 1,
        'draft_id': 'old-draft',
        'rest_start': DateTime.now()
            .subtract(const Duration(minutes: 5))
            .toIso8601String(),
        'timer_revision': action.timerRevision + 1,
        'token': 'not-issued',
      }.entries) {
        final changed = NotificationAction.decode(
          jsonEncode(action.toJson()..[entry.key] = entry.value),
        )!;
        final before = await db.store.inventory();
        expect(
          await consumeNotificationAction(actions, changed),
          isNull,
          reason: entry.key,
        );
        expect(await db.store.inventory(), before, reason: entry.key);
      }
      expect(NotificationAction.decode('{bad'), isNull);
      expect(
        NotificationAction.decode(
          jsonEncode(action.toJson()..['root'] = '/arbitrary'),
        ),
        isNull,
      );
      final before = await db.store.inventory();
      expect(
        await consumeNotificationAction(
          actions,
          action,
          now: c.restStart!.add(const Duration(seconds: 601)),
        ),
        isNull,
      );
      expect(await db.store.inventory(), before);
      await c.discard();
      final finished = await db.store.inventory();
      expect(await consumeNotificationAction(actions, action), isNull);
      expect(await db.store.inventory(), finished);
    },
  );

  for (final after in [false, true]) {
    test(
      'action ${after ? 'forwarded' : 'refused'} COMMIT retains controller and retries exact token',
      () async {
        final action = (await drafts.notificationAction())!;
        final before = await db.store.inventory();
        actions.fail = true;
        actions.afterCommit = after;
        await expectLater(c.applyNotificationAction(action), throwsStateError);
        expect(c.restTotal, 600);
        if (!after) expect(await db.store.inventory(), before);
        actions.fail = false;
        expect(await c.applyNotificationAction(action), isTrue);
        expect(c.restTotal, 630);
        final committed = await db.store.inventory();
        expect(await c.applyNotificationAction(action), isTrue);
        expect(await db.store.inventory(), committed);
      },
    );
  }

  test(
    'forwarded action COMMIT reconciles before an intervening edit save or replacement token',
    () async {
      final action = (await drafts.notificationAction())!;
      actions.fail = actions.afterCommit = true;
      await expectLater(c.applyNotificationAction(action), throwsStateError);
      actions.fail = false;
      final consumed = await db.store.inventory();
      await expectLater(
        drafts.notificationAction(),
        throwsA(isA<StoreException>()),
      );
      expect(await db.store.inventory(), consumed);
      c.addRestTime(1);
      expect(
        () => c.prepareFinish(WorkoutRepository.local(actions)),
        throwsA(isA<StoreException>()),
      );
      expect(c.pendingFinish, isNull);
      await c.flushPersistence();
      expect(c.restTotal, 631);
      expect(drafts.pending, isNull);
      expect((await drafts.load())!.restTotal, 631);
      final timer = await db.get(
        "SELECT payload_bytes FROM local_state WHERE state_kind='timer' AND state_key='active'",
      );
      final value =
          jsonDecode(utf8.decode((timer['payload_bytes'] as List).cast<int>()))
              as Map;
      expect(value['restTotal'], 631);
      expect(value['restStart'], c.restStart!.toIso8601String());
      expect(value['draftId'], c.draft.draftId);
      final next = (await drafts.notificationAction())!;
      expect(next.token, isNot(action.token));
      expect(await c.applyNotificationAction(next), isTrue);
      expect(c.restTotal, 661);
      final committed = await db.store.inventory();
      expect(await consumeNotificationAction(actions, action), isNull);
      expect(await db.store.inventory(), committed);
      await c.commitFinish(WorkoutRepository.local(actions));
      expect(await drafts.load(), isNull);
      expect(c.lastFinished!.draft.restTotal, 661);
    },
  );

  for (final afterCommit in [false, true]) {
    testWidgets(
      'Log Set during a gated action ${afterCommit ? 'forwarded COMMIT failure' : 'COMMIT'} keeps the logged set and its new absolute rest',
      (tester) async {
        const exercise = Exercise(
          id: 'synthetic-bench',
          name: 'Bench',
          slug: 'bench',
          muscleGroup: 'chest',
          compound: true,
          plateStepKg: 2.5,
          isTemplate: false,
          defaultRestSeconds: 90,
        );
        final set = SetState(
          id: 'synthetic-set',
          weightKg: 40,
          reps: 8,
          rir: 1,
          isWarmup: false,
          done: false,
        );
        await tester.runAsync(() async {
          c.seedForTest(
            SessionDraft(
              templateId: null,
              name: 'Synthetic workout',
              focus: '',
              startedAt: DateTime.now(),
              blocks: [
                BlockState(
                  exercise: exercise,
                  resolved: ResolvedSlot(
                    exercise: exercise,
                    workSets: 1,
                    warmupSets: 0,
                    repLow: 8,
                    repHigh: 10,
                    rirLow: 1,
                    rirHigh: 2,
                  ),
                  warmupSets: [],
                  workingSets: [set],
                  expanded: true,
                ),
              ],
            ),
          );
          await c.flushPersistence();
        });
        final oldStart = c.restStart;
        late Future<bool> actionWork;
        await tester.runAsync(() async {
          final action = (await drafts.notificationAction())!;
          actions.gate = true;
          actionWork = c.applyNotificationAction(action);
          await actions.entered.future;
        });
        try {
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider<ActiveSessionController>.value(value: c),
                ChangeNotifierProvider(create: (_) => SessionManager()),
                ChangeNotifierProvider(create: (_) => SettingsService()),
                ChangeNotifierProvider(create: (_) => UnitService()),
              ],
              child: MaterialApp(
                theme: buildTheme(Brightness.dark, accents[0]),
                localizationsDelegates: const [
                  AppLocalizations.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                supportedLocales: AppLocalizations.supportedLocales,
                home: const ActiveSessionScreen(),
              ),
            ),
          );
          await tester.pump();
          await tester.tap(find.byKey(const Key('log-set-bar')));
          await tester.pump();
          final atTap = c.restStart;
          final totalAtTap = c.restTotal;
          await tester.runAsync(() async {
            actions.fail = actions.afterCommit = afterCommit;
            actions.release.complete();
            if (afterCommit) {
              await expectLater(actionWork, throwsStateError);
            } else {
              await actionWork;
            }
            actions.fail = false;
            await c.flushPersistence();
            final saved = (await drafts.load())!;
            expect(saved.blocks.single.workingSets.single.done, isTrue);
            expect(saved.restTotal, 90);
            expect(saved.restStart, atTap);
          });
          expect(set.done, isTrue);
          expect(atTap, isNot(oldStart));
          expect(totalAtTap, 90);
          expect(c.restTotal, 90);
          expect(c.restStart, atTap);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            if (!actions.release.isCompleted) actions.release.complete();
            await actionWork.then<void>((_) {}, onError: (Object error) {});
          });
        }
      },
    );
  }

  test(
    'multiple queued rest commands preserve order and the original stop instant',
    () async {
      final action = (await drafts.notificationAction())!;
      actions.gate = true;
      final work = c.applyNotificationAction(action);
      await actions.entered.future;
      c.startRest(90);
      c.stopRest();
      c.startRest(45);
      c.stopRest();
      final endedAt = c.restEndedAt;
      actions.release.complete();
      await work;
      await c.flushPersistence();
      final saved = (await drafts.load())!;
      expect(saved.restStart, isNull);
      expect(saved.restTotal, 0);
      expect(saved.restEndedAt, endedAt);
      expect(c.restEndedAt, endedAt);
    },
  );

  test(
    'autosave reconciles an uncertain action before saving a later edit',
    () async {
      final action = (await drafts.notificationAction())!;
      actions.fail = actions.afterCommit = true;
      await expectLater(c.applyNotificationAction(action), throwsStateError);
      actions.fail = false;
      c.addRestTime(1);
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (c.persistenceOwed && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(c.persistenceOwed, isFalse);
      expect(c.persistenceError, isNull);
      expect(c.restTotal, 631);
      expect((await drafts.load())!.restTotal, 631);
    },
  );

  test(
    'in-flight action fences Finish and old autosaves; finish-first action is a no-op',
    () async {
      final action = (await drafts.notificationAction())!;
      actions.gate = true;
      final work = c.applyNotificationAction(action);
      await actions.entered.future;
      final repository = WorkoutRepository.local(actions);
      expect(() => c.prepareFinish(repository), throwsA(isA<StoreException>()));
      expect(c.pendingFinish, isNull);
      final flush = c.flushPersistence();
      actions.release.complete();
      await work;
      await flush;
      expect((await drafts.load())!.restTotal, 630);
      final next = (await drafts.notificationAction())!;
      c.prepareFinish(repository);
      final before = await db.store.inventory();
      expect(await c.applyNotificationAction(next), isFalse);
      expect(await db.store.inventory(), before);
      await c.commitFinish(repository);
      expect(await drafts.load(), isNull);
      final finished = await db.store.inventory();
      expect(await consumeNotificationAction(actions, next), isNull);
      expect(await db.store.inventory(), finished);
    },
  );
}
