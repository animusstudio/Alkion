// Host contract tests for the native sync quiescence adapter.
//
// The completion seam below is controlled by the test: these tests pin how
// evidence is bound and refused. They are NOT native qualification — no
// adapter here observes a real native apply continuation.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart';
import 'package:workout_tracker/capture/capture_profile.dart';
import 'package:workout_tracker/capture/native_sync_quiescence.dart';
import 'package:workout_tracker/sync/db.dart' show pendingUploadCount;

import '../support/capture_fixture.dart';

const _harnessMethodId = 'host-contract/controlled-completions';

/// A completion seam whose disconnect and native-apply drain the test
/// releases by hand.
class ControlledNativeSync implements NativeSyncMethod {
  final disconnectReleased = Completer<void>();
  final applyDrained = Completer<void>();
  int disconnectCalls = 0;
  int drainCalls = 0;

  @override
  String get methodId => _harnessMethodId;

  @override
  Future<void> disconnect(PowerSyncDatabase database) async {
    disconnectCalls++;
    await disconnectReleased.future;
    await database.disconnect();
  }

  @override
  Future<void> awaitNativeApplyDrained(PowerSyncDatabase database) {
    drainCalls++;
    return applyDrained.future;
  }

  void releaseAll() {
    if (!disconnectReleased.isCompleted) disconnectReleased.complete();
    if (!applyDrained.isCompleted) applyDrained.complete();
  }
}

/// The same controllable seam, claiming the registered method's id.
class ControlledCandidateSync extends ControlledNativeSync {
  @override
  String get methodId => candidateNativeSyncMethodId;
}

/// The documented `qualificationEvidenceDigest` of the Linux record
/// (docs/reps-capture-qualification.md).
const _documentedLinuxQualificationDigest =
    'd4ab5a782f2f22ba20bff793c56ee094da89a36a2f374fd3bbf2f7c1e05b7aa4';

Matcher unsupported(String code) =>
    throwsA(isA<UnsupportedCaptureProfile>().having((e) => e.code, 'code', code));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixtures = <CaptureFixture>[];
  final opened = <PowerSyncDatabase>[];

  Future<(PowerSyncDatabase, QualifiedProfile)> openSource(
      {bool queue = true}) async {
    final f = await CaptureFixture.create(queue: queue);
    fixtures.add(f);
    final database = await f.openNormally();
    opened.add(database);
    final runtime = qualifiedSourceProfiles
        .singleWhere((p) => p.runtime.platform == Platform.operatingSystem)
        .runtime;
    return (database, await qualifyCaptureProfile(database, runtime));
  }

  NativeSyncQualification harnessQualification(QualifiedProfile profile) =>
      NativeSyncQualification(
        platform: profile.runtime.platform,
        profileEvidenceDigest: profile.evidenceDigest,
        methodId: _harnessMethodId,
        qualificationEvidenceDigest: 'host-contract-only',
      );

  tearDown(() async {
    for (final d in opened) {
      await d.close();
    }
    opened.clear();
    for (final f in fixtures) {
      await f.dispose();
    }
    fixtures.clear();
  });

  test('disconnect_pending_never_returns_evidence', () async {
    final (database, profile) = await openSource(queue: false);
    // Every substitute signal already says "idle": the SDK reports
    // disconnected, nothing is queued, and the application has stopped
    // admitting work (the adapter accepts no such signal as input at all).
    expect(database.currentStatus.connected, isFalse);
    expect(await pendingUploadCount(database), 0);

    final method = ControlledNativeSync();
    final observer = NativeSyncQuiescence.withMethodForTesting(
        qualification: harnessQualification(profile), method: method);
    method.applyDrained.complete();

    var observationCompletedWhileDisconnectPending = false;
    final pending = observer
        .disconnectAndObserve(database, profile,
            captureId: 'capture-1',
            gateGeneration: 1,
            timeout: const Duration(milliseconds: 300))
        .whenComplete(() => observationCompletedWhileDisconnectPending = true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(observationCompletedWhileDisconnectPending, false);
    // The drain is never requested while the disconnect is pending, so an
    // already-drained signal cannot predate the disconnect.
    expect(method.disconnectCalls, 1);
    expect(method.drainCalls, 0);
    await expectLater(pending, throwsA(isA<TimeoutException>()));
    expect(method.drainCalls, 0);

    // The reverse: disconnect done, native apply still pending.
    final method2 = ControlledNativeSync()..disconnectReleased.complete();
    final observer2 = NativeSyncQuiescence.withMethodForTesting(
        qualification: harnessQualification(profile), method: method2);
    await expectLater(
      observer2.disconnectAndObserve(database, profile,
          captureId: 'capture-1',
          gateGeneration: 1,
          timeout: const Duration(milliseconds: 200)),
      throwsA(isA<TimeoutException>()),
    );
    expect(method2.drainCalls, 1);

    // Only both completions, in order, produce evidence: the drain is
    // requested after the disconnect completes, and evidence waits for it.
    final method3 = ControlledNativeSync();
    final observer3 = NativeSyncQuiescence.withMethodForTesting(
        qualification: harnessQualification(profile), method: method3);
    var observed = false;
    final observing = observer3
        .disconnectAndObserve(database, profile,
            captureId: 'capture-1',
            gateGeneration: 1,
            timeout: const Duration(seconds: 5))
        .whenComplete(() => observed = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(method3.drainCalls, 0);
    method3.disconnectReleased.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(method3.drainCalls, 1);
    expect(observed, false);
    method3.applyDrained.complete();
    final evidence = await observing;
    expect(evidence.disconnectCompleted, true);
    expect(evidence.nativeApplyDrained, true);
    expect(evidence.captureId, 'capture-1');
    expect(evidence.gateGeneration, 1);
    expect(evidence.methodId, _harnessMethodId);
    expect(evidence.profileEvidenceDigest, profile.evidenceDigest);
    expect(evidence.qualificationEvidenceDigest, 'host-contract-only');
    expect(method3.disconnectCalls, 1);
    expect(method3.drainCalls, 1);
  });

  test('unqualified_native_method_refuses_observation', () async {
    final (database, profile) = await openSource();
    final queued = await pendingUploadCount(database);
    expect(queued, greaterThan(0));

    // Only the exact combination a real native test qualified is
    // registered; a qualification for the same method with any other
    // evidence digest is not.
    expect(registeredNativeSyncQualifications,
        [linuxNativeSyncQualificationRecord.qualification]);

    final candidate = NativeSyncQualification(
      platform: profile.runtime.platform,
      profileEvidenceDigest: profile.evidenceDigest,
      methodId: candidateNativeSyncMethodId,
      qualificationEvidenceDigest: 'not-qualified',
    );
    final production = NativeSyncQuiescence(qualification: candidate);
    await expectLater(
      production.disconnectAndObserve(database, profile,
          captureId: 'capture-1',
          gateGeneration: 1,
          timeout: const Duration(seconds: 1)),
      unsupported('native_sync_unqualified'),
    );
    expect(await pendingUploadCount(database), queued,
        reason: 'refusal never clears or dequeues the source queue');

    // A controlled seam bound to another profile, platform or method is
    // refused before it runs.
    for (final mismatched in [
      NativeSyncQualification(
          platform: profile.runtime.platform,
          profileEvidenceDigest: '0' * 64,
          methodId: _harnessMethodId,
          qualificationEvidenceDigest: 'host-contract-only'),
      NativeSyncQualification(
          platform: 'android',
          profileEvidenceDigest: profile.evidenceDigest,
          methodId: _harnessMethodId,
          qualificationEvidenceDigest: 'host-contract-only'),
      NativeSyncQualification(
          platform: profile.runtime.platform,
          profileEvidenceDigest: profile.evidenceDigest,
          methodId: candidateNativeSyncMethodId,
          qualificationEvidenceDigest: 'host-contract-only'),
    ]) {
      final method = ControlledNativeSync()..releaseAll();
      final observer = NativeSyncQuiescence.withMethodForTesting(
          qualification: mismatched, method: method);
      await expectLater(
        observer.disconnectAndObserve(database, profile,
            captureId: 'capture-1',
            gateGeneration: 1,
            timeout: const Duration(seconds: 1)),
        unsupported('native_sync_profile_mismatch'),
      );
      expect(method.disconnectCalls + method.drainCalls, 0);
    }

    // Host-contract evidence is never current for the production adapter.
    final method = ControlledNativeSync()..releaseAll();
    final harness = NativeSyncQuiescence.withMethodForTesting(
        qualification: harnessQualification(profile), method: method);
    final evidence = await harness.disconnectAndObserve(database, profile,
        captureId: 'capture-1',
        gateGeneration: 1,
        timeout: const Duration(seconds: 5));
    expect(
        production.isCurrent(evidence, database, profile,
            captureId: 'capture-1', gateGeneration: 1),
        false);
    expect(await pendingUploadCount(database), queued);
  });

  test('evidence_rejects_other_database_generation_or_connection', () async {
    final (database, profile) = await openSource();
    final (otherDatabase, _) = await openSource();
    final method = ControlledNativeSync()..releaseAll();
    final observer = NativeSyncQuiescence.withMethodForTesting(
        qualification: harnessQualification(profile), method: method);

    Future<NativeSyncPauseEvidence> observe(PowerSyncDatabase d,
            {String captureId = 'capture-1', int gateGeneration = 7}) =>
        observer.disconnectAndObserve(d, profile,
            captureId: captureId,
            gateGeneration: gateGeneration,
            timeout: const Duration(seconds: 5));

    final evidence = await observe(database);
    expect(
        observer.isCurrent(evidence, database, profile,
            captureId: 'capture-1', gateGeneration: 7),
        true);

    const otherCaptureId = 'capture-2';
    expect(
        observer.isCurrent(evidence, database, profile,
            captureId: otherCaptureId, gateGeneration: evidence.gateGeneration),
        false);
    expect(
        observer.isCurrent(evidence, database, profile,
            captureId: evidence.captureId, gateGeneration: 8),
        false);
    expect(
        observer.isCurrent(evidence, otherDatabase, profile,
            captureId: evidence.captureId,
            gateGeneration: evidence.gateGeneration),
        false);
    final otherProfile = QualifiedProfile.forTesting(
        runtime: profile.runtime,
        profileId: profile.profileId,
        evidenceDigest: 'f' * 64);
    expect(
        observer.isCurrent(evidence, database, otherProfile,
            captureId: evidence.captureId,
            gateGeneration: evidence.gateGeneration),
        false);

    // Evidence for another database never transfers, even once that
    // database has its own evidence.
    final otherEvidence = await observe(otherDatabase);
    expect(otherEvidence.databaseInstanceId,
        isNot(evidence.databaseInstanceId));
    expect(
        observer.isCurrent(otherEvidence, database, profile,
            captureId: 'capture-1', gateGeneration: 7),
        false);

    // A connection change invalidates evidence before any reconnect.
    observer.connectionWillChange(database);
    expect(
        observer.isCurrent(evidence, database, profile,
            captureId: evidence.captureId,
            gateGeneration: evidence.gateGeneration),
        false);
    final renewed = await observe(database);
    expect(renewed.connectionEpoch, evidence.connectionEpoch + 1);
    expect(renewed.databaseInstanceId, evidence.databaseInstanceId);
    expect(
        observer.isCurrent(renewed, database, profile,
            captureId: 'capture-1', gateGeneration: 7),
        true);

    // A connection change while observation is in flight yields no evidence.
    final slow = ControlledNativeSync();
    final slowObserver = NativeSyncQuiescence.withMethodForTesting(
        qualification: harnessQualification(profile), method: slow);
    final inFlight = slowObserver.disconnectAndObserve(database, profile,
        captureId: 'capture-1',
        gateGeneration: 7,
        timeout: const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
    observer.connectionWillChange(database);
    slow.releaseAll();
    await expectLater(inFlight, unsupported('native_sync_connection_changed'));
    expect(
        observer.isCurrent(renewed, database, profile,
            captureId: 'capture-1', gateGeneration: 7),
        false);

    // A closed database has no current evidence.
    final last = await observe(otherDatabase, gateGeneration: 9);
    await otherDatabase.close();
    opened.remove(otherDatabase);
    expect(
        observer.isCurrent(last, otherDatabase, profile,
            captureId: 'capture-1', gateGeneration: 9),
        false);
  });

  test('seam_evidence_never_current_for_production', () async {
    final (database, profile) = await openSource(queue: false);
    final registered = nativeSyncQualificationFor(profile);
    expect(registered, linuxNativeSyncQualificationRecord.qualification);

    // A seam bound to the REGISTERED qualification and method id.
    final seam = NativeSyncQuiescence.withMethodForTesting(
        qualification: registered!, method: ControlledCandidateSync()..releaseAll());
    final evidence = await seam.disconnectAndObserve(database, profile,
        captureId: 'capture-1',
        gateGeneration: 1,
        timeout: const Duration(seconds: 5));
    expect(evidence.methodId, candidateNativeSyncMethodId);
    expect(evidence.qualificationEvidenceDigest,
        registered.qualificationEvidenceDigest);
    expect(
        seam.isCurrent(evidence, database, profile,
            captureId: 'capture-1', gateGeneration: 1),
        true);

    final production = NativeSyncQuiescence(qualification: registered);
    expect(
        production.isCurrent(evidence, database, profile,
            captureId: 'capture-1', gateGeneration: 1),
        false,
        reason: 'test-seam evidence is never production evidence');
    final otherSeam = NativeSyncQuiescence.withMethodForTesting(
        qualification: registered, method: ControlledCandidateSync()..releaseAll());
    expect(
        otherSeam.isCurrent(evidence, database, profile,
            captureId: 'capture-1', gateGeneration: 1),
        false);
  });

  test('linux_native_sync_record_digest_matches_guide', () async {
    expect(linuxNativeSyncQualificationRecord.evidenceDigest,
        _documentedLinuxQualificationDigest);
    final guide =
        await File('../docs/reps-capture-qualification.md').readAsString();
    expect(guide, contains(_documentedLinuxQualificationDigest));
    expect(guide,
        contains(linuxNativeSyncQualificationRecord.profileEvidenceDigest));
  });
}
