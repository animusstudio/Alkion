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
