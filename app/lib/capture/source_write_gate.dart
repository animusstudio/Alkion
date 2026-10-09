import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:reps_capture_platform/reps_capture_platform.dart';

/// A refusal or failure of the native source-write gate or file primitives.
/// [code] is the stable native code (for example `admission_closed`,
/// `capture_in_progress`, `mismatch`, `destination_exists`, `io_error`,
/// `unsupported`) or `platform_unavailable` when no native implementation
/// answers. It never carries personal data.
@immutable
class SourceGateException implements Exception {
  const SourceGateException(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() => detail == null
      ? 'SourceGateException($code)'
      : 'SourceGateException($code: $detail)';
}

/// Admission of one logical source mutation. It stays admitted, and the gate
/// cannot be held, until the operation and every nested continuation that
/// runs under it as `parent` have finished.
@immutable
class SourceTicket {
  const SourceTicket(this.id, this.generation);

  final String id;

  /// Gate generation current when the ticket was admitted.
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is SourceTicket && other.id == id && other.generation == generation;

  @override
  int get hashCode => Object.hash(id, generation);

  @override
  String toString() => 'SourceTicket($id, $generation)';
}

/// Admission is closed for [captureId] at [generation]. The coordinator's own
/// preparation work (committing editor input, the final draft flush) runs
/// under [ticket], which [SourceWriteGate.drain] completes.
@immutable
class SourcePreparation {
  const SourcePreparation(this.captureId, this.generation, this.ticket);

  final String captureId;
  final int generation;
  final SourceTicket ticket;
}

/// Exclusive source exclusion for [captureId] at [generation], durably
/// recorded until an explicit release.
@immutable
class SourceHold {
  const SourceHold(this.captureId, this.generation);

  final String captureId;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is SourceHold &&
      other.captureId == captureId &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(captureId, generation);
}

/// Facade over the native source-write gate.
///
/// All admission decisions are native: the platform keeps a process-wide
/// ticket table behind a process mutex, takes an interprocess file lock in
/// [stateDirectory] for every admission decision, and checks the durable
/// hold record under that same lock. This class keeps no admission state of
/// its own, so any engine or isolate (each with its own instance) sees the
/// same gate.
class SourceWriteGate {
  SourceWriteGate({
    required this.stateDirectory,
    RepsCapturePlatform platform = const RepsCapturePlatform(),
  }) : _platform = platform;

  /// Private directory holding the gate's lock and durable state files.
  final Directory stateDirectory;
  final RepsCapturePlatform _platform;

  static const _pollStart = Duration(milliseconds: 5);
  static const _pollMax = Duration(milliseconds: 50);

  /// Runs [body] as one admitted logical operation. With [parent], [body]
  /// is a nested continuation of that still-running operation and reuses its
  /// ticket, so it is admitted even while admission is closed; a parent whose
  /// operation already finished is refused (`parent_completed`).
  ///
  /// Throws [SourceGateException] before [body] runs if admission is
  /// refused or the native gate is unavailable.
  Future<T> run<T>(
    String operation,
    Future<T> Function(SourceTicket ticket) body, {
    SourceTicket? parent,
  }) async {
    final admitted = await _call('admit', {
      'operation': operation,
      if (parent != null) 'parent': parent.id,
    });
    final ticket = SourceTicket(
      admitted['ticket']! as String,
      admitted['generation']! as int,
    );
    try {
      return await body(ticket);
    } finally {
      await _call('complete', {'ticket': ticket.id});
    }
  }

  /// Durably records that capture [captureId] is preparing and closes
  /// admission everywhere (`capture_in_progress` if another capture is
  /// already recorded). Already-admitted operations may still finish.
  Future<SourcePreparation> closeAdmission(String captureId) async {
    final r = await _call('prepare', {'captureId': captureId});
    final generation = r['generation']! as int;
    return SourcePreparation(
      captureId,
      generation,
      SourceTicket(r['ticket']! as String, generation),
    );
  }

  /// Completes [preparation]'s own ticket, then waits until every admitted
  /// ticket in every process has finished and takes the exclusive hold.
  /// Throws `drain_timeout` after [timeout]; admission then stays closed.
  Future<SourceHold> drain(
    SourcePreparation preparation, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    final completed = await _invoke('complete', {
      'ticket': preparation.ticket.id,
    });
    final code = completed['code'];
    // `unknown_ticket`: an earlier drain of this preparation completed it.
    if (code != 'ok' && code != 'unknown_ticket') {
      throw SourceGateException(code! as String);
    }
    var delay = _pollStart;
    while (true) {
      final r = await _invoke('drain', {
        'captureId': preparation.captureId,
        'generation': preparation.generation,
      });
      switch (r['code']) {
        case 'held':
          return SourceHold(preparation.captureId, preparation.generation);
        case 'pending':
          if (DateTime.now().isAfter(deadline)) {
            throw const SourceGateException('drain_timeout');
          }
          await Future<void>.delayed(delay);
          delay = delay * 2 > _pollMax ? _pollMax : delay * 2;
        default:
          throw SourceGateException(r['code']! as String);
      }
    }
  }

  /// Releases [hold] (or a still-preparing capture with the same id and
  /// generation) by an explicit coordinator decision, recorded durably.
  Future<void> release(SourceHold hold, {required String decisionDigest}) =>
      _call('release', {
        'captureId': hold.captureId,
        'generation': hold.generation,
        'decisionDigest': decisionDigest,
      });

  /// The native view of [hold]: `held` (live in this process), `recorded`
  /// (durably held but no live owner, e.g. after the owner died),
  /// `preparing`, `open` or `mismatch`.
  Future<String> holdStatus(SourceHold hold) async {
    final r = await _invoke('verifyHold', {
      'captureId': hold.captureId,
      'generation': hold.generation,
    });
    return r['code']! as String;
  }

  /// Whether [hold] is live and owned by this process.
  Future<bool> isHeld(SourceHold hold) async =>
      await holdStatus(hold) == 'held';

  Future<Map<String, Object?>> _call(
    String method,
    Map<String, Object?> arguments,
  ) async {
    final r = await _invoke(method, arguments);
    if (r['code'] != 'ok') throw SourceGateException(r['code']! as String);
    return r;
  }

  Future<Map<String, Object?>> _invoke(
    String method,
    Map<String, Object?> arguments,
  ) => _invokeNative(_platform, method, {
    'dir': stateDirectory.path,
    ...arguments,
  });
}

/// Durable file primitives for capture state and publication. Each call
/// returns only after the bytes and the containing directories were flushed
/// by the native side; any failure throws and is never reported as success.
class CaptureFiles {
  const CaptureFiles({
    RepsCapturePlatform platform = const RepsCapturePlatform(),
  }) : _platform = platform;

  final RepsCapturePlatform _platform;

  /// Replaces [destination] with [bytes]: a new temporary file in the same
  /// directory is written and flushed, renamed over [destination], and the
  /// directory is flushed.
  Future<void> durableReplace(File destination, List<int> bytes) => _ok(
    'durableReplace',
    {'path': destination.path, 'bytes': Uint8List.fromList(bytes)},
  );

  /// Flushes every file and directory under [staging], then renames it to
  /// [finalDirectory] atomically WITHOUT replacing anything already there
  /// (`destination_exists`), and flushes the parent directories. A platform
  /// or filesystem that cannot refuse replacement atomically answers
  /// `unsupported`.
  Future<void> publishNoReplace(Directory staging, Directory finalDirectory) =>
      _ok('publishNoReplace', {
        'staging': staging.path,
        'final': finalDirectory.path,
      });

  /// Debug builds only: makes the next native file (`file_sync`) or
  /// directory (`dir_sync`) flush fail, to prove failures propagate.
  @visibleForTesting
  Future<void> injectFaultForTesting(String fault) =>
      _ok('injectFault', {'fault': fault});

  Future<void> _ok(String method, Map<String, Object?> arguments) async {
    final r = await _invokeNative(_platform, method, arguments);
    if (r['code'] != 'ok') throw SourceGateException(r['code']! as String);
  }
}

Future<Map<String, Object?>> _invokeNative(
  RepsCapturePlatform platform,
  String method,
  Map<String, Object?> arguments,
) async {
  try {
    return await platform.invoke(method, arguments);
  } on MissingPluginException {
    throw const SourceGateException('platform_unavailable');
  } on PlatformException catch (e) {
    throw SourceGateException('platform_error', e.code);
  }
}
