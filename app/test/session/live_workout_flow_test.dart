import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/shell/session_launcher.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/units/unit_service.dart';

import '../support/app_fonts.dart';

// P7 live workout flow: discard predicate, Undo, early finish, screen-reader
// announcements, the lb suggestion grid and the reduced-motion launch. All
// controller state is seeded; rest ownership is compared against the
// `restStart` each test captures, never against real timers.

final AppLocalizations _l = lookupAppLocalizations(const Locale('en'));

const _squat = Exercise(
  id: 'squat',
  name: 'Squat',
  slug: 'squat',
  muscleGroup: 'legs',
  compound: true,
  plateStepKg: 2.5,
  isTemplate: false,
);

const _curl = Exercise(
  id: 'curl',
  name: 'Curl',
  slug: 'curl',
  muscleGroup: 'arms',
  compound: false,
  plateStepKg: 2.5,
  isTemplate: false,
);

SetState _set(String id, {bool warmup = false, bool done = false}) => SetState(
  id: id,
  weightKg: warmup ? 40 : 100,
  reps: warmup ? 8 : 5,
  rir: null,
  isWarmup: warmup,
  done: done,
);

ResolvedSlot _resolved(Exercise ex, {int work = 2, int warm = 1}) =>
    ResolvedSlot(
      exercise: ex,
      workSets: work,
      warmupSets: warm,
      repLow: 5,
      repHigh: 8,
      rirLow: null,
      rirHigh: null,
    );

BlockState _block(List<SetState> warm, List<SetState> work) => BlockState(
  exercise: _squat,
  resolved: _resolved(_squat, work: work.length, warm: warm.length),
  warmupSets: warm,
  workingSets: work,
  expanded: true,
);

SessionDraft _draft(List<BlockState> blocks) => SessionDraft(
  templateId: 't',
  name: 'Leg day',
  focus: '',
  startedAt: DateTime.now(),
  blocks: blocks,
);

/// A discard refused like one blocked by a pending notification action.
class _BusyController extends ActiveSessionController {
  @override
  Future<void> discard() =>
      Future.error(const StoreException('notification_action_pending'));
}

/// The live workout pushed over a launcher route, so leaving it is visible.
Widget _app(ActiveSessionController controller) => MultiProvider(
  providers: [
    ChangeNotifierProvider<ActiveSessionController>.value(value: controller),
    ChangeNotifierProvider<SessionManager>(create: (_) => SessionManager()),
    ChangeNotifierProvider<SettingsService>(create: (_) => SettingsService()),
    ChangeNotifierProvider<UnitService>(create: (_) => UnitService()),
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
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const ActiveSessionScreen(),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester, ActiveSessionController c) async {
  await tester.pumpWidget(_app(c));
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// Ends the test with no screen ticker or toast timer left running.
Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 6));
}

Future<void> _pickFromWorkoutMenu(WidgetTester tester, String label) async {
  await tester.tap(find.bySemanticsLabel(_l.sessionWorkoutOptions));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Records every screen-reader announcement the app sends.
List<String> _captureAnnouncements(WidgetTester tester) {
  final said = <String>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
    SystemChannels.accessibility,
    (message) async {
      final map = message as Map<Object?, Object?>;
      if (map['type'] == 'announce') {
        said.add((map['data'] as Map<Object?, Object?>)['message'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
          SystemChannels.accessibility,
          null,
        ),
  );
  return said;
}

void main() {
  setUpAll(preloadAppFonts);

  group('controller', () {
    test('a pristine draft has no edits; any touch, log or change has', () {
      final edits = <String, void Function(ActiveSessionController, SetState)>{
        'weight': (_, s) => s.weightKg = 102.5,
        'reps': (_, s) => s.reps = 6,
        'rir': (_, s) => s.rir = 2,
        'done': (c, _) => c.logLiveSet(),
        'set added': (c, _) => c.addSet(c.draft.blocks.single),
        'set removed': (c, s) => c.removeSet(c.draft.blocks.single, s),
        'warm-up added': (c, _) => c.addWarmupSet(c.draft.blocks.single),
        'block removed': (c, _) => c.removeBlock(c.draft.blocks.single),
      };
      for (final MapEntry(:key, :value) in edits.entries) {
        final first = _set('a');
        final c = ActiveSessionController()
          ..seedForTest(
            _draft([
              _block([], [first, _set('b')]),
            ]),
          );
        expect(c.hasEdits, isFalse, reason: 'pristine before $key');
        value(c, first);
        expect(c.hasEdits, isTrue, reason: key);
        c.dispose();
      }
      final moved = ActiveSessionController()
        ..seedForTest(
          _draft([
            _block([], [_set('a')]),
            _block([], [_set('b')]),
          ]),
        );
      moved.moveBlock(moved.draft.blocks.first, 1);
      expect(moved.hasEdits, isTrue, reason: 'block moved');
      moved.dispose();
      final adopted = ActiveSessionController.fromDraft(
        _draft([
          _block([], [_set('a')]),
        ]),
      );
      expect(
        adopted.hasEdits,
        isTrue,
        reason: 'structure changes are not in the draft file, so ask',
      );
      adopted.dispose();
    });

    test('undoLog stops only the rest its own log started', () {
      final a = _set('a');
      final b = _set('b');
      final c = ActiveSessionController()
        ..seedForTest(
          _draft([
            _block([], [a, b]),
          ]),
        );
      addTearDown(c.dispose);

      // a's log starts rest A; undo stops it and restores the rested mark.
      final earlierEnd = DateTime.now().subtract(const Duration(minutes: 3));
      c.setRestRaw(null, 0);
      c.restEndedAt = earlierEnd;
      final logA = c.logLiveSet()!;
      expect(logA.set, same(a));
      c.startRestAfterLog(a, 90);
      final restA = c.restStart;
      expect(restA, isNotNull);
      expect(c.restStartedBy(a), isTrue);
      expect(c.undoLog(a), isTrue);
      expect(a.done, isFalse);
      expect(c.liveSet!.set, same(a), reason: 'restored as the live set');
      expect(c.rirPromptSetId, isNull);
      expect(c.restStart, isNull);
      expect(c.restEndedAt, earlierEnd);

      // a then b: b's newer rest keeps running when a is undone.
      c.logLiveSet();
      c.startRestAfterLog(a, 90);
      c.logLiveSet();
      c.startRestAfterLog(b, 120);
      final restB = c.restStart;
      expect(c.undoLog(a), isTrue);
      expect(c.restStart, restB);
      expect(c.restTotal, 120);

      // Re-log a, which starts no rest (as a correction would not): the
      // older rest B keeps running when a is undone again.
      c.logLiveSet();
      expect(c.restStartedBy(a), isFalse);
      expect(c.undoLog(a), isTrue);
      expect(c.restStart, restB);

      // A rest restarted since b's log is not b's any more.
      c.setRestRaw(restB!.add(const Duration(seconds: 1)), 120);
      final restarted = c.restStart;
      expect(c.undoLog(b), isTrue);
      expect(c.restStart, restarted);

      // Gone or already not done: nothing changes.
      expect(c.undoLog(b), isFalse);
      expect(c.undoLog(_set('stranger', done: true)), isFalse);
    });

    test('unlogged working sets exclude warm-ups', () {
      final c = ActiveSessionController()
        ..seedForTest(
          _draft([
            _block(
              [_set('w', warmup: true)],
              [_set('a', done: true), _set('b'), _set('c')],
            ),
          ]),
        );
      addTearDown(c.dispose);
      expect(c.unloggedWorkingSets, 2);
      c.draft.blocks.single.workingSets
          .where((s) => !s.done)
          .forEach((s) => s.done = true);
      expect(c.unloggedWorkingSets, 0);
    });

    test('in lb a 135 lb top set suggests whole multiples of 5 lb', () {
      double lb(double kg) => UnitService.fromKg(kg, Unit.lb);
      void onGrid(double kg, String what) => expect(
        (lb(kg) / 5 - (lb(kg) / 5).round()).abs(),
        lessThan(.01),
        reason: '$what ${lb(kg)} lb',
      );
      final top = UnitService.toKg(135, Unit.lb);
      final compound = buildBlock(
        resolved: _resolved(_squat, warm: 3),
        lastTopKg: top,
        unit: Unit.lb,
      );
      expect(lb(compound.workingSets.first.weightKg).round(), 140);
      for (final s in compound.allSets) {
        onGrid(s.weightKg, 'compound ${s.isWarmup ? 'warm-up' : 'set'}');
      }
      final isolation = buildBlock(
        resolved: _resolved(_curl),
        lastTopKg: top,
        unit: Unit.lb,
      );
      expect(lb(isolation.workingSets.first.weightKg).round(), 135);

      final c = ActiveSessionController()..seedForTest(_draft([compound]));
      addTearDown(c.dispose);
      compound.workingSets.clear();
      c.addSet(compound, unit: Unit.lb);
      onGrid(compound.workingSets.last.weightKg, 'added set');
      c.addWarmupSet(compound, unit: Unit.lb);
      onGrid(compound.warmupSets.last.weightKg, 'added warm-up');
    });

    test('kg suggestions keep the kg plate step', () {
      final block = buildBlock(
        resolved: _resolved(_squat, warm: 2),
        lastTopKg: 61.23,
      );
      expect(block.workingSets.first.weightKg, roundTo(61.23 + 2.5, 2.5));
      expect(block.warmupSets.first.weightKg, roundTo(62.5 * .5, 2.5));
      expect(suggestedWeightKg(61.23, _squat, Unit.kg), 62.5);
    });
  });

  group('discard', () {
    testWidgets('a pristine workout leaves without asking', (tester) async {
      final c = ActiveSessionController()
        ..seedForTest(
          _draft([
            _block([], [_set('a')]),
          ]),
        );
      addTearDown(c.dispose);
      await _open(tester, c);
      await _pickFromWorkoutMenu(tester, _l.sessionDiscardWorkout);
      expect(find.text(_l.sessionDiscardTitle), findsNothing);
      expect(c.hasSession, isFalse);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ActiveSessionScreen), findsNothing);
      await _teardown(tester);
    });

    for (final edit in ['weight', 'reps', 'rir', 'done', 'set added']) {
      testWidgets('after a $edit edit it asks first', (tester) async {
        final a = _set('a');
        final block = _block([], [a, _set('b')]);
        final c = ActiveSessionController()..seedForTest(_draft([block]));
        addTearDown(c.dispose);
        switch (edit) {
          case 'weight':
            a.weightKg = 102.5;
          case 'reps':
            a.reps = 6;
          case 'rir':
            a.rir = 1;
          case 'done':
            a.done = true;
          default:
            c.addSet(block);
        }
        await _open(tester, c);
        await _pickFromWorkoutMenu(tester, _l.sessionDiscardWorkout);
        expect(find.text(_l.sessionDiscardTitle), findsOneWidget);
        expect(
          find.text(
            edit == 'done'
                ? _l.sessionDiscardMessage
                : _l.sessionDiscardChangesOnlyMessage,
          ),
          findsOneWidget,
        );
        await tester.tap(find.text(_l.sessionKeepGoing));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(c.hasSession, isTrue);
        expect(find.byType(ActiveSessionScreen), findsOneWidget);
        await _teardown(tester);
      });
    }

    testWidgets('a discard blocked by a pending action says try again', (
      tester,
    ) async {
      final c = _BusyController()
        ..seedForTest(
          _draft([
            _block([], [_set('a')]),
          ]),
        );
      addTearDown(c.dispose);
      await _open(tester, c);
      await _pickFromWorkoutMenu(tester, _l.sessionDiscardWorkout);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(_l.errorBusy), findsOneWidget);
      expect(find.text(_l.editorSaveFailed), findsNothing);
      expect(find.byType(ActiveSessionScreen), findsOneWidget);
      await _teardown(tester);
    });
  });

  group('undo', () {
    testWidgets('Undo un-logs the set, refocuses it and stops its rest', (
      tester,
    ) async {
      final a = _set('a');
      final c = ActiveSessionController()
        ..seedForTest(
          _draft([
            _block([], [a, _set('b')]),
          ]),
        );
      addTearDown(c.dispose);
      await _open(tester, c);
      await tester.tap(find.byKey(const Key('log-set-bar')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(a.done, isTrue);
      expect(c.restStart, isNotNull);
      expect(find.text(_l.sessionSetLogged(1)), findsOneWidget);
      await tester.tap(find.text(_l.commonUndo));
      await tester.pump();
      expect(a.done, isFalse);
      expect(c.liveSet!.set, same(a));
      expect(c.restStart, isNull);
      await _teardown(tester);
    });

    testWidgets('minimizing takes the Undo toast down with the screen', (
      tester,
    ) async {
      final a = _set('a');
      final c = ActiveSessionController()
        ..seedForTest(
          _draft([
            _block([], [a, _set('b')]),
          ]),
        );
      addTearDown(c.dispose);
      await _open(tester, c);
      await tester.tap(find.byKey(const Key('log-set-bar')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(_l.commonUndo), findsOneWidget);
      await tester.tap(find.bySemanticsLabel(_l.sessionMinimize));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(ActiveSessionScreen), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(find.text(_l.sessionSetLogged(1)), findsNothing);
      expect(find.text(_l.commonUndo), findsNothing);
      expect(a.done, isTrue, reason: 'leaving is not an undo');
      await _teardown(tester);
    });

    testWidgets('Mark as not done keeps a newer rest running', (tester) async {
      final a = _set('a');
      final b = _set('b');
      final c = ActiveSessionController()
        ..seedForTest(
          _draft([
            _block([], [a, b, _set('c')]),
          ]),
        );
      addTearDown(c.dispose);
      await _open(tester, c);
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byKey(const Key('log-set-bar')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect([a.done, b.done], [true, true]);
      final restB = c.restStart;
      expect(c.restStartedBy(b), isTrue);
      expect(find.text(_l.sessionSetLogged(2)), findsOneWidget);
      expect(find.text(_l.sessionSetLogged(1)), findsNothing);
      final menu = find.byTooltip(_l.sessionSetOptions('SET 1'));
      await tester.ensureVisible(menu);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(menu);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(_l.sessionMarkNotDone));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(a.done, isFalse);
      expect(c.restStart, restB);
      await _teardown(tester);
    });

    testWidgets('a warm-up has no Undo toast and is announced', (tester) async {
      final said = _captureAnnouncements(tester);
      final c = ActiveSessionController()
        ..seedForTest(
          _draft([
            _block([_set('w', warmup: true)], [_set('a')]),
          ]),
        );
      addTearDown(c.dispose);
      await _open(tester, c);
      await tester.tap(find.byKey(const Key('log-set-bar')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(_l.commonUndo), findsNothing);
      expect(c.restStart, isNull);
      expect(said, [_l.sessionWarmupLogged]);
      await _teardown(tester);
    });

    testWidgets('the end of rest is announced once', (tester) async {
      final said = _captureAnnouncements(tester);
      final c = ActiveSessionController()
        ..seedForTest(
          _draft([
            _block([], [_set('a', done: true), _set('b')]),
          ]),
        );
      addTearDown(c.dispose);
      c.setRestRaw(DateTime.now().subtract(const Duration(seconds: 91)), 90);
      await _open(tester, c);
      await tester.pump(const Duration(seconds: 3));
      expect(said, [_l.sessionRestOver]);
      expect(c.restStart, isNull);
      await _teardown(tester);
    });
  });

  group('finish', () {
    testWidgets('unlogged working sets ask first; Keep going keeps it', (
      tester,
    ) async {
      final c = ActiveSessionController()
        ..seedForTest(
          _draft([
            _block(
              [_set('w', warmup: true)],
              [_set('a', done: true), _set('b')],
            ),
          ]),
        );
      addTearDown(c.dispose);
      await _open(tester, c);
      await _pickFromWorkoutMenu(tester, _l.sessionFinishWorkout);
      expect(find.text(_l.sessionUnloggedSetsTitle(1)), findsOneWidget);
      await tester.tap(find.text(_l.sessionKeepGoing));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.finishPending, isFalse);
      expect(c.hasSession, isTrue);
      expect(find.byType(ActiveSessionScreen), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('an unlogged warm-up alone does not ask', (tester) async {
      final c = ActiveSessionController()
        ..seedForTest(
          _draft([
            _block([_set('w', warmup: true)], [_set('a', done: true)]),
          ]),
        );
      addTearDown(c.dispose);
      await _open(tester, c);
      await _pickFromWorkoutMenu(tester, _l.sessionFinishWorkout);
      expect(find.textContaining('not logged'), findsNothing);
      await _teardown(tester);
    });

    testWidgets('Finish with nothing logged explains why', (tester) async {
      final c = ActiveSessionController()
        ..seedForTest(
          _draft([
            _block([], [_set('a')]),
          ]),
        );
      addTearDown(c.dispose);
      await _open(tester, c);
      await _pickFromWorkoutMenu(tester, _l.sessionFinishWorkout);
      expect(find.text(_l.sessionFinishNeedsSet), findsOneWidget);
      expect(c.finishPending, isFalse);
      await _teardown(tester);
    });
  });

  group('launch', () {
    for (final reduced in [false, true]) {
      testWidgets('opening the workout ${reduced ? 'with' : 'without'} '
          'reduced motion', (tester) async {
        if (reduced) {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              FakeAccessibilityFeatures.allOn;
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
        }
        final manager = SessionManager();
        final c = ActiveSessionController()
          ..seedForTest(
            _draft([
              _block([], [_set('a')]),
            ]),
          );
        manager.register(c);
        addTearDown(manager.dispose);
        addTearDown(c.dispose);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<SessionManager>.value(value: manager),
              ChangeNotifierProvider<SettingsService>(
                create: (_) => SettingsService(),
              ),
              ChangeNotifierProvider<UnitService>(create: (_) => UnitService()),
            ],
            child: MaterialApp(
              theme: buildTheme(Brightness.dark, accents[0]),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Builder(
                builder: (context) => TextButton(
                  onPressed: () => openActiveSession(context, manager),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pump();
        await tester.pump();
        final screen = find.byType(ActiveSessionScreen);
        expect(screen, findsOneWidget);
        final route = ModalRoute.of(tester.element(screen))!;
        expect(
          route.transitionDuration,
          reduced ? Duration.zero : const Duration(milliseconds: 300),
        );
        expect(
          find.ancestor(of: screen, matching: find.byType(SlideTransition)),
          reduced ? findsNothing : findsWidgets,
        );
        await _teardown(tester);
      });
    }
  });
}
