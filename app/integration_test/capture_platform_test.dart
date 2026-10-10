// Native capture qualification on one explicitly chosen device:
//   make -C app capture-integration CAPTURE_DEVICE=linux
//
// Everything here runs against the real `reps/capture` plugin and the real
// PowerSync SDK/core. Every state directory, capture directory and database
// is a fresh temporary directory; no app-support data is ever touched.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:powersync/powersync.dart';
import 'package:reps_capture_platform/reps_capture_platform.dart';
import 'package:crypto/crypto.dart';
import 'package:workout_tracker/capture/capture_artifact.dart'
    show verifyCaptureDirectory;
import 'package:workout_tracker/capture/capture_coordinator.dart';
import 'package:workout_tracker/capture/capture_journal.dart';
import 'package:workout_tracker/capture/capture_profile.dart';
import 'package:workout_tracker/capture/capture_startup.dart';
import 'package:workout_tracker/capture/capture_transport.dart';
import 'package:workout_tracker/capture/native_sync_quiescence.dart';
import 'package:workout_tracker/capture/session_capture_hooks.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';
import 'package:workout_tracker/capture/startup_inventory.dart';
import 'package:workout_tracker/data/active_session_draft.dart';
import 'package:workout_tracker/data/finished_session_store.dart';
import 'package:workout_tracker/session/session_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:workout_tracker/sync/schema.dart';

import 'support/gate_helper_process.dart';
import 'support/native_sync_fixture.dart';

Matcher gateCode(String code) =>
    throwsA(isA<SourceGateException>().having((e) => e.code, 'code', code));

Matcher unsupported(String code) => throwsA(
  isA<UnsupportedCaptureProfile>().having((e) => e.code, 'code', code),
);

/// Filesystem roots the file primitives are exercised on: the system temp
/// directory and a disposable directory inside the build output (the
/// filesystem the checkout, and typically the home directory, lives on).
Future<List<Directory>> _scratchRoots() async {
  final build = File(Platform.resolvedExecutable).parent.parent;
  return [
    await Directory.systemTemp.createTemp('reps-capture-native'),
    await Directory(
      '${build.path}/capture-native-scratch',
    ).create(recursive: true).then((d) => d.createTemp('fs')),
  ];
}

Future<String> _filesystemType(Directory d) async {
  final r = await Process.run('stat', ['-f', '-c', '%T', d.path]);
  return (r.stdout as String).trim();
}

/// Delegates every call to the REAL qualified method and records what it
/// sees: when the real `disconnect()` completes, whether the watched row was
/// already applied at that moment (read on a reader connection), and, inside
/// an extra writer lease taken before the real barrier, whether the row is
/// visible to the writer. Its own observations come only from the database,
/// never from SDK status. Callbacks of an earlier [watch] are ignored.
class _ObservedMethod implements NativeSyncMethod {
  _ObservedMethod(this._inner);

  final NativeSyncMethod _inner;
  var _round = 0;
  String? _row;
  var disconnectCompleted = false;
  bool? visibleWhenDisconnectCompleted;
  bool? visibleInsideBarrier;
  var barrierCompleted = false;

  void watch(String? row) {
    _round++;
    _row = row;
    disconnectCompleted = false;
    visibleWhenDisconnectCompleted = null;
    visibleInsideBarrier = null;
    barrierCompleted = false;
  }

  @override
  String get methodId => _inner.methodId;

  @override
  Future<void> disconnect(PowerSyncDatabase database) async {
    final round = _round;
    final row = _row;
    await _inner.disconnect(database);
    if (round != _round) return;
    disconnectCompleted = true;
    if (row != null) {
      visibleWhenDisconnectCompleted =
          await database.getOptional('SELECT id FROM exercises WHERE id = ?', [
            row,
          ]) !=
          null;
    }
  }

  @override
  Future<void> awaitNativeApplyDrained(PowerSyncDatabase database) async {
    final round = _round;
    final row = _row;
    if (row != null) {
      await database.writeLock((tx) async {
        final seen =
            await tx.getOptional('SELECT id FROM exercises WHERE id = ?', [
              row,
            ]) !=
            null;
        if (round == _round) visibleInsideBarrier = seen;
      });
    }
    await _inner.awaitNativeApplyDrained(database);
    if (round == _round) barrierCompleted = true;
  }
}

/// A background isolate that talks to the plugin through its own binary
/// messenger, as a second engine context in the same process would.
class _BackgroundGate {
  _BackgroundGate._(this._isolate, this._commands, this._results);

  final Isolate _isolate;
  final SendPort _commands;
  final StreamIterator<Object?> _results;

  static Future<_BackgroundGate> spawn(Directory stateDir) async {
    final results = ReceivePort();
    final iterator = StreamIterator<Object?>(results);
    final isolate = await Isolate.spawn(_main, (
      RootIsolateToken.instance!,
      stateDir.path,
      results.sendPort,
    ));
    await iterator.moveNext();
    return _BackgroundGate._(isolate, iterator.current as SendPort, iterator);
  }

  /// Asks the isolate to run one write through the gate. With [holdOpen] the
  /// admitted body waits until [finishHeld].
  Future<String> write({bool holdOpen = false}) async {
    _commands.send(holdOpen ? 'write-held' : 'write');
    await _results.moveNext();
    return _results.current as String;
  }

  Future<String> finishHeld() async {
    _commands.send('finish');
    await _results.moveNext();
    return _results.current as String;
  }

  void kill() => _isolate.kill(priority: Isolate.immediate);

  static Future<void> _main((RootIsolateToken, String, SendPort) args) async {
    final (token, dir, results) = args;
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    final gate = SourceWriteGate(stateDirectory: Directory(dir));
    final commands = ReceivePort();
    results.send(commands.sendPort);
    Completer<void>? held;
    var writes = 0;
    await for (final command in commands) {
      switch (command) {
        case 'write' || 'write-held':
          final gateOpen = Completer<void>();
          if (command == 'write-held') held = gateOpen;
          final running = gate.run('background-write', (_) async {
            if (command == 'write-held') {
              results.send('admitted');
              await gateOpen.future;
            }
            writes++;
          });
          if (command == 'write') {
            try {
              await running;
              results.send('written:$writes');
            } on SourceGateException catch (e) {
              results.send('rejected:${e.code}:$writes');
            }
          } else {
            unawaited(
              running.then(
                (_) {},
                onError: (Object e) {
                  results.send('rejected:${(e as SourceGateException).code}');
                },
              ),
            );
          }
        case 'finish':
          held?.complete();
          held = null;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          results.send('finished:$writes');
      }
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory stateDir;
  final cleanup = <Future<void> Function()>[];

  setUp(() async {
    stateDir = await Directory.systemTemp.createTemp('reps-capture-gate');
  });

  tearDown(() async {
    for (final c in cleanup.reversed) {
      await c();
    }
    cleanup.clear();
    if (await stateDir.exists()) await stateDir.delete(recursive: true);
  });

  test('nested_ticket_lives_through_last_continuation', () async {
    final gate = SourceWriteGate(stateDirectory: stateDir);
    final nestedSave = Completer<void>();
    var nestedSaved = false;
    late Future<void> nested;

    await gate.run('finish', (ticket) async {
      nested = gate.run('recordFinished', (inner) async {
        expect(inner, ticket);
        await nestedSave.future;
        await File('${stateDir.path}/finished.json').writeAsString('{}');
        nestedSaved = true;
      }, parent: ticket);
    });

    final preparation = await gate.closeAdmission('capture-nested');
    var drainCompletedBeforeNestedSave = false;
    final draining = gate
        .drain(preparation, timeout: const Duration(seconds: 10))
        .whenComplete(() {
          if (!nestedSaved) drainCompletedBeforeNestedSave = true;
        });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(drainCompletedBeforeNestedSave, false);
    expect(
      await gate.holdStatus(
        SourceHold(preparation.captureId, preparation.generation),
      ),
      'preparing',
    );

    nestedSave.complete();
    await nested;
    final hold = await draining;
    expect(drainCompletedBeforeNestedSave, false);
    expect(await gate.isHeld(hold), true);

    await gate.release(hold, decisionDigest: 'a' * 64);
    late SourceTicket finished;
    await gate.run('edit', (t) async => finished = t);
    expect(finished.generation, hold.generation);
    await expectLater(
      gate.run('late', (_) async {}, parent: finished),
      gateCode('parent_completed'),
    );
  });

  test('two_engines_hold_excludes_background_and_process', () async {
    final gate = SourceWriteGate(stateDirectory: stateDir);
    final background = await _BackgroundGate.spawn(stateDir);
    cleanup.add(() async => background.kill());
    final helper = await GateHelperProcess.start();
    cleanup.add(helper.close);

    // Work admitted in another isolate and in another process before the
    // capture is prepared keeps the hold from being taken.
    expect(await background.write(holdOpen: true), 'admitted');
    final other = await helper.call('admit', stateDir.path, 'notification');
    expect(other['code'], 'ok');

    final preparation = await gate.closeAdmission('capture-two');
    var held = false;
    final holding = gate
        .drain(preparation, timeout: const Duration(seconds: 20))
        .whenComplete(() => held = true);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(held, false, reason: 'background ticket still admitted');
    expect(await background.finishHeld(), 'finished:1');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(held, false, reason: 'the other process still holds a ticket');
    expect(
      (await helper.call('complete', stateDir.path, other['ticket']!))['code'],
      'ok',
    );
    final hold = await holding;
    expect(await gate.isHeld(hold), true);

    var writesWhileHeld = 0;
    await expectLater(
      gate.run('foreground', (_) async => writesWhileHeld++),
      gateCode('admission_closed'),
    );
    final second = SourceWriteGate(stateDirectory: stateDir);
    await expectLater(
      second.run('second-engine', (_) async => writesWhileHeld++),
      gateCode('admission_closed'),
    );
    expect(await background.write(), 'rejected:admission_closed:1');
    final processAdmit = await helper.call('admit', stateDir.path, 'process');
    expect(processAdmit['code'], 'admission_closed');
    expect(writesWhileHeld, 0);

    // The other process cannot take or release this capture either.
    expect(
      (await helper.call('prepare', stateDir.path, 'capture-other'))['code'],
      'capture_in_progress',
    );
    expect(
      (await helper.call(
        'release',
        stateDir.path,
        'capture-other',
        '${hold.generation}',
        'c' * 64,
      ))['code'],
      'mismatch',
    );
    await expectLater(
      gate.closeAdmission('capture-again'),
      gateCode('capture_in_progress'),
    );

    await gate.release(hold, decisionDigest: 'd' * 64);
    expect(await background.write(), 'written:2');
    expect(
      (await helper.call('admit', stateDir.path, 'process'))['code'],
      'ok',
    );
  });

  test('missing_plugin_runs_ordinary_writes_ungated', () async {
    // A build without the plugin is not capture-capable: no capture can
    // close admission there, so ordinary writes run ungated, while every
    // capture primitive still fails.
    const absent = RepsCapturePlatform(
      channel: MethodChannel('reps/capture/not-registered'),
    );
    final gate = SourceWriteGate(stateDirectory: stateDir, platform: absent);
    SourceTicket? ran;
    await gate.run('write', (t) async => ran = t);
    expect(ran, SourceTicket.ungated);
    await expectLater(
      gate.closeAdmission('capture-1'),
      gateCode('platform_unavailable'),
    );
    var bodyRan = false;
    final destination = File('${stateDir.path}/journal.json');
    await destination.writeAsBytes([1, 2, 3], flush: true);
    await expectLater(
      const CaptureFiles(platform: absent).durableReplace(destination, [9]),
      gateCode('platform_unavailable'),
    );
    expect(await destination.readAsBytes(), [1, 2, 3]);

    // With the plugin present, a missing or unusable state directory is
    // refused, never assumed open or run ungated.
    final missing = SourceWriteGate(
      stateDirectory: Directory('${stateDir.path}/does-not-exist'),
    );
    await expectLater(
      missing.run('write', (_) async => bodyRan = true),
      gateCode('invalid_argument'),
    );
    expect(bodyRan, false);
  });

  test('killed_owner_preserves_durable_hold', () async {
    final owner = await GateHelperProcess.start();
    cleanup.add(owner.close);
    final prepared = await owner.call(
      'prepare',
      stateDir.path,
      'capture-killed',
    );
    expect(prepared['code'], 'ok');
    final generation = prepared['generation']!;
    expect(
      (await owner.call(
        'complete',
        stateDir.path,
        prepared['ticket']!,
      ))['code'],
      'ok',
    );
    expect(
      (await owner.call(
        'drain',
        stateDir.path,
        'capture-killed',
        generation,
      ))['code'],
      'held',
    );
    await owner.kill();

    // A restarted app cannot admit, and cannot start another capture.
    final gate = SourceWriteGate(stateDirectory: stateDir);
    final hold = SourceHold('capture-killed', int.parse(generation));
    var writes = 0;
    await expectLater(
      gate.run('boot-backfill', (_) async => writes++),
      gateCode('admission_closed'),
    );
    expect(writes, 0);
    expect(await gate.holdStatus(hold), 'recorded');
    expect(await gate.isHeld(hold), false);
    await expectLater(
      gate.closeAdmission('capture-new'),
      gateCode('capture_in_progress'),
    );

    // Process loss while preparing also stays closed.
    await expectLater(
      gate.release(
        SourceHold('capture-killed', hold.generation + 1),
        decisionDigest: 'b' * 64,
      ),
      gateCode('mismatch'),
    );
    await gate.release(hold, decisionDigest: 'b' * 64);
    await gate.run('boot-backfill', (_) async => writes++);
    expect(writes, 1);

    final preparer = await GateHelperProcess.start();
    cleanup.add(preparer.close);
    expect(
      (await preparer.call('prepare', stateDir.path, 'capture-p'))['code'],
      'ok',
    );
    await preparer.kill();
    await expectLater(
      gate.run('boot-backfill', (_) async => writes++),
      gateCode('admission_closed'),
    );
    expect(writes, 1);
  });

  test('killed_ticket_holder_requires_recovery', () async {
    final worker = await GateHelperProcess.start();
    cleanup.add(worker.close);
    final admitted = await worker.call(
      'admit',
      stateDir.path,
      'cross-store-write',
    );
    expect(admitted['code'], 'ok');

    final gate = SourceWriteGate(stateDirectory: stateDir);
    final preparation = await gate.closeAdmission('capture-interrupted');
    final recorded = SourceHold(preparation.captureId, preparation.generation);
    // A live owner with admitted work keeps the hold pending.
    await expectLater(
      gate.drain(preparation, timeout: const Duration(milliseconds: 500)),
      gateCode('drain_timeout'),
    );

    // The owner dies with its work in flight: its shared lock vanishes, but
    // its marker stays, so no hold is ever taken over that work.
    await worker.kill();
    await expectLater(
      gate.drain(preparation, timeout: const Duration(seconds: 2)),
      gateCode('recovery_required'),
    );
    await expectLater(
      gate.drain(preparation, timeout: const Duration(seconds: 2)),
      gateCode('recovery_required'),
      reason: 'nothing clears it implicitly',
    );
    expect(await gate.holdStatus(recorded), 'preparing');
    final other = await GateHelperProcess.start();
    cleanup.add(other.close);
    expect(
      (await other.call(
        'drain',
        stateDir.path,
        preparation.captureId,
        '${preparation.generation}',
      ))['code'],
      'recovery_required',
    );

    // Only an explicit recovery decision clears it.
    expect(await gate.acknowledgeInterruptedWork(decisionDigest: 'a' * 64), 1);
    final hold = await gate.drain(
      preparation,
      timeout: const Duration(seconds: 2),
    );
    expect(await gate.isHeld(hold), true);
    await gate.release(hold, decisionDigest: 'b' * 64);

    // A live process's marker is never cleared by an acknowledgement.
    final live = await other.call('admit', stateDir.path, 'live-write');
    expect(live['code'], 'ok');
    expect(await gate.acknowledgeInterruptedWork(decisionDigest: 'c' * 64), 0);
    final next = await gate.closeAdmission('capture-after');
    await expectLater(
      gate.drain(next, timeout: const Duration(milliseconds: 500)),
      gateCode('drain_timeout'),
    );
    expect(
      (await other.call('complete', stateDir.path, live['ticket']!))['code'],
      'ok',
    );
    final nextHold = await gate.drain(
      next,
      timeout: const Duration(seconds: 2),
    );
    expect(await gate.isHeld(nextHold), true);
  });

  test('destination_conflict_never_replaces', () async {
    const files = CaptureFiles();
    for (final root in await _scratchRoots()) {
      cleanup.add(() => root.delete(recursive: true));
      final fs = await _filesystemType(root);
      // ignore: avoid_print
      print('capture file primitives on ${root.path}: $fs');

      Future<Directory> staged(String name) async {
        final d = await Directory('${root.path}/$name').create();
        await File(
          '${d.path}/manifest.json',
        ).writeAsString('{"staged":"$name"}');
        await Directory('${d.path}/stores').create();
        await File('${d.path}/stores/a.json').writeAsString('[]');
        return d;
      }

      // An absent destination is published whole.
      final first = await staged('staging-1');
      final published = Directory('${root.path}/capture-1');
      await files.publishNoReplace(first, published);
      expect(await first.exists(), false);
      expect(
        await File('${published.path}/manifest.json').readAsString(),
        '{"staged":"staging-1"}',
      );

      // A non-empty and an empty existing destination are both refused.
      final originalBytes = await File(
        '${published.path}/manifest.json',
      ).readAsBytes();
      final second = await staged('staging-2');
      await expectLater(
        files.publishNoReplace(second, published),
        gateCode('destination_exists'),
      );
      final bytesAtExistingDestination = await File(
        '${published.path}/manifest.json',
      ).readAsBytes();
      expect(bytesAtExistingDestination, originalBytes);
      expect(await File('${second.path}/manifest.json').exists(), true);

      final empty = await Directory('${root.path}/capture-empty').create();
      await expectLater(
        files.publishNoReplace(second, empty),
        gateCode('destination_exists'),
      );
      expect(await empty.list().isEmpty, true);
      expect(await second.exists(), true);

      // durableReplace swaps whole contents and leaves no temporary file.
      final journal = File('${root.path}/journal.json');
      await files.durableReplace(journal, [1, 2, 3]);
      await files.durableReplace(journal, [4, 5]);
      expect(await journal.readAsBytes(), [4, 5]);
      expect(
        await root.list().where((e) => e.path.contains('.capture-tmp')).isEmpty,
        true,
      );
    }
  });

  test('flush_or_directory_sync_failure_blocks', () async {
    const files = CaptureFiles();
    final root = await Directory.systemTemp.createTemp('reps-capture-faults');
    cleanup.add(() => root.delete(recursive: true));
    final journal = File('${root.path}/journal.json');
    await journal.writeAsBytes([1], flush: true);

    var reportedSuccess = 0;
    Future<void> attempt(Future<void> Function() op, String code) async {
      try {
        await op();
        reportedSuccess++;
      } on SourceGateException catch (e) {
        expect(e.code, code);
      }
    }

    await files.injectFaultForTesting('file_sync');
    await attempt(() => files.durableReplace(journal, [2]), 'io_error');
    expect(
      await journal.readAsBytes(),
      [1],
      reason: 'a failed file flush never renames over the destination',
    );
    await files.injectFaultForTesting('dir_sync');
    await attempt(() => files.durableReplace(journal, [3]), 'io_error');
    expect(
      await root.list().where((e) => e.path.contains('.capture-tmp')).isEmpty,
      true,
    );

    final staging = await Directory('${root.path}/staging').create();
    await File('${staging.path}/manifest.json').writeAsString('{}');
    final finalDir = Directory('${root.path}/capture');
    await files.injectFaultForTesting('file_sync');
    await attempt(() => files.publishNoReplace(staging, finalDir), 'io_error');
    expect(
      await finalDir.exists(),
      false,
      reason: 'a failed flush never publishes',
    );
    await files.injectFaultForTesting('dir_sync');
    await attempt(() => files.publishNoReplace(staging, finalDir), 'io_error');
    expect(reportedSuccess, 0);

    // A failed gate-state write is never reported as success. A failed FILE
    // flush happens before the rename: closeAdmission is refused and
    // admission stays open, exactly as before.
    final gate = SourceWriteGate(stateDirectory: stateDir);
    await files.injectFaultForTesting('file_sync');
    await expectLater(
      gate.closeAdmission('capture-fault'),
      gateCode('io_error'),
    );
    var writes = 0;
    await gate.run('write', (_) async => writes++);
    expect(writes, 1);

    // A failed DIRECTORY flush happens after the rename: closeAdmission is
    // still refused, but the `preparing` record may already be in place, so
    // admission is closed (fail-closed) until an explicit release.
    final inFlight = Completer<void>();
    final running = gate.run('in-flight', (_) => inFlight.future);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await files.injectFaultForTesting('dir_sync');
    await expectLater(
      gate.closeAdmission('capture-fault-dir'),
      gateCode('io_error'),
    );
    const recorded = SourceHold('capture-fault-dir', 1);
    expect(await gate.holdStatus(recorded), 'preparing');
    await expectLater(
      gate.run('write', (_) async => writes++),
      gateCode('admission_closed'),
    );
    expect(writes, 1);
    inFlight.complete();
    await running;
    await gate.release(recorded, decisionDigest: 'f' * 64);
    await gate.run('write', (_) async => writes++);
    expect(writes, 2);
  });

  test(
    'paused_native_apply_and_pending_disconnect_block_observation',
    () async {
      final probe = await Directory.systemTemp.createTemp(
        'reps-native-profile',
      );
      cleanup.add(() => probe.delete(recursive: true));
      final probeDb = PowerSyncDatabase(
        schema: schema,
        path: '${probe.path}/workout-tracker.db',
      );
      await probeDb.initialize();
      final runtime = qualifiedSourceProfiles
          .singleWhere((p) => p.runtime.platform == Platform.operatingSystem)
          .runtime;
      final profile = await qualifyCaptureProfile(probeDb, runtime);
      final observedCore = (await probeDb.get(
        'SELECT powersync_rs_version() AS v',
      ))['v'];
      await probeDb.close();
      // ignore: avoid_print
      print(
        'native core in this bundle: $observedCore; profile ${profile.profileId}',
      );

      final candidate = linuxNativeSyncQualificationRecord;
      expect(
        candidate.qualification.profileEvidenceDigest,
        profile.evidenceDigest,
      );
      expect(candidate.qualification.methodId, candidateNativeSyncMethodId);
      // The real method, unmocked, observed through a delegating spy; the
      // adapter is the production class (its seam evidence is never current
      // for a production adapter).
      final observed = _ObservedMethod(
        nativeSyncMethodById(candidateNativeSyncMethodId)!,
      );
      final quiescence = NativeSyncQuiescence.withMethodForTesting(
        qualification: candidate.qualification,
        method: observed,
      );

      final f = await openNativeSyncFixture(profile);
      cleanup.add(f.close);
      final queued = await openNativeSyncFixture(profile, queue: true);
      cleanup.add(queued.close);

      // Application tickets are fully drained and the gate is held: none of
      // that is evidence about native sync.
      final gate = SourceWriteGate(stateDirectory: stateDir);
      final hold = await gate.drain(
        await gate.closeAdmission('capture-native'),
        timeout: const Duration(seconds: 5),
      );
      expect(await gate.isHeld(hold), true);

      quiescence.connectionWillChange(f.database);
      await f.connect();
      await f.deliverCheckpoint([const SyntheticRow('ex-1', 'Synthetic one')]);
      await f.stageCheckpoint([const SyntheticRow('ex-2', 'Synthetic two')]);
      final queueBefore = await f.queue();

      // 1. The native apply continuation is paused. The fixture's pause holds
      // the same writer the method's barrier needs, so the observation not
      // completing proves little by itself; what is asserted is that the real
      // disconnect() itself stays pending, and that when it returns the row
      // is already applied.
      await f.pauseNextApply();
      await f.waitUntilApplyPaused(unappliedIds: ['ex-2']);
      observed.watch('ex-2');
      var observationCompletedWhileNativeApplyPaused = false;
      final observing = quiescence
          .disconnectAndObserve(
            f.database,
            profile,
            captureId: hold.captureId,
            gateGeneration: hold.generation,
            timeout: const Duration(seconds: 30),
          )
          .whenComplete(
            () => observationCompletedWhileNativeApplyPaused = true,
          );
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final disconnectCompletedWhileNativeApplyPaused =
          observed.disconnectCompleted;
      expect(disconnectCompletedWhileNativeApplyPaused, false);
      expect(observationCompletedWhileNativeApplyPaused, false);
      expect(await f.visible('ex-2'), false);
      expect(await gate.isHeld(hold), true);

      await f.releaseApply();
      final evidence = await observing;
      expect(evidence.disconnectCompleted && evidence.nativeApplyDrained, true);
      // The real disconnect() returned only after the paused apply ran: the
      // row is visible at that moment (reader) and inside the barrier
      // (writer). Lines received after the abort are discarded, so this row
      // was received, and its apply pending, before the disconnect began.
      expect(observed.visibleWhenDisconnectCompleted, true);
      expect(observed.visibleInsideBarrier, true);
      expect(observed.barrierCompleted, true);
      expect(f.database.currentStatus.connected, false);
      expect(await f.queue(), queueBefore);
      expect(
        quiescence.isCurrent(
          evidence,
          f.database,
          profile,
          captureId: hold.captureId,
          gateGeneration: hold.generation,
        ),
        true,
      );

      // 2. Disconnect pending while the writer is free: an admitted upload is
      // still in flight in the other database.
      final queueRows = await queued.queue();
      expect(queueRows, hasLength(2));
      queued.holdUploads();
      quiescence.connectionWillChange(queued.database);
      await queued.connect();
      await _until(() async => queued.uploadCalls > 0);
      expect(await queued.writerAvailable(), true);
      observed.watch(null);
      var observationCompletedWhileDisconnectPending = false;
      final observingQueued = quiescence
          .disconnectAndObserve(
            queued.database,
            profile,
            captureId: hold.captureId,
            gateGeneration: hold.generation,
            timeout: const Duration(seconds: 30),
          )
          .whenComplete(
            () => observationCompletedWhileDisconnectPending = true,
          );
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      // Here nothing holds the writer, so the barrier cannot be what blocks.
      expect(observed.disconnectCompleted, false);
      expect(observationCompletedWhileDisconnectPending, false);
      queued.releaseUploads();
      final queuedEvidence = await observingQueued;
      expect(
        queuedEvidence.disconnectCompleted && queuedEvidence.nativeApplyDrained,
        true,
      );
      expect(
        await queued.queue(),
        queueRows,
        reason: 'observation never clears or dequeues the source queue',
      );

      // 3. Mismatched or stale evidence is rejected.
      bool current(
        NativeSyncPauseEvidence e,
        PowerSyncDatabase d, {
        String? captureId,
        int? generation,
      }) => quiescence.isCurrent(
        e,
        d,
        profile,
        captureId: captureId ?? hold.captureId,
        gateGeneration: generation ?? hold.generation,
      );
      expect(current(evidence, f.database, captureId: 'capture-other'), false);
      expect(
        current(evidence, f.database, generation: hold.generation + 1),
        false,
      );
      expect(current(evidence, queued.database), false);
      expect(current(queuedEvidence, f.database), false);
      expect(current(queuedEvidence, queued.database), true);

      // 4. A reconnect changes the epoch; the earlier evidence is stale.
      quiescence.connectionWillChange(f.database);
      expect(current(evidence, f.database), false);
      await f.connect();
      expect(f.streamRequests, 2);
      expect(current(evidence, f.database), false);

      // 5. Timeout while the apply is paused yields no evidence.
      await f.stageCheckpoint([const SyntheticRow('ex-3', 'Synthetic three')]);
      await f.pauseNextApply();
      await f.waitUntilApplyPaused(unappliedIds: ['ex-3']);
      observed.watch('ex-3');
      await expectLater(
        quiescence.disconnectAndObserve(
          f.database,
          profile,
          captureId: hold.captureId,
          gateGeneration: hold.generation,
          timeout: const Duration(seconds: 1),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(observed.disconnectCompleted, false);
      await f.releaseApply();
      // The abandoned observation's disconnect still finishes, after the
      // apply, and nothing is lost.
      await _until(() async => observed.barrierCompleted);
      expect(observed.visibleWhenDisconnectCompleted, true);
      expect(await f.visible('ex-3'), true);

      // 6. A connection change during observation yields no evidence.
      quiescence.connectionWillChange(f.database);
      await f.connect();
      await f.stageCheckpoint([const SyntheticRow('ex-4', 'Synthetic four')]);
      await f.pauseNextApply();
      await f.waitUntilApplyPaused(unappliedIds: ['ex-4']);
      observed.watch('ex-4');
      final changing = quiescence.disconnectAndObserve(
        f.database,
        profile,
        captureId: hold.captureId,
        gateGeneration: hold.generation,
        timeout: const Duration(seconds: 30),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      quiescence.connectionWillChange(f.database);
      await f.releaseApply();
      await expectLater(
        changing,
        unsupported('native_sync_connection_changed'),
      );
      expect(await f.queue(), queueBefore);
      expect(await queued.queue(), queueRows);

      // Only this passing run authorizes the registration below.
      expect(
        registeredNativeSyncQualifications,
        contains(candidate.qualification),
      );
      expect(nativeSyncQualificationFor(profile), candidate.qualification);
      final production = NativeSyncQuiescence(
        qualification: nativeSyncQualificationFor(profile)!,
      );
      quiescence.connectionWillChange(f.database);
      await f.connect();
      final productionEvidence = await production.disconnectAndObserve(
        f.database,
        profile,
        captureId: hold.captureId,
        gateGeneration: hold.generation,
        timeout: const Duration(seconds: 30),
      );
      expect(
        production.isCurrent(
          productionEvidence,
          f.database,
          profile,
          captureId: hold.captureId,
          gateGeneration: hold.generation,
        ),
        true,
      );
      await gate.release(hold, decisionDigest: 'e' * 64);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('startup_preserves_through_native_files_and_gate', () async {
    final source = await Directory.systemTemp.createTemp('reps-capture-src');
    cleanup.add(() => source.delete(recursive: true));
    final locations = CaptureLocations(source);
    final draft = File('${source.path}/${DraftStore.fileName}')
      ..writeAsBytesSync([0xff, 0x7b]);
    final orphan = File('${draft.path}.tmp')..writeAsStringSync('{"name":"x');
    final draftStore = DraftStore(directory: () async => source);
    final finishedStore = FinishedSessionStore(directory: () async => source);
    final preservation = RawPreservation(locations.preparation, base: source);
    final journal = CaptureJournal(locations.journal, base: source);
    final gate = SourceWriteGate(stateDirectory: locations.gate);
    final now = DateTime(2026, 10, 10, 12);

    Future<(StartupOutcome, List<String>)> start() async {
      final calls = <String>[];
      final outcome = await runCaptureAwareStartup(
        journal: journal,
        probeGate: () => probeSourceGate(gate, base: source),
        source: source,
        preservation: preservation,
        files: [
          await draftStartupFile(draftStore, (_) async {
            calls.add('load:draft');
            await draftStore.load();
          }),
          await finishedStartupFile(finishedStore, (_) async {
            calls.add('load:finished');
          }),
        ],
        steps: _RecordingSteps(calls),
        now: now,
      );
      return (outcome, calls);
    }

    expect(await probeSourceGate(gate, base: source), 'open');

    // A held journal written through the native primitive holds startup.
    await journal.write(
      CaptureJournalState(
        captureId: '3f1c2a4e-8b7d-4c6a-9e2f-1a2b3c4d5e6f',
        installation: const {'platform': 'linux'},
        producerVersion: '0.18.1+37',
        runtimeVersions: const {},
        storeVersions: const {},
        mode: CaptureMode.rehearsal,
        stage: CaptureStage.held,
        gateGeneration: 1,
        priorSyncIntent: PriorSyncIntent.unknown,
        inventory: const [],
        files: const {},
        manifestSha256: null,
      ),
    );
    var (outcome, calls) = await start();
    expect(
      (outcome as CaptureRecoveryRequired).recovery.code,
      'capture_active',
    );
    expect(calls, isEmpty);
    expect(draft.readAsBytesSync(), [0xff, 0x7b]);
    // Held startup still copied every present version natively.
    expect(
      (await readRawFile(
        preservation.blobFile(sha256.convert([0xff, 0x7b]).toString()),
      )).bytes,
      [0xff, 0x7b],
    );
    await locations.journal.delete();

    // A capture recorded only in the native gate also holds startup.
    final preparation = await gate.closeAdmission('native-startup-probe');
    expect(await probeSourceGate(gate, base: source), 'mismatch');
    (outcome, calls) = await start();
    expect(
      (outcome as CaptureRecoveryRequired).recovery.code,
      'gate_mismatch',
    );
    expect(calls, isEmpty);
    await gate.release(
      SourceHold(preparation.captureId, preparation.generation),
      decisionDigest: 'f' * 64,
    );
    expect(await probeSourceGate(gate, base: source), 'open');

    // Ordinary startup: the malformed draft is durably preserved before its
    // loader deletes it; the orphan stays in place, preserved separately.
    (outcome, calls) = await start();
    expect(outcome, isA<StartupAllowed>());
    expect(calls, [
      'settings',
      'openDatabase',
      'identity',
      'migrations',
      'sessions',
      'load:draft',
      'load:finished',
      'connect',
    ]);
    expect(draft.existsSync(), isFalse);
    expect(orphan.existsSync(), isTrue);
    final inventory = (outcome as StartupAllowed).inventory;
    expect(inventory.complete, isTrue);
    expect(
      inventory.entries.where((e) => e.preserved).map((e) => e.reason).toSet(),
      {'malformed', 'orphan_tmp'},
    );
    // No temporary file of the durable primitive is left behind.
    final leftovers = locations.preparation
        .listSync(recursive: true)
        .where((e) => e.path.contains('.capture-tmp-'));
    expect(leftovers, isEmpty);

    // A failed directory flush during preservation holds this
    // capture-capable startup: zero ordinary steps, source bytes intact.
    draft.writeAsBytesSync([0xfe, 0x7b]);
    final faultCalls = <String>[];
    final faulted = await runCaptureAwareStartup(
      journal: journal,
      probeGate: () async {
        final answer = await probeSourceGate(gate, base: source);
        await const CaptureFiles().injectFaultForTesting('dir_sync');
        return answer;
      },
      source: source,
      preservation: preservation,
      files: [
        await draftStartupFile(draftStore, (_) async {
          faultCalls.add('load:draft');
          await draftStore.load();
        }),
        await finishedStartupFile(finishedStore, (_) async {
          faultCalls.add('load:finished');
        }),
      ],
      steps: _RecordingSteps(faultCalls),
      now: now,
    );
    expect(
      (faulted as CaptureRecoveryRequired).recovery.code,
      'preservation_failed',
    );
    expect(faultCalls, isEmpty);
    expect(draft.readAsBytesSync(), [0xfe, 0x7b]);
  });

  test('ensure_directory_flushes_chain_and_fails_closed', () async {
    const files = CaptureFiles();
    for (final root in await _scratchRoots()) {
      cleanup.add(() => root.delete(recursive: true));
      final leaf = Directory('${root.path}/capture/preparation/blobs');

      await files.ensureDirectory(leaf, base: root);
      expect(leaf.existsSync(), isTrue);
      // Created private (0700) at every level.
      for (final d in [leaf, leaf.parent, leaf.parent.parent]) {
        expect(d.statSync().mode & 0x1ff, 0x1c0, reason: d.path);
      }
      // Idempotent on an existing chain.
      await files.ensureDirectory(leaf, base: root);

      // A failed directory flush is never success, for a new component and
      // for an existing chain alike (existing components are re-flushed, so
      // one left unflushed by an earlier call cannot pass silently).
      await files.injectFaultForTesting('dir_sync');
      await expectLater(
        files.ensureDirectory(Directory('${root.path}/fresh/one'), base: root),
        gateCode('io_error'),
      );
      await files.injectFaultForTesting('dir_sync');
      await expectLater(
        files.ensureDirectory(leaf, base: root),
        gateCode('io_error'),
      );
      // The retry after a failure flushes again and succeeds.
      await files.ensureDirectory(Directory('${root.path}/fresh/one'), base: root);

      // Outside the base, a `..` segment, a file or a link in the chain.
      await expectLater(
        files.ensureDirectory(
          Directory('${root.parent.path}/elsewhere'),
          base: root,
        ),
        gateCode('invalid_argument'),
      );
      await expectLater(
        files.ensureDirectory(Directory('${root.path}/a/../b'), base: root),
        gateCode('invalid_argument'),
      );
      File('${root.path}/plain').writeAsStringSync('x');
      await expectLater(
        files.ensureDirectory(Directory('${root.path}/plain/sub'), base: root),
        gateCode('not_a_directory'),
      );
      Link('${root.path}/link').createSync(leaf.path);
      await expectLater(
        files.ensureDirectory(Directory('${root.path}/link/sub'), base: root),
        gateCode('not_a_directory'),
      );
      expect(Directory('${leaf.path}/sub').existsSync(), isFalse);
      // A base that does not exist is refused.
      await expectLater(
        files.ensureDirectory(
          Directory('${root.path}/nobase/x'),
          base: Directory('${root.path}/nobase'),
        ),
        gateCode('invalid_argument'),
      );
    }
  });

  test('coordinator_publishes_and_recovers_through_native_primitives', () async {
    // The production path end to end: real gate, durable files, no-replace
    // publication, statvfs, the registered native sync adapter through
    // CaptureTransport.forProfile, and the app version from PackageInfo.
    final source = await Directory.systemTemp.createTemp('reps-capture-coord');
    cleanup.add(() => source.delete(recursive: true));
    SharedPreferences.setMockInitialValues({'unit': 'kg'});
    TransportAdmission.instance.resetForTesting();
    final locations = CaptureLocations(source);
    final gate = SourceWriteGate(stateDirectory: locations.gate);
    const files = CaptureFiles();
    await files.ensureDirectory(locations.gate, base: source);
    appSourceGate = gate;
    cleanup.add(() async => appSourceGate = null);
    final database = PowerSyncDatabase(
        schema: schema, path: p.join(source.path, 'workout-tracker.db'));
    await database.initialize();
    cleanup.add(database.close);
    await database.execute(
      'INSERT INTO sessions (id, date, split_label, created_at) '
      'VALUES (?, ?, ?, ?)',
      ['d1000000-0000-4000-8000-000000000001', '2026-10-01', 'Custom',
        '2026-10-01T10:00:00.000Z'],
    );
    final manager = SessionManager(finishedStore: _NoFinished());
    cleanup.add(() async => manager.dispose());
    final hooks = SessionCaptureHooks(
      manager: manager,
      preservation: RawPreservation(locations.preparation, base: source),
    );
    CaptureCoordinator coordinator() => CaptureCoordinator(
          locations: locations,
          gate: gate,
          sources: CaptureSourceBindings(
            database: database,
            hooks: hooks,
            transportFor: (profile) => CaptureTransport.forProfile(
              database: database,
              profile: profile,
              reconnect: () async {},
            ),
          ),
        );

    // statvfs answers for the private capture directory.
    final available = await files.availableBytes(locations.gate);
    final df = await Process.run('stat', ['-f', '-c', '%a %S', source.path]);
    final parts = (df.stdout as String).trim().split(' ');
    final expected = int.parse(parts[0]) * int.parse(parts[1]);
    expect((available - expected).abs(), lessThan(64 << 20));
    await expectLater(
        files.availableBytes(Directory(p.join(source.path, 'missing'))),
        gateCode('invalid_argument'));

    final certified = await coordinator().capture(mode: CaptureMode.localHold);
    expect(certified.directory.path,
        p.join(locations.captures.path, certified.captureId));
    expect((await verifyCaptureDirectory(certified.directory)).manifestSha256,
        certified.manifestSha256);
    expect(
        Directory(p.join(locations.staging.path, certified.captureId))
            .existsSync(),
        isFalse);
    final journal =
        await CaptureJournal(locations.journal, base: source).read();
    expect(journal!.stage, CaptureStage.localHold);
    expect(await gate.holdStatus(
            SourceHold(certified.captureId, journal.gateGeneration!)),
        'held');
    await expectLater(gate.run('test.write', (_) async {}),
        gateCode('admission_closed'));

    // Another coordinator (as after a restart) recovers the same artifact
    // and keeps the hold.
    final recovered = await coordinator().recover();
    expect(recovered.stage, CaptureStage.localHold);
    expect(recovered.capture!.manifestSha256, certified.manifestSha256);
    expect(await probeSourceGate(gate, base: source), 'mismatch');

    await coordinator().resumeOriginal(
        captureId: certified.captureId, decisionDigest: 'a' * 64);
    expect(await probeSourceGate(gate, base: source), 'open');
    expect(
        (await CaptureJournal(locations.journal, base: source).read())!.stage,
        CaptureStage.resumed);
    await gate.run('test.write', (_) async {});
    expect(TransportAdmission.instance.isOpen, isTrue);
  });
}

class _RecordingSteps implements OrdinaryStartupSteps {
  _RecordingSteps(this.calls);

  final List<String> calls;

  @override
  Future<void> loadSettings() async => calls.add('settings');

  @override
  Future<void> openDatabase() async => calls.add('openDatabase');

  @override
  Future<void> initIdentity() async => calls.add('identity');

  @override
  Future<void> runBootMigrations() async => calls.add('migrations');

  @override
  Future<void> prepareSessions() async => calls.add('sessions');

  @override
  Future<void> connect() async => calls.add('connect');
}

Future<void> _until(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _NoFinished extends FinishedSessionStore {
  @override
  Future<FinishedSession?> load() async => null;
  @override
  Future<void> save(FinishedSession f) async {}
  @override
  Future<void> clear() async {}
}
