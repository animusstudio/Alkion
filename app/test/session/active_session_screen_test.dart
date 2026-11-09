import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/catalog_execution.dart';
import 'package:alkion/session/catalog_set_values_editor.dart';
import 'package:alkion/session/live_set_card.dart';
import 'package:alkion/widgets/pending_input.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/session/session_summary_screen.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/active_session_screen.dart';
import 'package:alkion/session/confirmed_set_feedback.dart';
import 'package:alkion/widgets/state_motion.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/session/set_line.dart';
import 'package:alkion/session/exercise_picker_sheet.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/widgets/ruler_picker.dart';
import 'package:alkion/widgets/fit_label.dart';
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
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.dark,
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
      theme: buildTheme(brightness, accents[0]),
      locale: locale,
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
  targetRepRange: (low: 8, high: 10),
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

CatalogSetEvidence _typedEvidence({
  String context = 'Machine A',
  String profile = 'load_reps',
  String load = '020.500',
  String unit = 'lb',
}) => CatalogSetEvidence(
  selection: CatalogSelectionEvidence(
    exerciseId: _compound.id,
    contextId: context,
    contextRevision: 1,
    profile: CatalogMeasurementProfileEvidence.forKey(profile),
    displayLabel: 'Synthetic execution',
    contextLabel: context,
    resistanceSource: 'external',
    loadConvention: 'reported_mass',
  ),
  metrics: {
    if (profile == 'load_reps') ...{
      'reported_load': CatalogMetricEvidence.fromInput(
        load,
        metric: 'reported_load',
        unit: unit,
      ),
      'repetitions': CatalogMetricEvidence.fromInput(
        '08',
        metric: 'repetitions',
        unit: 'count',
      ),
    } else ...{
      'duration': CatalogMetricEvidence.fromInput(
        '00065.250',
        metric: 'duration',
        unit: 's',
      ),
      'distance': CatalogMetricEvidence.fromInput(
        '100.125',
        metric: 'distance',
        unit: 'm',
      ),
    },
  },
);

SetState _typedSet(
  String id,
  CatalogSetEvidence evidence, {
  bool done = false,
  bool warmup = false,
}) => SetState(
  id: id,
  weightKg: 0,
  reps: 0,
  rir: null,
  isWarmup: warmup,
  done: done,
  catalog: evidence,
);

class _RefusingPreferences extends real.RealZoneDatabase {
  _RefusingPreferences(super.database, super.zone);
  bool refuse = true;
  @override
  Future<T> writeTransaction<T>(
    Future<T> Function(LocalTransaction) callback, {
    StoreToken? expected,
  }) => refuse
      ? Future.error(const StoreException('synthetic_write_failure'))
      : super.writeTransaction(callback, expected: expected);
}

void main() {
  setUpAll(preloadAppFonts);
  for (final range in [null, (low: 5, high: 9)]) {
    testWidgets(
      'legacy target $range survives draft separately from default actual seeds',
      (tester) async {
        final harness = real.ScreenHarness();
        addTearDown(harness.close);
        await harness.open(tester);
        await tester.runAsync(
          () => harness.settings.setRepEntry(RepEntry.range),
        );
        final original = buildBlock(
          resolved: const ResolvedSlot(
            exercise: _compound,
            workSets: 1,
            warmupSets: 0,
            repLow: 8,
            repHigh: 8,
            rirLow: null,
            rirHigh: null,
          ),
          repRange: range,
        );
        final observations = original.workingSets.single.toJson();
        final restored = BlockState.fromJson(original.toJson());
        expect(restored.targetRepRange, range);
        expect(restored.workingSets.single.toJson(), observations);
        final oldDraft = original.toJson()..remove('targetRepRange');
        expect(
          BlockState.fromJson(oldDraft).targetRepRange,
          isNull,
          reason: 'old resolved values cannot prove an authored target',
        );
        final controller = ActiveSessionController();
        addTearDown(controller.dispose);
        controller.seedForTest(_draftWith([restored]));
        await tester.pumpWidget(
          _harness(controller, settings: harness.settings),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.text('Rep range: ${range == null ? '—' : '5–9'}'),
          findsOneWidget,
        );
        expect(restored.workingSets.single.toJson(), observations);
        expect(restored.workingSets.single.reps, 8);
        await _teardown(tester);
      },
    );
  }
  testWidgets(
    'failed preference persistence and retry preserve active evidence',
    (tester) async {
      final harness = real.ScreenHarness();
      addTearDown(harness.close);
      await harness.open(tester);
      final database = _RefusingPreferences(harness.database, Zone.current);
      final settings = SettingsService.local(database);
      addTearDown(settings.dispose);
      await tester.runAsync(settings.load);
      final controller = ActiveSessionController();
      addTearDown(controller.dispose);
      final set = _typedSet('unchanged', _typedEvidence())..rir = 99;
      final block = _block(warm: [], work: [set]);
      controller.seedForTest(_draftWith([block]));
      final before = set.toJson();
      final prescription = block.resolved;
      await tester.pumpWidget(_harness(controller, settings: settings));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
        () => expectLater(
          settings.setRirControls(RirControls.show),
          throwsA(isA<StoreException>()),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('rir-2')), findsOneWidget);
      expect(set.toJson(), before);
      expect(block.resolved, same(prescription));
      database.refuse = false;
      await tester.runAsync(settings.flushPersistence);
      expect(set.toJson(), before);
      expect(block.resolved, same(prescription));
      await _teardown(tester);
    },
  );
  for (final profile in ['load_reps', 'duration_distance_optional']) {
    for (final range in [null, (low: 5, high: 9)]) {
      testWidgets(
        'catalog target $range for $profile survives resume separately from observations',
        (tester) async {
          final harness = real.ScreenHarness();
          addTearDown(harness.close);
          await harness.open(tester);
          await tester.runAsync(
            () => harness.settings.setRepEntry(RepEntry.range),
          );
          final original = buildCatalogBlock(
            resolved: _block(
              warm: [],
              work: [_typedSet('seed', _typedEvidence())],
            ).resolved,
            selection: _typedEvidence(profile: profile).selection,
            targets: _typedEvidence(profile: profile).metrics,
            repRange: range,
          );
          final restored = BlockState.fromJson(original.toJson());
          expect(restored.targetRepRange, range);
          final controller = ActiveSessionController();
          addTearDown(controller.dispose);
          controller.seedForTest(_draftWith([restored]));
          await tester.pumpWidget(
            _harness(controller, settings: harness.settings),
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(
            find.text('Rep range: ${range == null ? '—' : '5–9'}'),
            profile == 'load_reps' ? findsOneWidget : findsNothing,
          );
          expect(
            restored.workingSets.single.catalog!.toJson(),
            original.workingSets.single.catalog!.toJson(),
          );
          await _teardown(tester);
        },
      );
    }
  }

  testWidgets(
    'set and exercise menus have separate scopes; logged removal can be cancelled',
    (tester) async {
      final controller = ActiveSessionController();
      addTearDown(controller.dispose);
      final logged = _typedSet('logged', _typedEvidence(), done: true);
      final block = _block(warm: [], work: [logged])
        ..catalogSelection = logged.catalog!.selection;
      controller.seedForTest(_draftWith([block]));
      controller.focusSet(logged);
      await tester.pumpWidget(_harness(controller));
      await tester.pump(const Duration(milliseconds: 400));
      final before = logged.toJson();
      await tester.tap(find.byKey(const Key('block-menu-squat')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Add set'), findsOneWidget);
      expect(find.text('Mark as not done'), findsNothing);
      expect(find.text('Add warm-up'), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('SET 1 options'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Add set'), findsNothing);
      expect(find.text('Mark as not done'), findsOneWidget);
      expect(find.text('Add warm-up'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Remove set?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(block.workingSets, [logged]);
      expect(logged.toJson(), before);
      await _teardown(tester);
    },
  );

  testWidgets(
    'live preferences change presentation without rewriting observations or targets',
    (tester) async {
      real.setPhone(tester, width: 412);
      final controller = ActiveSessionController();
      final harness = real.ScreenHarness();
      addTearDown(harness.close);
      await harness.open(tester);
      final settings = harness.settings;
      addTearDown(controller.dispose);
      final a = SetState(
        id: 'a',
        weightKg: 60.25,
        reps: 7,
        rir: 4,
        isWarmup: false,
        done: false,
      );
      final block = _block(warm: [], work: [a]);
      controller.seedForTest(_draftWith([block]));
      final before = a.toJson();
      final prescription = block.resolved;
      controller.startRest(90);
      final restStart = controller.restStart;
      await tester.pumpWidget(_harness(controller, settings: settings));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('rir-2')), findsNothing);
      expect(find.text('Rep range: 8–10'), findsNothing);
      await tester.runAsync(() => settings.setRirControls(RirControls.show));
      await tester.runAsync(() => settings.setRepEntry(RepEntry.range));
      await tester.pump();
      expect(find.byKey(const Key('rir-2')), findsOneWidget);
      expect(find.text('Rep range: 8–10'), findsOneWidget);
      expect(a.toJson(), before);
      expect(block.resolved, same(prescription));
      await tester.runAsync(() => settings.setRestCompoundSeconds(45));
      await tester.pump();
      expect(controller.restStart, restStart);
      expect(controller.restTotal, 90);
      await tester.runAsync(() => settings.setRirControls(RirControls.off));
      await tester.runAsync(() => settings.setRepEntry(RepEntry.fixed));
      await tester.pump();
      expect(find.byKey(const Key('rir-2')), findsNothing);
      expect(find.text('Rep range: 8–10'), findsNothing);
      expect(a.toJson(), before);
      await tester.tap(find.byKey(const Key('log-set-bar')));
      await tester.pump();
      expect(
        controller.restTotal,
        45,
        reason: 'new rest defaults apply to the next timer',
      );
      await _teardown(tester);
    },
  );

  for (final refuseCommit in [false, true]) {
    testWidgets(
      'held Finish hides the not-saved notice and ${refuseCommit ? 'failed retry' : 'success'} stays truthful',
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
          final warning = find.text(l.finishNotSavedBanner);
          expect(warning, findsNothing);
          await tester.tap(find.byKey(const Key('log-set-bar')));
          await real.settleReal(tester, ticks: 2);
          final intent = controller!.pendingFinish!;
          expect(
            database.actions,
            hasLength(1),
            reason: 'real Finish is waiting at the gate',
          );
          expect(
            controller!.callbacksFrozenListenable.value,
            isTrue,
            reason: 'the write fence remains active',
          );
          expect(
            warning,
            findsNothing,
            reason: 'in-flight Finish has not failed',
          );
          expect(find.byType(SessionSummaryScreen), findsNothing);
          expect(find.byType(SuccessMark), findsNothing);
          expect(
            await tester.runAsync(
              () => harness.database.getAll('SELECT * FROM sessions'),
            ),
            isEmpty,
          );
          // The held Finish is visibly busy, and neither back nor minimize
          // can leave before its summary.
          expect(find.text(l.sessionFinishSaving), findsOneWidget);
          expect(
            tester
                .widget<PopScope<Object?>>(
                  find.byWidgetPredicate((w) => w is PopScope),
                )
                .canPop,
            isFalse,
          );
          await tester.tap(find.bySemanticsLabel(l.sessionMinimize));
          await real.settleReal(tester, ticks: 1);
          expect(find.byType(ActiveSessionScreen), findsOneWidget);
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
            expect(find.byType(SuccessMark), findsNothing);
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
              reason: 'retrying must rebuild even though callbacks stay frozen',
            );
            expect(controller!.callbacksFrozenListenable.value, isTrue);
            expect(find.byType(SessionSummaryScreen), findsNothing);
            expect(find.byType(SuccessMark), findsNothing);
            expect(first.actions.single.hash, database.actions.single.hash);
            await tester.runAsync(() async => releases.last.complete());
          }
          await real.settleUntilFound(
            tester,
            find.byType(SessionSummaryScreen),
            where: 'durable Finish',
          );
          await real.settleUntilFound(
            tester,
            find.byType(SuccessMark),
            where: 'confirmed summary mark',
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
    'explicitly delete a pending set, then Undo restores it at its index',
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

      await tester.tap(find.byKey(const Key('set-menu-s0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

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
  for (final mode in ['log', 'next']) {
    testWidgets('catalog $mode settles a fling on its own immutable evidence', (
      tester,
    ) async {
      real.setPhone(tester, width: 412);
      final controller = ActiveSessionController();
      addTearDown(controller.dispose);
      final a = _typedSet('typed-a', _typedEvidence(load: '60', unit: 'kg'));
      final b = _typedSet('typed-b', _typedEvidence(context: 'Machine B'));
      final block = _block(warm: [], work: [a, b])
        ..catalogSelection = a.catalog!.selection;
      controller.seedForTest(_draftWith([block]));
      await tester.pumpWidget(_harness(controller));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LiveSetCard), findsOneWidget);
      expect(find.byType(CatalogSetValuesEditor), findsOneWidget);
      expect(find.byType(SetLine), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.fling(
        find.byKey(const Key('catalog-ruler-reported_load')),
        const Offset(-150, 0),
        3000,
      );
      await tester.pump(const Duration(milliseconds: 32));
      final shown = a.catalog!.toJson();
      if (mode == 'log') {
        await tester.tap(find.byKey(const Key('log-set-bar')));
      } else {
        await tester.ensureVisible(find.byType(SetLine));
        await tester.tap(find.byType(SetLine));
      }
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(a.catalog!.toJson(), shown);
      expect(a.done, mode == 'log');
      expect(controller.liveSet!.set, same(b));
      expect(b.catalog!.metrics['reported_load']!.raw, '020.500');
      expect(b.catalog!.metrics['reported_load']!.unit, 'lb');
      expect(controller.resting, mode == 'log');
      expect(tester.takeException(), isNull);
      await _teardown(tester);
    });
  }

  testWidgets(
    'catalog modal, done correction and RIR use the incumbent focused card',
    (tester) async {
      real.setPhone(tester, width: 412);
      final controller = ActiveSessionController();
      addTearDown(controller.dispose);
      final a = _typedSet('typed-a', _typedEvidence())..rir = 99;
      final b = _typedSet('typed-b', _typedEvidence(context: 'Machine B'));
      final block = _block(warm: [], work: [a, b])
        ..catalogSelection = a.catalog!.selection;
      final repeat =
          _block(
              warm: [],
              work: [_typedSet('repeat', _typedEvidence(context: 'Machine C'))],
            )
            ..catalogSelection = _typedEvidence(context: 'Machine C').selection
            ..expanded = false;
      controller.seedForTest(_draftWith([block, repeat]));
      final harness = real.ScreenHarness();
      addTearDown(harness.close);
      await harness.open(tester);
      final settings = harness.settings;
      await tester.runAsync(() => settings.setRirControls(RirControls.show));
      await tester.pumpWidget(_harness(controller, settings: settings));
      await tester.pump(const Duration(milliseconds: 400));
      final before = a.catalog!.toJson();
      await tester.tap(find.byKey(const Key('catalog-ruler-reported_load')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('number-entry-field')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('number-entry-field')),
        '060.250000000000001',
      );
      expect(
        a.catalog!.toJson(),
        before,
        reason: 'the modal protects uncommitted input',
      );
      await tester.pump();
      expect(
        find.byKey(const Key('number-entry-done')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('number-entry-done')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(a.catalog!.metrics['reported_load']!.raw, '060.250000000000001');
      expect(a.catalog!.metrics['reported_load']!.unit, 'kg');
      expect(a.catalog!.metrics['repetitions']!.raw, '08');
      await tester.tap(find.byKey(const Key('log-set-bar')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(a.done, isTrue);
      final feedback = tester.widget<ConfirmedSetFeedback>(
        find.byType(ConfirmedSetFeedback),
      );
      expect(feedback.event, greaterThan(0));
      expect(feedback.loggedSet, same(a));
      expect(controller.rirPromptSetId, a.id);
      expect(a.rir, 99, reason: 'logging never normalizes an untouched RIR');
      final prompt = find.descendant(
        of: find.byType(SetLine).first,
        matching: find.byKey(const Key('rir-2')),
      );
      await tester.ensureVisible(prompt);
      await tester.tap(prompt);
      await tester.pump();
      expect(a.rir, 2);
      final compactLabel = find.text('Synthetic execution · Machine A');
      await Scrollable.ensureVisible(
        tester.element(compactLabel),
        alignment: .5,
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(compactLabel.hitTestable(), findsOneWidget);
      await tester.tap(compactLabel);
      await tester.pump();
      expect(controller.liveSet!.set, same(a));
      expect(find.byType(LiveSetCard), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('live-clear-rir')));
      await tester.tap(find.byKey(const Key('live-clear-rir')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(a.rir, isNull);
      await Scrollable.ensureVisible(
        tester.element(find.byTooltip('SET 1 options')),
        alignment: .5,
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('SET 1 options'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Mark as not done'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(a.done, isFalse);
      expect(controller.liveSet!.set, same(a));
      expect(block.blockId, isNot(repeat.blockId));
      expect(b.catalog!.selection.contextLabel, 'Machine B');
      expect(
        repeat.workingSets.single.catalog!.selection.contextLabel,
        'Machine C',
      );
      commitPendingInput();
      expect(tester.takeException(), isNull);
      await _teardown(tester);
    },
  );

  for (final width in [320.0, 412.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final brightness in Brightness.values) {
        for (final code in ['en', 'de', 'es', 'it']) {
          testWidgets(
            'typed workout hierarchy $width $scale $code ${brightness.name}',
            (tester) async {
              real.setPhone(tester, width: width, textScale: scale);
              final controller = ActiveSessionController();
              addTearDown(controller.dispose);
              final evidence = _typedEvidence(profile: 'distance_duration');
              final a = _typedSet('duration-a', evidence);
              final b = _typedSet(
                'duration-b',
                _typedEvidence(
                  profile: 'distance_duration',
                  context: 'Other setup',
                ),
                done: true,
              );
              final block = _block(warm: [], work: [a, b])
                ..catalogSelection = a.catalog!.selection;
              controller.seedForTest(_draftWith([block]));
              await tester.pumpWidget(
                _harness(
                  controller,
                  locale: Locale(code),
                  brightness: brightness,
                ),
              );
              await tester.pump(const Duration(milliseconds: 400));
              expect(find.byType(LiveSetCard), findsOneWidget);
              expect(find.byType(SetLine), findsOneWidget);
              expect(find.byType(CatalogSetValuesEditor), findsOneWidget);
              expect(find.byType(TextField), findsNothing);
              expect(
                find.byKey(const Key('catalog-ruler-duration')),
                findsOneWidget,
              );
              expect(
                find.byKey(const Key('catalog-ruler-distance')),
                findsOneWidget,
              );
              expect(find.textContaining('kg'), findsNothing);
              expect(find.textContaining('8–10'), findsNothing);
              expect(tester.takeException(), isNull);
              await _teardown(tester);
            },
          );
        }
      }
    }
  }

  for (final brightness in Brightness.values) {
    for (final language in ['en', 'de', 'it']) {
      testWidgets('narrow-enlarged-header $language ${brightness.name}', (
        tester,
      ) async {
        real.setPhone(tester, width: 320, textScale: 2);
        final controller = ActiveSessionController()
          ..seedForTest(real.longDraft());
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          _harness(
            controller,
            locale: Locale(language),
            brightness: brightness,
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        final title = find.byKey(const ValueKey('block-title-ex1'));
        expect(tester.renderObject<RenderFitLabel>(title).ellipsized, isFalse);
        expect(tester.getSize(title).height, greaterThan(50));
        final l = lookupAppLocalizations(Locale(language));
        expect(find.textContaining(l.muscleChest), findsWidgets);
        expect(
          tester.getSize(find.byKey(const ValueKey('block-menu-ex1'))).height,
          greaterThanOrEqualTo(48),
        );
        final reps = find.byKey(const Key('live-reps'));
        await tester.ensureVisible(reps);
        await tester.pumpAndSettle();
        expect(
          tester.getRect(reps).bottom,
          lessThanOrEqualTo(
            tester.getRect(find.byKey(const Key('log-set-bar'))).top,
          ),
        );
        expect(tester.getRect(reps).top, greaterThanOrEqualTo(0));
        expect(tester.takeException(), isNull);
        await _teardown(tester);
      });
    }
  }

  testWidgets(
    'catalog live label omits only duplicate header identity and retains a different set context',
    (tester) async {
      real.setPhone(tester, width: 412);
      final controller = ActiveSessionController();
      addTearDown(controller.dispose);
      final a = _typedSet('same-header', _typedEvidence());
      final b = _typedSet(
        'different-context',
        _typedEvidence(context: 'Machine B'),
      );
      final block = _block(warm: [], work: [a, b])
        ..catalogSelection = a.catalog!.selection;
      controller.seedForTest(_draftWith([block]));
      final before = [a.toJson(), b.toJson()];
      await tester.pumpWidget(_harness(controller));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.descendant(
          of: find.byType(LiveSetCard),
          matching: find.textContaining('Synthetic execution'),
        ),
        findsNothing,
      );
      controller.focusSet(b);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(LiveSetCard),
          matching: find.text('Synthetic execution · Machine B'),
        ),
        findsOneWidget,
      );
      expect([a.toJson(), b.toJson()], before);
      await _teardown(tester);
    },
  );

  testWidgets(
    'backgrounded, the open screen leaves the rest end to the notification',
    (tester) async {
      final haptics = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method.startsWith('HapticFeedback')) {
            haptics.add(call.method);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final controller = ActiveSessionController();
      addTearDown(controller.dispose);
      final a = SetState(
        id: 'a',
        weightKg: 60,
        reps: 8,
        rir: 1,
        isWarmup: false,
        done: false,
      );
      controller.seedForTest(
        _draftWith([
          _block(warm: [], work: [a]),
        ]),
      );
      await tester.pumpWidget(_harness(controller));
      await tester.pump();
      final manager = tester
          .element(find.byType(ActiveSessionScreen))
          .read<SessionManager>();
      expect(manager.screenOpen, isTrue);

      // Phone locked with the screen open: a rest that ends meanwhile neither
      // buzzes here nor is stopped here, so the scheduled alert stands.
      manager.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(manager.restEndAlertWanted, isTrue);
      final start = DateTime.now().subtract(const Duration(seconds: 30));
      controller.setRestRaw(start, 10);
      await tester.pump(const Duration(seconds: 2));
      expect(controller.restStart, start);
      expect(haptics, isEmpty);

      // Back in front: the over rest is stopped without a late second buzz.
      manager.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(manager.restEndAlertWanted, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.restStart, isNull);
      expect(haptics, isEmpty);

      // In the foreground the screen still marks the end itself.
      controller.setRestRaw(DateTime.now(), 60);
      await tester.pump(const Duration(seconds: 1));
      controller.setRestRaw(
        DateTime.now().subtract(const Duration(seconds: 10)),
        10,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(haptics, contains('HapticFeedback.vibrate'));
      expect(controller.restStart, isNull);
      await _teardown(tester);
    },
  );

  testWidgets(
    'timers frozen while locked: a rest that ended meanwhile gets no late buzz',
    (tester) async {
      final haptics = <String>[], said = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method.startsWith('HapticFeedback')) {
          haptics.add(call.method);
        }
        return null;
      });
      messenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility,
        (message) async {
          final map = message as Map<Object?, Object?>;
          if (map['type'] == 'announce') {
            said.add(
              (map['data'] as Map<Object?, Object?>)['message'] as String,
            );
          }
          return null;
        },
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        messenger.setMockDecodedMessageHandler<Object?>(
          SystemChannels.accessibility,
          null,
        );
      });
      final controller = ActiveSessionController();
      addTearDown(controller.dispose);
      controller.seedForTest(
        _draftWith([
          _block(
            warm: [],
            work: [
              SetState(
                id: 'a',
                weightKg: 60,
                reps: 8,
                rir: 1,
                isWarmup: false,
                done: false,
              ),
            ],
          ),
        ]),
      );
      controller.setRestRaw(DateTime.now(), 60);
      await tester.pumpWidget(_harness(controller));
      await tester.pump(const Duration(seconds: 1));
      final manager = tester
          .element(find.byType(ActiveSessionScreen))
          .read<SessionManager>();
      expect(haptics, isEmpty, reason: 'rest still running, guards armed');

      // Locked with no tick at all while paused; on unlock the rest has been
      // over for 10 s (the rest-end notification already marked it).
      manager.didChangeAppLifecycleState(AppLifecycleState.paused);
      controller.setRestRaw(
        DateTime.now().subtract(const Duration(seconds: 70)),
        60,
      );
      manager.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.restStart, isNull, reason: 'the over rest is stopped');
      expect(haptics, isEmpty);
      expect(said, isEmpty);
      await _teardown(tester);
    },
  );
}
