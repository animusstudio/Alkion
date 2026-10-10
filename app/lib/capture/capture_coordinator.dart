import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show immutable, mapEquals, visibleForTesting;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart' show PowerSyncDatabase, uuid;

import '../data/active_session_draft.dart';
import 'capture_artifact.dart';
import 'capture_journal.dart' hide CaptureFileDigest;
import 'capture_journal.dart' as journal show CaptureFileDigest;
import 'capture_manifest.dart';
import 'capture_profile.dart';
import 'capture_reader.dart';
import 'capture_startup.dart';
import 'capture_transport.dart';
import 'native_sync_quiescence.dart';
import 'session_capture_hooks.dart';
import 'source_write_gate.dart';
import 'startup_inventory.dart';

export 'capture_journal.dart' show CaptureMode, CaptureStage;

/// The PowerSync Dart SDK version this build is compiled against: a build
/// constant (pinned in `pubspec.lock`), part of the runtime a source profile
/// is qualified for.
const capturePowerSyncSdkVersion = '2.2.0';

/// Room kept free beyond the artifact itself (journal, records, the
/// directory entries and file-system slack).
const captureSpaceMargin = 8 << 20;

/// The runtime a capture is produced by: the app version and build from
/// [packageInfo], the build constants (SDK version, producer revision), this
/// platform, and the core version and layout [observed] in the database.
/// [qualifyCaptureProfile] accepts it only if it is a registered profile
/// and the database really is that core and layout.
CaptureRuntime captureRuntimeFor(
  PackageInfo packageInfo,
  CaptureDatabaseObservation observed, {
  String? platform,
}) =>
    CaptureRuntime(
      appVersion: '${packageInfo.version}+${packageInfo.buildNumber}',
      platform: platform ?? Platform.operatingSystem,
      sdkVersion: capturePowerSyncSdkVersion,
      coreVersion: observed.coreVersion,
      schemaFingerprint: observed.schema.value,
      producerRevision: captureProducerRevision,
    );

/// The R1 handoff: a published, re-verified capture whose boundary was fully
/// attested on a qualified profile.
///
/// It certifies the qualified LOCAL capture boundary and the artifact's
/// integrity only: not global writer authority, not account or source
/// binding, not server state. Only [CaptureCoordinator] creates one, and
/// only when all five boundary attestations are true, the native sync
/// evidence was current before and after the read, and the sealed capture
/// is usable; anything less is a [CaptureNotCertified].
@immutable
class CertifiedCapture {
  const CertifiedCapture._({
    required this.captureId,
    required this.manifestSha256,
    required this.directory,
    required this.profileEvidenceDigest,
  });

  final String captureId;

  /// SHA-256 of the published `manifest.json`.
  final String manifestSha256;

  /// The published capture directory. Never written again.
  final Directory directory;

  /// [QualifiedProfile.evidenceDigest] of the source profile.
  final String profileEvidenceDigest;
}

/// A capture written and integrity-verified in its private staging
/// directory but NOT usable: it is kept for diagnosis, never published,
/// exported or certified.
@immutable
class ExploratoryCapture {
  ExploratoryCapture._({
    required this.captureId,
    required this.manifestSha256,
    required this.directory,
    required List<String> blockers,
  }) : blockers = List.unmodifiable(blockers);

  final String captureId;
  final String manifestSha256;

  /// The retained staging directory.
  final Directory directory;

  /// Safe codes of what keeps it from being usable.
  final List<String> blockers;
}

/// What it takes to end a held or interrupted capture.
enum CaptureDecision {
  /// Nothing.
  none('none'),

  /// An explicit [CaptureCoordinator.resumeOriginal] for that capture.
  resumeOriginal('resume_original'),

  /// Something the coordinator cannot resolve (an unreadable journal, a
  /// gate record without a journal): the owner must look.
  ownerReview('owner_review');

  const CaptureDecision(this.wire);

  final String wire;
}

/// A capture attempt that produced no [CertifiedCapture]. [code] is a safe,
/// stable code; [detail] names stores, editors or native codes, never data.
sealed class CaptureNotCertified implements Exception {
  const CaptureNotCertified(
    this.code, {
    this.detail,
    this.captureId,
    this.stage,
    this.decision = CaptureDecision.none,
    this.remediation,
    this.exploratory,
  });

  final String code;
  final String? detail;
  final String? captureId;

  /// The attempt's durable stage when it stopped, if it got that far.
  final CaptureStage? stage;

  /// What must happen before the source is in ordinary use again.
  /// [CaptureDecision.none] when the coordinator already released it.
  final CaptureDecision decision;

  /// A safe code for what the person can do (`save_or_cancel_forms`,
  /// `retry_after_resume`, `free_space`).
  final String? remediation;

  /// The sealed but unusable capture, if one was written.
  final ExploratoryCapture? exploratory;

  @override
  String toString() =>
      '$runtimeType($code${detail == null ? '' : ': $detail'})';
}

/// Capture is not possible on this platform, build or profile at all
/// (`platform_unavailable`, `runtime_unqualified`, ...).
final class CaptureUnsupported extends CaptureNotCertified {
  const CaptureUnsupported(super.code, {super.detail});
}

/// The boundary could not be reached, attested, sealed or published.
final class CaptureBlocked extends CaptureNotCertified {
  const CaptureBlocked(
    super.code, {
    super.detail,
    super.captureId,
    super.stage,
    super.decision,
    super.remediation,
    super.exploratory,
  });
}

/// What [CaptureCoordinator.recover] found and did.
@immutable
class CaptureRecovery {
  const CaptureRecovery({
    required this.code,
    this.stage,
    this.captureId,
    this.capture,
    this.decision = CaptureDecision.none,
  });

  /// Durable stage after recovery, or null without a journal.
  final CaptureStage? stage;

  /// Safe code: `none`, `capture_running`, `capture_interrupted`,
  /// `awaiting_resume_decision`, `local_hold`, `resumed`,
  /// `sealed_divergence`, `destination_conflict`, `hold_lost`,
  /// `published_divergence`, `publish_failed`, `gate_*`, `journal_*`, ...
  final String code;
  final String? captureId;

  /// The re-verified published capture, when there is one.
  final CertifiedCapture? capture;

  /// The decision still required.
  final CaptureDecision decision;
}

/// The running app's sources a capture reads: the database, the session
/// side, the transport for a qualified profile and the app's version.
class CaptureSourceBindings {
  CaptureSourceBindings({
    required this.database,
    required this.hooks,
    required this.transportFor,
    Future<PackageInfo> Function()? packageInfo,
    this.readPreferences,
    this.reviewedUnknownPreferences = const {},
  }) : packageInfo = packageInfo ?? PackageInfo.fromPlatform;

  final PowerSyncDatabase database;
  final SessionCaptureHooks hooks;

  /// The transport side for a qualified profile (normally
  /// [CaptureTransport.forProfile]).
  final CaptureTransport Function(QualifiedProfile profile) transportFor;
  final Future<PackageInfo> Function() packageInfo;
  final Future<Map<String, Object>> Function()? readPreferences;
  final Set<String> reviewedUnknownPreferences;
}

/// One attempt's in-memory state: everything a restart loses.
class _Attempt {
  _Attempt(this.captureId, this.transport, this.hooks);

  final String captureId;
  final CaptureTransport transport;
  final SessionCaptureHooks hooks;
  SourcePreparation? preparation;
  TransportPauseEvidence? evidence;
}

/// An orderly stop inside [CaptureCoordinator.capture]. [abandon] stops
/// release the source by a recorded coordinator decision; the others keep
/// it held for an explicit decision.
class _Stop implements Exception {
  const _Stop(
    this.code, {
    this.detail,
    this.abandon = true,
    this.remediation,
    this.exploratory,
  });

  final String code;
  final String? detail;
  final bool abandon;
  final String? remediation;
  final ExploratoryCapture? exploratory;
}

/// A test hook stopped the attempt: behaves like process death (nothing is
/// cleaned up, nothing is released).
class _Interrupted implements Exception {
  const _Interrupted(this.error, this.stack);

  final Object error;
  final StackTrace stack;
}

/// Owns one capture attempt at a time: its private journal, the six
/// boundary steps, publication and restart recovery.
///
/// Boundary (running app):
/// 1. Prepare: refuse open forms with unsaved edits, a second capture and
///    an unqualified profile; persist `preparing` with a new capture UUID,
///    then close source and transport admission; preserve every present
///    raw store version; commit focused input under the preparation ticket.
/// 2. Drain local work: freeze callbacks and await running store
///    operations, observe the settled draft, flush it exactly once, and
///    check the flush replaced exactly what was observed.
/// 3. Drain network work: await admitted uploads, disconnect without
///    clearing and require native evidence of the drained apply.
/// 4. Hold: persist `held`, take the exclusive hold, reload preferences.
/// 5. Read: with the live hold and current native evidence checked right
///    before and right after, persist `copying` and read every store once.
/// 6. Seal and publish: check free space, write and verify the artifact in
///    private staging, persist `sealed` with every digest, publish without
///    replacing, persist `published`, re-verify the final directory. Then a
///    rehearsal persists `resume_allowed`, releases the gate and restores
///    the prior sync policy only; a local hold persists `local_hold` and
///    keeps everything closed until [resumeOriginal].
///
/// A failure before `sealed` releases the source by a recorded decision
/// (`resume_allowed`, then `resumed`, no manifest) and keeps every output
/// for diagnosis, except work left by a dead process (`recovery_required`),
/// which needs [resumeOriginal]. A failure from `sealed` on keeps the hold.
/// Nothing is ever deleted or expired by the coordinator.
class CaptureCoordinator {
  CaptureCoordinator({
    required this.locations,
    required this.gate,
    this.files = const CaptureFiles(),
    this.sources,
    this.drainTimeout = const Duration(seconds: 30),
    DateTime Function()? clock,
    String Function()? newCaptureId,
    @visibleForTesting FutureOr<void> Function(String step)? onStep,
  })  : _clock = clock ?? DateTime.now,
        _newCaptureId = newCaptureId ?? uuid.v4,
        _onStep = onStep;

  final CaptureLocations locations;
  final SourceWriteGate gate;
  final CaptureFiles files;

  /// The running app's sources; without them only [recover] and
  /// [resumeOriginal] are available (capture-first startup).
  final CaptureSourceBindings? sources;

  /// Bound on draining local, network and gate work.
  final Duration drainTimeout;
  final DateTime Function() _clock;
  final String Function() _newCaptureId;
  final FutureOr<void> Function(String step)? _onStep;

  /// Journals with an attempt running in this process (any coordinator).
  static final _running = <String>{};

  /// Attempts left held in this process (frozen callbacks, closed transport
  /// admission), by journal: whichever coordinator of this process records
  /// the decision that releases one also resumes it. A restart loses them,
  /// as it loses the freeze itself.
  static final _held = <String, _Attempt>{};

  /// Forgets this process's in-memory capture state, as a restart does.
  @visibleForTesting
  static void forgetProcessStateForTesting() {
    _running.clear();
    _held.clear();
  }

  _Attempt? get _attempt => _held[_key];
  set _attempt(_Attempt? attempt) =>
      attempt == null ? _held.remove(_key) : _held[_key] = attempt;

  String get _key => locations.journal.absolute.path;

  CaptureJournal get _journal =>
      CaptureJournal(locations.journal, base: locations.source, files: files);

  RawPreservation get _preservation =>
      RawPreservation(locations.preparation, base: locations.source, files: files);

  Directory _stagingOf(String id) => Directory(p.join(locations.staging.path, id));
  Directory _finalOf(String id) => Directory(p.join(locations.captures.path, id));

  Future<void> _step(String step) async {
    final hook = _onStep;
    if (hook == null) return;
    try {
      await hook(step);
    } catch (e, s) {
      throw _Interrupted(e, s);
    }
  }

  Future<CaptureJournalState> _persist(CaptureJournalState state) async {
    await _journal.write(state);
    await _step('journal:${state.stage.wire}');
    return state;
  }

  // ---------------------------------------------------------------------
  // Capture

  /// Runs one capture attempt in [mode]. Returns only a fully attested,
  /// published and re-verified capture; throws [CaptureUnsupported] where
  /// capture is impossible and [CaptureBlocked] for everything else.
  Future<CertifiedCapture> capture({required CaptureMode mode}) async {
    final sources = this.sources;
    if (sources == null) throw const CaptureUnsupported('sources_unavailable');
    if (!_running.add(_key)) throw const CaptureBlocked('capture_in_progress');
    try {
      return await _capture(mode, sources);
    } on _Interrupted catch (e) {
      // Process death: whatever is durable stays exactly as it is.
      _attempt = null;
      Error.throwWithStackTrace(e.error, e.stack);
    } finally {
      _running.remove(_key);
    }
  }

  Future<CertifiedCapture> _capture(
      CaptureMode mode, CaptureSourceBindings sources) async {
    // Nothing durable happens before these pass.
    final unsaved = sources.hooks.unsavedEditors();
    if (unsaved.isNotEmpty) {
      throw CaptureBlocked('unsaved_editor_input',
          detail: unsaved.join(','), remediation: 'save_or_cancel_forms');
    }
    if (_attempt != null) {
      final held = _attempt!;
      throw CaptureBlocked('capture_active',
          captureId: held.captureId, decision: CaptureDecision.resumeOriginal);
    }
    final probe = await probeSourceGate(gate, base: locations.source, files: files);
    if (probe == 'platform_unavailable' || probe == 'unsupported') {
      throw CaptureUnsupported(probe);
    }
    if (probe == 'mismatch') throw const CaptureBlocked('capture_in_progress');
    if (probe != 'open') throw CaptureBlocked('gate_$probe');
    CaptureJournalState? previous;
    try {
      previous = await _journal.read();
    } on CaptureJournalException catch (e) {
      throw CaptureBlocked(e.code, decision: CaptureDecision.ownerReview);
    }
    if (previous != null && previous.stage == CaptureStage.resumeAllowed) {
      // A recorded decision whose release (or whose `resumed` record) did
      // not complete: finish it idempotently. Ordinary startup does not
      // hold for `resume_allowed` once the gate is open, so nothing else
      // would.
      final code =
          await _completeResume(previous, _decision(previous, 'recorded_resume'));
      if (code != null) {
        throw CaptureBlocked(code,
            captureId: previous.captureId,
            stage: CaptureStage.resumeAllowed,
            decision: CaptureDecision.resumeOriginal);
      }
      previous = previous.copyWith(stage: CaptureStage.resumed);
    }
    if (previous != null && previous.stage != CaptureStage.resumed) {
      throw CaptureBlocked('capture_active',
          captureId: previous.captureId,
          stage: previous.stage,
          decision: CaptureDecision.resumeOriginal);
    }

    final database = sources.database;
    final PackageInfo info;
    final CaptureDatabaseObservation observed;
    final QualifiedProfile profile;
    try {
      info = await sources.packageInfo();
      observed = await observeCaptureDatabase(database);
      profile = await qualifyCaptureProfile(
          database, captureRuntimeFor(info, observed));
    } on UnsupportedCaptureProfile catch (e) {
      throw CaptureUnsupported(e.code);
    } catch (_) {
      throw const CaptureUnsupported('profile_unobservable');
    }
    final qualification = nativeSyncQualificationFor(profile);
    if (qualification == null) {
      throw const CaptureUnsupported('native_sync_unqualified');
    }
    final transport = sources.transportFor(profile);
    final hooks = sources.hooks;
    final captureId = _newCaptureId();
    final attempt = _Attempt(captureId, transport, hooks);

    // 1. Prepare: the journal names the attempt before admission closes.
    var state = _initialState(captureId, mode, info, profile, observed);
    try {
      state = await _persist(state);
    } on _Interrupted {
      rethrow;
    } catch (_) {
      throw const CaptureBlocked('journal_write_failed');
    }
    final SourcePreparation preparation;
    try {
      preparation = await transport.closeAdmission(gate, captureId);
    } on SourceGateException catch (e) {
      await _restoreJournal(previous, state);
      throw CaptureBlocked(e.code == 'capture_in_progress'
          ? 'capture_in_progress'
          : 'gate_${e.code}');
    }
    attempt.preparation = preparation;
    _attempt = attempt;

    try {
      return await _boundary(attempt, state, mode, sources, profile, qualification);
    } on _Interrupted {
      rethrow;
    } on _Stop catch (stop) {
      throw await _stopped(attempt, stop);
    } catch (_) {
      // Anything unforeseen: released by a recorded decision only while
      // nothing is sealed yet; from `sealed` on the hold is kept.
      CaptureStage? stage;
      try {
        stage = (await _journal.read())?.stage;
      } catch (_) {
        stage = null;
      }
      const unsealed = {
        CaptureStage.preparing,
        CaptureStage.held,
        CaptureStage.copying,
      };
      throw await _stopped(
          attempt, _Stop('capture_failed', abandon: unsealed.contains(stage)));
    }
  }

  CaptureJournalState _initialState(
    String captureId,
    CaptureMode mode,
    PackageInfo info,
    QualifiedProfile profile,
    CaptureDatabaseObservation observed,
  ) {
    final runtime = profile.runtime;
    return CaptureJournalState(
      captureId: captureId,
      installation: {
        'platform': runtime.platform,
        if (isSafeToken(info.packageName)) 'application_id': info.packageName,
      },
      producerVersion: captureProducerRevision,
      runtimeVersions: {
        'app_version': runtime.appVersion,
        'sdk_version': runtime.sdkVersion,
        'core_version': runtime.coreVersion,
        'schema_physical': observed.schema.physical,
        'schema_public': observed.schema.public,
        'profile_id': profile.profileId,
        'profile_evidence_digest': profile.evidenceDigest,
      },
      storeVersions: Map.of(captureStoreFormats),
      mode: mode,
      stage: CaptureStage.preparing,
      gateGeneration: null,
      priorSyncIntent: PriorSyncIntent.unknown,
      inventory: const [],
      files: const {},
      manifestSha256: null,
    );
  }

  /// Admission never closed: put back what the journal said before, so a
  /// refused attempt leaves no claim behind. Only while the journal still
  /// names this attempt: another attempt that wrote it meanwhile (a racing
  /// process) is never rolled back.
  Future<void> _restoreJournal(
      CaptureJournalState? previous, CaptureJournalState refused) async {
    try {
      final current = await _journal.read();
      if (current == null || current.captureId != refused.captureId) return;
      await _journal.write(previous ?? refused.copyWith(stage: CaptureStage.resumed));
    } catch (_) {
      // The journal then names an attempt that holds nothing; recovery sees
      // an open gate and needs only the explicit decision.
    }
  }

  Future<CertifiedCapture> _boundary(
    _Attempt attempt,
    CaptureJournalState state,
    CaptureMode mode,
    CaptureSourceBindings sources,
    QualifiedProfile profile,
    NativeSyncQualification qualification,
  ) async {
    final transport = attempt.transport;
    final hooks = attempt.hooks;
    final preparation = attempt.preparation!;
    final captureId = attempt.captureId;
    final elapsed = Stopwatch()..start();
    Duration remaining() {
      final left = drainTimeout - elapsed.elapsed;
      return left > Duration.zero ? left : Duration.zero;
    }

    Future<CaptureJournalState> persist(CaptureJournalState next) async {
      try {
        return await _persist(next);
      } on _Interrupted {
        rethrow;
      } catch (_) {
        throw const _Stop('journal_write_failed', abandon: false);
      }
    }

    final prior = transport.priorPolicyFor(captureId);
    state = await persist(state.copyWith(
      gateGeneration: preparation.generation,
      priorSyncIntent: prior == null
          ? PriorSyncIntent.unknown
          : prior
              ? PriorSyncIntent.enabled
              : PriorSyncIntent.disabled,
    ));
    await _step('admission_closed');

    // Every present raw version is kept before anything can overwrite it.
    final StartupInventory inventory;
    try {
      inventory = await inspectCaptureStartup(
          locations.source, locations.preparation,
          files: files, base: locations.source);
    } catch (_) {
      throw const _Stop('inventory_failed');
    }
    if (!inventory.complete) {
      throw _Stop('inventory_incomplete',
          detail: inventory.errors.map((e) => e.role).toSet().join(','));
    }
    state = await persist(state.copyWith(inventory: inventory.entries));
    await _step('inventory');

    try {
      await hooks.commitEditorInput(preparation);
    } on SessionCaptureException catch (e) {
      throw _Stop(e.code, detail: e.detail, remediation: 'save_or_cancel_forms');
    } catch (_) {
      throw const _Stop('editor_commit_failed');
    }
    await _step('editor_committed');

    // 2. Local work: settle, observe, flush once, cross-check.
    final RawFileObservation settled;
    final RawReplacement? flush;
    try {
      await hooks.quiesce(preparation).timeout(remaining());
      settled = await readRawFile(
          File(p.join(locations.source.path, DraftStore.fileName)));
      await hooks.drainAndFlush(preparation).timeout(remaining());
      flush = hooks.lastFlush;
    } on TimeoutException {
      throw const _Stop('local_drain_timeout');
    } on SessionCaptureException catch (e) {
      throw _Stop(e.code,
          detail: e.detail,
          remediation: e.code == 'persistence_failed'
              ? 'retry_after_resume'
              : 'save_or_cancel_forms');
    } on PreservationException catch (e) {
      throw _Stop('preservation_failed', detail: e.code);
    } catch (_) {
      throw const _Stop('flush_failed');
    }
    if (flush != null &&
        (flush.before.status != settled.status ||
            flush.before.sha256 != settled.sha256)) {
      throw const _Stop('flush_before_mismatch');
    }
    await _step('local_drained');

    // 3. Network and background work.
    final TransportPauseEvidence evidence;
    try {
      evidence = await transport.pauseAndDrain(preparation, timeout: remaining());
    } on SourceGateException catch (e) {
      throw _Stop('transport_${e.code}');
    }
    attempt.evidence = evidence;
    await _step('network_drained');
    if (!evidence.uploadPaused) {
      throw _Stop(evidence.blockedCode ?? 'upload_drain_timeout');
    }
    if (!evidence.downloadPaused || evidence.nativeSync == null) {
      throw _Stop(evidence.blockedCode ?? 'native_sync_unattested');
    }
    state = await persist(state.copyWith(
      stage: CaptureStage.held,
      priorSyncIntent: evidence.previouslyConnected
          ? PriorSyncIntent.enabled
          : PriorSyncIntent.disabled,
    ));

    // 4. Hold.
    final SourceHold hold;
    try {
      hold = await gate.drain(preparation, timeout: remaining());
    } on SourceGateException catch (e) {
      if (e.code == 'recovery_required') {
        // A process died with admitted work in flight: never acknowledged
        // or released implicitly.
        throw const _Stop('recovery_required', abandon: false);
      }
      throw _Stop(e.code);
    }
    await _step('hold_acquired');
    try {
      await transport.reloadPreferences();
    } catch (_) {
      throw const _Stop('preferences_reload_failed');
    }
    await _step('preferences_reloaded');

    // 5. Read, between two checks of the live hold and the evidence.
    final holdBefore = await _holdStatus(hold);
    if (holdBefore != 'held') throw _Stop('hold_lost', detail: holdBefore);
    if (!_evidenceCurrent(
        sources, transport, evidence, preparation, profile, qualification)) {
      throw const _Stop('native_sync_stale');
    }
    await _step('native_current_before_read');
    state = await persist(state.copyWith(stage: CaptureStage.copying));

    CapturePayload payload;
    try {
      payload = await readCapturePayload(
        sources.database,
        hold,
        profile,
        inventory,
        source: locations.source,
        preservation: _preservation,
        replacements: [if (flush != null) flush],
        transport: evidence,
        readPreferences: sources.readPreferences,
        reviewedUnknownPreferences: sources.reviewedUnknownPreferences,
      );
    } catch (_) {
      throw const _Stop('read_failed');
    }
    await _step('read');
    final holdAfter = await _holdStatus(hold);
    if (holdAfter != 'held') throw _Stop('hold_lost', detail: holdAfter);
    if (!_evidenceCurrent(
        sources, transport, evidence, preparation, profile, qualification)) {
      throw const _Stop('native_sync_stale');
    }
    await _step('native_current_after_read');

    // Only what was actually proven above; every flag is true here because
    // anything less stopped the attempt.
    const boundary = CaptureBoundary(
      sqlSnapshot: 'single_read_transaction',
      mutationPaused: true,
      uploadPaused: true,
      downloadPaused: true,
      editorInputCommitted: true,
      autosaveFlushed: true,
    );
    payload = _withCoordinatorEvidence(payload, {
      'mode': state.mode.wire,
      'gate_generation': preparation.generation,
      'hold_before_read': holdBefore,
      'hold_after_read': holdAfter,
      'native_sync_current_before_read': true,
      'native_sync_current_after_read': true,
      'editor_input_committed': true,
      'autosave_flushed': true,
      'final_flush': flush != null,
      'flush_before_matches_settled': flush == null ? null : true,
      'preparation_inventory_complete': inventory.complete,
      'prior_sync_policy':
          evidence.previouslyConnected ? 'connected' : 'disconnected',
      'uncertain_upload_count': evidence.uncertainUploads.length,
    });

    // 6. Seal.
    final manifest = captureManifestFor(payload,
        capturedAt: _clock(), boundary: boundary);
    final staging = _stagingOf(captureId);
    try {
      await files.ensureDirectory(locations.staging, base: locations.source);
      final available = await files.availableBytes(locations.staging);
      final needed = _artifactBytes(manifest) + captureSpaceMargin;
      if (available < needed) {
        throw _Stop('insufficient_space',
            detail: 'needed_$needed', remediation: 'free_space');
      }
      await files.ensureDirectory(staging, base: locations.source);
    } on _Stop {
      rethrow;
    } on SourceGateException catch (e) {
      throw _Stop('staging_unavailable', detail: e.code);
    }
    final SealedCapture sealed;
    try {
      sealed = await writeAndVerifyCapture(staging, payload, manifest);
    } on CaptureArtifactException catch (e) {
      throw _Stop('staging_failed', detail: e.code);
    } catch (_) {
      throw const _Stop('staging_failed');
    }
    await _step('staged');
    if (!sealed.usable || !manifest.boundary.attested) {
      throw _Stop('capture_unusable',
          detail: sealed.blockers.join(','),
          exploratory: ExploratoryCapture._(
            captureId: captureId,
            manifestSha256: sealed.manifestSha256,
            directory: staging,
            blockers: sealed.blockers,
          ));
    }
    state = await persist(state.copyWith(
      stage: CaptureStage.sealed,
      files: _journalFiles(sealed.files),
      manifestSha256: sealed.manifestSha256,
    ));

    // From here on the hold is kept on any failure.
    final holdAtPublish = await _holdStatus(hold);
    if (holdAtPublish != 'held') {
      throw _Stop('hold_lost', detail: holdAtPublish, abandon: false);
    }
    final finalDirectory = _finalOf(captureId);
    final code = await _publish(staging, finalDirectory);
    if (code != null) throw _Stop(code, abandon: false);
    await _step('published_renamed');
    state = await persist(state.copyWith(stage: CaptureStage.published));
    final certified = await _certify(state, finalDirectory);
    if (certified == null) {
      throw const _Stop('published_divergence', abandon: false);
    }
    await _step('final_verified');

    switch (mode) {
      case CaptureMode.localHold:
        await persist(state.copyWith(stage: CaptureStage.localHold));
        // Source and transport stay closed, callbacks frozen.
        return certified;
      case CaptureMode.rehearsal:
        state = await persist(state.copyWith(stage: CaptureStage.resumeAllowed));
        try {
          await gate.release(hold,
              decisionDigest: _decision(state, 'rehearsal_resume'));
        } on SourceGateException catch (e) {
          throw _Stop('release_failed', detail: e.code, abandon: false);
        }
        await _step('released');
        await persist(state.copyWith(stage: CaptureStage.resumed));
        await _resumeInProcess(attempt);
        return certified;
    }
  }

  /// Turns an orderly stop into the public refusal, releasing the source by
  /// a recorded decision when the stop allows it.
  Future<CaptureBlocked> _stopped(_Attempt attempt, _Stop stop) async {
    var decision = CaptureDecision.resumeOriginal;
    CaptureStage? stage;
    try {
      stage = (await _journal.read())?.stage;
    } catch (_) {
      stage = null;
    }
    if (stop.abandon) {
      final released = await _abandon(attempt, stop.code);
      if (released != null) {
        stage = released;
        if (released == CaptureStage.resumed) decision = CaptureDecision.none;
      }
    }
    return CaptureBlocked(
      stop.code,
      detail: stop.detail,
      captureId: attempt.captureId,
      stage: stage,
      decision: decision,
      remediation: stop.remediation,
      exploratory: stop.exploratory,
    );
  }

  /// Releases an attempt that never reached `sealed`: completes the
  /// preparation ticket, durably records the decision, releases the gate,
  /// marks it resumed and resumes callbacks and the prior sync policy.
  /// Returns the stage it reached; null if nothing could be recorded.
  Future<CaptureStage?> _abandon(_Attempt attempt, String code) async {
    final preparation = attempt.preparation!;
    CaptureJournalState? state;
    try {
      state = await _journal.read();
    } catch (_) {
      return null;
    }
    if (state == null || state.captureId != attempt.captureId) return null;
    try {
      await gate.completePreparation(preparation);
    } catch (_) {
      // A drain already completed it, or the gate failed: release still
      // reopens admission; recovery reports anything left.
    }
    state = state.copyWith(stage: CaptureStage.resumeAllowed);
    try {
      await _persist(state);
    } on _Interrupted {
      rethrow;
    } catch (_) {
      return null;
    }
    if (await _releaseRecorded(state, _decision(state, 'abandon:$code')) != null) {
      return CaptureStage.resumeAllowed;
    }
    await _step('released');
    try {
      await _persist(state.copyWith(stage: CaptureStage.resumed));
    } on _Interrupted {
      rethrow;
    } catch (_) {
      // Recovery completes the recorded resumption.
    }
    await _resumeInProcess(attempt);
    return CaptureStage.resumed;
  }

  /// Ends the in-process freeze and reopens transport admission with the
  /// prior sync policy only (sync is reconnected only if it was connected
  /// before and this capture disconnected it).
  Future<void> _resumeInProcess(_Attempt attempt) async {
    if (identical(_attempt, attempt)) _attempt = null;
    final preparation = attempt.preparation;
    if (preparation == null) return;
    attempt.hooks.resumeCallbacks(DateTime.now(), generation: preparation.generation);
    try {
      await attempt.transport.resumePriorPolicy(
          attempt.evidence?.previouslyConnected ?? false,
          captureId: attempt.captureId);
    } catch (_) {
      // A failed reconnect is an ordinary sync error the app reports; it
      // does not change what was captured or released.
    }
  }

  Future<String> _holdStatus(SourceHold hold) async {
    try {
      return await gate.holdStatus(hold);
    } on SourceGateException catch (e) {
      return e.code;
    }
  }

  /// Whether [evidence] is native evidence current for exactly this
  /// database, connection epoch, capture, gate generation, qualified profile
  /// and registered method, as a production adapter the coordinator builds
  /// itself judges it. The transport's own [CaptureTransport.isCurrent] is
  /// not consulted: a transport is supplied by the caller and could
  /// override it.
  bool _evidenceCurrent(
    CaptureSourceBindings sources,
    CaptureTransport transport,
    TransportPauseEvidence evidence,
    SourcePreparation preparation,
    QualifiedProfile profile,
    NativeSyncQualification qualification,
  ) {
    final native = evidence.nativeSync;
    return native != null &&
        evidence.downloadPaused &&
        native.disconnectCompleted &&
        native.nativeApplyDrained &&
        identical(transport.database, sources.database) &&
        transport.profile.evidenceDigest == profile.evidenceDigest &&
        native.captureId == preparation.captureId &&
        native.gateGeneration == preparation.generation &&
        native.profileEvidenceDigest == profile.evidenceDigest &&
        native.methodId == qualification.methodId &&
        native.qualificationEvidenceDigest ==
            qualification.qualificationEvidenceDigest &&
        // Verified here, not by the (overridable) transport: a production
        // adapter for the registered qualification accepts only evidence
        // a production adapter observed, for this database instance and
        // its current connection epoch. Test-seam evidence never passes.
        NativeSyncQuiescence(qualification: qualification).isCurrent(
          native,
          sources.database,
          profile,
          captureId: preparation.captureId,
          gateGeneration: preparation.generation,
        );
  }

  static CapturePayload _withCoordinatorEvidence(
          CapturePayload payload, Map<String, Object?> coordinator) =>
      CapturePayload(
        captureId: payload.captureId,
        generation: payload.generation,
        appVersion: payload.appVersion,
        platform: payload.platform,
        syncHistory: payload.syncHistory,
        sql: payload.sql,
        queue: payload.queue,
        draft: payload.draft,
        lastFinished: payload.lastFinished,
        preferences: payload.preferences,
        opaque: payload.opaque,
        exclusions: payload.exclusions,
        evidence: {...payload.evidence, 'coordinator': coordinator},
        blockers: payload.blockers,
      );

  static int _artifactBytes(CaptureManifest manifest) {
    var total = manifest.encode().length;
    for (final s in manifest.stores) {
      total += s.bytes ?? 0;
    }
    return total;
  }

  static Map<String, journal.CaptureFileDigest> _journalFiles(
          Map<String, CaptureFileDigest> files) =>
      {
        for (final e in files.entries)
          e.key: journal.CaptureFileDigest(
              sha256: e.value.sha256, length: e.value.bytes),
      };

  /// Publishes [staging] as [finalDirectory] without replacing anything;
  /// returns null or a safe failure code.
  Future<String?> _publish(Directory staging, Directory finalDirectory) async {
    try {
      await files.ensureDirectory(locations.captures, base: locations.source);
      await files.publishNoReplace(staging, finalDirectory);
      return null;
    } on SourceGateException catch (e) {
      return e.code == 'destination_exists' ? 'destination_conflict' : 'publish_failed';
    }
  }

  /// Fully re-verifies [directory] from disk against what [state]
  /// recorded; the certified handoff, or null on any difference.
  Future<CertifiedCapture?> _certify(
      CaptureJournalState state, Directory directory) async {
    final verified = await _verify(state, directory);
    if (verified == null) return null;
    final digest = state.runtimeVersions['profile_evidence_digest'];
    if (!verified.manifest.boundary.attested ||
        verified.manifest.boundary.sqlSnapshot != 'single_read_transaction' ||
        digest == null ||
        !qualifiedSourceProfiles.any((q) => q.evidenceDigest == digest)) {
      return null;
    }
    return CertifiedCapture._(
      captureId: state.captureId,
      manifestSha256: verified.manifestSha256,
      directory: directory,
      profileEvidenceDigest: digest,
    );
  }

  /// [directory] verified strictly and matching [state]'s capture id,
  /// manifest digest and every recorded file digest; null otherwise.
  Future<VerifiedCapture?> _verify(
      CaptureJournalState state, Directory directory) async {
    final VerifiedCapture verified;
    try {
      verified = await verifyCaptureDirectory(directory);
    } catch (_) {
      return null;
    }
    final recorded = {
      for (final e in state.files.entries) e.key: (e.value.length, e.value.sha256),
    };
    final found = {
      for (final e in verified.files.entries) e.key: (e.value.bytes, e.value.sha256),
    };
    if (state.manifestSha256 == null ||
        verified.manifestSha256 != state.manifestSha256 ||
        verified.manifest.captureId != state.captureId ||
        !mapEquals(recorded, found)) {
      return null;
    }
    return verified;
  }

  /// Digest of an automatic coordinator decision about [state].
  static String _decision(CaptureJournalState state, String decision) =>
      crypto.sha256
          .convert(utf8.encode(jsonEncode({
            'capture_id': state.captureId,
            'decision': decision,
            'gate_generation': state.gateGeneration,
            'manifest_sha256': state.manifestSha256,
          })))
          .toString();

  // ---------------------------------------------------------------------
  // Recovery

  /// Inspects the journal, the gate and the outputs after a restart (or a
  /// blocked attempt) and does only what a durable record already decided:
  /// finishes a recorded resumption, finishes a `sealed` publication whose
  /// staging bytes match every recorded hash while the hold stayed
  /// recorded, adopts a final directory a crash left unrecorded after full
  /// verification, and moves a published local hold to `local_hold`. It
  /// never releases a hold, never overwrites recorded hashes or an existing
  /// destination, and never certifies an interrupted attempt.
  Future<CaptureRecovery> recover() async {
    if (_running.contains(_key)) {
      return const CaptureRecovery(code: 'capture_running');
    }
    final CaptureJournalState? state;
    try {
      state = await _journal.read();
    } on CaptureJournalException catch (e) {
      return CaptureRecovery(code: e.code, decision: CaptureDecision.ownerReview);
    } catch (_) {
      return const CaptureRecovery(
          code: 'journal_unreadable', decision: CaptureDecision.ownerReview);
    }
    if (state == null) {
      final probe = await probeSourceGate(gate, base: locations.source, files: files);
      return switch (probe) {
        'open' => const CaptureRecovery(code: 'none'),
        'platform_unavailable' || 'unsupported' => CaptureRecovery(code: probe),
        'mismatch' => const CaptureRecovery(
            code: 'gate_without_journal', decision: CaptureDecision.ownerReview),
        _ => CaptureRecovery(code: 'gate_$probe', decision: CaptureDecision.ownerReview),
      };
    }
    try {
      return await _recover(state);
    } on _Interrupted catch (e) {
      Error.throwWithStackTrace(e.error, e.stack);
    }
  }

  Future<CaptureRecovery> _recover(CaptureJournalState state) async {
    CaptureRecovery result(String code, {CertifiedCapture? capture, CaptureStage? stage, CaptureDecision decision = CaptureDecision.resumeOriginal}) =>
        CaptureRecovery(
          code: code,
          stage: stage ?? state.stage,
          captureId: state.captureId,
          capture: capture,
          decision: decision,
        );

    switch (state.stage) {
      case CaptureStage.preparing:
      case CaptureStage.held:
      case CaptureStage.copying:
        // Acknowledgements lived in the lost process: nothing about this
        // attempt is attested any more.
        return result('capture_interrupted');
      case CaptureStage.sealed:
        return _recoverSealed(state, result);
      case CaptureStage.published:
        return _recoverPublished(state, result);
      case CaptureStage.localHold:
        final certified = await _certify(state, _finalOf(state.captureId));
        if (certified == null) return result('published_divergence');
        return result('local_hold', capture: certified);
      case CaptureStage.resumeAllowed:
        final code = await _completeResume(state, _decision(state, 'recorded_resume'));
        if (code != null) return result(code);
        return CaptureRecovery(
          code: 'resumed',
          stage: CaptureStage.resumed,
          captureId: state.captureId,
          capture: await _publishedCapture(state),
        );
      case CaptureStage.resumed:
        final probe = await probeSourceGate(gate, base: locations.source, files: files);
        if (probe != 'open' && probe != 'platform_unavailable' && probe != 'unsupported') {
          return result('gate_$probe', decision: CaptureDecision.ownerReview);
        }
        return result('resumed',
            capture: await _publishedCapture(state), decision: CaptureDecision.none);
    }
  }

  Future<CertifiedCapture?> _publishedCapture(CaptureJournalState state) async {
    if (state.manifestSha256 == null) return null;
    final dir = _finalOf(state.captureId);
    if (FileSystemEntity.typeSync(dir.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    return _certify(state, dir);
  }

  Future<CaptureRecovery> _recoverSealed(
    CaptureJournalState state,
    CaptureRecovery Function(String,
            {CertifiedCapture? capture, CaptureStage? stage, CaptureDecision decision})
        result,
  ) async {
    final staging = _stagingOf(state.captureId);
    final finalDirectory = _finalOf(state.captureId);
    if (FileSystemEntity.typeSync(finalDirectory.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      // A crash after the rename, before `published` was recorded: adopt
      // only a destination that verifies in full against the record.
      if (await _certify(state, finalDirectory) == null) {
        return result('destination_conflict');
      }
      return _recoverPublished(
          await _persist(state.copyWith(stage: CaptureStage.published)), result);
    }
    if (await _verify(state, staging) == null) return result('sealed_divergence');
    final gen = state.gateGeneration;
    final status = gen == null
        ? 'mismatch'
        : await _holdStatus(SourceHold(state.captureId, gen));
    // `held` in this process, `recorded` after a restart: no admission was
    // possible since the hold was taken.
    if (status != 'held' && status != 'recorded') return result('hold_lost');
    final code = await _publish(staging, finalDirectory);
    if (code != null) return result(code);
    await _step('published_renamed');
    return _recoverPublished(
        await _persist(state.copyWith(stage: CaptureStage.published)), result);
  }

  Future<CaptureRecovery> _recoverPublished(
    CaptureJournalState state,
    CaptureRecovery Function(String,
            {CertifiedCapture? capture, CaptureStage? stage, CaptureDecision decision})
        result,
  ) async {
    final certified = await _certify(state, _finalOf(state.captureId));
    if (certified == null) {
      return result('published_divergence', stage: state.stage);
    }
    if (state.mode == CaptureMode.localHold) {
      // The safe direction: the requested hold is recorded, never released.
      await _persist(state.copyWith(stage: CaptureStage.localHold));
      return result('local_hold', capture: certified, stage: CaptureStage.localHold);
    }
    return result('awaiting_resume_decision',
        capture: certified, stage: CaptureStage.published);
  }

  /// Completes a recorded resumption: releases the gate if it still holds
  /// this capture, then records `resumed`. Returns null or a safe code.
  Future<String?> _completeResume(CaptureJournalState state, String decision) async {
    final code = await _releaseRecorded(state, decision);
    if (code != null) return code;
    await _step('released');
    try {
      await _persist(state.copyWith(stage: CaptureStage.resumed));
    } on _Interrupted {
      rethrow;
    } catch (_) {
      return 'journal_write_failed';
    }
    final attempt = _attempt;
    if (attempt != null && attempt.captureId == state.captureId) {
      await _resumeInProcess(attempt);
    }
    return null;
  }

  /// Releases whatever the gate records for [state]'s capture; null when
  /// it is released (or nothing was recorded), else a safe code.
  Future<String?> _releaseRecorded(CaptureJournalState state, String decision) async {
    final probe = await probeSourceGate(gate, base: locations.source, files: files);
    if (probe == 'open') return null;
    if (probe != 'mismatch') return 'gate_$probe';
    final gen = state.gateGeneration ?? await _findGeneration(state.captureId);
    if (gen == null) return 'gate_generation_unknown';
    final status = await _holdStatus(SourceHold(state.captureId, gen));
    if (status == 'open') return null;
    if (status != 'held' && status != 'recorded' && status != 'preparing') {
      // Another capture is recorded: not ours to release.
      return 'gate_$status';
    }
    try {
      await gate.release(SourceHold(state.captureId, gen), decisionDigest: decision);
      return null;
    } on SourceGateException catch (e) {
      return 'release_${e.code}';
    }
  }

  /// The generation the gate records for [captureId], when the journal was
  /// written before admission closed and the process died before it could
  /// record the generation. Generations count captures on this device.
  Future<int?> _findGeneration(String captureId) async {
    for (var gen = 1; gen <= 4096; gen++) {
      final status = await _holdStatus(SourceHold(captureId, gen));
      // Only a record naming exactly this capture and generation answers
      // one of these; `open` means nothing is recorded, and any gate error
      // ends the search rather than being taken for a match.
      if (status == 'preparing' || status == 'held' || status == 'recorded') {
        return gen;
      }
      if (status != 'mismatch') return null;
    }
    return null;
  }

  /// Startup's view of [recover]: null when nothing holds startup any more,
  /// else the safe state the recovery screen shows.
  Future<CaptureRecoveryState?> recoverForStartup() async {
    final r = await recover();
    if (r.decision == CaptureDecision.none &&
        (r.code == 'none' || r.code == 'resumed')) {
      return null;
    }
    return CaptureRecoveryState(
      code: r.code,
      stage: r.stage?.wire,
      captureId: r.captureId,
      decision: r.decision == CaptureDecision.none ? null : r.decision.wire,
    );
  }

  // ---------------------------------------------------------------------
  // Explicit decision

  /// The explicit coordinator decision that ends [captureId]'s hold and
  /// returns the source to ordinary use: from an interrupted attempt (after
  /// acknowledging work a dead process left in flight), a `sealed` capture
  /// that could not be published, a published capture awaiting the
  /// decision, or a local hold. It records `resume_allowed`, releases the
  /// gate with [decisionDigest], records `resumed`, and in this process
  /// resumes callbacks and the prior sync policy. Recorded hashes and every
  /// output are kept; an interrupted attempt is never certified afterwards
  /// and a new capture gets a new id.
  ///
  /// Throws [CaptureBlocked] (`decision_invalid`, `capture_running`,
  /// `capture_mismatch`, a `journal_*` or gate code) and changes nothing
  /// it has not durably recorded.
  Future<void> resumeOriginal({
    required String captureId,
    required String decisionDigest,
  }) async {
    if (!isSha256Hex(decisionDigest)) {
      throw const CaptureBlocked('decision_invalid');
    }
    if (_running.contains(_key)) throw const CaptureBlocked('capture_running');
    final CaptureJournalState? state;
    try {
      state = await _journal.read();
    } on CaptureJournalException catch (e) {
      throw CaptureBlocked(e.code, decision: CaptureDecision.ownerReview);
    }
    if (state == null || state.captureId != captureId) {
      throw const CaptureBlocked('capture_mismatch');
    }
    try {
      await _resumeOriginal(state, decisionDigest);
    } on _Interrupted catch (e) {
      Error.throwWithStackTrace(e.error, e.stack);
    }
  }

  Future<void> _resumeOriginal(CaptureJournalState state, String decisionDigest) async {
    if (state.stage == CaptureStage.resumed) {
      final attempt = _attempt;
      if (attempt != null && attempt.captureId == state.captureId) {
        await _resumeInProcess(attempt);
      }
      return;
    }
    final interrupted = state.stage == CaptureStage.preparing ||
        state.stage == CaptureStage.held ||
        state.stage == CaptureStage.copying;
    if (interrupted) {
      try {
        await gate.acknowledgeInterruptedWork(decisionDigest: decisionDigest);
      } on SourceGateException catch (e) {
        if (e.code != 'platform_unavailable') {
          throw CaptureBlocked('gate_${e.code}',
              captureId: state.captureId,
              stage: state.stage,
              decision: CaptureDecision.resumeOriginal);
        }
      }
      final attempt = _attempt;
      if (attempt != null && attempt.captureId == state.captureId) {
        try {
          await gate.completePreparation(attempt.preparation!);
        } catch (_) {
          // Already completed by its drain.
        }
      }
    }
    var next = state;
    if (state.stage != CaptureStage.resumeAllowed) {
      try {
        next = await _persist(state.copyWith(stage: CaptureStage.resumeAllowed));
      } on _Interrupted {
        rethrow;
      } catch (_) {
        throw CaptureBlocked('journal_write_failed',
            captureId: state.captureId,
            stage: state.stage,
            decision: CaptureDecision.resumeOriginal);
      }
    }
    final code = await _completeResume(next, decisionDigest);
    if (code != null) {
      throw CaptureBlocked(code,
          captureId: state.captureId,
          stage: CaptureStage.resumeAllowed,
          decision: CaptureDecision.resumeOriginal);
    }
  }
}
