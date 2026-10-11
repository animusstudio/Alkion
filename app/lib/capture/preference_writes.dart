import 'package:flutter/foundation.dart' show immutable;
import 'package:shared_preferences/shared_preferences.dart';

import 'session_capture_hooks.dart';
import 'source_write_gate.dart';

/// A preference write the platform store reported as not stored.
@immutable
class PreferenceWriteFailed implements Exception {
  const PreferenceWriteFailed(this.operation);

  final String operation;

  @override
  String toString() => 'PreferenceWriteFailed($operation)';
}

/// Runs one preference write as an admitted source operation named
/// [operation] (or a continuation of [parent]): the preferences are loaded
/// and written only after admission, under the ticket. The write is tracked
/// by [SessionWriteLedger] so a capture awaits it, and its outcome is
/// recorded under [operation]: a failure stays recorded, blocking capture,
/// until a later write of the same operation succeeds.
///
/// Throws [SourceGateException] (`admission_closed` while a capture prepares
/// or holds the source) before anything is loaded or written, the store's
/// error, or [PreferenceWriteFailed] if [write] reports a value not stored.
Future<void> writePreferences(
  String operation,
  Future<bool> Function(SharedPreferences prefs) write, {
  SourceTicket? parent,
}) {
  final ledger = SessionWriteLedger.instance;
  return ledger.track(runSourceWrite(
    operation,
    (_) => ledger.write(operation, () async {
      final prefs = await SharedPreferences.getInstance();
      if (!await write(prefs)) throw PreferenceWriteFailed(operation);
    }),
    parent: parent,
  ));
}

/// Whether [error] is the gate refusing new work while a capture prepares or
/// holds the source (nothing was written).
bool isAdmissionRefusal(Object error) =>
    error is SourceGateException && error.code == 'admission_closed';
