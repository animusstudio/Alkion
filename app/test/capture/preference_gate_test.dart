// Host tests for the preference side of a capture: every preference writer is
// one admitted source operation whose outcome capture can await, a failed
// write stays observable, and the notification's rest keys, foreground and
// background, are never written while a capture holds the source.
//
// The gate here is test/support/gate_model.dart, a Dart model of the native
// admission protocol. It pins the Dart ordering only: the Android background
// engine itself is not exercised on this host.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:workout_tracker/capture/session_capture_hooks.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';
import 'package:workout_tracker/capture/startup_inventory.dart';
import 'package:workout_tracker/session/session_manager.dart';
import 'package:workout_tracker/session/workout_notification.dart';
import 'package:workout_tracker/settings/settings_service.dart';
import 'package:workout_tracker/units/unit_service.dart';

import '../support/fake_stores.dart';
import '../support/gate_model.dart';

/// An in-memory preference store that counts loads and writes, and can hold
/// or fail its writes.
class _CountingStore extends SharedPreferencesStorePlatform {
  _CountingStore(Map<String, Object> values)
      : _data = {for (final e in values.entries) 'flutter.${e.key}': e.value};

  final Map<String, Object> _data;
  int loads = 0;
  int writes = 0;
  Completer<void>? holdWrites;
  bool failWrites = false;

  Object? value(String key) => _data['flutter.$key'];

  Future<bool> _write(void Function() apply) async {
    final hold = holdWrites;
    if (hold != null) await hold.future;
    if (failWrites) {
      throw PlatformException(code: 'write_failed');
    }
    writes++;
    apply();
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      _write(() => _data[key] = value);

  @override
  Future<bool> remove(String key) => _write(() => _data.remove(key));

  @override
  Future<bool> clear() => _write(_data.clear);

  @override
  Future<Map<String, Object>> getAll() async {
    loads++;
    return Map.of(_data);
  }

  @override
  Future<Map<String, Object>> getAllWithParameters(
      GetAllParameters parameters) async {
    loads++;
    final prefix = parameters.filter.prefix;
    return {
      for (final e in _data.entries)
        if (e.key.startsWith(prefix)) e.key: e.value,
    };
  }
}

/// Records what the notification surface was asked to do; [showGate] holds
/// `show` until released.
class _FakePlugin implements FlutterLocalNotificationsPlugin {
  int shows = 0;
  int schedules = 0;
  int cancels = 0;
  Completer<void>? showGate;

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
        onDidReceiveBackgroundNotificationResponse,
  }) async =>
      true;

  @override
  T? resolvePlatformSpecificImplementation<
          T extends FlutterLocalNotificationsPlatform>() =>
      null;

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    final gate = showGate;
    if (gate != null) await gate.future;
    shows++;
  }

  @override
  Future<void> zonedSchedule({
    required int id,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required AndroidScheduleMode androidScheduleMode,
    String? title,
    String? body,
    String? payload,
    DateTimeComponents? matchDateTimeComponents,
  }) async {
    schedules++;
  }

  @override
  Future<void> cancel({required int id, String? tag}) async {
    cancels++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late _CountingStore store;

  void useStore(Map<String, Object> values) {
    store = _CountingStore(values);
    SharedPreferencesStorePlatform.instance = store;
    SharedPreferences.resetStatic();
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('reps-preference-gate');
    SessionWriteLedger.instance.resetForTesting();
    appSourceGate = null;
  });

  tearDown(() async {
    appSourceGate = null;
    SessionWriteLedger.instance.resetForTesting();
    await dir.delete(recursive: true);
  });

  test('pending_unit_failure_blocks_capture', () async {
    useStore({'unit': 'kg'});
    final model = GateModel('unit');
    addTearDown(model.detach);
    final gate = model.gate(dir);
    appSourceGate = gate;

    final units = UnitService();
    await units.load();
    expect(units.unit, Unit.kg);

    // A unit change whose write is still running: the write holds a ticket,
    // so the gate cannot drain, and flushing waits for it.
    store.holdWrites = Completer<void>();
    units.setUnit(Unit.lb);
    expect(units.unit, Unit.lb);
    var flushed = false;
    final flushing =
        units.flushPersistence().whenComplete(() => flushed = true);
    await pumpEventQueue();
    expect(flushed, false, reason: 'flush waits for the pending unit write');
    expect(model.idle, false, reason: 'the pending write holds its ticket');
    store.holdWrites!.complete();
    store.holdWrites = null;
    await flushing;
    expect(model.idle, true);

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final reloadedUnit = prefs.getString('unit');
    expect(reloadedUnit, 'lb');
    expect(store.value('unit'), 'lb');

    // A failing write propagates through flushPersistence and blocks the
    // capture's local drain until a later write of the unit succeeds.
    store.failWrites = true;
    units.setUnit(Unit.kg);
    await expectLater(units.flushPersistence(), throwsA(anything));
    expect(SessionWriteLedger.instance.failures.keys, contains('prefs.unit'));
    final hooks = SessionCaptureHooks(
      manager: SessionManager(finishedStore: FakeFinishedSessionStore()),
      preservation: RawPreservation(Directory('${dir.path}/prep'), base: dir),
    );
    final preparation = await gate.closeAdmission('capture-unit');
    await expectLater(
      hooks.drainAndFlush(preparation),
      throwsA(isA<SessionCaptureException>()
          .having((e) => e.code, 'code', 'persistence_failed')
          .having((e) => e.detail, 'detail', contains('prefs.unit'))),
    );

    // While admission is closed a unit change is refused: nothing is
    // written, the shown unit goes back to the stored one, and flushing
    // reports the refused change as settled (memory equals disk).
    await gate.release(SourceHold(preparation.captureId, preparation.generation),
        decisionDigest: 'test');
    store.failWrites = false;
    units.setUnit(Unit.kg);
    await units.flushPersistence();
    expect(store.value('unit'), 'kg');
    expect(SessionWriteLedger.instance.failures, isEmpty,
        reason: 'the later successful write supersedes the failure');

    final again = await gate.closeAdmission('capture-unit-2');
    final writesBefore = store.writes;
    units.setUnit(Unit.lb);
    await units.flushPersistence();
    expect(units.unit, Unit.kg, reason: 'a refused change is undone');
    expect(store.writes, writesBefore);
    await prefs.reload();
    expect(prefs.getString('unit'), 'kg');
    expect(model.refused, contains('prefs.unit'));
    await gate.release(SourceHold(again.captureId, again.generation),
        decisionDigest: 'test');
  });

  test('settings_writers_are_admitted_and_refused_visibly', () async {
    useStore({'mode': 'dark'});
    final model = GateModel('settings');
    addTearDown(model.detach);
    final gate = model.gate(dir);
    appSourceGate = gate;

    final settings = SettingsService();
    await settings.load();
    await settings.setMode('light');
    expect(store.value('mode'), 'light');
    expect(model.admitted, contains('prefs.settings.mode'));

    final preparation = await gate.closeAdmission('capture-settings');
    final writesBefore = store.writes;
    await expectLater(
      settings.setMode('dark'),
      throwsA(isA<SourceGateException>()
          .having((e) => e.code, 'code', 'admission_closed')),
    );
    expect(settings.mode, 'light', reason: 'the refused change is undone');
    await expectLater(settings.setSyncEnabled(true),
        throwsA(isA<SourceGateException>()));
    expect(settings.syncEnabled, false);
    await expectLater(settings.markUpdateChecked(42),
        throwsA(isA<SourceGateException>()));
    expect(settings.lastUpdateCheckMs, 0);
    expect(store.writes, writesBefore);
    await gate.release(SourceHold(preparation.captureId, preparation.generation),
        decisionDigest: 'test');
  });

  test('refused_undo_shows_last_stored_value', () async {
    useStore({'unit': 'kg', 'mode': 'dark'});
    final model = GateModel('undo');
    addTearDown(model.detach);
    final gate = model.gate(dir);
    appSourceGate = gate;
    final units = UnitService();
    await units.load();
    final settings = SettingsService();
    await settings.load();
    final preparation = await gate.closeAdmission('capture-undo');

    // Stored kg; two refused changes in a row. The undo of the second must
    // not show the first refused value.
    units.setUnit(Unit.lb);
    units.setUnit(Unit.kg);
    await units.flushPersistence();
    expect(units.unit, Unit.kg);
    units.setUnit(Unit.lb);
    await units.flushPersistence();
    expect(units.unit, Unit.kg);
    expect(store.value('unit'), 'kg');

    // Stored dark; the same for a setting.
    final light = settings.setMode('light');
    final dark = settings.setMode('dark');
    await expectLater(light, throwsA(isA<SourceGateException>()));
    await expectLater(dark, throwsA(isA<SourceGateException>()));
    expect(settings.mode, 'dark');
    await expectLater(
        settings.setMode('light'), throwsA(isA<SourceGateException>()));
    expect(settings.mode, 'dark');
    expect(store.value('mode'), 'dark');

    // After release a successful write becomes the stored value.
    await gate.release(SourceHold(preparation.captureId, preparation.generation),
        decisionDigest: 'test');
    await settings.setMode('light');
    units.setUnit(Unit.lb);
    await units.flushPersistence();
    final again = await gate.closeAdmission('capture-undo-2');
    await expectLater(
        settings.setMode('dark'), throwsA(isA<SourceGateException>()));
    expect(settings.mode, 'light');
    units.setUnit(Unit.kg);
    await units.flushPersistence();
    expect(units.unit, Unit.lb);
    await gate.release(SourceHold(again.captureId, again.generation),
        decisionDigest: 'test');
  });

  test('background_plus30_and_notifier_block_under_hold', () async {
    final restStart = DateTime.now();
    useStore({
      restBlobName: 'Push',
      restBlobStartedAt: restStart.subtract(const Duration(minutes: 20))
          .toIso8601String(),
      restBlobStartMs: restStart.millisecondsSinceEpoch,
      restBlobTotal: 90,
    });
    final model = GateModel('notification');
    addTearDown(model.detach);
    // The foreground engine's gate and the background engine's own instance
    // over the same state directory: both answer through the one native
    // ticket table.
    final foregroundGate = model.gate(dir);
    final backgroundGate = model.gate(dir);
    appSourceGate = foregroundGate;
    final plugin = _FakePlugin();

    // 1. The background +30s takes its ticket BEFORE it loads or reloads
    //    preferences, and keeps it through every preference and plugin
    //    continuation; a capture closing meanwhile waits for all of it.
    model.holdAdmits.add('notification.background_add30');
    final loadsBefore = store.loads;
    plugin.showGate = Completer<void>();
    final background =
        extendRestInBackground(gate: backgroundGate, plugin: plugin);
    await pumpEventQueue();
    expect(model.heldCount, 1);
    expect(store.loads, loadsBefore,
        reason: 'no preference load or reload before admission');
    model.holdAdmits.clear();
    model.releaseHeld();
    await pumpEventQueue();
    expect(store.value(restBlobTotal), 120);
    expect(model.idle, false, reason: 'the plugin continuation still runs');

    final preparation =
        await foregroundGate.closeAdmission('capture-notification');
    var held = false;
    final draining = foregroundGate
        .drain(preparation, timeout: const Duration(seconds: 5))
        .then((h) {
      held = true;
      return h;
    });
    await pumpEventQueue();
    expect(held, false, reason: 'the admitted background +30s is drained');
    plugin.showGate!.complete();
    plugin.showGate = null;
    await background;
    final hold = await draining;
    expect(held, true);

    // 2. Under the hold neither engine writes the rest keys: a background
    //    tap and the foreground notifier are both refused before touching
    //    preferences or the notification.
    final writesAtHold = store.writes;
    final showsAtHold = plugin.shows;
    final loadsAtHold = store.loads;
    await extendRestInBackground(gate: backgroundGate, plugin: plugin);
    expect(store.loads, loadsAtHold);

    final notifier = WorkoutNotification(plugin: plugin, isAndroid: true);
    await notifier.init();
    await notifier.showFor(
      name: 'Push',
      startedAt: restStart,
      restStart: DateTime.now(),
      restTotal: 60,
    );
    await notifier.cancel();
    final backgroundWritesWhileHeld = store.writes - writesAtHold;
    expect(backgroundWritesWhileHeld, 0);
    expect(plugin.shows, showsAtHold);
    expect(plugin.cancels, 0);
    expect(store.value(restBlobTotal), 120);

    // 3. After release the refused foreground update is not lost: the same
    //    state is written again (nothing was remembered as shown).
    await foregroundGate.release(hold, decisionDigest: 'test');
    final restAgain = DateTime.now();
    await notifier.showFor(
      name: 'Push',
      startedAt: restStart,
      restStart: restAgain,
      restTotal: 60,
    );
    expect(store.value(restBlobTotal), 60);
    expect(store.value(restBlobStartMs), restAgain.millisecondsSinceEpoch);
    expect(model.idle, true);
  });
}
