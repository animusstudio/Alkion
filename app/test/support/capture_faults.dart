// Test wiring for the capture fault boundaries (lib/capture/capture_faults.dart).
//
// [ScriptedCaptureFaults] records every boundary a capture passes, in order,
// and can act at one of them: run a callback there (to change the file
// system or park a disposable fixture process so it can be killed) or throw
// [CaptureFaultInjected], which the coordinator treats as process death.
// The production [CaptureFaults] does nothing.
import 'dart:async';

import 'package:workout_tracker/capture/capture_faults.dart';

/// Thrown at an injected boundary: the attempt stops there as if the
/// process died.
class CaptureFaultInjected implements Exception {
  const CaptureFaultInjected(this.boundary);

  final String boundary;

  @override
  String toString() => 'CaptureFaultInjected($boundary)';
}

class ScriptedCaptureFaults extends CaptureFaults {
  ScriptedCaptureFaults({this.interruptAt, this.interruptWhen, this.onHit});

  /// Interrupts at the [occurrence]th (0-based) time [boundary] is passed.
  factory ScriptedCaptureFaults.at(String boundary, int occurrence) {
    var seen = 0;
    return ScriptedCaptureFaults(
      interruptWhen: (b) => b == boundary && seen++ == occurrence,
    );
  }

  /// Boundaries passed so far, in order.
  final hits = <String>[];

  /// Throws [CaptureFaultInjected] at the boundary with this index.
  int? interruptAt;

  /// Throws [CaptureFaultInjected] at the first boundary it accepts.
  bool Function(String boundary)? interruptWhen;

  /// Runs at every boundary (after it is recorded, before any interruption).
  FutureOr<void> Function(String boundary, int index)? onHit;

  /// Where the attempt was stopped, if it was.
  String? interruptedAt;

  @override
  Future<void> hit(String boundary) async {
    final index = hits.length;
    hits.add(boundary);
    await onHit?.call(boundary, index);
    if (interruptedAt == null &&
        (interruptAt == index || (interruptWhen?.call(boundary) ?? false))) {
      interruptedAt = boundary;
      throw CaptureFaultInjected(boundary);
    }
  }
}

/// The boundaries in [hits] worth interrupting at, each with how many times
/// it was passed before (`(boundary, occurrence, index)`): every boundary
/// except the coordinator's own `journal:<stage>` steps, each of which
/// directly follows its `journal_renamed:<stage>` with nothing in between.
List<(String, int, int)> interruptionPoints(List<String> hits) {
  final seen = <String, int>{};
  return [
    for (var i = 0; i < hits.length; i++)
      if (!hits[i].startsWith('journal:'))
        (hits[i], seen.update(hits[i], (n) => n + 1, ifAbsent: () => 0), i),
  ];
}
