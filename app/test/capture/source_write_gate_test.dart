// Host contract tests for the source-write gate facade.
//
// Host tests have no native plugin. Except for `missing_plugin_fails_before_write`
// (which uses the real, absent channel), they drive the facade against a
// small reference model of the native `reps/capture` protocol. They pin how
// the Dart side admits, nests, drains, releases and reports failures; they
// prove nothing about native locking or durability. The same scenarios run
// against the real plugin in integration_test/capture_platform_test.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reps_capture_platform/reps_capture_platform.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';

/// Durable state shared by every modelled process: per state directory, the
/// recorded gate state. Tickets of all live processes stand in for the shared
/// ticket lock.
class _Machine {
  final records = <String, Map<String, Object?>>{};
  final processes = <_Process>[];

  _Process spawn(String name) {
    final p = _Process(this, MethodChannel('reps/capture/test/$name'));
    processes.add(p);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(p.channel, p.handle);
    return p;
  }

  void detachAll() {
    for (final p in processes) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(p.channel, null);
    }
  }
}

class _Process {
  _Process(this.machine, this.channel);

  final _Machine machine;
  final MethodChannel channel;
  final tickets = <String, int>{};
  final liveHolds = <String>{};
  var _counter = 0;
  String? fileResultCode;

  RepsCapturePlatform get platform => RepsCapturePlatform(channel: channel);

  /// Process loss: in-memory tickets and live holds vanish, the durable
  /// record stays.
  void kill() {
    tickets.clear();
    liveHolds.clear();
    machine.processes.remove(this);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  Future<Object?> handle(MethodCall call) async {
    final args = Map<String, Object?>.from(call.arguments as Map);
    final dir = args['dir'] as String?;
    final record = dir == null
        ? null
        : machine.records.putIfAbsent(
            dir,
            () => {'state': 'open', 'generation': 0, 'capture': ''},
          );
    Map<String, Object?> ticket(int generation) {
      final id = '${identityHashCode(this)}-${++_counter}';
      tickets[id] = 1;
      return {'code': 'ok', 'ticket': id, 'generation': generation};
    }

    switch (call.method) {
      case 'admit':
        final parent = args['parent'] as String?;
        if (parent != null) {
          if (!tickets.containsKey(parent)) return {'code': 'parent_completed'};
          tickets[parent] = tickets[parent]! + 1;
          return {
            'code': 'ok',
            'ticket': parent,
            'generation': record!['generation'],
          };
        }
        if (record!['state'] != 'open') return {'code': 'admission_closed'};
        return ticket(record['generation'] as int);
      case 'complete':
        final id = args['ticket'] as String;
        final refs = tickets[id];
        if (refs == null) return {'code': 'unknown_ticket'};
        if (refs == 1) {
          tickets.remove(id);
        } else {
          tickets[id] = refs - 1;
        }
        return {'code': 'ok'};
      case 'prepare':
        if (record!['state'] != 'open') return {'code': 'capture_in_progress'};
        record
          ..['state'] = 'preparing'
          ..['generation'] = (record['generation'] as int) + 1
          ..['capture'] = args['captureId'];
        return ticket(record['generation'] as int);
      case 'drain':
        if (record!['capture'] != args['captureId'] ||
            record['generation'] != args['generation'] ||
            record['state'] == 'open') {
          return {'code': 'mismatch'};
        }
        final busy = machine.processes.any((p) => p.tickets.isNotEmpty);
        if (busy) return {'code': 'pending'};
        record['state'] = 'held';
        liveHolds.add(dir!);
        return {'code': 'held'};
      case 'release':
        if (record!['capture'] != args['captureId'] ||
            record['generation'] != args['generation'] ||
            record['state'] == 'open') {
          return {'code': 'mismatch'};
        }
        record
          ..['state'] = 'open'
          ..['capture'] = ''
          ..['decision'] = args['decisionDigest'];
        liveHolds.remove(dir);
        return {'code': 'ok'};
      case 'verifyHold':
        if (record!['capture'] != args['captureId'] ||
            record['generation'] != args['generation']) {
          return {'code': 'mismatch'};
        }
        if (record['state'] != 'held') return {'code': record['state']};
        return {'code': liveHolds.contains(dir) ? 'held' : 'recorded'};
      case 'durableReplace':
      case 'publishNoReplace':
        return {'code': fileResultCode ?? 'ok'};
    }
    return {'code': 'unsupported'};
  }
}

Matcher gateCode(String code) =>
    throwsA(isA<SourceGateException>().having((e) => e.code, 'code', code));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Machine machine;
  late Directory stateDir;

  setUp(() async {
    machine = _Machine();
    stateDir = await Directory.systemTemp.createTemp('reps-gate-host');
  });

  tearDown(() async {
    machine.detachAll();
    if (await stateDir.exists()) await stateDir.delete(recursive: true);
  });

  test('nested_ticket_lives_through_last_continuation', () async {
    final process = machine.spawn('fg');
    final gate = SourceWriteGate(
      stateDirectory: stateDir,
      platform: process.platform,
    );
    final nestedSave = Completer<void>();
    var nestedSaved = false;
    late Future<void> nested;

    // The parent operation returns while its nested file continuation still
    // runs under the parent's ticket.
    await gate.run('finish', (ticket) async {
      nested = gate.run('recordFinished', (inner) async {
        expect(inner, ticket);
        await nestedSave.future;
        nestedSaved = true;
      }, parent: ticket);
    });
    expect(
      process.tickets,
      isNotEmpty,
      reason: 'the ticket count stays nonzero after the parent returned',
    );

    final preparation = await gate.closeAdmission('capture-1');
    var drainCompletedBeforeNestedSave = false;
    final draining = gate
        .drain(preparation, timeout: const Duration(seconds: 5))
        .whenComplete(() {
          if (!nestedSaved) drainCompletedBeforeNestedSave = true;
        });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(drainCompletedBeforeNestedSave, false);

    nestedSave.complete();
    await nested;
    final hold = await draining;
    expect(drainCompletedBeforeNestedSave, false);
    expect(hold.captureId, 'capture-1');
    expect(hold.generation, preparation.generation);
    expect(process.tickets, isEmpty);

    // A parent ticket that has completed cannot be reused to slip past the
    // closed admission.
    late SourceTicket finished;
    await gate.release(hold, decisionDigest: 'a' * 64);
    await gate.run('edit', (t) async => finished = t);
    await expectLater(
      gate.run('late', (_) async {}, parent: finished),
      gateCode('parent_completed'),
    );
  });

  test('two_engines_hold_excludes_background_and_process', () async {
    final foreground = machine.spawn('fg');
    final otherProcess = machine.spawn('other');
    final gate = SourceWriteGate(
      stateDirectory: stateDir,
      platform: foreground.platform,
    );
    // Another engine's Dart side keeps no state of its own: it only asks the
    // native gate.
    final background = SourceWriteGate(
      stateDirectory: stateDir,
      platform: foreground.platform,
    );
    final processGate = SourceWriteGate(
      stateDirectory: stateDir,
      platform: otherProcess.platform,
    );

    // Work admitted in the other process before preparation delays the hold.
    final otherWork = Completer<void>();
    final admitted = processGate.run('notification', (_) => otherWork.future);
    await Future<void>.delayed(Duration.zero);

    final preparation = await gate.closeAdmission('capture-1');
    var held = false;
    final holding = gate
        .drain(preparation, timeout: const Duration(seconds: 5))
        .whenComplete(() => held = true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(held, false);
    otherWork.complete();
    await admitted;
    final hold = await holding;

    var writesWhileHeld = 0;
    for (final g in [gate, background, processGate]) {
      await expectLater(
        g.run('write', (_) async => writesWhileHeld++),
        gateCode('admission_closed'),
      );
    }
    expect(writesWhileHeld, 0);
    expect(await gate.isHeld(hold), true);
    await expectLater(
      gate.closeAdmission('capture-2'),
      gateCode('capture_in_progress'),
    );
  });

  test('missing_plugin_fails_before_write', () async {
    // No handler is registered for the real channel on the host.
    final gate = SourceWriteGate(stateDirectory: stateDir);
    var successOnMissingPlugin = false;
    var bodyRan = false;
    try {
      await gate.run('write', (_) async => bodyRan = true);
      successOnMissingPlugin = true;
    } on SourceGateException catch (e) {
      expect(e.code, 'platform_unavailable');
    }
    expect(successOnMissingPlugin, false);
    expect(bodyRan, false);
    await expectLater(
      gate.closeAdmission('capture-1'),
      gateCode('platform_unavailable'),
    );

    final destination = File('${stateDir.path}/journal.json');
    await destination.writeAsBytes([1, 2, 3], flush: true);
    await expectLater(
      const CaptureFiles().durableReplace(destination, [9]),
      gateCode('platform_unavailable'),
    );
    expect(await destination.readAsBytes(), [1, 2, 3]);
  });

  test('killed_owner_preserves_durable_hold', () async {
    final owner = machine.spawn('owner');
    final ownerGate = SourceWriteGate(
      stateDirectory: stateDir,
      platform: owner.platform,
    );
    final preparation = await ownerGate.closeAdmission('capture-1');
    final hold = await ownerGate.drain(
      preparation,
      timeout: const Duration(seconds: 1),
    );
    owner.kill();

    final restarted = machine.spawn('restarted');
    final gate = SourceWriteGate(
      stateDirectory: stateDir,
      platform: restarted.platform,
    );
    var writes = 0;
    await expectLater(
      gate.run('boot-backfill', (_) async => writes++),
      gateCode('admission_closed'),
    );
    expect(writes, 0);
    // The record survives, but no live process owns the hold any more.
    expect(await gate.isHeld(hold), false);
    expect(await gate.holdStatus(hold), 'recorded');
    await expectLater(
      gate.closeAdmission('capture-2'),
      gateCode('capture_in_progress'),
    );

    // Only an explicit decision for exactly that capture reopens admission.
    await expectLater(
      gate.release(const SourceHold('capture-1', 99), decisionDigest: 'b' * 64),
      gateCode('mismatch'),
    );
    await gate.release(hold, decisionDigest: 'b' * 64);
    await gate.run('boot-backfill', (_) async => writes++);
    expect(writes, 1);
  });

  test('destination_conflict_never_replaces', () async {
    final process = machine.spawn('fg')..fileResultCode = 'destination_exists';
    final files = CaptureFiles(platform: process.platform);
    final staging = await Directory('${stateDir.path}/staging').create();
    final existing = await Directory('${stateDir.path}/final').create();
    final marker = File('${existing.path}/manifest.json');
    final originalBytes = [1, 2, 3];
    await marker.writeAsBytes(originalBytes, flush: true);

    await expectLater(
      files.publishNoReplace(staging, existing),
      gateCode('destination_exists'),
    );
    final bytesAtExistingDestination = await marker.readAsBytes();
    expect(bytesAtExistingDestination, originalBytes);
    expect(await staging.exists(), true);
  });

  test('flush_or_directory_sync_failure_blocks', () async {
    final process = machine.spawn('fg');
    final files = CaptureFiles(platform: process.platform);
    final staging = await Directory('${stateDir.path}/staging').create();
    for (final code in [
      'io_error',
      'unsupported',
      'cross_device',
      'surprise',
    ]) {
      process.fileResultCode = code;
      var reportedSuccess = false;
      try {
        await files.durableReplace(File('${stateDir.path}/j.json'), [1]);
        reportedSuccess = true;
      } on SourceGateException catch (e) {
        expect(e.code, code);
      }
      try {
        await files.publishNoReplace(
          staging,
          Directory('${stateDir.path}/final'),
        );
        reportedSuccess = true;
      } on SourceGateException catch (e) {
        expect(e.code, code);
      }
      expect(reportedSuccess, false, reason: code);
    }
  });
}
