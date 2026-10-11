// Host tests for the session side of a capture: complete logical operations
// keep their gate ticket through their last file continuation, file writers
// are serialized, persistence failures stay observable, callbacks freeze, and
// the one final draft flush happens after preserving the pre-flush bytes.
//
// Host tests have no native plugin: the gate here is a small reference model
// of the native `reps/capture` admission protocol (ticket table, parent
// reuse, closed admission). It pins how the Dart writers use tickets; native
// locking is qualified by integration_test/capture_platform_test.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:reps_capture_platform/reps_capture_platform.dart';
import 'package:workout_tracker/auth/auth_store.dart';
import 'package:workout_tracker/capture/session_capture_hooks.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';
import 'package:workout_tracker/capture/startup_inventory.dart';
import 'package:workout_tracker/data/active_session_draft.dart';
import 'package:workout_tracker/data/exercise_repository.dart';
import 'package:workout_tracker/data/finished_session_store.dart';
import 'package:workout_tracker/data/models.dart';
import 'package:workout_tracker/data/session_repository.dart';
import 'package:workout_tracker/data/session_writer.dart';
import 'package:workout_tracker/l10n/app_localizations.dart';
import 'package:workout_tracker/session/active_session_controller.dart';
import 'package:workout_tracker/session/active_session_screen.dart';
import 'package:workout_tracker/session/resume.dart';
import 'package:workout_tracker/session/session_manager.dart';
import 'package:workout_tracker/settings/settings_service.dart';
import 'package:workout_tracker/shell/app_shell.dart';
import 'package:workout_tracker/shell/session_launcher.dart';
import 'package:workout_tracker/sync/db.dart';
import 'package:workout_tracker/theme/app_theme.dart';
import 'package:workout_tracker/theme/icons.dart';
import 'package:workout_tracker/theme/tokens.dart';
import 'package:workout_tracker/ui/day_editor.dart';
import 'package:workout_tracker/ui/history_screen.dart';
import 'package:workout_tracker/ui/set_editor_sheet.dart';
import 'package:workout_tracker/ui/split_tab.dart';
import 'package:workout_tracker/units/unit_service.dart';
import 'package:workout_tracker/widgets/plan_form.dart';
import 'package:workout_tracker/widgets/ruler_picker.dart';

import '../support/fake_capture_files.dart';
import '../support/fake_stores.dart';
import '../support/l10n_harness.dart';
import '../support/screen_harness.dart';

/// Reference model of the native admission protocol, per test.
class _GateModel {
  _GateModel(String name)
      : channel = MethodChannel('reps/capture/test/hooks/$name') {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
  }

  final MethodChannel channel;

  /// Live tickets and their reference counts (nested continuations).
  final tickets = <String, int>{};

  /// Operations admitted as new tickets, in order.
  final admitted = <String>[];

  /// Admissions for these operations are decided when they arrive but
  /// answered only after [releaseHeld].
  final holdAdmits = <String>{};
  final _held = <Completer<void>>[];

  var _state = 'open';
  var _generation = 0;
  var _capture = '';
  var _counter = 0;

  bool get idle => tickets.isEmpty;
  int get heldCount => _held.length;

  SourceWriteGate gate(Directory stateDirectory) => SourceWriteGate(
        stateDirectory: stateDirectory,
        platform: RepsCapturePlatform(channel: channel),
      );

  void releaseHeld() {
    for (final c in _held) {
      c.complete();
    }
    _held.clear();
  }

  void detach() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  Map<String, Object?> _newTicket() {
    final id = 't${++_counter}';
    tickets[id] = 1;
    return {'code': 'ok', 'ticket': id, 'generation': _generation};
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = Map<String, Object?>.from(call.arguments as Map);
    switch (call.method) {
      case 'admit':
        final operation = args['operation'] as String;
        final parent = args['parent'] as String?;
        Map<String, Object?> answer;
        if (parent != null) {
          if (!tickets.containsKey(parent)) {
            answer = {'code': 'parent_completed'};
          } else {
            tickets[parent] = tickets[parent]! + 1;
            answer = {'code': 'ok', 'ticket': parent, 'generation': _generation};
          }
        } else if (_state != 'open') {
          answer = {'code': 'admission_closed'};
        } else {
          answer = _newTicket();
          admitted.add(operation);
        }
        if (holdAdmits.contains(operation)) {
          final hold = Completer<void>();
          _held.add(hold);
          await hold.future;
        }
        return answer;
      case 'complete':
        final id = args['ticket'] as String;
        final refs = tickets[id];
        if (refs == null) return {'code': 'unknown_ticket'};
        refs == 1 ? tickets.remove(id) : tickets[id] = refs - 1;
        return {'code': 'ok'};
      case 'prepare':
        if (_state != 'open') return {'code': 'capture_in_progress'};
        _state = 'preparing';
        _generation++;
        _capture = args['captureId'] as String;
        return _newTicket();
      case 'drain':
        if (_capture != args['captureId']) return {'code': 'mismatch'};
        if (tickets.isNotEmpty) return {'code': 'pending'};
        _state = 'held';
        return {'code': 'held'};
      case 'release':
        _state = 'open';
        _capture = '';
        return {'code': 'ok'};
    }
    return {'code': 'unsupported'};
  }
}

class _NoopExec implements SqlExecutor {
  @override
  Future<void> execute(String sql, [List<Object?> params = const []]) async {}
}

/// A real file-backed draft store that counts saves and can hold or fail
/// its clear.
class _RecordingDraftStore extends DraftStore {
  _RecordingDraftStore(Directory dir) : super(directory: () async => dir);

  int saveCount = 0;
  int clearCount = 0;
  Completer<void>? clearGate;
  Completer<void>? saveGate;
  bool failClear = false;

  @override
  Future<void> save(SessionDraft draft) async {
    final gate = saveGate;
    if (gate != null) await gate.future;
    saveCount++;
    await super.save(draft);
  }

  @override
  Future<void> clear() async {
    final gate = clearGate;
    if (gate != null) await gate.future;
    clearCount++;
    if (failClear) throw const FileSystemException('read-only');
    await super.clear();
  }
}

/// An in-memory snapshot store whose save/clear can be held.
class _HeldFinishedStore extends FakeFinishedSessionStore {
  _HeldFinishedStore({super.failSave});

  Completer<void>? saveGate;
  Completer<void>? clearGate;
  bool saveStarted = false;
  bool clearStarted = false;

  @override
  Future<void> save(FinishedSession f) async {
    saveStarted = true;
    final gate = saveGate;
    if (gate != null) await gate.future;
    await super.save(f);
  }

  @override
  Future<void> clear() async {
    clearStarted = true;
    final gate = clearGate;
    if (gate != null) await gate.future;
    await super.clear();
  }
}

Matcher _captureCode(String code) => throwsA(
    isA<SessionCaptureException>().having((e) => e.code, 'code', code));

Matcher _gateCode(String code) =>
    throwsA(isA<SourceGateException>().having((e) => e.code, 'code', code));

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'condition never held');
}

const _bench = Exercise(
  id: 'bench', name: 'Bench', slug: 'bench', muscleGroup: 'chest',
  compound: true, plateStepKg: 2.5, isTemplate: false,
);

SessionDraft _draft({double weight = 100, String? sessionId}) => SessionDraft(
      templateId: 't',
      name: 'Upper A',
      focus: '',
      startedAt: DateTime(2026, 10, 9, 9, 30),
      sessionId: sessionId,
      blocks: [
        BlockState(
          exercise: _bench,
          resolved: const ResolvedSlot(
              exercise: _bench, workSets: 2, warmupSets: 0,
              repLow: 8, repHigh: 10, rirLow: 1, rirHigh: 2),
          warmupSets: [],
          workingSets: [
            SetState(id: 'set-a', weightKg: weight, reps: 8, rir: 1,
                isWarmup: false, done: true),
            SetState(id: 'set-b', weightKg: weight, reps: 8, rir: 2,
                isWarmup: false, done: false),
          ],
          expanded: true,
        ),
      ],
    );

FinishedSession _finished({required DateTime at, String id = 'S'}) =>
    FinishedSession(
      sessionId: id,
      sessionDate: '${at.year}-${at.month.toString().padLeft(2, '0')}-'
          '${at.day.toString().padLeft(2, '0')}',
      finishedAt: at,
      elapsedSeconds: 2400,
      draft: _draft(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late _GateModel model;
  late FakeCaptureFiles fakeFiles;
  var serial = 0;

  RawPreservation preservation() => RawPreservation(
        Directory('${temp.path}/capture/preparation'),
        base: temp,
        files: fakeFiles.files,
      );

  SessionCaptureHooks hooks(SessionManager m) =>
      SessionCaptureHooks(manager: m, preservation: preservation());

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('reps-session-capture');
    model = _GateModel('m${++serial}');
    fakeFiles = FakeCaptureFiles('f$serial');
    appSourceGate = model.gate(Directory('${temp.path}/capture/gate'));
    SessionWriteLedger.instance.resetForTesting();
    UnsavedEditors.instance.resetForTesting();
  });

  tearDown(() async {
    appSourceGate = null;
    model.detach();
    fakeFiles.detach();
    SessionWriteLedger.instance.resetForTesting();
    UnsavedEditors.instance.resetForTesting();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('finish_ticket_includes_commit_adoption_and_file', () async {
    final store = _HeldFinishedStore()..saveGate = Completer<void>();
    final m = SessionManager(finishedStore: store);
    addTearDown(m.dispose);
    final c = ActiveSessionController.fromDraft(_draft());
    m.register(c);

    var committed = false;
    final finishing = finishWorkout(c, m, transact: (body) async {
      final id = await body(_NoopExec());
      committed = true; // COMMIT returned
      return id;
    });
    await _until(() => store.saveStarted);
    expect(committed, true);
    final idleBeforeFinishedFile = model.idle;
    var finishReturned = false;
    unawaited(finishing.then((_) => finishReturned = true));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(finishReturned, false,
        reason: 'the finish waits for the adopted snapshot to persist');

    store.saveGate!.complete();
    final id = await finishing;
    expect(idleBeforeFinishedFile, false);
    expect(model.idle, true);
    expect(store.stored?.sessionId, id);
    expect(model.admitted, ['session.finish'],
        reason: 'recordFinished reuses the finish ticket');

    // The error continuation (a failed save clears the file) also runs under
    // the finish ticket, and the failure stays observable to capture.
    final failing = _HeldFinishedStore(failSave: true)
      ..clearGate = Completer<void>();
    final m2 = SessionManager(finishedStore: failing);
    addTearDown(m2.dispose);
    final c2 = ActiveSessionController.fromDraft(_draft());
    m2.register(c2);
    final finishing2 =
        finishWorkout(c2, m2, transact: (body) => body(_NoopExec()));
    await _until(() => failing.clearStarted);
    expect(model.idle, false, reason: 'the clear continuation holds the ticket');
    failing.clearGate!.complete();
    await finishing2; // the committed finish itself still succeeds
    expect(model.idle, true);
    expect(failing.clearCount, 1);

    final hooks = SessionCaptureHooks(manager: m2, preservation: preservation());
    final prep = await appSourceGate!.closeAdmission('capture-1');
    await expectLater(hooks.drainAndFlush(prep), _captureCode('persistence_failed'));
  });

  test('old_autosave_cannot_overwrite_new_flush', () async {
    final store = _RecordingDraftStore(temp);
    final m = SessionManager(finishedStore: FakeFinishedSessionStore());
    addTearDown(m.dispose);
    final c = ActiveSessionController.fromDraft(_draft(weight: 100),
        draftStore: store);
    addTearDown(c.dispose);
    m.register(c);
    model.holdAdmits.add('session.autosave');

    c.markChanged(); // schedules an autosave of the 100 kg draft
    await Future<void>.delayed(
        ActiveSessionController.saveDebounce + const Duration(milliseconds: 100));
    expect(model.heldCount, 1, reason: 'the old autosave is admitted, in flight');

    c.draft.blocks.single.workingSets.first.weightKg = 110;
    c.markChanged(); // the newest state, debounced again

    final hooks = SessionCaptureHooks(manager: m, preservation: preservation());
    final prep = await appSourceGate!.closeAdmission('capture-1');
    final flushing = hooks.drainAndFlush(prep);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    model.releaseHeld(); // the old autosave's admission answers late
    await flushing;

    final savedDraftBytes =
        await File('${temp.path}/${DraftStore.fileName}').readAsBytes();
    final newestFlushBytes = hooks.lastFlush!.after.bytes!;
    expect(savedDraftBytes, newestFlushBytes);
    expect(store.decodeBytes(savedDraftBytes)!
        .blocks.single.workingSets.first.weightKg, 110);
    final finalFlushCount = hooks.finalFlushCount;
    expect(finalFlushCount, 1);
    expect(store.saveCount, 1, reason: 'the stale autosave never wrote');

    // Frozen: no later autosave lands while the capture holds the source.
    c.markChanged();
    await Future<void>.delayed(
        ActiveSessionController.saveDebounce + const Duration(milliseconds: 100));
    expect(store.saveCount, 1);

    // Reverse completions on the file writer itself: two writers of the same
    // store in call order, the newest wins and no temporary file is left.
    final a = DraftStore(directory: () async => temp);
    final b = DraftStore(directory: () async => temp);
    await Future.wait([
      a.save(_draft(weight: 1)),
      b.save(_draft(weight: 2)),
      a.save(_draft(weight: 3)),
    ]);
    expect((await b.load())!.blocks.single.workingSets.first.weightKg, 3);
    expect(await File('${temp.path}/${DraftStore.fileName}.tmp').exists(), false);
    await Future.wait([a.save(_draft(weight: 4)), b.clear()]);
    expect(await File('${temp.path}/${DraftStore.fileName}').exists(), false);
  });

  test('discard_resume_expiry_drain_or_block', () async {
    final hooksStore = FakeFinishedSessionStore();
    final m = SessionManager(finishedStore: hooksStore);
    addTearDown(m.dispose);
    final hooks = SessionCaptureHooks(manager: m, preservation: preservation());

    // An admitted discard finishes its file clear before the drain returns.
    final draftStore = _RecordingDraftStore(temp)..clearGate = Completer<void>();
    final c = ActiveSessionController.fromDraft(_draft(), draftStore: draftStore);
    m.register(c);
    final discarding = c.discard();
    await _until(() => !c.hasSession); // admitted, torn down, clear running
    final prep = await appSourceGate!.closeAdmission('capture-1');
    var drained = false;
    final draining = hooks.drainAndFlush(prep).then((_) => drained = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(drained, false, reason: 'drain waits for the discard clear');
    expect(model.idle, false);
    draftStore.clearGate!.complete();
    await discarding;
    await draining;
    expect(draftStore.clearCount, 1);
    expect(hooks.finalFlushCount, 0, reason: 'no live workout, nothing to flush');

    // New work is refused visibly while admission is closed.
    final late = ActiveSessionController.fromDraft(_draft(), draftStore: draftStore);
    await expectLater(late.discard(), _gateCode('admission_closed'));
    expect(late.hasSession, isTrue, reason: 'a refused discard changes nothing');
    await expectLater(
        runSourceWrite('exercise.update', (_) async {}),
        _gateCode('admission_closed'));
    hooks.resumeCallbacks(DateTime.now(), generation: prep.generation);
    await appSourceGate!.release(
        SourceHold('capture-1', prep.generation), decisionDigest: 'a' * 64);

    // A failing discard clear is observable: the discarded workout would
    // resurrect, so the capture cannot succeed.
    final failing = _RecordingDraftStore(temp)..failClear = true;
    final c2 = ActiveSessionController.fromDraft(_draft(), draftStore: failing);
    m.register(c2);
    await expectLater(c2.discard(), throwsA(isA<FileSystemException>()));
    final prep2 = await appSourceGate!.closeAdmission('capture-2');
    await expectLater(hooks.drainAndFlush(prep2), _captureCode('persistence_failed'));
    hooks.resumeCallbacks(DateTime.now(), generation: prep2.generation);
    await appSourceGate!.release(
        SourceHold('capture-2', prep2.generation), decisionDigest: 'b' * 64);
    SessionWriteLedger.instance.resetForTesting();

    // An admitted resume save completes (and its workout is flushed once)
    // before the drain returns.
    final at = DateTime.now();
    final snapshot = _finished(at: at);
    await m.recordFinished(snapshot, now: at);
    final resumeStore = _RecordingDraftStore(temp)..saveGate = Completer<void>();
    final repo = _ResumeRepo(snapshot);
    final resuming = prepareResume(m, 'S',
        sessionRepo: repo, exerciseRepo: _NoExercises(), draftStore: resumeStore,
        now: at);
    await _until(() => model.tickets.isNotEmpty);
    final prep3 = await appSourceGate!.closeAdmission('capture-3');
    var drained3 = false;
    final draining3 = hooks.drainAndFlush(prep3).then((_) => drained3 = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(drained3, false, reason: 'drain waits for the resume save');
    resumeStore.saveGate!.complete();
    resumeStore.saveGate = null;
    expect(await resuming, isNotNull);
    await draining3;
    expect(m.active?.draft.sessionId, 'S');
    expect(hooks.finalFlushCount, 1);
    expect(resumeStore.saveCount, 2, reason: 'resume save, then the one flush');
    await appSourceGate!.release(
        SourceHold('capture-3', prep3.generation), decisionDigest: 'c' * 64);
    hooks.resumeCallbacks(DateTime.now(), generation: prep3.generation);
    await m.active!.discard();

    // An expiry that already started finishes before the drain returns.
    final expiring = _HeldFinishedStore()..clearGate = Completer<void>();
    final m4 = SessionManager(finishedStore: expiring);
    addTearDown(m4.dispose);
    final soon = _finished(at: DateTime.now());
    await m4.recordFinished(soon,
        now: resumableUntil(soon).subtract(const Duration(milliseconds: 20)));
    await _until(() => expiring.clearStarted);
    final hooks4 = SessionCaptureHooks(manager: m4, preservation: preservation());
    final prep4 = await appSourceGate!.closeAdmission('capture-4');
    var drained4 = false;
    final draining4 = hooks4.drainAndFlush(prep4).then((_) => drained4 = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(drained4, false, reason: 'the admitted expiry finishes first');
    expiring.clearGate!.complete();
    await draining4;
    expect(expiring.clearCount, 1);
    expect(m4.lastFinished, isNull);
    hooks4.resumeCallbacks(DateTime.now(), generation: prep4.generation);
    await appSourceGate!.release(
        SourceHold('capture-4', prep4.generation), decisionDigest: 'd' * 64);

    // A new expiry while frozen does not clear the file; it is reconciled on
    // release.
    final frozenStore = _HeldFinishedStore();
    final m5 = SessionManager(finishedStore: frozenStore);
    addTearDown(m5.dispose);
    final later = _finished(at: DateTime.now(), id: 'L');
    final adoptedAt =
        resumableUntil(later).subtract(const Duration(milliseconds: 60));
    await m5.recordFinished(later, now: adoptedAt);
    final hooks5 = SessionCaptureHooks(manager: m5, preservation: preservation());
    final prep5 = await appSourceGate!.closeAdmission('capture-5');
    await hooks5.drainAndFlush(prep5);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(frozenStore.clearCount, 0);
    expect(m5.lastFinished, isNotNull);
    await appSourceGate!.release(
        SourceHold('capture-5', prep5.generation), decisionDigest: 'e' * 64);
    hooks5.resumeCallbacks(resumableUntil(later).add(const Duration(seconds: 1)), generation: prep5.generation);
    await _until(() => frozenStore.clearCount == 1);
    expect(m5.lastFinished, isNull);
  });

  testWidgets('input_mid_fling_commits_once', (tester) async {
    final store = _RecordingDraftStore(temp);
    final draft = _draft(weight: 100);
    final original = draft.deepCopy();
    final m = SessionManager(finishedStore: FakeFinishedSessionStore());
    final c = ActiveSessionController.fromDraft(draft, draftStore: store);
    m.register(c);
    final hooks = SessionCaptureHooks(manager: m, preservation: preservation());

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<ActiveSessionController>.value(value: c),
        ChangeNotifierProvider<SessionManager>.value(value: m),
        ChangeNotifierProvider<SettingsService>.value(value: SettingsService()),
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
    ));
    await tester.pump(const Duration(milliseconds: 400));

    final live = c.liveSet!.set;
    expect(live.id, 'set-b');
    await tester.fling(
        find.byKey(const Key('live-weight')), const Offset(-150, 0), 3000);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));

    final prep = (await tester.runAsync(
        () => appSourceGate!.closeAdmission('capture-1')))!;
    await tester.runAsync(() => hooks.commitEditorInput(prep));
    final shown = live.weightKg;
    expect(shown, isNot(100), reason: 'the fling moved the ruler');
    await tester.runAsync(() => hooks.drainAndFlush(prep));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(live.weightKg, shown, reason: 'no glide tick after the commit');

    final bytes = (await tester.runAsync(() =>
        File('${temp.path}/${DraftStore.fileName}').readAsBytes()))!;
    final saved = store.decodeBytes(bytes)!;
    final finalFlushCount = hooks.finalFlushCount;
    expect(finalFlushCount, 1);
    expect(store.saveCount, 1, reason: 'one flush, no autosave');
    final sets = saved.blocks.single.workingSets;
    expect(sets.map((s) => s.id), ['set-a', 'set-b']);
    expect(sets[1].weightKg, shown);
    expect(sets[1].reps, 8);
    expect(sets[1].rir, 2);
    expect(sets[0].weightKg, 100);
    expect(saved.startedAt, original.startedAt);
    expect(saved.name, original.name);

    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });

  test('failed_flush_is_retried_never_reported', () async {
    final store = _RecordingDraftStore(temp);
    final m = SessionManager(finishedStore: FakeFinishedSessionStore());
    addTearDown(m.dispose);
    final c = ActiveSessionController.fromDraft(_draft(weight: 100),
        draftStore: store);
    addTearDown(c.dispose);
    m.register(c);
    c.markChanged(); // an autosave is owed when the capture starts
    final hooks = SessionCaptureHooks(manager: m, preservation: preservation());

    final prep = await appSourceGate!.closeAdmission('capture-1');
    fakeFiles.failWith = 'io_error'; // preservation cannot write
    await expectLater(hooks.drainAndFlush(prep),
        throwsA(isA<PreservationException>()));
    expect(hooks.finalFlushCount, 0);
    expect(hooks.lastFlush, isNull);
    expect(SessionWriteLedger.instance.failures.keys, contains('draft'));
    expect(store.saveCount, 0, reason: 'the flush never ran');

    // A retry of the same capture flushes; it does not report the earlier
    // attempt as done.
    fakeFiles.failWith = null;
    await hooks.drainAndFlush(prep);
    expect(hooks.finalFlushCount, 1);
    expect(store.saveCount, 1);
    expect(hooks.lastFlush, isNotNull);
    expect(SessionWriteLedger.instance.failures, isEmpty);

    // The next capture never exposes this capture's replacement relation.
    await appSourceGate!.release(
        SourceHold('capture-1', prep.generation), decisionDigest: 'a' * 64);
    hooks.resumeCallbacks(DateTime.now(), generation: prep.generation);
    await c.discard();
    final prep2 = await appSourceGate!.closeAdmission('capture-2');
    await hooks.drainAndFlush(prep2);
    expect(hooks.lastFlush, isNull);
  });

  test('failed_flush_keeps_autosave_owed', () async {
    final store = _RecordingDraftStore(temp);
    final m = SessionManager(finishedStore: FakeFinishedSessionStore());
    addTearDown(m.dispose);
    final c = ActiveSessionController.fromDraft(_draft(weight: 100),
        draftStore: store);
    addTearDown(c.dispose);
    m.register(c);
    c.markChanged();
    final hooks = SessionCaptureHooks(manager: m, preservation: preservation());
    final prep = await appSourceGate!.closeAdmission('capture-1');
    fakeFiles.failWith = 'io_error';
    await expectLater(hooks.drainAndFlush(prep), throwsA(anything));
    fakeFiles.failWith = null;
    await appSourceGate!.release(
        SourceHold('capture-1', prep.generation), decisionDigest: 'a' * 64);
    hooks.resumeCallbacks(DateTime.now(), generation: prep.generation);
    await Future<void>.delayed(
        ActiveSessionController.saveDebounce + const Duration(milliseconds: 150));
    expect(store.saveCount, 1, reason: 'the mutation the flush missed is saved');
  });

  test('refused_autosave_stays_owed_until_release', () async {
    final store = _RecordingDraftStore(temp);
    final m = SessionManager(finishedStore: FakeFinishedSessionStore());
    addTearDown(m.dispose);
    final c = ActiveSessionController.fromDraft(_draft(weight: 100),
        draftStore: store);
    addTearDown(c.dispose);
    m.register(c);

    c.draft.blocks.single.workingSets.first.weightKg = 105;
    c.markChanged();
    // Admission closes before the debounce fires (a capture that has not
    // frozen callbacks yet, and then aborts).
    final prep = await appSourceGate!.closeAdmission('capture-1');
    await Future<void>.delayed(
        ActiveSessionController.saveDebounce * 2 + const Duration(milliseconds: 150));
    expect(store.saveCount, 0, reason: 'refused, and retried while closed');
    expect(SessionWriteLedger.instance.failures, isEmpty,
        reason: 'a refusal changed nothing on disk');

    await appSourceGate!.release(
        SourceHold('capture-1', prep.generation), decisionDigest: 'a' * 64);
    await _until(() => store.saveCount == 1);
    final saved = (await store.load())!;
    expect(saved.blocks.single.workingSets.first.weightKg, 105);

    // The same refusal settled by an explicit (unfrozen) resume.
    c.markChanged();
    final prep2 = await appSourceGate!.closeAdmission('capture-2');
    await Future<void>.delayed(
        ActiveSessionController.saveDebounce + const Duration(milliseconds: 150));
    expect(store.saveCount, 1);
    await appSourceGate!.release(
        SourceHold('capture-2', prep2.generation), decisionDigest: 'b' * 64);
    hooks(m).resumeCallbacks(DateTime.now(), generation: prep2.generation);
    await _until(() => store.saveCount == 2);
  });

  test('stale_resume_cannot_unfreeze_later_capture', () async {
    final store = _RecordingDraftStore(temp);
    final m = SessionManager(finishedStore: FakeFinishedSessionStore());
    addTearDown(m.dispose);
    final c = ActiveSessionController.fromDraft(_draft(), draftStore: store);
    addTearDown(c.dispose);
    m.register(c);
    final h = hooks(m);

    final prep1 = await appSourceGate!.closeAdmission('capture-1');
    await h.drainAndFlush(prep1);
    await appSourceGate!.release(
        SourceHold('capture-1', prep1.generation), decisionDigest: 'a' * 64);
    h.resumeCallbacks(DateTime.now(), generation: prep1.generation);
    expect(c.callbacksFrozen, false);

    final prep2 = await appSourceGate!.closeAdmission('capture-2');
    await h.drainAndFlush(prep2);
    final saves = store.saveCount;
    // A late resume of the first capture arrives while the second holds.
    h.resumeCallbacks(DateTime.now(), generation: prep1.generation);
    expect(c.callbacksFrozen, true);
    expect(m.callbacksFrozen, true);
    c.markChanged();
    await Future<void>.delayed(
        ActiveSessionController.saveDebounce + const Duration(milliseconds: 150));
    expect(store.saveCount, saves, reason: 'still frozen: nothing written');

    await appSourceGate!.release(
        SourceHold('capture-2', prep2.generation), decisionDigest: 'b' * 64);
    h.resumeCallbacks(DateTime.now(), generation: prep2.generation);
    expect(c.callbacksFrozen, false);
    await _until(() => store.saveCount == saves + 1);
  });

  test('retry_owed_never_lands_a_stale_write_over_a_newer_one', () async {
    final editors = UnsavedEditors.instance;
    // The stored rows, keyed like the History set editor's owed writes.
    final stored = <String, String>{};
    Future<void> Function() write(String key, String value,
            {Future<void>? before, bool fails = false}) =>
        () async {
          if (before != null) await before;
          if (fails) throw const SourceGateException('admission_closed');
          stored[key] = value;
        };

    for (final newerLands in [true, false]) {
      editors.resetForTesting();
      stored.clear();
      // Two owed edits; the first retry is still awaited when ...
      final firstRetry = Completer<void>();
      editors.owe('set-a', 'history_sets',
          write('set-a', 'a1', before: firstRetry.future));
      editors.owe('set-k', 'history_sets', write('set-k', 'k1'));
      final retrying = editors.retryOwed();
      await pumpEventQueue();

      // ... a newer edit of set-k lands (or is refused and owed instead).
      final newer = write('set-k', 'k2', fails: !newerLands);
      editors.owe('set-k', 'history_sets', newer);
      try {
        await newer();
        editors.paid('set-k', newer);
      } on SourceGateException {
        // Stays owed.
      }
      firstRetry.complete();
      await retrying;

      expect(stored['set-a'], 'a1');
      expect(editors.isOwed('set-a'), false);
      if (newerLands) {
        expect(stored['set-k'], 'k2', reason: 'the newest value wins');
        expect(editors.isOwed('set-k'), false);
        expect(editors.unsaved(), isEmpty);
      } else {
        expect(stored.containsKey('set-k'), false,
            reason: 'the superseded edit never lands');
        expect(editors.isOwed('set-k'), true,
            reason: 'the newer edit is still owed and blocks capture');
        expect(editors.unsaved(), ['history_sets']);
      }
    }
  });

  test('history_delete_ticket_spans_forget', () async {
    final finished = _HeldFinishedStore()..clearGate = Completer<void>();
    final m = SessionManager(finishedStore: finished);
    addTearDown(m.dispose);
    final at = DateTime.now();
    await m.recordFinished(_finished(at: at), now: at);
    final repo = _GatedSessionRepo();
    model.admitted.clear();

    final deleting = deleteHistorySession(repo, 'S',
        onDeleted: (ticket) => m.forgetFinished('S', parent: ticket));
    await _until(() => finished.clearStarted);
    expect(repo.deleted, ['S']);
    expect(model.idle, false, reason: 'the delete ticket waits for the forget');
    expect(model.admitted, ['history.delete_session'],
        reason: 'the forget reuses the delete ticket');
    finished.clearGate!.complete();
    await deleting;
    expect(model.idle, true);
    expect(m.lastFinished, isNull);
    expect(finished.clearCount, 1);

    // Refused whole while a capture holds the source: nothing is deleted or
    // forgotten.
    await m.recordFinished(_finished(at: at, id: 'T'), now: at);
    await appSourceGate!.closeAdmission('capture-1');
    await expectLater(
        deleteHistorySession(repo, 'T',
            onDeleted: (ticket) => m.forgetFinished('T', parent: ticket)),
        _gateCode('admission_closed'));
    expect(repo.deleted, ['S']);
    expect(m.lastFinished?.sessionId, 'T');
  });

  testWidgets('refused_history_edit_stays_owed', (tester) async {
    final repo = _GatedSessionRepo();
    final m = SessionManager(finishedStore: FakeFinishedSessionStore());
    final h = hooks(m);
    await tester.pumpWidget(wrapL10n(SetEditorSheet(
      block: const ExerciseBlockData(exerciseId: 'bench', sets: [
        LoggedSet(id: 's1', exerciseId: 'bench', setNumber: 1,
            weightKg: 100, reps: 5, rir: 1, isWarmup: false,
            isTopSet: false, isPr: false),
      ], topWeight: 100, topReps: 5, isPr: false),
      exercise: _bench,
      sessionId: 'session-1',
      sessionRepo: repo,
      units: UnitService(),
    )));
    await tester.tap(find.byKey(const Key('set-line-s1')));
    await tester.pumpAndSettle();
    await tester.timedDrag(find.byKey(const Key('live-weight')),
        const Offset(-1 * RulerPicker.defaultItemExtent, 0),
        const Duration(milliseconds: 100));
    await tester.pump();

    final prep = (await tester.runAsync(
        () => appSourceGate!.closeAdmission('capture-1')))!;
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // The debounce fires while admission is closed: refused, and shown.
    await tester.pump(const Duration(milliseconds: 500));
    await settle();
    expect(find.text('Paused for data capture'), findsOneWidget);
    expect(repo.updates, isEmpty);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await settle(); // the ruler's glide ends; its refusals are owed too
    final edited = tester
        .widget<RulerPicker>(find.byKey(const Key('live-weight')))
        .value
        .toStringAsFixed(2);
    expect(edited, isNot('100.00'));
    if (find.text('OK').evaluate().isNotEmpty) {
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
    }

    // Collapsing while still closed is refused too; the edit stays owed and
    // keeps blocking capture although no card is open and no timer runs.
    await tester.tap(find.byKey(const Key('set-line-s1')));
    await settle();
    expect(find.text('Paused for data capture'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(h.unsavedEditors(), ['history_sets']);
    Object? error;
    await tester.runAsync(() async {
      try {
        await h.commitEditorInput(prep);
      } catch (e) {
        error = e;
      }
    });
    expect(error, isA<SessionCaptureException>()
        .having((e) => e.detail, 'detail', contains('history_sets')));
    expect(repo.updates, isEmpty, reason: 'never saved automatically');

    // Released: the owed edit is written, with the value the sheet shows,
    // even after the sheet itself has closed.
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => appSourceGate!.release(
        SourceHold('capture-1', prep.generation), decisionDigest: 'a' * 64));
    h.resumeCallbacks(DateTime.now(), generation: prep.generation);
    await settle();
    expect(repo.updates.last, edited);
    expect(h.unsavedEditors(), isEmpty);
    m.dispose();
  });

  group('unrepresented_unsaved_form_blocks', () {
    final harness = ScreenHarness();
    tearDown(harness.close);

    testWidgets('an edited Plan day requires Save or Cancel', (tester) async {
      await harness.open(tester);
      setPhone(tester, width: 412);
      final m = SessionManager(finishedStore: FakeFinishedSessionStore());
      final hooks = SessionCaptureHooks(manager: m, preservation: preservation());

      await tester.pumpWidget(
          harness.wrap(AppShell(onLogout: () async {}, auth: AuthStore())));
      await settleReal(tester);
      await openTab(tester, WIcons.plan);
      final card = find.byWidgetPredicate(
          (w) => w is SplitDayCard && w.name == longDay);
      await settleUntilFound(tester, card, where: 'Plan split');
      await tester.tap(card);
      await settleUntilFound(tester, find.byType(DaySlotRow), where: 'day editor');
      final bench = find.descendant(
          of: find.byType(DayEditor), matching: find.text('Bench Press'));
      await tester.ensureVisible(bench);
      await tester.pump();
      await tester.tap(bench);
      await settleReal(tester, ticks: 3);
      final inc = find.descendant(
        of: find.ancestor(
            of: find.text(lookupAppLocalizations(const Locale('en'))
                .dayEditorWorkingSets
                .toUpperCase()),
            matching: find.byType(Field)),
        matching: find.byKey(const Key('stepper-inc')),
      );
      await tester.ensureVisible(inc);
      await tester.pump();
      await tester.tap(inc);
      await settleReal(tester, ticks: 3);

      Future<int> crudCount() async =>
          ((await db.get('SELECT COUNT(*) AS n FROM ps_crud'))['n']
              as num).toInt();
      final before = (await tester.runAsync(crudCount))!;
      final prep = (await tester.runAsync(
          () => appSourceGate!.closeAdmission('capture-plan')))!;
      Object? error;
      await tester.runAsync(() async {
        try {
          await hooks.commitEditorInput(prep);
        } catch (e) {
          error = e;
        }
      });
      await settleReal(tester, ticks: 3);
      expect(error, isA<SessionCaptureException>()
          .having((e) => e.code, 'code', 'unsaved_editor_input')
          .having((e) => e.detail, 'detail', contains('plan')));
      final formAutosaveCount = (await tester.runAsync(crudCount))! - before;
      expect(formAutosaveCount, 0);
      expect(find.byType(DayEditor), findsOneWidget,
          reason: 'the form stays open for a normal Save or Cancel');
      expect(model.admitted.where((o) => o.startsWith('day')), isEmpty);

      await harness.unmount(tester);
      m.dispose();
    });

    testWidgets('an open History set editor requires closing it',
        (tester) async {
      final repo = _RecordingSessionRepo();
      final m = SessionManager(finishedStore: FakeFinishedSessionStore());
      final hooks = SessionCaptureHooks(manager: m, preservation: preservation());
      await tester.pumpWidget(wrapL10n(SetEditorSheet(
        block: const ExerciseBlockData(exerciseId: 'bench', sets: [
          LoggedSet(id: 's1', exerciseId: 'bench', setNumber: 1,
              weightKg: 100, reps: 5, rir: 1, isWarmup: false,
              isTopSet: false, isPr: false),
        ], topWeight: 100, topReps: 5, isPr: false),
        exercise: _bench,
        sessionId: 'session-1',
        sessionRepo: repo,
        units: UnitService(),
      )));
      await tester.tap(find.byKey(const Key('set-line-s1')));
      await tester.pumpAndSettle();

      final prep = (await tester.runAsync(
          () => appSourceGate!.closeAdmission('capture-history')))!;
      Object? error;
      await tester.runAsync(() async {
        try {
          await hooks.commitEditorInput(prep);
        } catch (e) {
          error = e;
        }
      });
      expect(error, isA<SessionCaptureException>()
          .having((e) => e.code, 'code', 'unsaved_editor_input')
          .having((e) => e.detail, 'detail', contains('history')));
      await tester.pump(const Duration(seconds: 1));
      final formAutosaveCount = repo.updates;
      expect(formAutosaveCount, 0);

      // Closed normally, the form no longer blocks.
      await tester.tap(find.byKey(const Key('set-line-s1')));
      await tester.pumpAndSettle();
      await tester.runAsync(() => hooks.commitEditorInput(prep));
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    });
  });
}

/// Session/sets lookups for a resume of the one snapshot.
class _ResumeRepo implements SessionRepository {
  _ResumeRepo(this.snapshot);
  final FinishedSession snapshot;

  @override
  Future<SessionSummaryRow?> sessionById(String id) async =>
      SessionSummaryRow(id: id, date: snapshot.sessionDate,
          dayTemplateId: 't', splitLabel: 'Upper A', durationMin: 40);

  @override
  Future<List<LoggedSet>> setsForSession(String sessionId) async => const [
        LoggedSet(id: 'set-a', exerciseId: 'bench', setNumber: 1,
            weightKg: 100, reps: 8, rir: 1, isWarmup: false,
            isTopSet: true, isPr: false),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoExercises implements ExerciseRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Session writes that go through the app gate, like the real repository.
class _GatedSessionRepo implements SessionRepository {
  final updates = <String>[];
  final deleted = <String>[];

  @override
  Future<void> updateSet(String id,
          {required String weightKg, required int reps, required int? rir}) =>
      runSourceWrite('history.update_set', (_) async => updates.add(weightKg));

  @override
  Future<void> deleteSession(String id, {SourceTicket? parent}) =>
      runSourceWrite('history.delete_session', (_) async => deleted.add(id),
          parent: parent);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingSessionRepo implements SessionRepository {
  int updates = 0;

  @override
  Future<void> updateSet(String id,
      {required String weightKg, required int reps, required int? rir}) async {
    updates++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
