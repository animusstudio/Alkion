import 'package:flutter/material.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/session/session_summary_screen.dart';
import '../support/app_fonts.dart';
import '../support/screen_harness.dart' show setPhone;
import '../alkion/acceptance/acceptance_support.dart'
    show act, mountReal, realSettle, settleUntil, settleWhile, startWorkout;
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'package:alkion/main.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/session/notification_action.dart';
import 'package:alkion/session/workout_notification.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/session_manager.dart';

class FakeDraftStore extends DraftStore {
  FakeDraftStore({this.draft});
  SessionDraft? draft;

  @override
  Future<SessionDraft?> load() async => draft;

  @override
  Future<void> save(SessionDraft d) async => draft = d;

  @override
  Future<void> clear() async => draft = null;
}

class FakeWorkoutNotification extends WorkoutNotification {
  FakeWorkoutNotification({this.launch, this.problem}) : super(isAndroid: true);
  final NotificationResponse? launch;
  final NotificationLimitation? problem;
  @override
  NotificationLimitation? get limitation => problem;
  final shown = <int>[];
  int cancels = 0, closes = 0;
  @override
  Future<NotificationResponse?> init({
    required void Function(NotificationResponse) onResponse,
  }) async => launch;
  @override
  Future<void> showFor({
    required String name,
    required DateTime startedAt,
    DateTime? restStart,
    int restTotal = 0,
    NotificationAction? action,
  }) async {
    shown.add(restTotal);
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Future<void> close() async {
    closes++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('register/clear lifecycle notifies', () {
    final m = SessionManager();
    addTearDown(m.dispose);
    var notifies = 0;
    m.addListener(() => notifies++);

    final c = ActiveSessionController();
    addTearDown(c.dispose);
    c.seedEmpty(name: 'Custom', focus: '');
    m.register(c);
    expect(m.hasActive, isTrue);
    expect(m.active, same(c));

    m.clear();
    expect(m.hasActive, isFalse);
    expect(notifies, 2);
  });

  test('controller discard auto-clears the manager', () async {
    final m = SessionManager();
    addTearDown(m.dispose);
    final c = ActiveSessionController();
    addTearDown(c.dispose);
    c.seedEmpty(name: 'Custom', focus: '');
    m.register(c);

    await c.discard(); // draft → null → manager clears itself
    expect(m.hasActive, isFalse);
  });

  test('resumeFromDraft restores a session from disk', () async {
    final store = FakeDraftStore(
      draft: SessionDraft(
        templateId: null,
        name: 'Upper A',
        focus: 'Push',
        startedAt: DateTime(2026, 6, 3, 9, 0),
        blocks: [],
      ),
    );
    final m = SessionManager();
    addTearDown(m.dispose);
    final resumed = await m.resumeFromDraft(store: store);
    expect(resumed, isTrue);
    expect(m.hasActive, isTrue);
    expect(m.active!.draft.name, 'Upper A');
    expect(m.active!.draft.startedAt, DateTime(2026, 6, 3, 9, 0));
  });

  test('resumeFromDraft without a draft is a no-op', () async {
    final m = SessionManager();
    addTearDown(m.dispose);
    final resumed = await m.resumeFromDraft(store: FakeDraftStore());
    expect(resumed, isFalse);
    expect(m.hasActive, isFalse);
  });

  test(
    'cold +30 waits for selected runtime/draft ownership, mirrors committed rest and resumes one controller',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'alkion-notification-cold-',
      );
      final root = Directory('${temp.path}/${AlkionIdentity.applicationId}');
      var runtime = await AlkionRuntime.open(root);
      try {
        final c = ActiveSessionController(
          draftStore: runtime.sessions.draftStore,
        );
        c.seedEmpty(name: 'Synthetic workout', focus: '');
        c.startRest(600);
        runtime.sessions.register(c);
        await runtime.flushPersistence();
        final action = (await runtime.sessions.draftStore!
            .notificationAction())!;
        await runtime.close();
        c.dispose();
        final response = NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: AlkionIdentity.addRestAction,
          payload: action.encode(),
        );
        final notifier = FakeWorkoutNotification(launch: response);
        runtime = await AlkionRuntime.open(root, notifications: notifier);
        final owner = runtime.sessions.active!;
        expect(owner.restTotal, 630);
        expect(notifier.shown, isNotEmpty);
        expect(notifier.shown.every((value) => value == 630), isTrue);
        expect(runtime.sessions.takeNotificationOpenRequest(), isTrue);
        final committed = await runtime.store.inventory();
        await runtime.sessions.handleNotificationResponse(response);
        expect(runtime.sessions.active, same(owner));
        expect(owner.restTotal, 630);
        expect(await runtime.store.inventory(), committed);
        expect(runtime.sessions.takeNotificationOpenRequest(), isFalse);
        expect(await runtime.sessions.resumeFromDraft(), isTrue);
        expect(runtime.sessions.active, same(owner));
        await runtime.sessions.handleNotificationResponse(
          NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotification,
            payload: action.encode(),
          ),
        );
        expect(runtime.sessions.takeNotificationOpenRequest(), isTrue);
        runtime.sessions.clear();
        await Future<void>.delayed(Duration.zero);
        expect(notifier.cancels, greaterThan(0));
        await runtime.sessions.handleNotificationResponse(response);
        expect(runtime.sessions.active, isNull);
        expect(runtime.sessions.takeNotificationOpenRequest(), isFalse);
        owner.dispose();
        await runtime.close();
        expect(notifier.closes, greaterThan(0));
      } finally {
        if (runtime.store.admission != StoreAdmission.closed) {
          await runtime.close();
        }
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'denial leaves logging/finish usable; expired cold action reconciles the original absolute deadline',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'alkion-notification-denied-',
      );
      final root = Directory('${temp.path}/${AlkionIdentity.applicationId}');
      var runtime = await AlkionRuntime.open(root);
      try {
        final c = ActiveSessionController(
          draftStore: runtime.sessions.draftStore,
        );
        c.seedEmpty(name: 'Synthetic workout', focus: '');
        final start = DateTime.now().subtract(const Duration(minutes: 5));
        c.setRestRaw(start, 60);
        runtime.sessions.register(c);
        await runtime.flushPersistence();
        final expired = (await runtime.sessions.draftStore!
            .notificationAction())!;
        await runtime.close();
        c.dispose();
        final notifier = FakeWorkoutNotification(
          problem: NotificationLimitation.denied,
          launch: NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotificationAction,
            actionId: AlkionIdentity.addRestAction,
            payload: expired.encode(),
          ),
        );
        runtime = await AlkionRuntime.open(root, notifications: notifier);
        await runtime.flushPersistence();
        final owner = runtime.sessions.active!;
        expect(owner.restStart, isNull);
        expect(owner.restEndedAt, start.add(const Duration(seconds: 60)));
        expect(runtime.sessions.takeNotificationOpenRequest(), isFalse);
        expect(
          runtime.sessions.notificationLimitation,
          NotificationLimitation.denied,
        );
        owner.startRest(120);
        await owner.flushPersistence();
        expect((await runtime.sessions.draftStore!.load())!.restTotal, 120);
        await owner.commitFinish(WorkoutRepository.local(runtime.store));
        expect(runtime.sessions.active, isNull);
        expect(await runtime.sessions.draftStore!.load(), isNull);
        await Future<void>.delayed(Duration.zero);
        expect(notifier.cancels, greaterThan(0));
        owner.dispose();
      } finally {
        if (runtime.store.admission != StoreAdmission.closed) {
          await runtime.close();
        }
        await temp.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'real runtime repeated Finish and lifecycle barriers preserve one workout',
    (tester) async {
      final temp = await tester.runAsync(
        () => Directory.systemTemp.createTemp('alkion-finish-ui-'),
      );
      final root = Directory('${temp!.path}/${AlkionIdentity.applicationId}');
      AlkionRuntime? runtime;
      ActiveSessionController? owner;
      final failures = <Object>[];
      try {
        await tester.runAsync(() async {
          await preloadAppFonts();
          runtime = await AlkionRuntime.open(root);
          final exercises = ExerciseRepository.local(runtime!.store);
          final exercise = await exercises.createExercise(
            ExerciseDraft(
              name: 'Synthetic finish',
              muscleGroup: 'chest',
              compound: false,
              baseWeightKg: 20,
              plateStepKg: 2.5,
              defaultWorkingSets: 1,
              defaultWarmupSets: 0,
              defaultRepLow: 5,
              defaultRepHigh: 5,
            ),
          );
          await DayTemplateRepository.local(runtime!.store).saveDay(
            draft: DayDraft(
              name: 'Synthetic day',
              slots: [
                SlotDraft(exerciseId: exercise, workSets: 1, warmupSets: 0),
              ],
            ),
          );
        });
        runtime!.persistenceFailure.addListener(() {
          final error = runtime!.persistenceFailure.value;
          if (error != null) failures.add(error);
        });
        setPhone(tester, width: 412);
        await mountReal(tester, AlkionApp(runtime: runtime!));
        await realSettle(tester, ticks: 10);
        await settleUntil(tester, startWorkout());
        await act(tester, () async {
          await tester.ensureVisible(startWorkout());
          await tester.tap(startWorkout());
        });
        await settleUntil(tester, find.byType(ActiveSessionScreen));
        owner = runtime!.sessions.active!;
        expect(owner.draft.blocks, hasLength(1));
        final set = owner.draft.blocks.single.workingSets.single;
        // The real launch has persisted the initial draft before exposing Finish.
        expect(
          await tester.runAsync(() => runtime!.sessions.draftStore!.load()),
          isNotNull,
        );
        await act(
          tester,
          () => tester.tap(find.byKey(const Key('log-set-bar'))),
        );
        await realSettle(tester, ticks: 3);
        expect(set.done, isTrue);
        // Two callbacks on the same synchronous stack must navigate only once.
        final finish = tester
            .widget<FilledButton>(find.byKey(const Key('log-set-bar')))
            .onPressed!;
        late Future<void> barrier;
        late String sessionId, operationId, hash;
        await tester.runAsync(() async {
          final queued = runtime!.flushPersistence();
          finish();
          final intent = owner!.pendingFinish!;
          sessionId = intent.action.target.id;
          operationId = intent.action.operationId;
          hash = intent.action.hash;
          finish();
          barrier = Future.wait([
            queued,
            runtime!.flushPersistence(),
          ]).then((_) {});
          runtime!.didChangeAppLifecycleState(AppLifecycleState.inactive);
          runtime!.sessions.didChangeAppLifecycleState(
            AppLifecycleState.inactive,
          );
        });
        await tester.runAsync(
          () => barrier.timeout(const Duration(seconds: 5)),
        );
        // The old route can still receive a tap while replacement animates.
        await act(tester, finish);
        await settleUntil(tester, find.byType(SessionSummaryScreen));
        await settleWhile(
          tester,
          () => find.byType(ActiveSessionScreen).evaluate().isNotEmpty,
        );
        expect(find.byType(SessionSummaryScreen), findsOneWidget);
        expect(find.byType(ActiveSessionScreen), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(runtime!.persistenceFailure.value, isNull);
        expect(failures, isEmpty);
        expect(tester.takeException(), isNull);
        late Map<String, Object?> saved;
        await tester.runAsync(() async {
          final rows = await runtime!.store.getAll('SELECT * FROM sessions');
          expect(rows.single['id'], sessionId);
          final stored = (await runtime!.store.getAll(
            'SELECT * FROM sets',
          )).single;
          expect(stored['id'], set.id);
          expect(double.parse(stored['weight_kg'] as String), 20);
          expect(stored['reps'], 5);
          final operations = await runtime!.store.getAll(
            "SELECT * FROM operations WHERE action='workoutFinish'",
          );
          expect(operations.single['operation_id'], operationId);
          expect(operations.single['input_hash'], hash);
          expect(await runtime!.sessions.draftStore!.load(), isNull);
          expect(runtime!.sessions.lastFinished!.sessionId, rows.single['id']);
          saved = await runtime!.store.inventory();
        });
        await mountReal(tester, const SizedBox());
        await realSettle(tester, ticks: 3);
        await tester.runAsync(() async {
          await runtime!.close();
          runtime = null;
          owner!.dispose();
          owner = null;
          for (var i = 0; i < 2; i++) {
            runtime = await AlkionRuntime.open(root);
            expect(await runtime!.store.inventory(), saved);
            expect(runtime!.sessions.hasActive, isFalse);
            expect(runtime!.sessions.lastFinished!.sessionId, sessionId);
            await runtime!.close();
            runtime = null;
          }
        });
      } finally {
        await mountReal(tester, const SizedBox());
        await realSettle(tester, ticks: 3);
        await tester.runAsync(() async {
          await runtime?.close();
          owner?.dispose();
          await temp.delete(recursive: true);
        });
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  for (final problem in NotificationLimitation.values) {
    testWidgets('runtime notification feedback for ${problem.name}', (
      tester,
    ) async {
      final temp = await tester.runAsync(
        () => Directory.systemTemp.createTemp('alkion-notification-feedback-'),
      );
      AlkionRuntime? runtime;
      try {
        await tester.runAsync(() async {
          await preloadAppFonts();
          runtime = await AlkionRuntime.open(
            Directory('${temp!.path}/${AlkionIdentity.applicationId}'),
            notifications: FakeWorkoutNotification(problem: problem),
          );
        });
        await mountReal(tester, AlkionApp(runtime: runtime!));
        await realSettle(tester, ticks: 5);
        final l = AppLocalizations.of(appNavigatorKey.currentContext!);
        expect(find.text(l.alkionNotificationsInexact), findsNothing);
        if (problem == NotificationLimitation.inexact) {
          expect(find.byType(SnackBar), findsNothing);
        } else {
          expect(
            find.text(
              problem == NotificationLimitation.denied
                  ? l.alkionNotificationsDenied
                  : l.alkionNotificationsUnavailable,
            ),
            findsOneWidget,
          );
        }
        expect(runtime!.sessions.notificationLimitation, problem);
      } finally {
        await mountReal(tester, const SizedBox());
        await realSettle(tester, ticks: 3);
        await tester.runAsync(() async {
          await runtime?.close();
          await temp!.delete(recursive: true);
        });
      }
    });
  }

  test('screenOpen flag notifies on change only', () {
    final m = SessionManager();
    addTearDown(m.dispose);
    var notifies = 0;
    m.addListener(() => notifies++);
    m.screenOpen = true;
    m.screenOpen = true; // no-op
    m.screenOpen = false;
    expect(notifies, 2);
  });
}
