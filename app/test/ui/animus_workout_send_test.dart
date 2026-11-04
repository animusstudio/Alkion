import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:alkion/animus/connection.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/ports.dart';
import 'package:alkion/animus/probe.dart';
import 'package:alkion/animus/recovery_review.dart';
import 'package:flutter/services.dart';
import 'package:alkion/animus/workout_send.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/ui/animus_connection_panel.dart';
import 'package:alkion/ui/animus_workout_send.dart';
import 'package:alkion/ui/history_screen.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../animus/support.dart';
import '../support/app_fonts.dart';
import '../support/l10n_harness.dart';
import '../support/pump_until.dart';
import '../support/screen_harness.dart';

const _sendKey = Key('animus-workout-send-action');
const _captureKey = Key('send-capture');
const _session = 'selected-session';
const _frozenName = 'Single-Arm Cable Lateral Raise with Wrist Strap';

AnimusWorkoutSelection _selection({
  AnimusWorkoutSendStatus status = AnimusWorkoutSendStatus.ready,
  AnimusWorkoutSendIssue? issue,
  bool verified = false,
}) => AnimusWorkoutSelection(
  sessionId: _session,
  selectionId: 'original-frozen-selection',
  exerciseCount: 1,
  setCount: 4,
  exerciseNames: const [_frozenName],
  workoutLabel: 'Frozen Synthetic Upper A',
  savedDay: '2030-01-01',
  status: status,
  issue: issue,
  readBackVerified: verified,
);

class _Sender extends ChangeNotifier implements AnimusWorkoutSendPort {
  AnimusWorkoutSelection? current;
  final selectedIds = <String>[];
  final sent = <AnimusWorkoutSelection>[];
  Completer<void>? gate;
  AnimusWorkoutSelection result = _selection(
    status: AnimusWorkoutSendStatus.uncertain,
    issue: AnimusWorkoutSendIssue.network,
  );
  @override
  bool busy = false;
  @override
  Future<AnimusWorkoutSelection?> selectionFor(String id) async => current;
  @override
  Future<AnimusWorkoutSelection> select(String id) async {
    selectedIds.add(id);
    return current = _selection();
  }

  void publish(AnimusWorkoutSelection value) {
    current = value;
    notifyListeners();
  }

  @override
  Future<void> send(AnimusWorkoutSelection selection) async {
    sent.add(selection);
    busy = true;
    publish(_selection(status: AnimusWorkoutSendStatus.sending));
    await gate?.future;
    busy = false;
    publish(result);
  }

  @override
  Future<void> close() async {}
}

RecoveryStage _reviewStage({
  String id = 'synthetic-stage',
  bool verified = false,
}) => RecoveryStage(
  id,
  'synthetic-attachment',
  '10000000-0000-4000-8000-000000000002',
  verified ? 'verified' : 'staging',
  {
    'targets': [
      for (var i = 0; i < 4; i++)
        {
          'dataset': 'definitions',
          'id': 'synthetic-target-$i',
          'expected': <Object?>[],
        },
    ],
    'coverage': 'incomplete-known-targets',
  },
  {
    'definitions/a': RecoveryComparison.unchanged,
    'definitions/b': RecoveryComparison.changed,
    'workouts/a': RecoveryComparison.acknowledgedMissing,
    'workouts/b': RecoveryComparison.uncertainMissing,
  },
);

class _Review extends ChangeNotifier implements AnimusRecoveryReviewPort {
  @override
  bool busy = false;
  @override
  RecoveryReviewIssue? issue;
  @override
  bool reviewedReply = false;
  @override
  RecoveryReviewSnapshot? snapshot = const RecoveryReviewSnapshot(
    required: true,
    adopted: false,
    manualDisposition: false,
  );
  int localLoads = 0, comparisons = 0;
  final adoptions = <String>[], retries = <String>[];
  void publish(RecoveryReviewSnapshot value) {
    snapshot = value;
    notifyListeners();
  }

  @override
  Future<void> load() async {
    localLoads++;
    notifyListeners();
  }

  @override
  Future<void> compare() async {
    comparisons++;
    publish(
      RecoveryReviewSnapshot(
        required: true,
        adopted: false,
        manualDisposition: false,
        canAdopt: true,
        stage: _reviewStage(verified: true),
      ),
    );
  }

  @override
  Future<void> adopt(String stageId) async {
    adoptions.add(stageId);
    publish(
      RecoveryReviewSnapshot(
        required: false,
        adopted: true,
        manualDisposition: false,
        stage: snapshot!.stage,
      ),
    );
  }

  @override
  Future<bool> canRetry(String sessionId) async => snapshot?.adopted == true;
  @override
  Future<ReviewedRetryScope?> prepareRetry(String sessionId) async =>
      snapshot?.adopted != true
      ? null
      : ReviewedRetryScope(
          journalId: 'synthetic-once',
          bindingId: 'synthetic-binding',
          sessionId: sessionId,
          selectionId: 'original-frozen-selection',
          stageId: snapshot!.stage!.id,
          operationId: 'synthetic-op',
          attemptId: 'synthetic-attempt',
          requestHash: 'synthetic-hash',
          origin: 'old-origin',
          generation: 'current-generation',
          epoch: 0,
        );
  @override
  Future<void> retryReviewed(ReviewedRetryScope scope) async {
    retries.add('${scope.sessionId}/${scope.stageId}');
    reviewedReply = true;
    notifyListeners();
  }

  @override
  Future<void> close() async {}
}

class _Auth implements AnimusAuthPort {
  int calls = 0;
  final session = AnimusAuthSession(
    identity: AnimusIdentity(
      issuer: Uri.parse('https://identity.example.test/'),
      subject: 'synthetic-selected-owner',
      displayName: 'Synthetic Athlete',
    ),
    accessToken: 'synthetic-memory-only',
    expiresAt: DateTime.utc(2040),
  );
  @override
  Future<AnimusAuthSession?> authorize({
    AnimusAuthIntent intent = AnimusAuthIntent.signIn,
  }) async {
    calls++;
    return session;
  }

  @override
  Future<AnimusAuthSession?> restore() async {
    calls++;
    return session;
  }

  @override
  Future<AnimusAuthSession?> refresh() async {
    calls++;
    return session;
  }

  @override
  Future<void> retain(AnimusAuthSession session) async {
    calls++;
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> close() async {}
}

class _Probe implements AnimusProbePort {
  @override
  Future<AnimusProbeResult> verify(AnimusAuthSession session) async =>
      AnimusProbeResult.verified;
  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}

Widget _wrap(
  _Sender sender,
  AnimusConnectionController connection, {
  Locale locale = const Locale('en'),
  bool profile = false,
  Brightness brightness = Brightness.dark,
  AnimusRecoveryReviewPort? review,
}) => MultiProvider(
  providers: [
    ListenableProvider<AnimusWorkoutSendPort?>.value(value: sender),
    ListenableProvider<AnimusRecoveryReviewPort?>.value(value: review),
    ChangeNotifierProvider<AnimusConnectionController?>.value(
      value: connection,
    ),
  ],
  child: RepaintBoundary(
    key: _captureKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(brightness, accents[0]),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: profile
              ? const AnimusConnectionPanel()
              : const AnimusWorkoutSendPanel(sessionId: _session),
        ),
      ),
    ),
  ),
);

Future<void> _pump(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _confirm(WidgetTester tester, AppLocalizations l) async {
  final action = find.widgetWithText(TextButton, l.animusSend).last;
  await tester.ensureVisible(action);
  await tester.tap(action);
  await _pump(tester);
}

Future<void> _capture(WidgetTester tester, String name) async {
  final path = Platform.environment['ALKION_T3_CAPTURE_DIR'];
  if (path == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(path).create(recursive: true);
    await File('$path/$name.png').writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(preloadAppFonts);
  late _Sender sender;
  late _Auth auth;
  late AnimusConnectionController connection;
  setUp(() {
    sender = _Sender();
    auth = _Auth();
    connection = AnimusConnectionController(
      config: syntheticAnimusConfig(),
      auth: auth,
      probe: _Probe(),
    );
  });
  tearDown(() async {
    await connection.close();
    connection.dispose();
    sender.dispose();
  });
  Future<void> connect() async {
    await connection.connect();
    await connection.confirm();
  }

  testWidgets(
    'opening History status does no connection I/O; Profile is explicit',
    (tester) async {
      var profileOpened = false;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ListenableProvider<AnimusWorkoutSendPort?>.value(value: sender),
            ChangeNotifierProvider<AnimusConnectionController?>.value(
              value: connection,
            ),
          ],
          child: wrapL10n(
            AnimusWorkoutSendPanel(
              sessionId: _session,
              onOpenProfile: () => profileOpened = true,
            ),
          ),
        ),
      );
      await _pump(tester);
      expect(auth.calls, 0);
      expect(sender.selectedIds, isEmpty);
      expect(sender.sent, isEmpty);
      expect(tester.widget<TextButton>(find.byKey(_sendKey)).onPressed, isNull);
      await tester.tap(find.byKey(const Key('animus-send-open-profile')));
      expect(profileOpened, isTrue);
      expect(find.text('Saved locally'), findsOneWidget);
    },
  );

  testWidgets('confirmation names exact scope and cancel performs no send', (
    tester,
  ) async {
    await connect();
    await tester.pumpWidget(_wrap(sender, connection));
    await _pump(tester);
    await tester.tap(find.byKey(_sendKey));
    await _pump(tester);
    final l = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l.animusSendConfirmTitle), findsOneWidget);
    final body = find.textContaining('synthetic-selected-owner');
    expect(body, findsOneWidget);
    final text = tester.widget<Text>(body).data!;
    expect(text, contains(connection.dataSpaceId));
    expect(text, contains(_frozenName));
    expect(text, contains('Frozen Synthetic Upper A'));
    expect(text, contains('2030-01-01'));
    expect(text, contains('1 workout · Exercises: 1 · Sets: 4'));
    expect(sender.sent, isEmpty);
    await tester.tap(find.text(l.commonCancel));
    await _pump(tester);
    expect(sender.sent, isEmpty);
    expect(sender.selectedIds, [_session]);
    expect(find.text('Saved locally'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'busy blocks duplicate send; uncertain retry preserves selection',
    (tester) async {
      await connect();
      sender.gate = Completer<void>();
      await tester.pumpWidget(_wrap(sender, connection));
      await _pump(tester);
      final l = lookupAppLocalizations(const Locale('en'));
      await tester.tap(find.byKey(_sendKey));
      await _pump(tester);
      await _confirm(tester, l);
      expect(sender.sent, hasLength(1));
      expect(find.text(l.animusSendSending), findsOneWidget);
      expect(find.text(l.animusSavedLocally), findsOneWidget);
      expect(tester.widget<TextButton>(find.byKey(_sendKey)).onPressed, isNull);
      await _capture(tester, 'sending');
      sender.gate!.complete();
      await _pump(tester);
      expect(find.text(l.animusSendUncertain), findsOneWidget);
      expect(find.text(l.animusSendNetwork), findsOneWidget);
      await _capture(tester, 'uncertain');
      sender.gate = null;
      sender.result = _selection(
        status: AnimusWorkoutSendStatus.sent,
        issue: AnimusWorkoutSendIssue.readBackFailed,
      );
      await tester.tap(find.byKey(_sendKey));
      await _pump(tester);
      await _confirm(tester, l);
      expect(sender.selectedIds, [_session]);
      expect(
        sender.sent.map((s) => s.selectionId),
        everyElement('original-frozen-selection'),
      );
      expect(find.text(l.animusSendSent), findsOneWidget);
      expect(find.text(l.animusSendReadBackFailed), findsOneWidget);
      expect(find.text(l.animusSendVerifyCopy), findsOneWidget);
      expect(find.text(l.animusSavedLocally), findsOneWidget);
      await tester.tap(find.byKey(_sendKey));
      await _pump(tester);
      expect(find.textContaining('already-sent copy'), findsOneWidget);
      expect(sender.sent, hasLength(2));
      await tester.tap(find.text(l.commonCancel));
      await _pump(tester);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('unsupported scope remains visible with a concrete reason', (
    tester,
  ) async {
    await connect();
    sender.current = _selection(
      status: AnimusWorkoutSendStatus.unsupported,
      issue: AnimusWorkoutSendIssue.missingTimeEvidence,
    );
    await tester.pumpWidget(
      _wrap(sender, connection, brightness: Brightness.light),
    );
    await _pump(tester);
    final l = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l.animusSendUnsupported), findsOneWidget);
    expect(find.text(l.animusSendMissingTime), findsOneWidget);
    expect(find.text(l.animusSavedLocally), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(_sendKey)).onPressed, isNull);
    expect(sender.sent, isEmpty);
    await _capture(tester, 'unsupported');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'all four locales hold at narrow large text, including confirmation',
    (tester) async {
      await connect();
      setPhone(tester, width: 320, height: 900, textScale: 2);
      for (final code in ['en', 'de', 'es', 'it']) {
        sender.current = _selection(
          status: AnimusWorkoutSendStatus.needsReview,
          issue: AnimusWorkoutSendIssue.accessDenied,
        );
        await tester.pumpWidget(
          _wrap(sender, connection, locale: Locale(code)),
        );
        await _pump(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: '$code needs review layout',
        );
        if (code == 'de') await _capture(tester, 'german-large-text');
        sender.publish(_selection());
        await _pump(tester);
        await tester.ensureVisible(find.byKey(_sendKey));
        await tester.tap(find.byKey(_sendKey));
        await _pump(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: '$code confirmation layout',
        );
        if (code == 'de') {
          await _capture(tester, 'german-confirmation-large-text');
        }
        final l = lookupAppLocalizations(Locale(code));
        await tester.ensureVisible(find.text(l.commonCancel));
        await tester.tap(find.text(l.commonCancel));
        await _pump(tester);
        expect(sender.sent, isEmpty);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets('Profile retains connection controls and explains active send', (
    tester,
  ) async {
    await connect();
    sender.busy = true;
    setPhone(tester, width: 320, height: 900, textScale: 2);
    await tester.pumpWidget(
      _wrap(sender, connection, profile: true, locale: const Locale('de')),
    );
    await _pump(tester);
    final l = lookupAppLocalizations(const Locale('de'));
    expect(find.text(l.animusSendConnectionBusy), findsOneWidget);
    expect(find.text(l.animusDisconnect), findsOneWidget);
    expect(find.textContaining('synthetic-selected-owner'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'profile-german-large-text');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ordinary ready connection does not claim a reviewed view', (
    tester,
  ) async {
    await connect();
    final review = _Review();
    addTearDown(review.dispose);
    review.publish(
      const RecoveryReviewSnapshot(
        required: false,
        adopted: false,
        manualDisposition: false,
      ),
    );
    sender.current = _selection();
    await tester.pumpWidget(_wrap(sender, connection, review: review));
    await _pump(tester);
    final l = lookupAppLocalizations(const Locale('en'));
    expect(find.byKey(const Key('animus-recovery-review')), findsNothing);
    expect(find.text(l.animusRecoveryAdopted), findsNothing);
    expect(find.text(l.animusSavedLocally), findsOneWidget);
    expect(
      tester.widget<TextButton>(find.byKey(_sendKey)).onPressed,
      isNotNull,
    );
    expect(review.comparisons, 0);
    expect(review.adoptions, isEmpty);
    expect(review.retries, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'review opening and hiding never grant permission or send; incomplete stage cannot adopt',
    (tester) async {
      await connect();
      final review = _Review();
      addTearDown(review.dispose);
      sender.current = _selection(
        status: AnimusWorkoutSendStatus.needsReview,
        issue: AnimusWorkoutSendIssue.recoveryBlocked,
      );
      await tester.pumpWidget(_wrap(sender, connection, review: review));
      await _pump(tester);
      final l = lookupAppLocalizations(const Locale('en'));
      expect(review.comparisons, 0);
      expect(review.adoptions, isEmpty);
      expect(sender.sent, isEmpty);
      expect(tester.widget<TextButton>(find.byKey(_sendKey)).onPressed, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _pump(tester);
      expect(find.text(l.animusRecoveryCoverage), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('animus-recovery-adopt')))
            .onPressed,
        isNull,
      );
      final semantics = tester.ensureSemantics();
      expect(
        tester
            .getSemantics(find.byKey(const Key('animus-recovery-compare')))
            .label,
        l.animusRecoveryCompare,
      );
      semantics.dispose();
      await tester.tap(find.byKey(const Key('animus-recovery-open')));
      await _pump(tester);
      expect(review.comparisons, 0);
      expect(review.adoptions, isEmpty);
      expect(review.retries, isEmpty);
      expect(sender.sent, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'explicit comparison/adoption keeps ordinary send blocked; reviewed retry requires its own confirmation',
    (tester) async {
      await connect();
      final review = _Review();
      addTearDown(review.dispose);
      sender.current = _selection(
        status: AnimusWorkoutSendStatus.needsReview,
        issue: AnimusWorkoutSendIssue.recoveryBlocked,
      );
      await tester.pumpWidget(_wrap(sender, connection, review: review));
      await _pump(tester);
      final l = lookupAppLocalizations(const Locale('en'));
      await tester.tap(find.byKey(const Key('animus-recovery-open')));
      await _pump(tester);
      await tester.tap(find.byKey(const Key('animus-recovery-compare')));
      await _pump(tester);
      expect(review.comparisons, 1);
      await tester.tap(find.byKey(const Key('animus-recovery-adopt')));
      await _pump(tester);
      expect(review.adoptions, isEmpty);
      await tester.tap(
        find.widgetWithText(TextButton, l.animusRecoveryAdopt).last,
      );
      await _pump(tester);
      expect(review.adoptions, ['synthetic-stage']);
      expect(tester.widget<TextButton>(find.byKey(_sendKey)).onPressed, isNull);
      expect(sender.sent, isEmpty);
      await tester.tap(find.byKey(const Key('animus-recovery-retry')));
      await _pump(tester);
      expect(review.retries, isEmpty);
      await tester.tap(find.text(l.commonCancel));
      await _pump(tester);
      expect(review.retries, isEmpty);
      await tester.tap(find.byKey(const Key('animus-recovery-retry')));
      await _pump(tester);
      await tester.tap(
        find.widgetWithText(TextButton, l.animusRecoveryRetry).last,
      );
      await _pump(tester);
      expect(review.retries, ['$_session/synthetic-stage']);
      expect(sender.sent, isEmpty);
      expect(find.text(l.animusRecoveryReviewedReply), findsOneWidget);
      expect(find.text(l.animusSavedLocally), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'confirmation cannot adopt a replaced stage or retry after account changes',
    (tester) async {
      await connect();
      final review = _Review();
      addTearDown(review.dispose);
      await review.compare();
      await tester.pumpWidget(_wrap(sender, connection, review: review));
      await _pump(tester);
      final l = lookupAppLocalizations(const Locale('en'));
      await tester.tap(find.byKey(const Key('animus-recovery-open')));
      await _pump(tester);
      await tester.tap(find.byKey(const Key('animus-recovery-adopt')));
      await _pump(tester);
      review.publish(
        RecoveryReviewSnapshot(
          required: true,
          adopted: false,
          manualDisposition: false,
          canAdopt: true,
          stage: _reviewStage(id: 'newer-stage', verified: true),
        ),
      );
      await _pump(tester);
      await tester.tap(
        find.widgetWithText(TextButton, l.animusRecoveryAdopt).last,
      );
      await _pump(tester);
      expect(review.adoptions, isEmpty);
      await review.adopt('newer-stage');
      await _pump(tester);
      await tester.tap(find.byKey(const Key('animus-recovery-retry')));
      await _pump(tester);
      await connection.disconnect();
      await tester.tap(
        find.widgetWithText(TextButton, l.animusRecoveryRetry).last,
      );
      await _pump(tester);
      expect(review.retries, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'recovery comparison uses incumbent themes and four locales at narrow large text',
    (tester) async {
      await connect();
      setPhone(tester, width: 320, height: 900, textScale: 2);
      final review = _Review();
      addTearDown(review.dispose);
      review.publish(
        RecoveryReviewSnapshot(
          required: true,
          adopted: false,
          manualDisposition: true,
          canAdopt: true,
          stage: _reviewStage(verified: true),
        ),
      );
      sender.current = _selection(
        status: AnimusWorkoutSendStatus.needsReview,
        issue: AnimusWorkoutSendIssue.recoveryBlocked,
      );
      for (final brightness in Brightness.values) {
        for (final code in ['en', 'de', 'es', 'it']) {
          await tester.pumpWidget(
            _wrap(
              sender,
              connection,
              review: review,
              locale: Locale(code),
              brightness: brightness,
            ),
          );
          await _pump(tester);
          await tester.ensureVisible(
            find.byKey(const Key('animus-recovery-open')),
          );
          await tester.tap(find.byKey(const Key('animus-recovery-open')));
          await _pump(tester);
          expect(
            find.byKey(const Key('animus-recovery-unknown-history')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull, reason: '$code/$brightness');
          for (final key in [
            'animus-recovery-open',
            'animus-recovery-compare',
            'animus-recovery-adopt',
          ]) {
            expect(
              tester.getSize(find.byKey(Key(key))).height,
              greaterThanOrEqualTo(48),
            );
          }
          if (code == 'en' && brightness == Brightness.dark ||
              code == 'de' && brightness == Brightness.light) {
            await tester.ensureVisible(
              find.byKey(const Key('animus-saved-locally')),
            );
            await _pump(tester);
            await _capture(tester, 'recovery-${brightness.name}-$code-top');
            await tester.ensureVisible(
              find.byKey(const Key('animus-recovery-adopt')),
            );
            await _pump(tester);
            await _capture(tester, 'recovery-${brightness.name}-$code-actions');
          }
          await tester.pumpWidget(const SizedBox());
        }
      }
    },
  );

  testWidgets(
    'selected action composes with real SQLite History without hiding editors',
    (tester) async {
      final harness = ScreenHarness();
      addTearDown(harness.close);
      await harness.open(tester);
      await connect();
      await tester.pumpWidget(
        harness.wrap(
          const Scaffold(body: HistoryScreen()),
          extra: [
            ListenableProvider<AnimusWorkoutSendPort?>.value(value: sender),
            ChangeNotifierProvider<AnimusConnectionController?>.value(
              value: connection,
            ),
          ],
        ),
      );
      await pumpUntilFound(tester, find.byType(SessionCard));
      final card = find.byType(SessionCard).first;
      await tester.ensureVisible(card);
      await tester.tap(card, warnIfMissed: false);
      await settleReal(tester, ticks: 10);
      expect(find.byType(AnimusWorkoutSendPanel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('history-add-exercise')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('history-delete-session')),
        findsOneWidget,
      );
      expect(auth.calls, 2); // Only the explicit connect/confirm above.
      expect(sender.selectedIds, isEmpty);
      expect(sender.sent, isEmpty);
      expect(tester.takeException(), isNull);
      await harness.unmount(tester);
    },
  );
}
