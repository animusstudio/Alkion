import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/session/notification_background.dart';
import 'package:alkion/session/notification_envelope.dart';
import 'package:alkion/session/notification_journal.dart';
import 'package:alkion/session/workout_notification_render.dart';
import 'package:alkion/store/local_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/notification_journal_crash.dart'
    show crashEnvelope, crashIntentId, crashJournalDirectory, crashTappedAt;

final _restStart = DateTime.utc(2026, 6, 3, 10, 29, 30);
final _t0 = _restStart.add(const Duration(seconds: 30));

NotificationAction _action({String token = 'synthetic-token'}) =>
    NotificationAction(
      applicationId: AlkionIdentity.applicationId,
      profileId: 'synthetic-profile',
      generation: 1,
      draftId: 'synthetic-draft',
      restStart: _restStart.toIso8601String(),
      timerRevision: 2,
      token: token,
    );

NotificationView _view({
  String title = 'Upper A',
  int restTotal = 90,
  bool resting = true,
  String locale = 'en',
}) => NotificationView(
  title: title,
  restBody: 'Next · Row',
  elapsedBody: 'Next · Row',
  startedAt: DateTime.utc(2026, 6, 3, 10),
  restStart: resting ? _restStart : null,
  restTotal: resting ? restTotal : 0,
  locale: locale,
);

String _payload({
  int step = 1,
  NotificationView? view,
  bool withView = true,
  String token = 'synthetic-token',
}) => NotificationEnvelope(
  action: _action(token: token),
  step: step,
  view: withView ? view ?? _view() : null,
).encode()!;

NotificationResponse _tap(String? actionId, String? payload) =>
    NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      id: workoutNotificationId,
      actionId: actionId,
      payload: payload,
    );

NotificationResponse _add(String payload) =>
    _tap(AlkionIdentity.addRestAction, payload);
NotificationResponse _skip(String payload) =>
    _tap(AlkionIdentity.skipRestAction, payload);

/// Injected port, renderer, clock and directory.
final class _Harness {
  _Harness(this.root)
    : journalDirectory = notificationJournalDirectory(
        Directory(p.join(root.path, 'files', AlkionIdentity.applicationId)),
      );
  final Directory root;
  final Directory journalDirectory;
  bool port = false;
  bool exact = true;
  int wakes = 0;
  DateTime now = _t0;
  int _ids = 0;
  final renders = <RestMirror>[];
  final traces = <String>[];
  Future<void> Function(RestMirror mirror)? onRender;
  Future<bool> Function()? onExact;
  void Function(String path)? flushDirectory;
  Duration platformTimeout = const Duration(seconds: 10);

  NotificationBackground get background => NotificationBackground(
    journalDirectory: () async => journalDirectory,
    wakeOwner: () {
      if (!port) return false;
      wakes++;
      return true;
    },
    render: (mirror) async {
      await onRender?.call(mirror);
      renders.add(mirror);
    },
    exact: () => onExact?.call() ?? Future.value(exact),
    clock: () => now,
    newIntentId: () =>
        '00000000-0000-4000-8000-${(++_ids).toRadixString(16).padLeft(12, '0')}',
    trace: traces.add,
    platformTimeout: platformTimeout,
    flushDirectory: flushDirectory,
  );

  Future<NotificationBackgroundOutcome> deliver(NotificationResponse r) =>
      deliverNotificationResponse(r, background: background);

  Future<List<NotificationJournalEntry>> entries() =>
      NotificationJournal(journalDirectory).read();

  NotificationEnvelope lastPayload() =>
      NotificationEnvelope.decode(renders.last.payload)!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Harness h;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'alkion-notification-background-',
    );
    h = _Harness(root);
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('negative input (A19)', () {
    test(
      'an unknown action, or a bad payload, writes and renders nothing',
      () async {
        final oversize = jsonEncode({
          ...jsonDecode(_payload()) as Map,
          'pad': 'x' * 4096,
        });
        for (final response in [
          _tap(null, _payload()),
          _tap('${AlkionIdentity.preferencePrefix}other', _payload()),
          _tap('add_30s', _payload()),
          _add('not json'),
          _add(''),
          _tap(AlkionIdentity.addRestAction, null),
          _add(oversize),
          _skip(jsonEncode({'format': notificationPayloadFormat})),
        ]) {
          expect(
            await h.deliver(response),
            NotificationBackgroundOutcome.ignored,
            reason: '${response.actionId} ${response.payload}',
          );
        }
        expect(h.journalDirectory.existsSync(), isFalse);
        expect(h.renders, isEmpty);
        expect(h.wakes, 0);
        expect(h.traces, isEmpty);
      },
    );

    test('a full journal refuses the tap: no render, no wake-up', () async {
      for (var n = 0; n < notificationJournalMaxEntries; n++) {
        h.now = _t0.add(Duration(milliseconds: n));
        h.port = true;
        expect(
          await h.deliver(_add(_payload())),
          NotificationBackgroundOutcome.handedOff,
        );
      }
      final wakes = h.wakes;
      h.port = false;
      expect(
        await h.deliver(_add(_payload())),
        NotificationBackgroundOutcome.notJournaled,
      );
      expect(h.renders, isEmpty);
      expect(h.wakes, wakes);
      expect(await h.entries(), hasLength(notificationJournalMaxEntries));
    });

    test('a failed append stops before rendering', () async {
      File(h.journalDirectory.path)
        ..createSync(recursive: true)
        ..writeAsStringSync('not a directory');
      expect(
        await h.deliver(_add(_payload())),
        NotificationBackgroundOutcome.notJournaled,
      );
      expect(h.renders, isEmpty);
      expect(h.traces.map((t) => t.split(' ')[1]), ['received']);
    });
  });

  group('port (A22)', () {
    test(
      'an owner port gets the wake-up and the background never renders',
      () async {
        h.port = true;
        expect(
          await h.deliver(_add(_payload())),
          NotificationBackgroundOutcome.handedOff,
        );
        expect(h.wakes, 1);
        expect(h.renders, isEmpty);
        expect(await h.entries(), hasLength(1));
        expect(h.traces, [
          'alkion-notif received 00000000 1 add',
          'alkion-notif journaled 00000000 1 add',
          'alkion-notif woke 00000000 1 add',
        ]);
      },
    );

    test(
      'a stale registered port with no listener leaves the entry, unrendered',
      () async {
        final receive = ReceivePort();
        final stale = receive.sendPort;
        receive.close();
        IsolateNameServer.removePortNameMapping(notificationPortName);
        expect(
          IsolateNameServer.registerPortWithName(stale, notificationPortName),
          isTrue,
        );
        addTearDown(
          () => IsolateNameServer.removePortNameMapping(notificationPortName),
        );
        final background = h.background;
        final outcome = await deliverNotificationResponse(
          _add(_payload()),
          background: NotificationBackground(
            journalDirectory: background.journalDirectory,
            wakeOwner: wakeNotificationOwner,
            render: background.render,
            exact: background.exact,
            clock: background.clock,
            newIntentId: background.newIntentId,
          ),
        );
        expect(outcome, NotificationBackgroundOutcome.handedOff);
        expect(h.renders, isEmpty);
        final entry = (await h.entries()).single;
        expect(entry.intent!.payload.step, 1);
      },
    );

    test('a live registered port receives the wake-up message', () async {
      final receive = ReceivePort();
      addTearDown(receive.close);
      IsolateNameServer.removePortNameMapping(notificationPortName);
      IsolateNameServer.registerPortWithName(
        receive.sendPort,
        notificationPortName,
      );
      addTearDown(
        () => IsolateNameServer.removePortNameMapping(notificationPortName),
      );
      expect(wakeNotificationOwner(), isTrue);
      expect(await receive.first, notificationWakeMessage);
      IsolateNameServer.removePortNameMapping(notificationPortName);
      expect(wakeNotificationOwner(), isFalse);
    });

    test('an owner that appears during the render is woken after it', () async {
      h.onRender = (_) async => h.port = true;
      expect(
        await h.deliver(_add(_payload())),
        NotificationBackgroundOutcome.rendered,
      );
      expect(h.renders, hasLength(1));
      expect(h.wakes, 1);
      expect(h.traces.map((t) => t.split(' ')[1]), [
        'received',
        'journaled',
        'rendered',
        'woke',
      ]);
    });

    test('a failed render still checks the port', () async {
      h.onRender = (_) async {
        h.port = true;
        throw StateError('synthetic render failure');
      };
      expect(
        await h.deliver(_add(_payload())),
        NotificationBackgroundOutcome.unrendered,
      );
      expect(h.wakes, 1);
      expect(await h.entries(), hasLength(1));
      expect(h.traces.map((t) => t.split(' ')[1]), [
        'received',
        'journaled',
        'woke',
      ]);
    });
  });

  group('after the journal write', () {
    for (final port in [false, true]) {
      test(
        'a failed directory flush after the rename still counts as journaled '
        '(port: $port)',
        () async {
          h.port = port;
          h.flushDirectory = (path) {
            if (path == h.journalDirectory.path) {
              throw const FileSystemException('synthetic fsync failure');
            }
          };
          expect(
            await h.deliver(_add(_payload())),
            port
                ? NotificationBackgroundOutcome.handedOff
                : NotificationBackgroundOutcome.rendered,
          );
          expect((await h.entries()).single.intent!.payload.step, 1);
          expect(h.traces.map((t) => t.split(' ')[1]), [
            'received',
            'unflushed',
            'journaled',
            port ? 'woke' : 'rendered',
          ]);
        },
      );
    }

    test('a hung render cannot stall the taps queued behind it', () async {
      h.platformTimeout = const Duration(milliseconds: 50);
      h.onRender = (_) => Completer<void>().future;
      final first = h.deliver(_add(_payload()));
      h.now = _t0.add(const Duration(seconds: 1));
      final second = h.deliver(_add(_payload()));
      expect(await Future.wait([first, second]), [
        NotificationBackgroundOutcome.unrendered,
        NotificationBackgroundOutcome.unrendered,
      ]);
      expect(await h.entries(), hasLength(2));
      expect(h.traces.where((t) => t.contains(' journaled ')), hasLength(2));
    });

    test('a failing exact-alarm query renders with inexact alarms', () async {
      h.onExact = () async =>
          throw PlatformException(code: 'synthetic_exact_failure');
      expect(
        await h.deliver(_add(_payload())),
        NotificationBackgroundOutcome.rendered,
      );
      expect(h.renders.single.exact, isFalse);
    });

    test('a hung exact-alarm query renders with inexact alarms', () async {
      h.platformTimeout = const Duration(milliseconds: 50);
      h.onExact = () => Completer<bool>().future;
      expect(
        await h.deliver(_add(_payload())),
        NotificationBackgroundOutcome.rendered,
      );
      expect(h.renders.single.exact, isFalse);
    });
  });

  group('provisional render and fold (A7)', () {
    test('+30s renders the folded countdown with the next step', () async {
      for (final exact in [true, false]) {
        h.renders.clear();
        h.exact = exact;
        h.now = _t0.add(Duration(seconds: exact ? 0 : 1));
        final token = exact ? 'token-exact' : 'token-inexact';
        expect(
          await h.deliver(_add(_payload(token: token))),
          NotificationBackgroundOutcome.rendered,
        );
        final mirror = h.renders.single;
        expect(mirror.exact, exact);
        expect(mirror.alertAtRestEnd, isTrue);
        expect(mirror.actionable, isTrue);
        expect(mirror.now, h.now);
        expect(mirror.view.restTotal, 120);
        expect(mirror.view.restStart, _restStart);
        expect(mirror.mode.countdown, isTrue);
        final payload = h.lastPayload();
        expect(payload.action.encode(), _action(token: token).encode());
        expect(payload.step, 2);
        expect(payload.view!.toJson(), mirror.view.toJson());
      }
    });

    test('Skip renders elapsed mode with no actions', () async {
      expect(
        await h.deliver(_skip(_payload())),
        NotificationBackgroundOutcome.rendered,
      );
      final mirror = h.renders.single;
      expect(mirror.view.restStart, isNull);
      expect(mirror.view.restTotal, 0);
      expect(mirror.mode.countdown, isFalse);
      expect(mirror.mode.when, mirror.view.startedAt);
      expect(h.lastPayload().step, 2);
    });

    test('a +30s at or past the folded rest end gives elapsed mode', () async {
      h.now = _restStart.add(const Duration(seconds: 90));
      await h.deliver(_add(_payload()));
      expect(h.renders.single.view.restStart, isNull);
      expect(h.renders.single.mode.countdown, isFalse);
    });

    test('two un-awaited deliveries are serialised in arrival order', () async {
      final gate = Completer<void>();
      var inRender = 0;
      h.onRender = (_) async {
        inRender++;
        if (inRender == 1) {
          // The second delivery must not have journaled yet.
          expect(await h.entries(), hasLength(1));
          await gate.future;
        }
      };
      final first = h.deliver(_add(_payload()));
      h.now = _t0.add(const Duration(milliseconds: 300));
      final second = h.deliver(_add(_payload()));
      await pumpEventQueue();
      expect(inRender, 1);
      gate.complete();
      expect(await Future.wait([first, second]), [
        NotificationBackgroundOutcome.rendered,
        NotificationBackgroundOutcome.rendered,
      ]);
      // Both taps carried step 1: the first arrival counts once.
      expect(h.renders.map((m) => m.view.restTotal), [120, 120]);
      expect(
        h.renders.map((m) => NotificationEnvelope.decode(m.payload)!.step),
        [2, 2],
      );
      final intents = [for (final e in await h.entries()) e.intent!];
      expect(intents.map((i) => i.tappedAt), [_t0, h.now]);
      expect(intents.map((i) => i.payload.step), [1, 1]);
    });

    for (final (first, second, countdown) in [
      ('add', 'skip', true),
      ('skip', 'add', false),
    ]) {
      test(
        'mixed taps at one step: $first then $second folds $first',
        () async {
          NotificationResponse tap(String kind) =>
              kind == 'add' ? _add(_payload()) : _skip(_payload());
          final a = h.deliver(tap(first));
          h.now = _t0.add(const Duration(seconds: 1));
          final b = h.deliver(tap(second));
          await Future.wait([a, b]);
          final last = h.renders.last;
          expect(last.mode.countdown, countdown);
          expect(last.view.restTotal, countdown ? 120 : 0);
          expect(NotificationEnvelope.decode(last.payload)!.step, 2);
          final kinds = [
            for (final e in await h.entries()) e.intent!.kind.wire,
          ];
          expect(kinds, [first, second]);
        },
      );
    }

    test(
      'a chain through captured payloads: +30s, +30s, Skip (A4 background side)',
      () async {
        await h.deliver(_add(_payload()));
        expect(h.renders.last.view.restTotal, 120);
        h.now = _t0.add(const Duration(seconds: 2));
        await h.deliver(_add(h.renders.last.payload!));
        expect(h.renders.last.view.restTotal, 150);
        expect(h.lastPayload().step, 3);
        h.now = _t0.add(const Duration(seconds: 4));
        await h.deliver(_skip(h.renders.last.payload!));
        expect(h.renders.last.mode.countdown, isFalse);
        expect(h.lastPayload().step, 4);
        final intents = [for (final e in await h.entries()) e.intent!];
        expect(intents.map((i) => (i.payload.step, i.kind.wire)), [
          (1, 'add'),
          (2, 'add'),
          (3, 'skip'),
        ]);
      },
    );

    test('the fold never uses a tapped payload\'s own view', () async {
      await h.deliver(_add(_payload()));
      h.now = _t0.add(const Duration(seconds: 1));
      await h.deliver(
        _add(_payload(step: 2, view: _view(title: 'tampered', restTotal: 900))),
      );
      expect(h.renders.last.view.title, 'Upper A');
      expect(h.renders.last.view.restTotal, 150);
      expect(h.lastPayload().step, 3);
    });

    test('the fold stops at a gap and ignores other tokens', () async {
      await h.deliver(_add(_payload(token: 'other-token')));
      await h.deliver(_add(_payload()));
      h.now = _t0.add(const Duration(seconds: 1));
      await h.deliver(_add(_payload(step: 3, view: _view(restTotal: 150))));
      expect(h.renders.last.view.restTotal, 120);
      expect(h.lastPayload().step, 2);
      expect(h.lastPayload().action.token, 'synthetic-token');
    });

    test('the base is the lowest-step entry\'s view and step', () async {
      await h.deliver(_add(_payload(step: 3, view: _view(restTotal: 150))));
      expect(h.renders.last.view.restTotal, 180);
      expect(h.lastPayload().step, 4);
    });

    test('a base without a view journals but cannot render', () async {
      expect(
        await h.deliver(_add(_payload(withView: false))),
        NotificationBackgroundOutcome.unrendered,
      );
      expect(h.renders, isEmpty);
      expect(await h.entries(), hasLength(1));
    });

    test('a token without a rest start renders without actions', () async {
      final action = NotificationAction(
        applicationId: AlkionIdentity.applicationId,
        profileId: 'synthetic-profile',
        generation: 1,
        draftId: 'synthetic-draft',
        restStart: null,
        timerRevision: 2,
        token: 'synthetic-token',
      );
      await h.deliver(
        _add(
          NotificationEnvelope(
            action: action,
            step: 1,
            view: _view(),
          ).encode()!,
        ),
      );
      expect(h.renders.single.actionable, isFalse);
    });

    test('foldNotificationIntents is null with no entry on the token', () {
      expect(foldNotificationIntents(const [], _action()), isNull);
    });
  });

  group('4096-byte payload boundary (A21)', () {
    /// The longest title of [unit]s, then ASCII padding, whose payload is
    /// exactly [notificationPayloadByteLimit] UTF-8 bytes.
    String atBoundary(String unit, String locale) {
      var title = 'Ü';
      String encode(String t) => jsonEncode(
        NotificationEnvelope(
          action: _action(),
          step: 1,
          view: _view(title: t, locale: locale),
        ).toJson(),
      );
      while (utf8Length(encode('$title$unit')) <=
          notificationPayloadByteLimit) {
        title = '$title$unit';
      }
      while (utf8Length(encode(title)) < notificationPayloadByteLimit) {
        title = '${title}a';
      }
      final payload = encode(title);
      expect(utf8Length(payload), notificationPayloadByteLimit);
      return payload;
    }

    for (final (locale, unit) in [
      ('de', 'Ä'),
      ('es', 'ñ'),
      ('it', 'è'),
      ('en', '🏋️'),
    ]) {
      test(
        '$locale: exactly 4096 bytes journals and renders, 4097 is ignored',
        () async {
          final payload = atBoundary(unit, locale);
          expect(
            await h.deliver(_add(payload)),
            NotificationBackgroundOutcome.rendered,
          );
          final entry = (await h.entries()).single;
          expect(entry.intent!.payload.view!.locale, locale);
          expect(
            entry.bytes!.length,
            lessThanOrEqualTo(notificationJournalMaxEntryBytes),
          );
          // The re-render still fits: the title is shortened on a code point.
          final rendered = h.renders.single.payload!;
          expect(
            utf8Length(rendered),
            lessThanOrEqualTo(notificationPayloadByteLimit),
          );
          expect(
            NotificationEnvelope.decode(
              rendered,
            )!.view!.title.runes.every((r) => r < 0xD800 || r > 0xDFFF),
            isTrue,
          );
          final over = payload.replaceFirst('"title":"Ü', '"title":"ÜÜ');
          expect(utf8Length(over), notificationPayloadByteLimit + 2);
          final overByOne = payload.replaceFirst('"title":"Ü', '"title":"aÜ');
          expect(utf8Length(overByOne), notificationPayloadByteLimit + 1);
          for (final tooLong in [over, overByOne]) {
            expect(
              await h.deliver(_add(tooLong)),
              NotificationBackgroundOutcome.ignored,
            );
          }
          expect(await h.entries(), hasLength(1));
        },
      );
    }
  });

  test('trace markers carry no names', () async {
    await h.deliver(_add(_payload(view: _view(title: 'Secret Name'))));
    expect(h.traces, [
      'alkion-notif received 00000000 1 add',
      'alkion-notif journaled 00000000 1 add',
      'alkion-notif rendered 00000000 1 add',
    ]);
    expect(notificationTraceEnabled, isFalse);
  });

  group('isolation (A20)', () {
    test('the handler works while a real store holds the owner lock', () async {
      final supportRoot = Directory(
        p.join(root.path, 'files', AlkionIdentity.applicationId),
      );
      final profile = await AlkionProfile.open(supportRoot: supportRoot);
      final store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
      );
      addTearDown(store.close);
      List<String> listing() => [
        for (final e in supportRoot.listSync(
          recursive: true,
          followLinks: false,
        ))
          p.relative(e.path, from: supportRoot.path),
      ]..sort();
      final inventory = await store.inventory();
      final before = listing();
      expect(
        await h.deliver(_add(_payload())),
        NotificationBackgroundOutcome.rendered,
      );
      expect(await h.entries(), hasLength(1));
      expect(p.isWithin(supportRoot.path, h.journalDirectory.path), isFalse);
      expect(listing(), before);
      expect(await store.inventory(), inventory);
    });

    group('the platform wiring over the plugin v21 method channel', () {
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      late List<MethodCall> calls;
      setUp(() {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        AndroidFlutterLocalNotificationsPlugin.registerWith();
        calls = [];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return call.method == 'canScheduleExactNotifications'
                  ? true
                  : null;
            });
      });
      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      });

      test(
        'renders through the plugin without initializing or prompting',
        () async {
          IsolateNameServer.removePortNameMapping(notificationPortName);
          final files = Directory(p.join(root.path, 'files'));
          // A rest that is running now, so the rest end is in the future.
          final restStart = DateTime.fromMillisecondsSinceEpoch(
            DateTime.now().millisecondsSinceEpoch,
            isUtc: true,
          );
          final view = NotificationView(
            title: 'Upper A',
            restBody: 'Next · Row',
            elapsedBody: 'Next · Row',
            startedAt: restStart.subtract(const Duration(minutes: 20)),
            restStart: restStart,
            restTotal: 90,
            locale: 'en',
          );
          final outcome = await deliverNotificationResponse(
            _add(
              NotificationEnvelope(
                action: _action(),
                step: 1,
                view: view,
              ).encode()!,
            ),
            background: NotificationBackground.platform(
              plugin: FlutterLocalNotificationsPlugin(),
              supportDirectory: () async => files,
            ),
          );
          expect(outcome, NotificationBackgroundOutcome.rendered);
          expect(calls.map((c) => c.method), [
            'canScheduleExactNotifications',
            'cancel',
            'show',
            'zonedSchedule',
          ]);
          final shown = calls[2].arguments as Map;
          final payload = NotificationEnvelope.decode(
            shown['payload'] as String,
          )!;
          expect(payload.step, 2);
          expect(payload.view!.restTotal, 120);
          final scheduled = calls[3].arguments as Map;
          expect(
            scheduled['platformSpecifics']['scheduleMode'],
            AndroidScheduleMode.exactAllowWhileIdle.name,
          );
          expect(
            scheduled['platformSpecifics']['channelId'],
            AlkionIdentity.restEndChannel,
          );
          final journal = NotificationJournal(
            notificationJournalDirectory(notificationSupportRoot(files)),
          );
          expect(await journal.read(), hasLength(1));
        },
      );
    });
  });

  group('A10 process death', () {
    for (final cut in ['journal-partial-written', 'journal-renamed']) {
      test(
        'a child killed at $cut leaves no entry or one whole entry, unrendered',
        () async {
          final crashRoot = await Directory.systemTemp.createTemp(
            'alkion-notification-journal-crash-',
          );
          addTearDown(() => crashRoot.delete(recursive: true));
          final result = await Process.run(
            'make',
            [
              '--no-print-directory',
              '-C',
              Directory.current.path,
              'test',
              if (Platform.environment['ALKION_TEST_FLUTTER']
                  case final flutter?)
                'FLUTTER=$flutter',
              'TEST=test/support/notification_journal_crash.dart',
            ],
            environment: {
              'ALKION_NJ_ROOT': crashRoot.path,
              'ALKION_NJ_CUT': cut,
            },
          ).timeout(const Duration(minutes: 5));
          expect(result.exitCode, isNot(0), reason: '${result.stdout}');
          expect(
            File('${crashRoot.path}/cut-$cut').readAsStringSync(),
            cut,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(File('${crashRoot.path}/rendered').existsSync(), isFalse);
          final directory = crashJournalDirectory(crashRoot.path);
          final journal = NotificationJournal(directory);
          final names = [
            for (final e in directory.listSync()) p.basename(e.path),
          ];
          final expectedName =
              '${crashTappedAt.microsecondsSinceEpoch}-$crashIntentId.json';
          if (cut == 'journal-partial-written') {
            expect(names, ['$expectedName.partial']);
            expect(await journal.read(), isEmpty);
            // The leftover is removed once it is older than 60 s.
            File(p.join(directory.path, names.single)).setLastModifiedSync(
              DateTime.now().subtract(const Duration(seconds: 61)),
            );
            expect(journal.removeStalePartials(), 1);
            expect(directory.listSync(), isEmpty);
          } else {
            expect(names, [expectedName]);
            final entry = (await journal.read()).single;
            expect(entry.intent!.intentId, crashIntentId);
            expect(entry.intent!.payload.toJson(), crashEnvelope().toJson());
            // The next fold sees the tap exactly once.
            final folded = foldNotificationIntents([
              entry.intent!,
            ], crashEnvelope().action)!;
            expect(folded.step, 2);
            expect(folded.view!.restTotal, 120);
          }
        },
        timeout: const Timeout(Duration(minutes: 6)),
      );
    }
  });
}
