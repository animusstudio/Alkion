import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/notification_action.dart';
import 'package:alkion/session/notification_envelope.dart';
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

var _intents = 0;

/// A journaled tap on [action]'s token at [step], with a fresh intent ID.
NotificationIntent intentFor(
  NotificationAction action,
  int step, {
  NotificationIntentKind kind = NotificationIntentKind.add,
  DateTime? tappedAt,
}) {
  final n = (++_intents).toRadixString(16).padLeft(12, '0');
  return NotificationIntent(
    intentId: '00000000-0000-4000-8000-$n',
    actionId: kind == NotificationIntentKind.add
        ? 'alkion.dev.add_30s'
        : 'alkion.dev.skip_rest',
    kind: kind,
    tappedAt: (tappedAt ?? DateTime.now()).toUtc(),
    payload: NotificationEnvelope(action: action, step: step),
  );
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

  group('undoLog', () {
    late SetState logged;
    late DateTime earlier;
    Future<void> logWithRest() async {
      logged = SetState(
        id: 'undo-set',
        weightKg: 100,
        reps: 5,
        rir: null,
        isWarmup: false,
        done: false,
      );
      const ex = Exercise(
        id: 'synthetic',
        name: 'Synthetic',
        slug: 'synthetic',
        muscleGroup: 'legs',
        compound: true,
        plateStepKg: 2.5,
        isTemplate: false,
      );
      c.seedForTest(
        SessionDraft(
          templateId: null,
          name: 'Synthetic workout',
          focus: '',
          startedAt: DateTime.now(),
          blocks: [
            BlockState(
              exercise: ex,
              resolved: const ResolvedSlot(
                exercise: ex,
                workSets: 2,
                warmupSets: 0,
                repLow: 5,
                repHigh: 8,
                rirLow: null,
                rirHigh: null,
              ),
              warmupSets: [],
              workingSets: [
                logged,
                SetState(
                  id: 'next-set',
                  weightKg: 100,
                  reps: 5,
                  rir: null,
                  isWarmup: false,
                  done: false,
                ),
              ],
              expanded: true,
            ),
          ],
        ),
      );
      c.stopRest();
      earlier = DateTime.now().subtract(const Duration(minutes: 4));
      c.restEndedAt = earlier;
      c.logLiveSet();
      c.startRestAfterLog(logged, 600);
      await c.flushPersistence();
    }

    test(
      'during a notification +30s the undone rest stays stopped with the earlier rested mark',
      () async {
        await logWithRest();
        final action = (await drafts.notificationAction())!;
        actions.gate = true;
        final applying = c.applyNotificationAction(action);
        await actions.entered.future;
        expect(c.undoLog(logged), isTrue);
        expect(c.restStart, isNull);
        expect(c.restEndedAt, earlier);
        actions.release.complete();
        expect(await applying, isTrue);
        expect(logged.done, isFalse);
        expect(c.restStart, isNull, reason: 'the replayed +30s is undone too');
        expect(c.restTotal, 0);
        expect(c.restEndedAt, earlier);
        await c.flushPersistence();
        final saved = (await drafts.load())!;
        expect(saved.restStart, isNull);
        expect(saved.restEndedAt, earlier);
      },
    );

    test('while a Finish is pending it changes nothing', () async {
      await logWithRest();
      final restStart = c.restStart;
      c.prepareFinish(WorkoutRepository.local(actions));
      expect(c.finishPending, isTrue);
      final before = logged.toJson();
      expect(c.undoLog(logged), isFalse);
      expect(logged.toJson(), before);
      expect(c.restStart, restStart);
      expect(c.restTotal, 600);
      expect(c.restStartedBy(logged), isTrue);
    });
  });

  Future<Map<String, dynamic>> row(String kind, String key) async =>
      (await db.getAll(
        'SELECT * FROM local_state WHERE state_kind=? AND state_key=?',
        [kind, key],
      )).single;
  Future<Map<String, Object?>> payload(String kind, String key) async =>
      Map<String, Object?>.from(
        jsonDecode(
              utf8.decode(
                ((await row(kind, key))['payload_bytes'] as List).cast<int>(),
              ),
            )
            as Map,
      );
  Future<IssuedNotificationToken> token() async =>
      (await drafts.notificationToken())!;
  Future<void> unrelatedAutosave() async {
    final before = (await row('timer', 'active'))['revision'] as int;
    c.notifyListeners();
    await c.flushPersistence();
    expect((await row('timer', 'active'))['revision'], before + 1);
  }

  Future<void> putReceipt(Map<String, Object?> value, String status) =>
      actions.writeTransaction((tx) async {
        final old = await tx.localState(
          LocalStateKind.timer,
          notificationActionKey,
        );
        await tx.putLocalState(
          LocalStateKind.timer,
          notificationActionKey,
          localBytes(value),
          expectedRevision: old?['revision'] as int? ?? 0,
          status: status,
        );
      });

  Future<NotificationConsumption> decide(
    NotificationIntent intent, {
    DateTime? now,
  }) async {
    final before = await db.store.inventory();
    final outcome = await consumeNotificationIntent(actions, intent, now: now);
    if (outcome.outcome != NotificationOutcome.applied) {
      expect(await db.store.inventory(), before, reason: outcome.marker);
    }
    return outcome;
  }

  test(
    'token rule: autosaves keep the token, each applied step advances it, an in-app rest change replaces it',
    () async {
      final first = await token();
      expect(first.step, 1);
      final issuedRevision = first.action.timerRevision;
      await unrelatedAutosave();
      final again = await token();
      expect(again.action.encode(), first.action.encode());
      expect(again.step, 1);
      // The issued branch never compares the timer revision.
      final one = intentFor(first.action, 1);
      final applied = await c.applyNotificationIntent(one);
      expect(applied!.outcome, NotificationOutcome.applied);
      expect(c.restTotal, 630);
      expect(applied.change!.restEndedAt, isNull);
      final timer = await row('timer', 'active');
      expect(timer['revision'], greaterThan(issuedRevision + 1));
      final receipt = await payload('timer', notificationActionKey);
      expect((await row('timer', notificationActionKey))['status'], 'consumed');
      expect(receipt['consumed_step'], 1);
      expect(receipt['last_intent_id'], one.intentId);
      expect(receipt['kind'], 'add');
      expect(receipt['rest_total'], 630);
      expect(receipt['rest_start'], c.restStart!.toIso8601String());
      expect(receipt['basis'], {
        'draft_id': c.draft.draftId,
        'rest_start': c.restStart!.toIso8601String(),
        'rest_total': 600,
      });
      expect(
        (await payload('timer', 'active'))['restTotal'],
        630,
        reason: 'the timer is written at its current revision',
      );

      await unrelatedAutosave();
      // A redelivered step is a duplicate even after later autosaves.
      expect(
        (await decide(one)).outcome,
        NotificationOutcome.duplicate,
        reason: 'no consumed-branch revision check',
      );
      final second = await token();
      expect(second.action.encode(), first.action.encode());
      expect(second.step, 2);
      await unrelatedAutosave();
      expect((await token()).step, 2);

      // Another tap that carried the same visible step: refused.
      expect(
        (await decide(intentFor(first.action, 1))).marker,
        'refused conflict',
      );
      expect((await decide(intentFor(first.action, 3))).marker, 'refused gap');
      final two = intentFor(first.action, 2);
      expect(
        (await c.applyNotificationIntent(two))!.outcome,
        NotificationOutcome.applied,
      );
      expect(c.restTotal, 660);
      expect((await token()).step, 3);
      expect((await decide(two)).outcome, NotificationOutcome.duplicate);
      expect((await decide(one)).marker, 'refused conflict');

      c.addRestTime(1);
      await c.flushPersistence();
      final fresh = await token();
      expect(fresh.action.token, isNot(first.action.token));
      expect(fresh.step, 1);
      expect(
        (await decide(intentFor(first.action, 3))).marker,
        'refused token_superseded',
      );
      expect(c.restTotal, 661);
      expect((await drafts.load())!.restTotal, 661);
      expect(await db.getAll('SELECT * FROM operations'), isEmpty);
    },
  );

  test(
    'Skip ends the rest at the tap time in draft, timer, receipt and controller',
    () async {
      final issued = await token();
      final tapped = DateTime.now().toUtc();
      final skip = intentFor(
        issued.action,
        1,
        kind: NotificationIntentKind.skip,
        tappedAt: tapped,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final outcome = (await c.applyNotificationIntent(skip))!;
      expect(outcome.outcome, NotificationOutcome.applied);
      expect(outcome.change!.restStart, isNull);
      expect(outcome.change!.restTotal, 0);
      expect(outcome.change!.restEndedAt, tapped.toLocal());
      expect(c.restStart, isNull);
      expect(c.restTotal, 0);
      expect(c.restEndedAt, tapped.toLocal(), reason: 'not the adoption time');
      for (final kind in ['draft', 'timer']) {
        final value = await payload(kind, 'active');
        expect(value['restStart'], isNull, reason: kind);
        expect(value['restTotal'], 0, reason: kind);
        expect(
          value['restEndedAt'],
          tapped.toLocal().toIso8601String(),
          reason: kind,
        );
      }
      final receipt = await payload('timer', notificationActionKey);
      expect(receipt['kind'], 'skip');
      expect(receipt['rest_start'], isNull);
      expect(receipt['rest_total'], 0);
      expect(receipt['rest_ended_at'], tapped.toLocal().toIso8601String());
      await c.flushPersistence();
      expect((await drafts.load())!.restEndedAt, tapped.toLocal());
      final next = await token();
      expect(next.action.token, issued.action.token);
      expect(next.step, 2);
      // Nothing is running any more: a later step has no rest to change.
      expect(
        (await decide(intentFor(issued.action, 2))).marker,
        'refused late',
      );
      expect(await db.getAll('SELECT * FROM operations'), isEmpty);
    },
  );

  test(
    'mixed +30s and Skip at one step: only the first arrival applies',
    () async {
      final issued = await token();
      final add = intentFor(issued.action, 1);
      final skip = intentFor(
        issued.action,
        1,
        kind: NotificationIntentKind.skip,
      );
      expect((await decide(skip)).outcome, NotificationOutcome.applied);
      expect((await decide(add)).marker, 'refused conflict');
      expect((await decide(skip)).outcome, NotificationOutcome.duplicate);
      // The same intent ID with another kind is not the committed tap.
      expect(
        (await decide(
          NotificationIntent(
            intentId: skip.intentId,
            actionId: skip.actionId,
            kind: NotificationIntentKind.add,
            tappedAt: skip.tappedAt,
            payload: skip.payload,
          ),
        )).marker,
        'refused conflict',
      );
      expect((await payload('timer', 'active'))['restTotal'], 0);
    },
  );

  test(
    'an in-app rest change wins: the ticker stopping the rest refuses a pending +30s',
    () async {
      final issued = await token();
      c.stopRest();
      await c.flushPersistence();
      expect(
        (await decide(intentFor(issued.action, 1))).marker,
        'refused basis_changed',
      );
      c.startRest(90);
      await c.flushPersistence();
      expect(
        (await decide(intentFor(issued.action, 1))).marker,
        'refused basis_changed',
      );
      expect(c.restTotal, 90);
    },
  );

  test('tap-time checks: late and clock refusals write nothing', () async {
    final issued = await token();
    final start = c.restStart!;
    final due = start.add(const Duration(seconds: 600));
    for (final kind in NotificationIntentKind.values) {
      expect(
        (await decide(
          intentFor(issued.action, 1, kind: kind, tappedAt: due),
          now: due.add(const Duration(seconds: 5)),
        )).marker,
        'refused late',
        reason: kind.wire,
      );
      expect(
        (await decide(
          intentFor(
            issued.action,
            1,
            kind: kind,
            tappedAt: start.subtract(const Duration(milliseconds: 1)),
          ),
        )).marker,
        'refused clock',
        reason: kind.wire,
      );
      final now = DateTime.now();
      expect(
        (await decide(
          intentFor(
            issued.action,
            1,
            kind: kind,
            tappedAt: now.add(const Duration(minutes: 3)),
          ),
          now: now,
        )).marker,
        'refused clock',
        reason: kind.wire,
      );
    }
    // Judged at the tap, not at the decision: a tap inside the rest still
    // applies after the rest would have ended.
    final inside = intentFor(
      issued.action,
      1,
      tappedAt: due.subtract(const Duration(seconds: 1)),
    );
    final outcome = await decide(
      inside,
      now: due.add(const Duration(minutes: 1)),
    );
    expect(outcome.outcome, NotificationOutcome.applied);
    expect(outcome.change!.restTotal, 630);
  });

  test(
    'application, profile, generation, draft and token fences are exact no-op refusals',
    () async {
      final issued = await token();
      final action = issued.action;
      for (final entry in {
        'application_id': ('dev.animusstudio.alkion', 'refused foreign'),
        'profile_id': ('foreign-profile', 'refused foreign'),
        'generation': (action.generation + 1, 'refused stale_generation'),
        'draft_id': ('old-draft', 'refused draft_not_active'),
        'rest_start': (
          DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String(),
          'refused token_superseded',
        ),
        'timer_revision': (
          action.timerRevision + 1,
          'refused token_superseded',
        ),
        'token': ('not-issued', 'refused token_superseded'),
      }.entries) {
        final changed = NotificationAction.decode(
          jsonEncode(action.toJson()..[entry.key] = entry.value.$1),
        )!;
        expect(
          (await decide(intentFor(changed, 1))).marker,
          entry.value.$2,
          reason: entry.key,
        );
      }
      expect(NotificationAction.decode('{bad'), isNull);
      expect(
        NotificationAction.decode(
          jsonEncode(action.toJson()..['root'] = '/arbitrary'),
        ),
        isNull,
      );
      await c.discard();
      expect(
        (await decide(intentFor(action, 1))).marker,
        'refused draft_not_active',
      );
    },
  );

  test(
    'legacy receipts: an issued one gets its basis at first sight, a consumed one counts as step 1',
    () async {
      final issued = await token();
      final action = issued.action;
      final restStart = c.restStart!.toIso8601String();
      await putReceipt({'action': action.toJson()}, 'issued');
      final pinned = await token();
      expect(pinned.action.encode(), action.encode());
      expect(pinned.step, 1);
      expect(await payload('timer', notificationActionKey), {
        'action': action.toJson(),
        'basis': {
          'draft_id': c.draft.draftId,
          'rest_start': restStart,
          'rest_total': 600,
        },
      });

      // Unpinned, a legacy issued receipt is judged by its rest_start and
      // the current restTotal; a bare legacy tap is step 1 of an add.
      await putReceipt({'action': action.toJson()}, 'issued');
      expect(await c.applyNotificationAction(action), isTrue);
      expect(c.restTotal, 630);
      expect((await payload('timer', notificationActionKey))['basis'], {
        'draft_id': c.draft.draftId,
        'rest_start': restStart,
        'rest_total': 600,
      });

      final revision = (await row('draft', 'active'))['revision'];
      await putReceipt({
        'action': action.toJson(),
        'draft_revision': revision,
        'rest_total': 630,
      }, 'consumed');
      final next = await token();
      expect(next.action.encode(), action.encode());
      expect(next.step, 2);
      expect(await c.applyNotificationAction(action), isFalse);
      expect(
        (await decide(legacyNotificationIntent(action))).marker,
        'refused conflict',
      );
      expect(c.restTotal, 630);
      final two = await c.applyNotificationIntent(intentFor(action, 2));
      expect(two!.outcome, NotificationOutcome.applied);
      expect(c.restTotal, 660);
      final receipt = await payload('timer', notificationActionKey);
      expect(receipt['consumed_step'], 2);
      expect(receipt['basis'], {
        'draft_id': c.draft.draftId,
        'rest_start': restStart,
        'rest_total': 630,
      });
    },
  );

  test(
    'a stale later step is refused basis_changed after an in-app change, with no token refresh',
    () async {
      final issued = await token();
      expect(
        (await c.applyNotificationIntent(intentFor(issued.action, 1)))!.outcome,
        NotificationOutcome.applied,
      );
      c.addRestTime(1);
      await c.flushPersistence();
      expect((await payload('timer', 'active'))['restTotal'], 631);
      for (final kind in NotificationIntentKind.values) {
        expect(
          (await decide(intentFor(issued.action, 2, kind: kind))).marker,
          'refused basis_changed',
          reason: kind.wire,
        );
      }
      expect(c.restTotal, 631);
      expect((await drafts.load())!.restTotal, 631);
      expect(c.resting, isTrue);
    },
  );

  test(
    'reconciling a committed intent after SQL moved on adopts the durable rest and revision',
    () async {
      final issued = await token();
      final intent = intentFor(issued.action, 1);
      actions.fail = actions.afterCommit = true;
      await expectLater(c.applyNotificationIntent(intent), throwsStateError);
      actions.fail = false;
      expect(c.restTotal, 600);
      // No owner path writes the draft while the intent is uncertain; an
      // out-of-band writer stands in for one, so the duplicate's committed
      // step is no longer what SQL holds.
      await actions.writeTransaction((tx) async {
        for (final kind in [LocalStateKind.draft, LocalStateKind.timer]) {
          final row = (await tx.localState(kind, 'active'))!;
          final value = Map<String, Object?>.from(
            jsonDecode(utf8.decode((row['payload_bytes'] as List).cast<int>()))
                as Map,
          )..['restTotal'] = 700;
          await tx.putLocalState(
            kind,
            'active',
            localBytes(value),
            expectedRevision: row['revision'] as int,
          );
        }
      });
      final outcome = (await c.applyNotificationIntent(intent))!;
      expect(outcome.outcome, NotificationOutcome.duplicate);
      expect(drafts.pendingNotificationIntent, isNull);
      expect(c.restTotal, 700);
      expect(
        drafts.persistedRevision,
        (await row('draft', 'active'))['revision'],
      );
      c.addRestTime(1);
      await c.flushPersistence();
      expect(c.persistenceError, isNull);
      expect((await drafts.load())!.restTotal, 701);
    },
  );

  for (final after in [false, true]) {
    test(
      'intent ${after ? 'forwarded' : 'refused'} COMMIT retains the exact intent and never applies it twice',
      () async {
        final issued = await token();
        final intent = intentFor(issued.action, 1);
        final before = await db.store.inventory();
        actions.fail = true;
        actions.afterCommit = after;
        await expectLater(c.applyNotificationIntent(intent), throwsStateError);
        expect(c.restTotal, 600);
        expect(drafts.pendingNotificationIntent!.encode(), intent.encode());
        if (!after) expect(await db.store.inventory(), before);
        // Another intent cannot pass the uncertain one.
        await expectLater(
          drafts.consumeAction(intentFor(issued.action, 1)),
          throwsA(isA<StoreException>()),
        );
        actions.fail = false;
        final retried = (await c.applyNotificationIntent(intent))!;
        expect(
          retried.outcome,
          after ? NotificationOutcome.duplicate : NotificationOutcome.applied,
        );
        expect(drafts.pendingNotificationIntent, isNull);
        expect(c.restTotal, 630);
        final committed = await db.store.inventory();
        final again = (await c.applyNotificationIntent(intent))!;
        expect(again.outcome, NotificationOutcome.duplicate);
        expect(again.change!.restTotal, 630);
        expect(await db.store.inventory(), committed);
        expect(c.restTotal, 630);
        expect((await token()).step, 2);
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
