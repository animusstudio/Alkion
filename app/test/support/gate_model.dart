// Host reference model of the native `reps/capture` admission protocol.
//
// Host tests have no native plugin. This handler answers the gate channel the
// way the native side does (ticket table with parent reuse, closed admission
// while a capture prepares or holds, drain to `held`), so the Dart writers'
// use of tickets can be pinned. It proves nothing about native locking or
// other engines; that is qualified by integration_test/capture_platform_test.dart.
//
// [GateModel.simulateRestart] models a process restart: the durable record
// (state, capture, generation) survives, this process's tickets and live
// hold do not, so a held capture answers `recorded` until a drain takes the
// hold again, as the native gate does.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reps_capture_platform/reps_capture_platform.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';

class GateModel {
  GateModel(String name)
      : channel = MethodChannel('reps/capture/test/gate/$name') {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
  }

  final MethodChannel channel;

  /// Live tickets and their reference counts (nested continuations).
  final tickets = <String, int>{};

  /// Operations admitted as new tickets, in order.
  final admitted = <String>[];

  /// Operations refused because admission was closed, in order.
  final refused = <String>[];

  /// Every gate method called, in order (`prepare`, `drain`, `release`, ...).
  final calls = <String>[];

  /// Called with `gate:<method>` for every call, before it is answered.
  void Function(String event)? log;

  /// When set, a drain that would take the hold answers this code instead
  /// (for example `recovery_required` for work left by a dead process) until
  /// [acknowledgeInterrupted] clears it.
  String? drainCode;

  /// Decision digests of releases and acknowledgements, in order.
  final decisions = <String>[];

  /// Admissions for these operations are decided when they arrive but
  /// answered only after [releaseHeld].
  final holdAdmits = <String>{};
  final _held = <Completer<void>>[];

  var _state = 'open';
  var _generation = 0;
  var _capture = '';
  var _counter = 0;

  /// Whether this (model) process owns the live hold.
  var _live = false;

  bool get idle => tickets.isEmpty;
  int get generation => _generation;
  String get capture => _capture;

  /// A process restart: tickets and the live hold are gone, the durable
  /// record stays.
  void simulateRestart() {
    tickets.clear();
    _live = false;
  }
  int get heldCount => _held.length;
  String get state => _state;

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
    calls.add(call.method);
    log?.call('gate:${call.method}');
    bool matches() =>
        _state != 'open' &&
        _capture == args['captureId'] &&
        _generation == args['generation'];
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
          refused.add(operation);
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
        if (!matches()) return {'code': 'mismatch'};
        if (_live) return {'code': 'held'};
        if (tickets.isNotEmpty) return {'code': 'pending'};
        final code = drainCode;
        if (code != null) return {'code': code};
        _state = 'held';
        _live = true;
        return {'code': 'held'};
      case 'verifyHold':
        if (_state == 'open') return {'code': 'open'};
        if (!matches()) return {'code': 'mismatch'};
        if (_state == 'preparing') return {'code': 'preparing'};
        return {'code': _live ? 'held' : 'recorded'};
      case 'release':
        if (!matches()) return {'code': 'mismatch'};
        decisions.add(args['decisionDigest'] as String);
        _state = 'open';
        _capture = '';
        _live = false;
        return {'code': 'ok'};
      case 'acknowledgeInterrupted':
        decisions.add(args['decisionDigest'] as String);
        final interrupted = drainCode == null ? 0 : 1;
        drainCode = null;
        return {'code': 'ok', 'interrupted': interrupted};
    }
    return {'code': 'unsupported'};
  }
}
