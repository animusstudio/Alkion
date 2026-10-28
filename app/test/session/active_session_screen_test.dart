import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/session/session_summary_screen.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/session/set_line.dart';
import 'package:alkion/session/exercise_picker_sheet.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/widgets/ruler_picker.dart';
import '../support/l10n_harness.dart';
import '../support/app_fonts.dart';
import '../support/layout_expect.dart';
import '../support/screen_harness.dart' as real;
import '../alkion/domains/prepared_intent_retry_test.dart' show FaultDatabase;

/// Minimal providers for isolated live controls. Store-backed Finish tests use
/// the existing real SQLite ScreenHarness below.
Widget _harness(
  ActiveSessionController controller, {
  SettingsService? settings,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<ActiveSessionController>.value(value: controller),
      ChangeNotifierProvider<SessionManager>(create: (_) => SessionManager()),
      ChangeNotifierProvider<SettingsService>.value(
        value: settings ?? SettingsService(),
      ),
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
      home: const ActiveSessionScreen(),
    ),
  );
}

const _bench = Exercise(
  id: 'bench',
  name: 'Bench',
  slug: 'bench',
  muscleGroup: 'chest',
  compound: true,
  plateStepKg: 2.5,
  isTemplate: false,
);

const _compound = Exercise(
  id: 'squat',
  name: 'Squat',
  slug: 'squat',
  muscleGroup: 'legs',
  compound: true,
  plateStepKg: 2.5,
  isTemplate: false,
);

BlockState _block({
  required List<SetState> warm,
  required List<SetState> work,
  Exercise ex = _compound,
}) => BlockState(
  exercise: ex,
  resolved: ResolvedSlot(
    exercise: ex,
    workSets: work.length,
    warmupSets: warm.length,
    repLow: 8,
    repHigh: 10,
    rirLow: 1,
    rirHigh: 1,
  ),
  warmupSets: warm,
  workingSets: work,
  expanded: true,
);

SessionDraft _draftWith(List<BlockState> blocks) => SessionDraft(
  templateId: 't',
  name: 'Leg day',
  focus: '',
  startedAt: DateTime.now(),
  blocks: blocks,
);

/// Ends the test by swapping in a widget with no ticker, so the screen's
/// 1-second Timer.periodic actually disposes before the test binding checks
/// for pending timers.
Future<void> _teardown(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox());

void main() {
  setUpAll(preloadAppFonts);
  for (final refuseCommit in [false, true]) {
    testWidgets(
      'held Finish hides recovery notice and ${refuseCommit ? 'failed retry' : 'success'} stays truthful',
      (tester) async {
        final harness = real.ScreenHarness();
        ActiveSessionController? controller;
        SessionManager? manager;
        final releases = <Completer<void>>[];
        try {
          await harness.open(
            tester,
            seed: (db) => db.execute(
              'INSERT INTO exercises (id,name,is_template) VALUES (?,?,0)',
              ['bench', 'Bench'],
            ),
          );
          late Zone zone;
          late FaultDatabase database;
          await tester.runAsync(() async {
            zone = Zone.current;
            final drafts = DraftStore.local(harness.database);
            await drafts.load();
            controller = ActiveSessionController(draftStore: drafts)
              ..seedForTest(
                SessionDraft(
                  templateId: null,
                  name: 'Synthetic workout',
                  focus: '',
                  startedAt: DateTime.now(),
                  blocks: [
                    _block(
                      ex: _bench,
                      warm: [],
                      work: [
                        SetState(
                          id: 'finish-set',
                          weightKg: 20,
                          reps: 5,
                          rir: 1,
                          isWarmup: false,
                          done: true,
                        ),
                      ],
                    ),
                  ],
                ),
              );
            await controller!.flushPersistence();
            manager = SessionManager(
              draftStore: drafts,
              finishedStore: FinishedSessionStore.local(harness.database),
            );
            manager!.register(controller!);
            await manager!.flushPersistence();
            final release = Completer<void>();
            releases.add(release);
            database = FaultDatabase(
              harness.database.store,
              beforeCommit: refuseCommit,
              gate: release,
            );
          });
          Future<void> mount() => tester.pumpWidget(
            harness.wrap(
              const ActiveSessionScreen(),
              extra: [
                Provider<LocalDatabase>.value(
                  value: real.RealZoneDatabase(database, zone),
                ),
                ChangeNotifierProvider<SessionManager>.value(value: manager!),
                ChangeNotifierProvider<ActiveSessionController>.value(
                  value: controller!,
                ),
              ],
            ),
          );
          await mount();
          await real.settleReal(tester, ticks: 3);
          final l = AppLocalizations.of(
            tester.element(find.byType(ActiveSessionScreen)),
          );
          final warning = find.text(l.alkionStoreRecoveryBody);
          if (!refuseCommit) {
            manager!.freezeCallbacks(7);
            await tester.pump();
            expect(
              warning,
              findsOneWidget,
              reason: 'a genuine non-Finish hold stays visible',
            );
            manager!.resumeCallbacks(DateTime.now(), generation: 7);
            await tester.pump();
            expect(warning, findsNothing);
          }
          await tester.tap(find.byKey(const Key('log-set-bar')));
          await real.settleReal(tester, ticks: 2);
          final intent = controller!.pendingFinish!;
          expect(
            database.actions,
            hasLength(1),
            reason: 'real Finish is waiting at the gate',
          );
          expect(
            controller!.captureFrozen.value,
            isTrue,
            reason: 'the write fence remains active',
          );
          expect(
            warning,
            findsNothing,
            reason: 'in-flight Finish has not failed',
          );
          expect(find.byType(SessionSummaryScreen), findsNothing);
          expect(
            await tester.runAsync(
              () => harness.database.getAll('SELECT * FROM sessions'),
            ),
            isEmpty,
          );
          await tester.runAsync(() async => releases.single.complete());
          if (refuseCommit) {
            await real.settleUntilFound(
              tester,
              find.text(l.sessionSaveFailedMessage),
              where: 'real COMMIT refusal',
            );
            expect(
              warning,
              findsOneWidget,
              reason: 'failed Finish must expose preserved work',
            );
            expect(controller!.pendingFinish, same(intent));
            expect(controller!.hasSession, isTrue);
            expect(manager!.lastFinished, isNull);
            expect(find.byType(SessionSummaryScreen), findsNothing);
            expect(
              await tester.runAsync(
                () => harness.database.getAll('SELECT * FROM sessions'),
              ),
              isEmpty,
            );
            final screenState = tester.state(find.byType(ActiveSessionScreen));
            final first = database;
            await tester.runAsync(() async {
              final release = Completer<void>();
              releases.add(release);
              database = FaultDatabase(harness.database.store, gate: release);
            });
            await mount();
            await tester.pump();
            expect(
              tester.state(find.byType(ActiveSessionScreen)),
              same(screenState),
            );
            expect(warning, findsOneWidget);
            await tester.tap(find.byKey(const Key('log-set-bar')));
            await real.settleReal(tester, ticks: 2);
            expect(controller!.pendingFinish, same(intent));
            expect(
              database.actions,
              hasLength(1),
              reason: 'same intent retry is held before COMMIT',
            );
            expect(
              warning,
              findsNothing,
              reason:
                  'retrying must rebuild even though captureFrozen stays true',
            );
            expect(controller!.captureFrozen.value, isTrue);
            expect(find.byType(SessionSummaryScreen), findsNothing);
            expect(first.actions.single.hash, database.actions.single.hash);
            await tester.runAsync(() async => releases.last.complete());
          }
          await real.settleUntilFound(
            tester,
            find.byType(SessionSummaryScreen),
            where: 'durable Finish',
          );
          final sessions = await tester.runAsync(
            () => harness.database.getAll('SELECT * FROM sessions'),
          );
          final operations = await tester.runAsync(
            () => harness.database.getAll(
              "SELECT * FROM operations WHERE action='workoutFinish'",
            ),
          );
          final sets = await tester.runAsync(
            () => harness.database.getAll('SELECT * FROM sets'),
          );
          expect(sessions!.single['id'], intent.action.target.id);
          expect(operations!.single['operation_id'], intent.action.operationId);
          expect(operations.single['input_hash'], intent.action.hash);
          expect(sets!.single['id'], 'finish-set');
          expect(sets.single['reps'], 5);
          expect(manager!.lastFinished!.sessionId, intent.action.target.id);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.runAsync(() async {
            for (final release in releases) {
              if (!release.isCompleted) release.complete();
            }
          });
          await harness.unmount(tester);
          controller?.dispose();
          manager?.dispose();
          await harness.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
  for (final code in ['en', 'de', 'es', 'it']) {
    testWidgets(
      'live exercise picker keeps clear, keyboard targets and exact identity in $code at 320dp 2x',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        Exercise? picked;
        await tester.pumpWidget(
          wrapL10n(
            Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  picked = await showExercisePicker(
                    context,
                    exercises: [_bench, _compound],
                  );
                },
                child: const Text('Open'),
              ),
            ),
            locale: Locale(code),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final field = find.byType(TextField);
        await tester.enterText(field, 'Bench');
        await tester.pumpAndSettle();
        expect(find.text('Bench'), findsWidgets);
        expect(find.text('Squat'), findsNothing);
        final focus = tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode;
        final clear = find.byTooltip(
          MaterialLocalizations.of(tester.element(field)).clearButtonTooltip,
        );
        expect(tester.getSize(clear).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(clear).height, greaterThanOrEqualTo(48));
        expect(tester.getRect(clear).bottom, lessThanOrEqualTo(560));
        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller!.text, isEmpty);
        expect(
          tester.widget<EditableText>(find.byType(EditableText)).focusNode,
          same(focus),
        );
        expect(focus.hasFocus, isTrue);
        expect(find.text('Bench'), findsOneWidget);
        expect(find.text('Squat'), findsOneWidget);
        expectNoSplitWords(tester);
        await tester.ensureVisible(find.text('Squat'));
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.text('Squat')).bottom,
          lessThanOrEqualTo(560),
        );
        await tester.tap(find.text('Squat'));
        await tester.pumpAndSettle();
        expect(picked, same(_compound));
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('logging a warm-up starts no rest', (tester) async {
    final controller = ActiveSessionController();
    final warm = SetState(
      id: 'w1',
      weightKg: 20,
      reps: 8,
      rir: null,
      isWarmup: true,
      done: false,
    );
    final work = SetState(
      id: 's1',
      weightKg: 100,
      reps: 8,
      rir: 1,
      isWarmup: false,
      done: false,
    );
    controller.seedForTest(
      _draftWith([
        _block(warm: [warm], work: [work]),
      ]),
    );

    await tester.pumpWidget(_harness(controller));
    await tester.pump();

    await tester.tap(find.byKey(const Key('log-set-bar')));
    await tester.pump();

    expect(controller.resting, isFalse);
    expect(warm.done, isTrue);

    await _teardown(tester);
  });

  testWidgets(
    'logging a working set on a compound exercise with no per-exercise '
    'rest override starts rest at the settings compound default',
    (tester) async {
      final controller = ActiveSessionController();
      final work = SetState(
        id: 's1',
        weightKg: 100,
        reps: 8,
        rir: 1,
        isWarmup: false,
        done: false,
      );
      controller.seedForTest(
        _draftWith([
          _block(warm: [], work: [work]),
        ]),
      );
      final settings = SettingsService();

      await tester.pumpWidget(_harness(controller, settings: settings));
      await tester.pump();

      await tester.tap(find.byKey(const Key('log-set-bar')));
      await tester.pump();

      expect(work.done, isTrue);
      expect(controller.resting, isTrue);
      expect(controller.restTotal, settings.restCompoundSeconds);
      expect(settings.restCompoundSeconds, 180);

      await _teardown(tester);
    },
  );

  testWidgets(
    'swipe-remove a pending set, then Undo restores it at its index',
    (tester) async {
      final controller = ActiveSessionController();
      final s0 = SetState(
        id: 's0',
        weightKg: 100,
        reps: 8,
        rir: 1,
        isWarmup: false,
        done: false,
      );
      final s1 = SetState(
        id: 's1',
        weightKg: 100,
        reps: 8,
        rir: 1,
        isWarmup: false,
        done: false,
      );
      final block = _block(warm: [], work: [s0, s1]);
      controller.seedForTest(_draftWith([block]));

      await tester.pumpWidget(_harness(controller));
      await tester.pump();
      // Let the blocks' one-shot Reveal entrance animations finish.
      await tester.pump(const Duration(milliseconds: 400));

      expect(block.workingSets, [s0, s1]);

      // Swipe s0 (index 0) away.
      await tester.drag(
        find.byKey(const Key('dismiss-s0')),
        const Offset(-500, 0),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(block.workingSets, [s1]);

      // A real tap on the SnackBarAction is geometrically unreliable in a
      // narrow test surface (the bar sits right above the pinned LogSetBar and
      // widget-test hit-testing on SnackBars is a known-flaky area) — invoke
      // its callback directly; this still exercises exactly what the screen
      // wires up (`_removeSet`'s `SnackBarAction.onPressed`).
      final action = tester.widget<SnackBarAction>(find.byType(SnackBarAction));
      action.onPressed();
      await tester.pump();

      expect(block.workingSets, [s0, s1]);

      await _teardown(tester);
    },
  );

  testWidgets('a ruler change stays on its set when another set is tapped', (
    tester,
  ) async {
    final controller = ActiveSessionController();
    final s0 = SetState(
      id: 's0',
      weightKg: 100,
      reps: 8,
      rir: 1,
      isWarmup: false,
      done: false,
    );
    final s1 = SetState(
      id: 's1',
      weightKg: 120,
      reps: 8,
      rir: 1,
      isWarmup: false,
      done: false,
    );
    final block = _block(warm: [], work: [s0, s1]);
    controller.seedForTest(_draftWith([block]));

    await tester.pumpWidget(_harness(controller));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(controller.liveSet!.set.id, 's0');

    // ~180 dp/s: comfortably above the 120 dp/s zoom-in threshold and below
    // the 300 dp/s fling dead zone, so it stays a plain 2-step coarse swipe.
    await tester.timedDrag(
      find.byKey(const Key('live-weight')),
      const Offset(-2 * RulerPicker.defaultItemExtent, 0),
      const Duration(milliseconds: 800),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100)); // let the tape snap
    }
    expect(s0.weightKg, 102);

    await tester.tap(find.byType(SetLine));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(s0.weightKg, 102);
    expect(s1.weightKg, 120);
    expect(controller.liveSet!.set.id, 's1');

    await _teardown(tester);
  });

  testWidgets('long-pressing a block header opens exercise reordering', (
    tester,
  ) async {
    final controller = ActiveSessionController();
    final squat = _block(
      warm: [],
      work: [
        SetState(
          id: 'q1',
          weightKg: 100,
          reps: 8,
          rir: 1,
          isWarmup: false,
          done: true,
        ),
      ],
    )..expanded = false;
    final bench = _block(
      warm: [],
      work: [
        SetState(
          id: 'b1',
          weightKg: 80,
          reps: 8,
          rir: 1,
          isWarmup: false,
          done: false,
        ),
      ],
      ex: _bench,
    );
    controller.seedForTest(_draftWith([squat, bench]));

    await tester.pumpWidget(_harness(controller));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.longPress(find.text('Squat'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(tester.takeException(), isNull);
    expect(find.text('Reorder exercises'), findsOneWidget);
    expect(find.byKey(const ValueKey('reorder-handle-bench')), findsOneWidget);

    await _teardown(tester);
  });

  testWidgets(
    'switching sets mid-fling leaves the first set at the value shown',
    (tester) async {
      final controller = ActiveSessionController();
      final s0 = SetState(
        id: 's0',
        weightKg: 100,
        reps: 8,
        rir: 1,
        isWarmup: false,
        done: false,
      );
      final s1 = SetState(
        id: 's1',
        weightKg: 120,
        reps: 8,
        rir: 1,
        isWarmup: false,
        done: false,
      );
      controller.seedForTest(
        _draftWith([
          _block(warm: [], work: [s0, s1]),
        ]),
      );

      await tester.pumpWidget(_harness(controller));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.fling(
        find.byKey(const Key('live-weight')),
        const Offset(-150, 0),
        3000,
      );
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      final shown = s0.weightKg;
      await tester.tap(find.byType(SetLine));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(tester.takeException(), isNull);
      expect(controller.liveSet!.set.id, 's1');
      expect(s0.weightKg, shown);
      expect(s1.weightKg, 120);

      await _teardown(tester);
    },
  );
}
