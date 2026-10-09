import 'dart:async';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:powersync/powersync.dart' show PowerSyncDatabase, uuid;

import 'capture_profile.dart';

/// A reviewed native mechanism that stops PowerSync download/apply work on
/// one exact platform and source profile. Only a passing real native test
/// may add an entry to [registeredNativeSyncQualifications].
@immutable
class NativeSyncQualification {
  const NativeSyncQualification({
    required this.platform,
    required this.profileEvidenceDigest,
    required this.methodId,
    required this.qualificationEvidenceDigest,
  });

  final String platform;

  /// [QualifiedProfile.evidenceDigest] of the source profile it covers.
  final String profileEvidenceDigest;

  /// The [NativeSyncMethod.methodId] that was qualified.
  final String methodId;

  /// Digest of the recorded native qualification evidence.
  final String qualificationEvidenceDigest;

  @override
  bool operator ==(Object other) =>
      other is NativeSyncQualification &&
      other.platform == platform &&
      other.profileEvidenceDigest == profileEvidenceDigest &&
      other.methodId == methodId &&
      other.qualificationEvidenceDigest == qualificationEvidenceDigest;

  @override
  int get hashCode => Object.hash(
      platform, profileEvidenceDigest, methodId, qualificationEvidenceDigest);
}

/// Exact combinations whose native quiescence has been proven by a real
/// native test. None yet: until one passes, every profile is unsupported and
/// no capture may attest that download/native apply is paused.
const registeredNativeSyncQualifications = <NativeSyncQualification>[];

/// The candidate mechanism identified in the pinned SDK source (see
/// docs/reps-capture-qualification.md): a non-clearing `disconnect()`, whose
/// completion waits for the sync isolate to exit, followed by one exclusive
/// acquisition of the shared SQLite writer. A candidate only — it is neither
/// implemented here nor qualified.
const candidateNativeSyncMethodId =
    'powersync-2.2.0/disconnect-awaits-sync-isolate-exit+writer-barrier/v1';

/// The registered qualification for [profile] on its platform, if any.
NativeSyncQualification? nativeSyncQualificationFor(QualifiedProfile profile) {
  for (final q in registeredNativeSyncQualifications) {
    if (q.platform == profile.runtime.platform &&
        q.profileEvidenceDigest == profile.evidenceDigest) {
      return q;
    }
  }
  return null;
}

/// A native mechanism that disconnects without clearing and proves that no
/// downloaded data is being, or can afterwards be, applied by that
/// connection.
abstract interface class NativeSyncMethod {
  String get methodId;

  /// Non-clearing disconnect; completes when the disconnect has completed.
  Future<void> disconnect(PowerSyncDatabase database);

  /// Completes only once native apply work is drained and fenced.
  Future<void> awaitNativeApplyDrained(PowerSyncDatabase database);
}

/// Native methods by id, added alongside their qualification.
const Map<String, NativeSyncMethod> _nativeSyncMethods = {};

/// Proof that, for one capture attempt and gate generation, one database
/// instance's sync connection was disconnected and its native apply drained.
@immutable
class NativeSyncPauseEvidence {
  const NativeSyncPauseEvidence._({
    required this.captureId,
    required this.databaseInstanceId,
    required this.profileEvidenceDigest,
    required this.methodId,
    required this.qualificationEvidenceDigest,
    required this.gateGeneration,
    required this.connectionEpoch,
    required this.disconnectCompleted,
    required this.nativeApplyDrained,
  });

  final String captureId;
  final String databaseInstanceId;
  final String profileEvidenceDigest;
  final String methodId;
  final String qualificationEvidenceDigest;
  final int gateGeneration;
  final int connectionEpoch;
  final bool disconnectCompleted;
  final bool nativeApplyDrained;
}

/// Opaque per-instance identities and connection epochs, shared by every
/// adapter so a connection change reported to any of them invalidates all
/// evidence for that database.
final Expando<String> _instanceIds = Expando('capture database identity');
final Expando<_Epoch> _epochs = Expando('capture connection epoch');

class _Epoch {
  int value = 0;
}

String _instanceId(PowerSyncDatabase database) =>
    _instanceIds[database] ??= uuid.v4();

_Epoch _epoch(PowerSyncDatabase database) => _epochs[database] ??= _Epoch();

/// Observes native sync quiescence for one exact qualification.
///
/// Evidence is valid only for the database instance, connection epoch,
/// capture id, gate generation, source profile and qualified method it was
/// observed under. SDK status, an empty queue or an application-level gate
/// never substitute for it.
class NativeSyncQuiescence {
  NativeSyncQuiescence({required this.qualification})
      : _method = _nativeSyncMethods[qualification.methodId],
        _requireRegistration = true;

  /// Binds a controllable completion seam for host contract tests. Evidence
  /// it produces is never current for a production adapter and qualifies
  /// nothing.
  @visibleForTesting
  NativeSyncQuiescence.withMethodForTesting({
    required this.qualification,
    required NativeSyncMethod method,
  })  : _method = method,
        _requireRegistration = false;

  final NativeSyncQualification qualification;
  final NativeSyncMethod? _method;
  final bool _requireRegistration;

  bool get _registered =>
      !_requireRegistration ||
      registeredNativeSyncQualifications.contains(qualification);

  /// Disconnects [database] without clearing it and returns evidence only
  /// once both the disconnect and native apply drain have completed.
  ///
  /// Throws [UnsupportedCaptureProfile] when the qualification is not
  /// registered or does not cover [profile] and its method, or when the
  /// connection changed during observation; a [TimeoutException] when either
  /// completion is not seen within [timeout]. No evidence is produced then.
  Future<NativeSyncPauseEvidence> disconnectAndObserve(
    PowerSyncDatabase database,
    QualifiedProfile profile, {
    required String captureId,
    required int gateGeneration,
    required Duration timeout,
  }) async {
    final method = _method;
    if (!_registered || method == null) {
      throw const UnsupportedCaptureProfile('native_sync_unqualified');
    }
    if (qualification.platform != profile.runtime.platform ||
        qualification.profileEvidenceDigest != profile.evidenceDigest ||
        qualification.methodId != method.methodId) {
      throw const UnsupportedCaptureProfile('native_sync_profile_mismatch');
    }
    if (database.closed) {
      throw const UnsupportedCaptureProfile('database_closed');
    }

    final instanceId = _instanceId(database);
    final epoch = _epoch(database).value;

    var disconnectCompleted = false;
    var nativeApplyDrained = false;
    await Future.wait([
      method.disconnect(database).then((_) => disconnectCompleted = true),
      method
          .awaitNativeApplyDrained(database)
          .then((_) => nativeApplyDrained = true),
    ]).timeout(timeout);

    if (_epoch(database).value != epoch ||
        database.closed ||
        database.currentStatus.connected ||
        database.currentStatus.connecting) {
      throw const UnsupportedCaptureProfile('native_sync_connection_changed');
    }
    if (!disconnectCompleted || !nativeApplyDrained) {
      throw const UnsupportedCaptureProfile('native_sync_incomplete');
    }
    return NativeSyncPauseEvidence._(
      captureId: captureId,
      databaseInstanceId: instanceId,
      profileEvidenceDigest: profile.evidenceDigest,
      methodId: method.methodId,
      qualificationEvidenceDigest: qualification.qualificationEvidenceDigest,
      gateGeneration: gateGeneration,
      connectionEpoch: epoch,
      disconnectCompleted: disconnectCompleted,
      nativeApplyDrained: nativeApplyDrained,
    );
  }

  /// Must be called before every connect or reconnect of [database]: it
  /// advances the connection epoch, invalidating all earlier evidence.
  void connectionWillChange(PowerSyncDatabase database) {
    _epoch(database).value++;
  }

  /// Whether [evidence] still proves quiescence for exactly this database,
  /// profile, capture and gate generation under this adapter's qualification.
  bool isCurrent(
    NativeSyncPauseEvidence evidence,
    PowerSyncDatabase database,
    QualifiedProfile profile, {
    required String captureId,
    required int gateGeneration,
  }) {
    final method = _method;
    return _registered &&
        method != null &&
        evidence.disconnectCompleted &&
        evidence.nativeApplyDrained &&
        !database.closed &&
        !database.currentStatus.connected &&
        !database.currentStatus.connecting &&
        _instanceIds[database] == evidence.databaseInstanceId &&
        _epochs[database]?.value == evidence.connectionEpoch &&
        evidence.captureId == captureId &&
        evidence.gateGeneration == gateGeneration &&
        evidence.profileEvidenceDigest == profile.evidenceDigest &&
        qualification.profileEvidenceDigest == profile.evidenceDigest &&
        qualification.platform == profile.runtime.platform &&
        evidence.methodId == method.methodId &&
        evidence.methodId == qualification.methodId &&
        evidence.qualificationEvidenceDigest ==
            qualification.qualificationEvidenceDigest;
  }
}
