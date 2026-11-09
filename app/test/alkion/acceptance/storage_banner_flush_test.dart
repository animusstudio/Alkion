import 'dart:io';

import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/main.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/session_manager.dart';
import 'package:alkion/store/local_store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../session/session_manager_test.dart' show FakeWorkoutNotification;

/// The real store, except that writes refuse while [blocked]: a synthetic
/// fault that leaves the store itself healthy, so lifting it lets the same
/// owed draft land.
final class _BlockingDatabase implements LocalDatabase {
  _BlockingDatabase(this.store);
  final LocalStore store;
  bool blocked = false;
  int refused = 0;

  @override
  String get profileId => store.profileId;
  @override
  StoreToken get token => store.token;
  @override
  Future<LocalActionResult> apply(
    LocalAction action,
    Future<Object?> Function(LocalTransaction tx) mutate, {
    StoreToken? expected,
  }) => store.apply(action, mutate, expected: expected);
  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) => store.getAll(sql, parameters);
  @override
  Future<Map<String, dynamic>> get(
    String sql, [
    List<Object?> parameters = const [],
  ]) => store.get(sql, parameters);
  @override
  Future<Map<String, dynamic>?> getOptional(
    String sql, [
    List<Object?> parameters = const [],
  ]) => store.getOptional(sql, parameters);
  @override
  Stream<List<Map<String, dynamic>>> watch(
    String sql, {
    List<Object?> parameters = const [],
  }) => store.watch(sql, parameters: parameters);
  @override
  Future<T> readTransaction<T>(
    Future<T> Function(LocalRead tx) callback, {
    StoreToken? expected,
  }) => store.readTransaction(callback, expected: expected);
  @override
  Future<T> writeTransaction<T>(
    Future<T> Function(LocalTransaction tx) callback, {
    StoreToken? expected,
  }) {
    if (blocked) {
      refused++;
      return Future.error(const StoreException('synthetic_write_refused'));
    }
    return store.writeTransaction(callback, expected: expected);
  }
}

Future<void> _until(bool Function() condition, String what) async {
  for (var i = 0; i < 300 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: what);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  AlkionRuntime? runtime;

  setUp(() async {
    UnsavedEditors.instance.resetForTesting();
    temp = await Directory.systemTemp.createTemp('alkion-storage-banner-');
    runtime = await AlkionRuntime.open(
      Directory('${temp.path}/${AlkionIdentity.applicationId}'),
      notifications: FakeWorkoutNotification(),
    );
  });

  tearDown(() async {
    UnsavedEditors.instance.resetForTesting();
    await runtime?.close();
    runtime = null;
    await temp.delete(recursive: true);
  });

  test('drainOrThrow: an open form fails only the strict form', () async {
    final editors = UnsavedEditors.instance;
    final form = editors.register('history_sets', () => true);
    await editors.drainOrThrow(includeOpenForms: false);
    await expectLater(
      editors.drainOrThrow(),
      throwsA(
        isA<StoreException>().having(
          (e) => e.category,
          'category',
          'unsaved_editor_input',
        ),
      ),
    );
    editors.unregister(form);
    await editors.drainOrThrow();
  });

  test(
    'an open editor never raises the banner on a lifecycle flush; an owed write still does',
    () async {
      final r = runtime!;
      final failures = <Object>[];
      r.persistenceFailure.addListener(() {
        final value = r.persistenceFailure.value;
        if (value != null) failures.add(value);
      });
      // A merely open History set card under a pulled-down shade.
      final form = UnsavedEditors.instance.register('history_sets', () => true);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.resumed,
      ]) {
        r.didChangeAppLifecycleState(state);
      }
      // Joins the lifecycle flushes' shared tail.
      await r.flushPersistence(includeOpenForms: false);
      expect(r.persistenceFailure.value, isNull);
      expect(failures, isEmpty);

      // Strict barriers (backup, export, close) still refuse the open form,
      // and that refusal is not reported as a storage failure.
      await expectLater(
        r.flushPersistence(),
        throwsA(
          isA<StoreException>().having(
            (e) => e.category,
            'category',
            'unsaved_editor_input',
          ),
        ),
      );
      expect(r.persistenceFailure.value, isNull);

      // A genuinely owed write still fails the lifecycle flush and shows.
      var blocked = true;
      Future<void> owed() async {
        if (blocked) throw const StoreException('synthetic_owed_input');
      }

      UnsavedEditors.instance.owe('synthetic-owed', 'history_sets', owed);
      r.didChangeAppLifecycleState(AppLifecycleState.paused);
      await _until(
        () => r.persistenceFailure.value != null,
        'owed write raises the banner',
      );
      expect(UnsavedEditors.instance.isOwed('synthetic-owed'), isTrue);

      blocked = false;
      await r.retryPersistence();
      expect(r.persistenceFailure.value, isNull);
      expect(UnsavedEditors.instance.isOwed('synthetic-owed'), isFalse);
      UnsavedEditors.instance.unregister(form);
    },
  );

  test(
    'a failed workout save and resume refresh raise the banner; Retry clears it',
    () async {
      final r = runtime!;
      final faulty = _BlockingDatabase(r.store);
      final drafts = DraftStore.local(faulty);
      final controller = ActiveSessionController(draftStore: drafts);
      addTearDown(controller.dispose);
      controller.seedEmpty(name: 'Synthetic workout', focus: '');
      r.sessions.register(controller);
      await r.flushPersistence();
      expect(r.persistenceFailure.value, isNull);

      faulty.blocked = true;
      controller.startRest(90);
      await _until(
        () => r.persistenceFailure.value != null,
        'the background save failure reaches the banner',
      );
      expect(r.sessions.persistenceError, isA<StoreException>());
      expect(controller.persistenceOwed, isTrue);

      // The post-resume refresh reports through the same path.
      r.persistenceFailure.value = null;
      r.sessions.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _until(
        () => r.persistenceFailure.value != null,
        'the resume refresh failure reaches the banner',
      );

      // Retry fails while the fault holds and keeps the banner.
      await r.retryPersistence();
      expect(r.persistenceFailure.value, isA<StoreException>());

      faulty.blocked = false;
      await r.retryPersistence();
      expect(r.persistenceFailure.value, isNull);
      expect(controller.persistenceOwed, isFalse);
      final stored = await DraftStore.local(r.store).load();
      expect(stored?.name, 'Synthetic workout');
      expect(faulty.refused, greaterThan(0));
      await controller.discard();
    },
  );

  test('a failed debounced autosave reaches the owner callback', () async {
    final r = runtime!;
    final faulty = _BlockingDatabase(r.store)..blocked = true;
    final controller = ActiveSessionController(
      draftStore: DraftStore.local(faulty),
    );
    addTearDown(controller.dispose);
    final reported = <Object>[];
    controller.onAutosaveError = reported.add;
    controller.seedEmpty(name: 'Synthetic workout', focus: '');
    await Future<void>.delayed(
      ActiveSessionController.saveDebounce + const Duration(milliseconds: 300),
    );
    await _until(() => reported.isNotEmpty, 'autosave failure is reported');
    expect(reported.first, isA<StoreException>());
    expect(controller.persistenceError, same(reported.last));
  });

  test(
    'the session owner wires its active controller into onPersistenceError',
    () async {
      final manager = SessionManager();
      addTearDown(manager.dispose);
      final reported = <Object>[];
      manager.onPersistenceError = reported.add;
      final controller = ActiveSessionController();
      addTearDown(controller.dispose);
      controller.seedEmpty(name: 'Synthetic workout', focus: '');
      manager.register(controller);
      controller.onAutosaveError!(const StoreException('synthetic'));
      expect(reported, hasLength(1));
      manager.clear();
      expect(controller.onAutosaveError, isNull);
    },
  );

  test('two quick Retry calls share one recovery run', () async {
    final r = runtime!;
    r.persistenceFailure.value = const StoreException('synthetic');
    final first = r.retryPersistence();
    final second = r.retryPersistence();
    expect(identical(first, second), isTrue);
    await first;
    expect(r.persistenceFailure.value, isNull);
    final third = r.retryPersistence();
    expect(identical(first, third), isFalse);
    await third;
  });
}
