// A second engine context of the same process: a background isolate with
// its own binary messenger driving the SAME native gate, as the app's
// background notification engine does.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';

/// A background isolate that talks to the plugin through its own binary
/// messenger, as a second engine context in the same process would.
class BackgroundGate {
  BackgroundGate._(this._isolate, this._commands, this._results);

  final Isolate _isolate;
  final SendPort _commands;
  final StreamIterator<Object?> _results;

  static Future<BackgroundGate> spawn(Directory stateDir) async {
    final results = ReceivePort();
    final iterator = StreamIterator<Object?>(results);
    final isolate = await Isolate.spawn(_main, (
      RootIsolateToken.instance!,
      stateDir.path,
      results.sendPort,
    ));
    await iterator.moveNext();
    return BackgroundGate._(isolate, iterator.current as SendPort, iterator);
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
