import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
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
/// native test. Only Linux is registered (see
/// docs/reps-capture-qualification.md); every other combination stays
/// unsupported and no capture may attest that download/native apply is
/// paused there.
final List<NativeSyncQualification> registeredNativeSyncQualifications =
    List.unmodifiable([linuxNativeSyncQualificationRecord.qualification]);

/// The mechanism identified in the pinned SDK source (see
/// docs/reps-capture-qualification.md): a non-clearing `disconnect()`, whose
/// completion waits for the sync isolate to exit, followed by one exclusive
/// lease of the shared SQLite pool writer.
const candidateNativeSyncMethodId =
    'powersync-2.2.0/disconnect-awaits-sync-isolate-exit+writer-barrier/v1';

/// A native qualification with the evidence it was recorded from. The
/// [qualification]'s `qualificationEvidenceDigest` is SHA-256 over the
/// canonical JSON of this whole record.
@immutable
class NativeSyncQualificationRecord {
  const NativeSyncQualificationRecord({
    required this.platform,
    required this.profileEvidenceDigest,
    required this.methodId,
    required this.evidence,
  });

  final String platform;
  final String profileEvidenceDigest;
  final String methodId;

  /// Inspected sources, the native test and its recorded run.
  final List<String> evidence;

  String get evidenceDigest => sha256
      .convert(utf8.encode(jsonEncode({
        'evidence': evidence,
        'method_id': methodId,
        'platform': platform,
        'profile_evidence_digest': profileEvidenceDigest,
      })))
      .toString();

  NativeSyncQualification get qualification => NativeSyncQualification(
        platform: platform,
        profileEvidenceDigest: profileEvidenceDigest,
        methodId: methodId,
        qualificationEvidenceDigest: evidenceDigest,
      );
}

/// The Linux record for [candidateNativeSyncMethodId] on the registered Linux
/// source profile.
final NativeSyncQualificationRecord linuxNativeSyncQualificationRecord =
    NativeSyncQualificationRecord(
  platform: 'linux',
  profileEvidenceDigest: qualifiedSourceProfiles
      .singleWhere((p) => p.runtime.platform == 'linux')
      .evidenceDigest,
  methodId: candidateNativeSyncMethodId,
  evidence: const [
    'source:powersync-2.2.0/lib/src/sync/streaming_sync.dart:98-128,156-191,434-439,474-563',
    'source:powersync-2.2.0/lib/src/database/native/native_powersync_database.dart:64-86,161-185,201-236',
    'source:powersync-2.2.0/lib/src/sync/connection_manager.dart:60-86,145-168',
    'source:powersync-2.2.0/lib/src/sync/bucket_storage.dart:118-128',
    'source:sqlite_async-0.14.2/lib/src/native/database/native_sqlite_database.dart:123-148',
    'test:app/integration_test/capture_platform_test.dart#paused_native_apply_and_pending_disconnect_block_observation',
    'fixture:app/integration_test/support/native_sync_fixture.dart#pool-writer-lease-pause',
    'run:2026-10-10 make -C app capture-integration CAPTURE_DEVICE=linux; '
        'debug bundle, Flutter 3.44.0, x86_64, core 0.4.13/670c312e; '
        'real disconnect() observed by a delegating spy: pending while the '
        'apply is paused and while an upload is in flight, the paused row '
        'applied when it returns and inside the barrier; PASS',
    'mutation:disconnect not awaited, SDK status guards bypassed: FAIL '
        '(disconnect completed while the apply was paused; row not applied '
        'when it returned)',
  ],
);

/// Awaits the non-clearing disconnect, then leases the shared pool writer
/// once. Every isolate of the process writes through that one writer, so a
/// lease granted after the sync isolate exited fences any transaction it
/// left behind.
class _DisconnectThenWriterBarrier implements NativeSyncMethod {
  const _DisconnectThenWriterBarrier();

  @override
  String get methodId => candidateNativeSyncMethodId;

  @override
  Future<void> disconnect(PowerSyncDatabase database) => database.disconnect();

  @override
  Future<void> awaitNativeApplyDrained(PowerSyncDatabase database) =>
      database.writeLock((_) async {});
}

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

  /// Completes only once native apply work is drained and fenced. Requested
  /// only after [disconnect] has completed.
  Future<void> awaitNativeApplyDrained(PowerSyncDatabase database);
}

/// Native methods by id. A method only produces evidence for a
/// combination listed in [registeredNativeSyncQualifications].
const Map<String, NativeSyncMethod> _nativeSyncMethods = {
  candidateNativeSyncMethodId: _DisconnectThenWriterBarrier(),
};

/// The real method for [methodId], for the native qualification test, which
/// must run it before any registration exists.
@visibleForTesting
NativeSyncMethod? nativeSyncMethodById(String methodId) =>
    _nativeSyncMethods[methodId];

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
    required Object origin,
  }) : _origin = origin;

  final String captureId;
  final String databaseInstanceId;
  final String profileEvidenceDigest;
  final String methodId;
  final String qualificationEvidenceDigest;
  final int gateGeneration;
  final int connectionEpoch;
  final bool disconnectCompleted;
  final bool nativeApplyDrained;

  /// Which adapter kind produced it: production adapters share one origin,
  /// every test-seam adapter has its own, so seam evidence is never current
  /// for a production adapter.
  final Object _origin;
}

/// Origin of evidence from production adapters (registered methods only).
const Object _productionOrigin = _ProductionOrigin();

class _ProductionOrigin {
  const _ProductionOrigin();
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
        _requireRegistration = true,
        _origin = _productionOrigin;

  /// Binds a method seam for tests, without the registry lookup. Its
  /// evidence carries an origin private to this adapter, so it is never
  /// current for a production adapter (or any other seam) and qualifies
  /// nothing, even when [qualification] is a registered one.
  @visibleForTesting
  NativeSyncQuiescence.withMethodForTesting({
    required this.qualification,
    required NativeSyncMethod method,
  })  : _method = method,
        _requireRegistration = false,
        _origin = Object();

  final NativeSyncQualification qualification;
  final NativeSyncMethod? _method;
  final bool _requireRegistration;
  final Object _origin;

  bool get _registered =>
      !_requireRegistration ||
      registeredNativeSyncQualifications.contains(qualification);

  /// Disconnects [database] without clearing it, then — only after the
  /// disconnect has completed — awaits the native apply drain, and returns
  /// evidence only once both have completed, all within [timeout].
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
    // Strictly in order, under one timeout: a drain observed before the
    // disconnect completed would not fence work the connection still does
    // while shutting down (for example its final `stop` control call).
    await () async {
      await method.disconnect(database);
      disconnectCompleted = true;
      await method.awaitNativeApplyDrained(database);
      nativeApplyDrained = true;
    }()
        .timeout(timeout);

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
      origin: _origin,
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
        identical(evidence._origin, _origin) &&
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
