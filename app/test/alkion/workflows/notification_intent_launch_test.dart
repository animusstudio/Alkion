import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show AppLifecycleState, IsolateNameServer;

import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/main.dart';
import 'package:alkion/recovery/backup.dart' as backup;
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/notification_action.dart';
import 'package:alkion/session/notification_background.dart';
import 'package:alkion/session/notification_envelope.dart';
import 'package:alkion/session/notification_journal.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/session/workout_notification.dart';
import 'package:alkion/store/local_store.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../data/workflow_state_quarantine_test.dart' show seed;
import '../../support/recording_notification.dart';
import '../../support/notification_intent_crash.dart'
    show notificationIntentCrashCuts;

NotificationResponse actionTap(String actionId, String? payload) =>
    NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      id: 4101,
      actionId: actionId,
      payload: payload,
    );

Map<String, Object?> decodeRow(Map<String, dynamic> row) =>
    Map<String, Object?>.from(
      jsonDecode(utf8.decode((row['payload_bytes'] as List).cast<int>()))
          as Map,
    );

Future<void> until(
  bool Function() done, {
  Duration timeout = const Duration(seconds: 15),
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp, root, journalDirectory;
  late List<RestMirror> renders;
  late List<AlkionRuntime> runtimes;
  late List<ActiveSessionController> controllers;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('alkion-notification-launch-');
    root = Directory(p.join(temp.path, AlkionIdentity.applicationId));
    journalDirectory = notificationJournalDirectory(root);
    renders = [];
    runtimes = [];
    controllers = [];
    IsolateNameServer.removePortNameMapping(notificationPortName);
  });

  tearDown(() async {
    for (final runtime in runtimes) {
      if (runtime.store.admission != StoreAdmission.closed) {
        await runtime.close();
      }
    }
    for (final c in controllers) {
      c.dispose();
    }
    IsolateNameServer.removePortNameMapping(notificationPortName);
    await temp.delete(recursive: true);
  });

  /// The real background handler with a fake renderer and the real port
  /// lookup (or none, for a wake-up that never arrives).
  Future<NotificationBackgroundOutcome> tap(
    String actionId,
    String? payload, {
    DateTime? at,
    bool wake = true,
  }) => deliverNotificationResponse(
    actionTap(actionId, payload),
    background: NotificationBackground(
      journalDirectory: () async => journalDirectory,
      wakeOwner: wake ? wakeNotificationOwner : () => false,
      render: (mirror) async => renders.add(mirror),
      exact: () async => true,
      clock: at == null ? null : () => at.toUtc(),
    ),
  );

  Future<NotificationBackgroundOutcome> add(
    String? payload, {
    DateTime? at,
    bool wake = true,
  }) => tap(AlkionIdentity.addRestAction, payload, at: at, wake: wake);

  Future<NotificationBackgroundOutcome> skip(String? payload, {DateTime? at}) =>
      tap(AlkionIdentity.skipRestAction, payload, at: at);

  Future<AlkionRuntime> open({
    WorkoutNotification? notifications,
    Future<void> Function(String phase)? openCheckpoint,
    void Function(SessionManager sessions)? onSessions,
  }) async {
    final runtime = await AlkionRuntime.open(
      root,
      notifications: notifications ?? RecordingNotification(),
      openCheckpoint: openCheckpoint,
      onSessions: onSessions,
    );
    runtimes.add(runtime);
    final owner = runtime.sessions.active;
    if (owner != null) controllers.add(owner);
    return runtime;
  }

  /// Starts a synthetic workout resting [total] seconds and returns the
  /// controller once its mirror has been posted.
  Future<ActiveSessionController> startResting(
    AlkionRuntime runtime, {
    DateTime? restStart,
    int total = 600,
  }) async {
    final c = ActiveSessionController(draftStore: runtime.sessions.draftStore);
    controllers.add(c);
    c.seedEmpty(name: 'Synthetic workout', focus: '');
    if (restStart == null) {
      c.startRest(total);
    } else {
      c.setRestRaw(restStart, total);
    }
    runtime.sessions.register(c);
    await runtime.flushPersistence();
    return c;
  }

  Future<Map<String, Object?>> sqlRow(
    LocalDatabase db,
    LocalStateKind kind,
    String key,
  ) => db.readTransaction(
    (tx) async => decodeRow((await tx.localState(kind, key))!),
  );

  Future<Map<String, Object?>> receipt(LocalDatabase db) =>
      sqlRow(db, LocalStateKind.timer, notificationActionKey);

  Future<List<NotificationJournalEntry>> journal() =>
      NotificationJournal(journalDirectory).read();

  /// Waits for the owner to decide everything queued for it.
  Future<void> settled(AlkionRuntime runtime) async {
    await until(
      () =>
          !journalDirectory.existsSync() || journalDirectory.listSync().isEmpty,
      reason: 'an empty journal',
    );
    await runtime.sessions.notificationWorkIdle();
  }

  /// A runtime's workout resting 600 s, its posted payload, then a clean
  /// close: the state a killed process leaves behind.
  Future<String> postedThenClosed() async {
    final notifier = RecordingNotification();
    final runtime = await open(notifications: notifier);
    await startResting(runtime);
    final payload = notifier.payload!;
    await runtime.close();
    return payload;
  }

  group('A1, A2, A6 visible taps with the owner running', () {
    test(
      'repeated +30s taps on the same visible notification all apply; '
      'taps before the update count once; Skip ends the rest; no route',
      () async {
        final notifier = RecordingNotification();
        final runtime = await open(notifications: notifier);
        final c = await startResting(runtime);
        final sessions = runtime.sessions;
        expect(sessions.notificationPortMode, NotificationPortMode.immediate);
        final first = notifier.payload!;
        expect(NotificationEnvelope.decode(first)!.step, 1);

        expect(await add(first), NotificationBackgroundOutcome.handedOff);
        await until(() => c.restTotal == 630, reason: 'first +30s');
        await settled(runtime);
        final second = notifier.payload!;
        final envelope = NotificationEnvelope.decode(second)!;
        expect(envelope.step, 2);
        expect(
          envelope.action.encode(),
          NotificationEnvelope.decode(first)!.action.encode(),
          reason: 'the same token carries the next step',
        );
        expect(envelope.view!.restTotal, 630);
        expect(
          notifier.mirrors.where((m) => m.force && m.restTotal == 630),
          isNotEmpty,
          reason: 'a decided intent ends with a forced refresh',
        );

        // The gate: a second +30s on the same visible notification applies.
        expect(await add(second), NotificationBackgroundOutcome.handedOff);
        await until(() => c.restTotal == 660, reason: 'second +30s');
        await settled(runtime);
        expect(NotificationEnvelope.decode(notifier.payload!)!.step, 3);

        // Two taps before the visible update share one step: one applies.
        final third = notifier.payload!;
        await Future.wait([add(third), add(third)]);
        await settled(runtime);
        expect(c.restTotal, 690);
        expect((await receipt(runtime.store))['consumed_step'], 3);

        final before = DateTime.now();
        expect(
          await skip(notifier.payload),
          NotificationBackgroundOutcome.handedOff,
        );
        await until(() => c.restStart == null, reason: 'Skip');
        await settled(runtime);
        expect(c.restTotal, 0);
        expect(c.restEndedAt, isNotNull);
        expect(c.restEndedAt!.isBefore(before), isFalse);
        final timer = await sqlRow(
          runtime.store,
          LocalStateKind.timer,
          'active',
        );
        expect(timer['restStart'], isNull);
        expect(timer['restTotal'], 0);
        expect(notifier.mirrors.last.restStart, isNull);
        expect(renders, isEmpty, reason: 'the owner renders, not the handler');
        expect(sessions.takeNotificationOpenRequest(), isFalse);
      },
    );

    test('backgrounded: applied and re-rendered without coming forward; '
        'the screen shows the same rest on return', () async {
      final notifier = RecordingNotification();
      final runtime = await open(notifications: notifier);
      final c = await startResting(runtime);
      final sessions = runtime.sessions;
      sessions.didChangeAppLifecycleState(AppLifecycleState.paused);
      await sessions.notificationWorkIdle();
      expect(
        await add(notifier.payload),
        NotificationBackgroundOutcome.handedOff,
      );
      await until(() => c.restTotal == 630, reason: 'backgrounded +30s');
      await settled(runtime);
      expect(notifier.mirrors.last.restTotal, 630);
      expect(notifier.mirrors.last.alert, isTrue);
      expect(sessions.takeNotificationOpenRequest(), isFalse);
      sessions.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await sessions.notificationWorkIdle();
      expect(sessions.active, same(c));
      expect(c.restTotal, 630);
      expect(c.restStart, isNotNull);
    });
  });

  test('A3, A4 killed chain: +30s, +30s and Skip through the real handler, '
      'then a real launch applies all three in order', () async {
    final first = await postedThenClosed();
    final token = NotificationEnvelope.decode(first)!.action;
    expect(await add(first), NotificationBackgroundOutcome.rendered);
    var provisional = NotificationEnvelope.decode(renders.last.payload)!;
    expect(provisional.step, 2);
    expect(provisional.view!.restTotal, 630);
    expect(renders.last.alertAtRestEnd, isTrue);
    expect(renders.last.mode.countdown, isTrue);
    expect(
      await add(renders.last.payload),
      NotificationBackgroundOutcome.rendered,
    );
    provisional = NotificationEnvelope.decode(renders.last.payload)!;
    expect(provisional.step, 3);
    expect(provisional.view!.restTotal, 660);
    final skipAt = DateTime.now().toUtc();
    expect(
      await skip(renders.last.payload, at: skipAt),
      NotificationBackgroundOutcome.rendered,
    );
    expect(renders.last.mode.countdown, isFalse, reason: 'elapsed mode');
    expect(await journal(), hasLength(3));

    final notifier = RecordingNotification();
    final runtime = await open(notifications: notifier);
    await settled(runtime);
    final owner = runtime.sessions.active!;
    expect(owner.restStart, isNull);
    expect(owner.restTotal, 0);
    expect(owner.restEndedAt!.toUtc(), skipAt);
    for (final kind in [LocalStateKind.draft, LocalStateKind.timer]) {
      final row = await sqlRow(runtime.store, kind, 'active');
      expect(row['restStart'], isNull);
      expect(row['restTotal'], 0);
      expect(DateTime.parse(row['restEndedAt'] as String).toUtc(), skipAt);
    }
    final kept = await receipt(runtime.store);
    expect(kept['consumed_step'], 3);
    expect(kept['kind'], 'skip');
    expect(await journal(), isEmpty);
    final last = notifier.mirrors.last;
    expect(last.force, isTrue);
    expect(last.restStart, isNull);
    expect(last.action!.encode(), token.encode(), reason: 'the same token');
    expect(last.step, 4, reason: 'the next step');
  });

  group('A13 a tap at each open point is applied exactly once', () {
    for (final point in [
      'quarantined',
      'drained',
      'notifications',
      'drain-2',
      'step-9',
    ]) {
      test(point, () async {
        final payload = await postedThenClosed();
        var tapped = 0;
        var notificationsReady = false;
        Future<void> tapOnce() async {
          if (tapped++ > 0) return;
          await add(payload);
        }

        final notifier = RecordingNotification(
          onInit: point == 'notifications' ? tapOnce : null,
          onShow: point == 'step-9'
              ? (mirror) async {
                  if (mirror.force) await tapOnce();
                }
              : null,
        );
        final runtime = await open(
          notifications: notifier,
          openCheckpoint: (phase) async {
            if (phase == 'notifications-initialized') notificationsReady = true;
            if (phase == point ||
                (point == 'drain-2' &&
                    phase == 'drain-read' &&
                    notificationsReady)) {
              await tapOnce();
            }
          },
        );
        expect(tapped, greaterThan(0), reason: 'the hook ran');
        final owner = runtime.sessions.active!;
        await until(() => owner.restTotal == 630, reason: 'the tap applied');
        await settled(runtime);
        expect(owner.restTotal, 630, reason: 'exactly once');
        expect((await receipt(runtime.store))['consumed_step'], 1);
        expect(
          runtime.sessions.notificationPortMode,
          NotificationPortMode.immediate,
        );
        expect(runtime.sessions.drainOwed, isFalse);
        expect(notifier.mirrors.last.restTotal, 630);
        expect(NotificationEnvelope.decode(notifier.payload)!.step, 2);
        expect(await journal(), isEmpty);
      });
    }
  });

  test('A14 a failed open leaves no port and the store closed; a later tap '
      'renders provisionally', () async {
    final payload = await postedThenClosed();
    await expectLater(
      open(
        openCheckpoint: (phase) async {
          if (phase == 'drained') {
            expect(
              IsolateNameServer.lookupPortByName(notificationPortName),
              isNotNull,
            );
            throw const StoreException('synthetic_open_failure');
          }
        },
      ),
      throwsA(isA<StoreException>()),
    );
    expect(IsolateNameServer.lookupPortByName(notificationPortName), isNull);
    expect(await add(payload), NotificationBackgroundOutcome.rendered);
    expect(
      NotificationEnvelope.decode(renders.last.payload)!.view!.restTotal,
      630,
    );
    // The store was closed: a second open is not refused as profile_in_use.
    final runtime = await open();
    await settled(runtime);
    expect(runtime.sessions.active!.restTotal, 630);
  });

  group('A15 ghosts are cancelled at the next open', () {
    test('the unreadable-workout-state quarantine retires the draft', () async {
      final payload = await postedThenClosed();
      expect(await add(payload), NotificationBackgroundOutcome.rendered);
      final profile = await AlkionProfile.open(supportRoot: root);
      final store = await openAlkionStore(profile);
      try {
        await seed(
          store,
          LocalStateKind.draft,
          'active',
          Uint8List.fromList(utf8.encode('{"unreadable":')),
        );
      } finally {
        await store.close();
      }
      final notifier = RecordingNotification();
      final runtime = await open(notifications: notifier);
      await settled(runtime);
      expect(runtime.sessions.active, isNull);
      expect(notifier.cancels, greaterThan(0));
      expect(notifier.mirrors, isEmpty);
      expect(await journal(), isEmpty);
    });

    test('a restore selects a generation with no workout', () async {
      var runtime = await open();
      final schema = runtime.store.schema;
      final backups = await Directory(p.join(temp.path, 'backups')).create();
      final copy = await backup.createBackup(runtime.store, backups);
      final notifier = RecordingNotification();
      await runtime.close();
      runtime = await open(notifications: notifier);
      await startResting(runtime);
      final payload = notifier.payload!;
      await runtime.close();
      expect(await add(payload), NotificationBackgroundOutcome.rendered);
      await RestoreService(root, schema: schema).restore(File(copy.path));
      final next = RecordingNotification();
      runtime = await open(notifications: next);
      await settled(runtime);
      expect(runtime.sessions.active, isNull);
      expect(next.cancels, greaterThan(0));
      expect(next.mirrors, isEmpty);
      expect(await journal(), isEmpty);
    });

    test('an old-generation intent is refused; the restored workout is '
        're-rendered from SQL', () async {
      final notifier = RecordingNotification();
      var runtime = await open(notifications: notifier);
      final schema = runtime.store.schema;
      await startResting(runtime);
      final payload = notifier.payload!;
      final backups = await Directory(p.join(temp.path, 'backups')).create();
      final copy = await backup.createBackup(runtime.store, backups);
      await runtime.close();
      expect(await add(payload), NotificationBackgroundOutcome.rendered);
      await RestoreService(root, schema: schema).restore(File(copy.path));
      final next = RecordingNotification();
      runtime = await open(notifications: next);
      await settled(runtime);
      final owner = runtime.sessions.active!;
      expect(owner.restTotal, 600, reason: 'the refused tap wrote nothing');
      expect(next.mirrors.last.force, isTrue);
      expect(next.mirrors.last.restTotal, 600);
      expect(
        next.mirrors.last.action!.token,
        isNot(NotificationEnvelope.decode(payload)!.action.token),
      );
      expect(await journal(), isEmpty);
    });
  });

  test('A16 during close the port stays registered in closing mode, the '
      'background does not render and the mirror stays cancelled', () async {
    late String payload;
    NotificationBackgroundOutcome? during;
    var atClose = -1;
    Object? registered;
    NotificationPortMode? mode;
    late AlkionRuntime runtime;
    late final RecordingNotification notifier;
    notifier = RecordingNotification(
      onClose: () async {
        atClose = notifier.mirrors.length;
        registered = IsolateNameServer.lookupPortByName(notificationPortName);
        mode = runtime.sessions.notificationPortMode;
        during = await add(payload);
      },
    );
    runtime = await open(notifications: notifier);
    await startResting(runtime);
    payload = notifier.payload!;
    await runtime.close();
    expect(registered, isNotNull);
    expect(mode, NotificationPortMode.closing);
    expect(notifier.closes, greaterThan(0), reason: 'close cancels it');
    expect(during, NotificationBackgroundOutcome.handedOff);
    expect(renders, isEmpty);
    expect(
      notifier.mirrors,
      hasLength(atClose),
      reason: 'no render after close',
    );
    expect(IsolateNameServer.lookupPortByName(notificationPortName), isNull);
    expect(await journal(), hasLength(1), reason: 'the tap waits');
    final next = await open();
    await settled(next);
    expect(next.sessions.active!.restTotal, 630);
  });

  group('A17 rest reconciliation is bounded by the drain', () {
    test('on resumed a journaled +30s extends the rest instead of stopping '
        'it', () async {
      final notifier = RecordingNotification();
      final runtime = await open(notifications: notifier);
      final start = DateTime.now().subtract(const Duration(seconds: 70));
      final c = await startResting(runtime, restStart: start, total: 60);
      expect(c.restStart, isNotNull, reason: 'elapsed, not yet reconciled');
      // A tap 50 s into the rest whose wake-up never arrived.
      expect(
        await add(
          notifier.payload,
          at: start.add(const Duration(seconds: 50)),
          wake: false,
        ),
        NotificationBackgroundOutcome.rendered,
      );
      runtime.sessions.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await runtime.sessions.notificationWorkIdle();
      expect(c.restStart, start);
      expect(c.restTotal, 90);
      expect(await journal(), isEmpty);
    });

    test('an entry that cannot be decided does not keep an elapsed rest '
        'running', () async {
      final runtime = await open();
      final start = DateTime.now().subtract(const Duration(seconds: 70));
      final c = await startResting(runtime, restStart: start, total: 60);
      await journalDirectory.create(recursive: true);
      final stuck = File(
        p.join(
          journalDirectory.path,
          '1-00000000-0000-4000-8000-000000000001.json',
        ),
      )..writeAsStringSync('{}');
      Process.runSync('chmod', ['000', stuck.path]);
      addTearDown(() => Process.runSync('chmod', ['600', stuck.path]));
      runtime.sessions.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await runtime.sessions.notificationWorkIdle();
      expect(c.restStart, isNull);
      expect(c.restEndedAt, start.add(const Duration(seconds: 60)));
      expect(stuck.existsSync(), isTrue, reason: 'the entry stays');
      expect(runtime.persistenceFailure.value, isNotNull);
    });
  });

  test('A18 a legacy foreground +30s applies once and pushes no route; an '
      'unknown or current action in the foreground is ignored', () async {
    final notifier = RecordingNotification();
    final runtime = await open(notifications: notifier);
    final c = await startResting(runtime);
    final sessions = runtime.sessions;
    final bare = (await sessions.draftStore!.notificationAction())!.encode();
    await sessions.handleNotificationResponse(
      actionTap(AlkionIdentity.addRestAction, bare),
    );
    await sessions.notificationWorkIdle();
    expect(c.restTotal, 630);
    expect(sessions.takeNotificationOpenRequest(), isFalse);
    expect(notifier.mirrors.last.restTotal, 630);
    // The update re-posted the same token at the next step.
    expect(NotificationEnvelope.decode(notifier.payload)!.step, 2);
    final committed = await runtime.store.inventory();
    for (final response in [
      actionTap('${AlkionIdentity.addRestAction}-unknown', notifier.payload),
      actionTap(AlkionIdentity.addRestAction, notifier.payload),
      actionTap(AlkionIdentity.skipRestAction, notifier.payload),
      actionTap(AlkionIdentity.skipRestAction, bare),
    ]) {
      await sessions.handleNotificationResponse(response);
    }
    await sessions.notificationWorkIdle();
    expect(c.restTotal, 630);
    expect(c.restStart, isNotNull);
    expect(await runtime.store.inventory(), committed);
    expect(sessions.takeNotificationOpenRequest(), isFalse);
    // A body tap still opens the workout, with either payload form.
    for (final body in [notifier.payload, bare]) {
      await sessions.handleNotificationResponse(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: body,
        ),
      );
      expect(sessions.takeNotificationOpenRequest(), isTrue);
    }
  });

  group('A19 negative input on the owner side', () {
    test('an undecodable entry is copied byte-identical into reviews, then '
        'removed', () async {
      await journalDirectory.create(recursive: true);
      final bytes = utf8.encode('{"format":"alkion-notification-intent/1",');
      File(
        p.join(
          journalDirectory.path,
          '1-00000000-0000-4000-8000-0000000000aa.json',
        ),
      ).writeAsBytesSync(bytes);
      final odd = File(p.join(journalDirectory.path, 'unrelated.json'))
        ..writeAsBytesSync([0xff, 0xfe, 0x00]);
      final runtime = await open();
      await settled(runtime);
      final rows = await runtime.store.getAll(
        'SELECT review_id,category,evidence_bytes FROM reviews WHERE category=?',
        [notificationIntentUnreadableCategory],
      );
      expect(rows, hasLength(2));
      final kept = {
        for (final row in rows)
          row['review_id']: (row['evidence_bytes'] as List).cast<int>(),
      };
      expect(kept[notificationIntentReviewId(bytes)], bytes);
      expect(kept[notificationIntentReviewId([0xff, 0xfe, 0x00])], [
        0xff,
        0xfe,
        0x00,
      ]);
      expect(odd.existsSync(), isFalse);
      expect(journalDirectory.listSync(), isEmpty);
      expect(runtime.persistenceFailure.value, isNull);
      // The same bytes reappearing (a crash before the delete) count as kept.
      File(
        p.join(
          journalDirectory.path,
          '1-00000000-0000-4000-8000-0000000000aa.json',
        ),
      ).writeAsBytesSync(bytes);
      await runtime.sessions.drainNotificationIntents();
      expect(journalDirectory.listSync(), isEmpty);
      expect(
        await runtime.store.getAll(
          'SELECT review_id FROM reviews WHERE category=?',
          [notificationIntentUnreadableCategory],
        ),
        hasLength(2),
      );
    });

    test('directory, symlink and I/O faults never fail launch', () async {
      final payload = await postedThenClosed();
      // A journal path that is a file, not a directory.
      journalDirectory.parent.createSync(recursive: true);
      File(journalDirectory.path).writeAsStringSync('not a directory');
      var runtime = await open();
      await runtime.sessions.notificationWorkIdle();
      expect(runtime.sessions.active!.restTotal, 600);
      expect(
        runtime.persistenceFailure.value,
        isA<NotificationJournalRefused>(),
      );
      await runtime.close();
      File(journalDirectory.path).deleteSync();
      // A symlinked entry is never followed, a link is never decided.
      expect(await add(payload), NotificationBackgroundOutcome.rendered);
      final outside = File(p.join(temp.path, 'outside.json'))
        ..writeAsStringSync('outside');
      final link = Link(
        p.join(
          journalDirectory.path,
          '2-00000000-0000-4000-8000-0000000000bb.json',
        ),
      )..createSync(outside.path);
      runtime = await open();
      await until(
        () => runtime.sessions.active?.restTotal == 630,
        reason: 'the real entry applied',
      );
      await runtime.sessions.notificationWorkIdle();
      expect(link.existsSync(), isTrue);
      expect(outside.readAsStringSync(), 'outside');
      expect(
        await runtime.store.getAll(
          'SELECT review_id FROM reviews WHERE category=?',
          [notificationIntentUnreadableCategory],
        ),
        isEmpty,
      );
    });
  });

  group('A11 owner process death', () {
    for (final cut in notificationIntentCrashCuts) {
      test('a child killed at $cut applies the tap exactly once at the next '
          'launch', () async {
        final crashRoot = await Directory.systemTemp.createTemp(
          'alkion-notification-intent-crash-',
        );
        addTearDown(() => crashRoot.delete(recursive: true));
        root = Directory(p.join(crashRoot.path, AlkionIdentity.applicationId));
        journalDirectory = notificationJournalDirectory(root);
        final payload = await postedThenClosed();
        expect(await add(payload), NotificationBackgroundOutcome.rendered);
        final result = await Process.run(
          'make',
          [
            '--no-print-directory',
            '-C',
            Directory.current.path,
            'test',
            if (Platform.environment['ALKION_TEST_FLUTTER'] case final flutter?)
              'FLUTTER=$flutter',
            'TEST=test/support/notification_intent_crash.dart',
          ],
          environment: {'ALKION_NI_ROOT': crashRoot.path, 'ALKION_NI_CUT': cut},
        ).timeout(const Duration(minutes: 5));
        expect(result.exitCode, isNot(0), reason: '${result.stdout}');
        expect(
          File('${crashRoot.path}/cut-$cut').readAsStringSync(),
          cut,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(await journal(), hasLength(1), reason: 'the entry stays');
        final profile = await AlkionProfile.open(supportRoot: root);
        final store = await openAlkionStore(profile);
        try {
          final timer = await sqlRow(store, LocalStateKind.timer, 'active');
          expect(
            timer['restTotal'],
            cut == 'intent-consume-open' ? 600 : 630,
            reason: 'COMMIT happened only after the transaction cut',
          );
        } finally {
          await store.close();
        }
        final runtime = await open();
        await settled(runtime);
        expect(runtime.sessions.active!.restTotal, 630);
        for (final kind in [LocalStateKind.draft, LocalStateKind.timer]) {
          expect(
            (await sqlRow(runtime.store, kind, 'active'))['restTotal'],
            630,
          );
        }
        expect((await receipt(runtime.store))['consumed_step'], 1);
      }, timeout: const Timeout(Duration(minutes: 6)));
    }
  });

  group('review fixes', () {
    test('in immediate mode a wake-up with an empty journal still forces one '
        'settle of the live mirror', () async {
      final notifier = RecordingNotification();
      final runtime = await open(notifications: notifier);
      await startResting(runtime);
      await runtime.sessions.notificationWorkIdle();
      final before = notifier.mirrors.length;
      expect(await journal(), isEmpty);
      expect(wakeNotificationOwner(), isTrue);
      await until(
        () => notifier.mirrors.length > before,
        reason: 'the settle after the wake-up',
      );
      await runtime.sessions.notificationWorkIdle();
      final after = notifier.mirrors.sublist(before);
      expect(after, hasLength(1));
      expect(after.single.force, isTrue);
      expect(after.single.restTotal, 600);
    });

    test('the port is registered before drain #1: a tap at its read is '
        'handed off, renders nothing and owes a drain', () async {
      final payload = await postedThenClosed();
      late SessionManager sessions;
      var reads = 0;
      NotificationBackgroundOutcome? outcome;
      final runtime = await AlkionRuntime.open(
        root,
        notifications: RecordingNotification(),
        onSessions: (value) => sessions = value,
        openCheckpoint: (phase) async {
          if (phase == 'drain-read' && reads++ == 0) {
            expect(sessions.notificationPortMode, NotificationPortMode.opening);
            outcome = await add(payload);
          }
          if (phase == 'drained') {
            await until(() => sessions.drainOwed, reason: 'an owed drain');
          }
        },
      );
      runtimes.add(runtime);
      controllers.add(runtime.sessions.active!);
      expect(outcome, NotificationBackgroundOutcome.handedOff);
      expect(renders, isEmpty);
      await settled(runtime);
      expect(runtime.sessions.active!.restTotal, 630);
      expect(runtime.sessions.drainOwed, isFalse);
      expect(
        runtime.sessions.notificationPortMode,
        NotificationPortMode.immediate,
      );
    });

    test('init drains before it reconciles: a +30s journaled after drain #1 '
        'extends an elapsed rest instead of being stopped', () async {
      final notifier = RecordingNotification();
      var runtime = await open(notifications: notifier);
      final start = DateTime.now().subtract(const Duration(seconds: 70));
      await startResting(runtime, restStart: start, total: 60);
      final payload = notifier.payload!;
      await runtime.close();
      runtime = await open(
        openCheckpoint: (phase) async {
          if (phase != 'drained') return;
          // After drain #1 and before resume and init; no wake-up arrives.
          await add(
            payload,
            at: start.add(const Duration(seconds: 50)),
            wake: false,
          );
        },
      );
      await settled(runtime);
      final owner = runtime.sessions.active!;
      expect(owner.restStart, start);
      expect(owner.restTotal, 90);
      expect(owner.restEndedAt, isNull);
    });

    test('a failed open after init abandons its owner: no port, no lifecycle '
        'observer, no drains, and the OS mirror stays', () async {
      final payload = await postedThenClosed();
      late SessionManager sessions;
      final notifier = RecordingNotification();
      await expectLater(
        open(
          notifications: notifier,
          onSessions: (value) => sessions = value,
          openCheckpoint: (phase) async {
            if (phase == 'notifications-initialized') {
              throw const StoreException('synthetic_open_failure');
            }
          },
        ),
        throwsA(isA<StoreException>()),
      );
      expect(IsolateNameServer.lookupPortByName(notificationPortName), isNull);
      expect(sessions.notificationPortMode, NotificationPortMode.unregistered);
      expect(
        WidgetsBinding.instance.removeObserver(sessions),
        isFalse,
        reason: 'no longer a lifecycle observer',
      );
      expect(notifier.closes, 0, reason: 'the OS mirror stays posted');
      expect(notifier.cancels, 0);
      final owner = sessions.active;
      if (owner != null) controllers.add(owner);
      // A tap now renders provisionally and waits; the abandoned owner never
      // drains it against the closed store.
      expect(await add(payload), NotificationBackgroundOutcome.rendered);
      await sessions.drainNotificationIntents();
      expect(await journal(), hasLength(1));
      final runtime = await open();
      await settled(runtime);
      expect(runtime.sessions.active!.restTotal, 630);
    });
  });

  group('owner without a runtime', () {
    /// The selected profile's store, opened directly with no runtime and no
    /// port, and a manager that owns it and the journal.
    Future<(LocalStore, SessionManager)> bareOwner() async {
      final profile = await AlkionProfile.open(supportRoot: root);
      final store = await openAlkionStore(profile);
      final sessions = SessionManager(
        draftStore: DraftStore.local(store),
        notificationJournal: NotificationJournal(journalDirectory),
      );
      addTearDown(() async {
        final owner = sessions.active;
        sessions.dispose();
        owner?.dispose();
        await store.close();
      });
      return (store, sessions);
    }

    test('init drains on its own before it reconciles: a journaled +30s '
        'extends an elapsed rest', () async {
      final notifier = RecordingNotification();
      final runtime = await open(notifications: notifier);
      final start = DateTime.now().subtract(const Duration(seconds: 70));
      await startResting(runtime, restStart: start, total: 60);
      final payload = notifier.payload!;
      await runtime.close();
      final (_, sessions) = await bareOwner();
      expect(await sessions.resumeFromDraft(), isTrue);
      // The register-triggered refresh has drained an empty journal.
      await sessions.notificationWorkIdle();
      final owner = sessions.active!;
      expect(owner.restStart, start, reason: 'elapsed, not yet reconciled');
      // Journaled now, with no wake-up: only init's own drain can apply it
      // before init reconciles.
      expect(
        await add(
          payload,
          at: start.add(const Duration(seconds: 50)),
          wake: false,
        ),
        NotificationBackgroundOutcome.rendered,
      );
      sessions.init();
      await sessions.notificationWorkIdle();
      expect(owner.restStart, start);
      expect(owner.restTotal, 90);
      expect(owner.restEndedAt, isNull);
      expect(await journal(), isEmpty);
    });

    test('an undecodable entry is neither copied nor deleted while a launch '
        'holds the fence', () async {
      final (store, sessions) = await bareOwner();
      await journalDirectory.create(recursive: true);
      final bytes = utf8.encode('{"format":"alkion-notification-intent/1",');
      final entry = File(
        p.join(
          journalDirectory.path,
          '1-00000000-0000-4000-8000-0000000000cc.json',
        ),
      )..writeAsBytesSync(bytes);
      Future<List<Map<String, Object?>>> kept() => store.getAll(
        'SELECT review_id FROM reviews WHERE category=?',
        [notificationIntentUnreadableCategory],
      );
      expect(sessions.tryBeginLaunch(), isTrue);
      await sessions.drainNotificationIntents();
      expect(entry.readAsBytesSync(), bytes);
      expect(await kept(), isEmpty);
      sessions.endLaunch();
      await sessions.drainNotificationIntents();
      expect(entry.existsSync(), isFalse);
      expect(await kept(), hasLength(1));
    });
  });
}
