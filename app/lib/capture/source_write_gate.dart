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

  /// The stand-in ticket of an operation that ran without a gate: on a
  /// platform without the native plugin (not capture-capable), or where no
  /// app gate is installed (host tests). A gate whose plugin answers never
  /// reuses it as a parent: a continuation passing it is admitted, or
  /// refused, like a new operation.
  static const ungated = SourceTicket('', 0);

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

  /// Set once the native side answered `platform_unavailable`: this build
  /// has no capture plugin, so no capture can ever close admission here.
  bool _platformUnavailable = false;

  static const _pollStart = Duration(milliseconds: 5);
  static const _pollMax = Duration(milliseconds: 50);

  /// Runs [body] as one admitted logical operation. With [parent], [body]
  /// is a nested continuation of that still-running operation and reuses its
  /// ticket, so it is admitted even while admission is closed; a parent whose
  /// operation already finished is refused (`parent_completed`).
  ///
  /// Where the native plugin is present, throws [SourceGateException] before
  /// [body] runs if admission is refused (`admission_closed` while a capture
  /// prepares or holds the source) or the gate fails. Without the plugin
  /// (`platform_unavailable`: a build that is not capture-capable, where no
  /// capture can close admission) [body] runs ungated with
  /// [SourceTicket.ungated], so ordinary writes keep working.
  Future<T> run<T>(
    String operation,
    Future<T> Function(SourceTicket ticket) body, {
    SourceTicket? parent,
  }) async {
    if (_platformUnavailable) return body(parent ?? SourceTicket.ungated);
    final Map<String, Object?> admitted;
    try {
      admitted = await _call('admit', {
        'operation': operation,
        // An ungated parent ran before any gate existed: nothing to reuse,
        // so this is an ordinary admission (refused while closed).
        if (parent != null && parent != SourceTicket.ungated)
          'parent': parent.id,
      });
    } on SourceGateException catch (e) {
      if (e.code != 'platform_unavailable') rethrow;
      _platformUnavailable = true;
      return body(parent ?? SourceTicket.ungated);
    }
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
  /// Throws `recovery_required` when a process died while it had admitted
  /// work in flight: its half-finished work was never drained, so no hold is
  /// taken until [acknowledgeInterruptedWork] records a recovery decision.
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

  /// Completes [preparation]'s own ticket without taking the hold, for a
  /// capture abandoned before (or instead of) its drain. A ticket an
  /// earlier drain already completed is not an error.
  Future<void> completePreparation(SourcePreparation preparation) async {
    final r = await _invoke('complete', {'ticket': preparation.ticket.id});
    final code = r['code'];
    if (code != 'ok' && code != 'unknown_ticket') {
      throw SourceGateException(code! as String);
    }
  }

  /// Explicit recovery decision: forgets the in-flight markers of processes
  /// that died with admitted work, after the coordinator has dealt with
  /// what that work may have left behind. Returns how many were cleared.
  /// Markers of live processes are never touched. Never called implicitly.
  Future<int> acknowledgeInterruptedWork({
    required String decisionDigest,
  }) async {
    final r = await _call('acknowledgeInterrupted', {
      'decisionDigest': decisionDigest,
    });
    return r['interrupted']! as int;
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

/// The gate every source writer of this engine admits through. `main`
/// installs it before any ordinary startup step can write; null (no gate,
/// every write ungated) in host tests that do not install one.
SourceWriteGate? appSourceGate;

SourceTicket? _defaultParent;

/// Runs [body] as one admitted logical source operation through
/// [appSourceGate] (see [SourceWriteGate.run]). A nested continuation passes
/// the running operation's ticket as [parent]; without one it inherits the
/// parent set by [withDefaultParent] around the synchronous call that
/// started it. With no app gate, [body] runs at once, ungated.
Future<T> runSourceWrite<T>(
  String operation,
  Future<T> Function(SourceTicket ticket) body, {
  SourceTicket? parent,
}) {
  final gate = appSourceGate;
  final p = parent ?? _defaultParent;
  if (gate == null) return body(p ?? SourceTicket.ungated);
  return gate.run(operation, body, parent: p);
}

/// Calls [body] synchronously with [ticket] as the parent of every source
/// write it starts without naming one: writes that committing editor input
/// triggers then run under the capture's preparation ticket instead of being
/// refused by the closed admission. Only writes started before [body]
/// returns inherit it.
T withDefaultParent<T>(SourceTicket ticket, T Function() body) {
  final previous = _defaultParent;
  _defaultParent = ticket;
  try {
    return body();
  } finally {
    _defaultParent = previous;
  }
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

  /// Makes [directory] and every directory between [base] (which must
  /// already exist) and it exist durably. Missing components are created,
  /// and the parent of every component below [base] is flushed, whether this
  /// call created that component or an earlier, interrupted one did. A
  /// symbolic link or file in the chain answers `not_a_directory`; a
  /// [directory] outside [base] answers `invalid_argument`.
  Future<void> ensureDirectory(Directory directory, {required Directory base}) =>
      _ok('ensureDirectory', {'path': directory.path, 'base': base.path});

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

  /// Bytes still usable by this app on the file system holding [directory]
  /// (an existing directory). Read only.
  Future<int> availableBytes(Directory directory) async {
    final r = await _invokeNative(_platform, 'availableBytes', {
      'path': directory.path,
    });
    if (r['code'] != 'ok') throw SourceGateException(r['code']! as String);
    final bytes = r['bytes'];
    if (bytes is! int || bytes < 0) {
      throw const SourceGateException('malformed_result');
    }
    return bytes;
  }

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
