// Host reference model of the native `reps/capture` admission protocol.
//
// Host tests have no native plugin. This handler answers the gate channel the
// way the native side does (ticket table with parent reuse, closed admission
// while a capture prepares or holds, drain to `held`), so the Dart writers'
// use of tickets can be pinned. It proves nothing about native locking or
// other engines; that is qualified by integration_test/capture_platform_test.dart.
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
        if (_capture != args['captureId']) return {'code': 'mismatch'};
        if (tickets.isNotEmpty) return {'code': 'pending'};
        _state = 'held';
        return {'code': 'held'};
      case 'verifyHold':
        if (_capture != args['captureId']) return {'code': 'mismatch'};
        return {'code': _state};
      case 'release':
        _state = 'open';
        _capture = '';
        return {'code': 'ok'};
    }
    return {'code': 'unsupported'};
  }
}
