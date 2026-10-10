import 'dart:async';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:powersync/powersync.dart' show PowerSyncDatabase;
import 'package:shared_preferences/shared_preferences.dart';

import 'capture_profile.dart';
import 'native_sync_quiescence.dart';
import 'source_write_gate.dart';

/// A connector upload whose outcome is unknown: its request may have reached
/// the server (a lost response, a cancellation, a request still out when the
/// capture's bounded drain ended, or a completion that failed after the
/// server answered). It is never treated as accepted or rejected. Carries
/// only PowerSync's numeric queue ids and a safe code: no row contents, no
/// tokens, no URLs.
@immutable
class UncertainUpload {
  const UncertainUpload({
    required this.transactionId,
    required this.crudIds,
    required this.code,
  });

  /// `ps_crud.tx_id` of the uploaded transaction, when it had one.
  final int? transactionId;

  /// `ps_crud.id` of every operation in the upload, in queue order.
  final List<int> crudIds;

  /// Why it is uncertain: the failure's type name (for example
  /// `ClientException`, `TimeoutException`), `complete_failed` (the server
  /// accepted, the local completion failed) or `in_flight`.
  final String code;

  String get disposition => 'uncertain';

  Map<String, Object?> toSafeJson() => {
        'code': code,
        'crud_ids': crudIds,
        'disposition': disposition,
        'transaction_id': transactionId,
      };
}

/// What one admitted connector upload reports about itself, so its outcome
/// can be classified without looking at row contents.
class UploadAttempt {
  UploadAttempt._();

  int? _transactionId;
  List<int> _crudIds = const [];
  bool _sent = false;
  int? _status;
  bool _completed = false;

  bool get _hasBatch => _crudIds.isNotEmpty;

  /// The batch taken from the queue.
  void batch(int? transactionId, List<int> crudIds) {
    _transactionId = transactionId;
    _crudIds = List.unmodifiable(crudIds);
  }

  /// The request is about to go out: from here on the server may accept it.
  void requestSent() => _sent = true;

  /// The server answered with [statusCode].
  void responseReceived(int statusCode) => _status = statusCode;

  /// The batch was completed (removed from the queue) after acceptance.
  void completed() => _completed = true;

  UncertainUpload _uncertain(String code) => UncertainUpload(
      transactionId: _transactionId, crudIds: _crudIds, code: code);
}

/// Process-wide admission of transport work: connector uploads (through
/// their queue completion), credential refreshes, connection changes,
/// account sign-out and OTA installs. A capture closes it while it drains
/// the transport; it reopens only through [CaptureTransport.resumePriorPolicy].
///
/// Where the native gate exists it refuses the same work while admission is
/// closed; this admission also covers builds and tests without a gate, and
/// tracks the uploads a capture must await and the uncertain ones it must
/// report.
class TransportAdmission {
  TransportAdmission._();

  static final instance = TransportAdmission._();

  String? _closedFor;
  final _inFlight = <UploadAttempt, Future<void>>{};

  /// Uncertain uploads by `ps_crud.tx_id` (or first crud id), until a later
  /// upload of the same batch completes.
  final _uncertain = <int, UncertainUpload>{};

  bool get isOpen => _closedFor == null;

  /// The app's sync policy as its own connection changes left it: true after
  /// a successful connect, false after a disconnect or clear. Recorded by
  /// `changeSyncConnection`, never derived from SDK status (which reads
  /// "not connected" while an opted-in loop is retrying after an error).
  bool get syncRequested => _syncRequested;
  bool _syncRequested = false;

  /// Records that the app's last successful connection change [connected]
  /// or disconnected sync.
  void recordConnectionChange({required bool connected}) =>
      _syncRequested = connected;

  /// Throws `admission_closed` (naming [operation]) while a capture has
  /// transport admission closed.
  void ensureOpen(String operation) {
    if (!isOpen) throw SourceGateException('admission_closed', operation);
  }

  /// Runs one connector upload as an admitted transport operation and
  /// records its outcome. Refused (`admission_closed`) before [body] runs
  /// while admission is closed. Errors of [body] propagate unchanged.
  Future<T> runUpload<T>(Future<T> Function(UploadAttempt attempt) body) {
    ensureOpen('sync.upload');
    final attempt = UploadAttempt._();
    final run = Future.sync(() => body(attempt));
    final settled = run.then<void>((_) => _settle(attempt, null),
        onError: (Object e) => _settle(attempt, e));
    _inFlight[attempt] = settled;
    settled.whenComplete(() => _inFlight.remove(attempt));
    return run;
  }

  void _settle(UploadAttempt attempt, Object? error) {
    if (!attempt._hasBatch) return;
    final key = attempt._transactionId ?? attempt._crudIds.first;
    if (attempt._completed) {
      // This batch left the queue: any earlier uncertainty about it is moot
      // for what the queue still holds.
      _uncertain.remove(key);
      return;
    }
    if (error == null || !attempt._sent) return;
    final status = attempt._status;
    if (status == null) {
      // The request went out and no answer arrived.
      _uncertain[key] = attempt._uncertain(_safeCode(error));
    } else if (status >= 200 && status < 300) {
      // Accepted by the server, but the local completion failed.
      _uncertain[key] = attempt._uncertain('complete_failed');
    }
    // Any other answer says "not accepted": the batch stays queued and is
    // retried; an earlier uncertainty about it is kept.
  }

  void _close(String captureId) {
    final closed = _closedFor;
    if (closed != null && closed != captureId) {
      throw const SourceGateException('capture_in_progress');
    }
    _closedFor = captureId;
  }

  /// Reopens admission only if it is closed for [captureId]; returns
  /// whether it did. A late or repeated resume of another capture changes
  /// nothing.
  bool _openFor(String captureId) {
    if (_closedFor != captureId) return false;
    _closedFor = null;
    return true;
  }

  /// Waits until every admitted upload has finished, or [timeout] passed.
  Future<bool> _drain(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_inFlight.isNotEmpty) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return false;
      try {
        await Future.wait(_inFlight.values.toList()).timeout(left);
      } on TimeoutException {
        return false;
      }
    }
    return true;
  }

  List<UncertainUpload> _report({required bool includeInFlight}) => [
        ..._uncertain.values,
        if (includeInFlight)
          for (final a in _inFlight.keys)
            if (a._hasBatch && a._sent) a._uncertain('in_flight'),
      ];

  @visibleForTesting
  void resetForTesting() {
    _closedFor = null;
    _syncRequested = false;
    _inFlight.clear();
    _uncertain.clear();
  }

  static String _safeCode(Object e) => switch (e) {
        SourceGateException(:final code) => 'gate_$code',
        _ => e.runtimeType.toString(),
      };
}

/// What a capture's transport drain established, for one capture attempt.
///
/// [downloadPaused] is true only with native evidence that was current for
/// this database, connection epoch, source profile, capture and gate
/// generation when the drain returned; then and only then [nativeSync] is
/// set. Anything else (no registered qualification, a timeout, a failed or
/// stale observation) leaves it false with [blockedCode] saying why.
@immutable
class TransportPauseEvidence {
  const TransportPauseEvidence({
    required this.uploadPaused,
    required this.downloadPaused,
    required this.nativeSync,
    required this.uncertainUploads,
    required this.previouslyConnected,
    this.blockedCode,
  }) : assert(downloadPaused == (nativeSync != null));

  /// Upload admission is closed and every admitted upload finished,
  /// through its queue completion or its failure.
  final bool uploadPaused;

  /// The sync connection is disconnected without clearing and native apply
  /// was proven drained by a registered qualification.
  final bool downloadPaused;

  final NativeSyncPauseEvidence? nativeSync;

  /// Uploads whose acceptance is unknown; safe ids and codes only.
  final List<UncertainUpload> uncertainUploads;

  /// The app's sync policy when this capture first closed transport
  /// admission (see [TransportAdmission.syncRequested]): the prior policy
  /// [CaptureTransport.resumePriorPolicy] restores. Never read from SDK
  /// status.
  final bool previouslyConnected;

  /// Safe code for why a pause is not attested, or null.
  final String? blockedCode;

  /// Safe, declared evidence: flags, codes, queue ids and the native
  /// method/qualification digests. No row contents, tokens or URLs.
  Map<String, Object?> toSafeJson() => {
        'blocked_code': blockedCode,
        'download_paused': downloadPaused,
        if (nativeSync case final n?)
          'native_sync': {
            'connection_epoch': n.connectionEpoch,
            'disconnect_completed': n.disconnectCompleted,
            'gate_generation': n.gateGeneration,
            'method_id': n.methodId,
            'native_apply_drained': n.nativeApplyDrained,
            'qualification_evidence_digest': n.qualificationEvidenceDigest,
          },
        'previously_connected': previouslyConnected,
        'uncertain_uploads': [for (final u in uncertainUploads) u.toSafeJson()],
        'upload_paused': uploadPaused,
      };
}

/// The PowerSync transport side of a capture boundary, for the coordinator.
///
/// [pauseAndDrain] stops admission to connector uploads, credential refresh,
/// connection changes, sign-out and OTA installs, awaits every admitted
/// upload through its queue completion or failure, then asks the native
/// adapter for a non-clearing disconnect and native apply drain. It never
/// clears, completes or dequeues queued work, and never infers a pause from
/// SDK status, the queue size or the application gate.
class CaptureTransport {
  CaptureTransport({
    required this.database,
    required this.profile,
    required NativeSyncQuiescence? quiescence,
    required Future<void> Function() reconnect,
    TransportAdmission? admission,
    Future<void> Function()? reloadPreferences,
    DateTime Function()? clock,
  })  : _quiescence = quiescence,
        _reconnect = reconnect,
        _admission = admission ?? TransportAdmission.instance,
        _reloadPreferences = reloadPreferences ?? _reloadSharedPreferences,
        _clock = clock ?? DateTime.now;

  /// A transport whose download pause uses the registered native
  /// qualification for [profile], if there is one; without one no capture
  /// on [profile] can attest a download pause.
  factory CaptureTransport.forProfile({
    required PowerSyncDatabase database,
    required QualifiedProfile profile,
    required Future<void> Function() reconnect,
  }) {
    final qualification = nativeSyncQualificationFor(profile);
    return CaptureTransport(
      database: database,
      profile: profile,
      quiescence: qualification == null
          ? null
          : NativeSyncQuiescence(qualification: qualification),
      reconnect: reconnect,
    );
  }

  final PowerSyncDatabase database;
  final QualifiedProfile profile;
  final NativeSyncQuiescence? _quiescence;
  final Future<void> Function() _reconnect;
  final TransportAdmission _admission;
  final Future<void> Function() _reloadPreferences;
  final DateTime Function() _clock;

  /// Step one of a capture: closes transport admission for [captureId]
  /// synchronously, before anything is awaited (new uploads, credential
  /// fetches and refreshes, logins, connection changes, sign-out and OTA
  /// installs are refused from here on) and records the app's sync policy at
  /// that instant, then closes [gate]'s admission. If the gate close fails,
  /// transport admission is reopened for [captureId] and the error rethrown.
  /// Throws `capture_in_progress`, changing nothing, while another capture
  /// has transport admission closed.
  Future<SourcePreparation> closeAdmission(
      SourceWriteGate gate, String captureId) async {
    _hold(captureId);
    try {
      return await gate.closeAdmission(captureId);
    } catch (_) {
      if (_admission._openFor(captureId)) _priorPolicy.remove(captureId);
      rethrow;
    }
  }

  /// The app's sync policy recorded when each capture first closed
  /// transport admission.
  final _priorPolicy = <String, bool>{};

  void _hold(String captureId) {
    _admission._close(captureId);
    _priorPolicy.putIfAbsent(captureId, () => _admission.syncRequested);
  }

  /// Drains the transport for [preparation] within [timeout]. Never throws
  /// for a blocked boundary: the returned evidence says what was and was not
  /// paused. Throws `capture_in_progress` if another capture has transport
  /// admission closed. Admission stays closed afterwards, whatever the
  /// outcome, until [resumePriorPolicy].
  Future<TransportPauseEvidence> pauseAndDrain(
    SourcePreparation preparation, {
    required Duration timeout,
  }) async {
    final deadline = _clock().add(timeout);
    _hold(preparation.captureId);
    // A retried drain of the same capture reports the first recorded value.
    final previouslyConnected = _priorPolicy[preparation.captureId]!;

    TransportPauseEvidence result({
      required bool uploadPaused,
      NativeSyncPauseEvidence? native,
      String? code,
    }) =>
        TransportPauseEvidence(
          uploadPaused: uploadPaused,
          downloadPaused: native != null,
          nativeSync: native,
          uncertainUploads:
              _admission._report(includeInFlight: !uploadPaused),
          previouslyConnected: previouslyConnected,
          blockedCode: code,
        );

    // 1. Admitted uploads finish: response, completion or failure.
    if (!await _admission._drain(deadline.difference(_clock()))) {
      return result(uploadPaused: false, code: 'upload_drain_timeout');
    }

    // 2. Non-clearing disconnect and native apply drain, proven only by a
    //    registered qualification for this exact profile.
    final quiescence = _quiescence;
    if (quiescence == null) {
      return result(uploadPaused: true, code: 'native_sync_unqualified');
    }
    final remaining = deadline.difference(_clock());
    if (remaining <= Duration.zero) {
      return result(uploadPaused: true, code: 'native_sync_timeout');
    }
    final NativeSyncPauseEvidence observed;
    try {
      observed = await quiescence.disconnectAndObserve(
        database,
        profile,
        captureId: preparation.captureId,
        gateGeneration: preparation.generation,
        timeout: remaining,
      );
    } on UnsupportedCaptureProfile catch (e) {
      return result(uploadPaused: true, code: e.code);
    } on TimeoutException {
      return result(uploadPaused: true, code: 'native_sync_timeout');
    } catch (_) {
      return result(uploadPaused: true, code: 'native_sync_failed');
    }

    // 3. Background preference writers already drained by now are visible
    //    to this engine.
    try {
      await _reloadPreferences();
    } catch (_) {
      return result(uploadPaused: true, code: 'preferences_reload_failed');
    }

    if (!_current(observed, preparation)) {
      return result(uploadPaused: true, code: 'native_sync_stale');
    }
    return result(uploadPaused: true, native: observed);
  }

  /// Whether [evidence] still attests a download pause for [preparation]:
  /// the coordinator rechecks this right before it reads the source.
  bool isCurrent(
    TransportPauseEvidence evidence,
    SourcePreparation preparation,
  ) {
    final native = evidence.nativeSync;
    return evidence.downloadPaused &&
        native != null &&
        _current(native, preparation);
  }

  bool _current(NativeSyncPauseEvidence native, SourcePreparation p) {
    final quiescence = _quiescence;
    return quiescence != null &&
        native.disconnectCompleted &&
        native.nativeApplyDrained &&
        quiescence.isCurrent(native, database, profile,
            captureId: p.captureId, gateGeneration: p.generation);
  }

  /// Reloads this engine's preference cache from disk; the coordinator calls
  /// it again once the source gate has drained every engine's writers.
  Future<void> reloadPreferences() => _reloadPreferences();

  /// Reopens transport admission closed for [captureId] and restores the
  /// prior sync policy only: reconnects (through the gated connect path,
  /// after the capture released the source) when the app's policy was to be
  /// connected before the capture, and otherwise leaves sync off. Never
  /// enables sync because of a capture.
  ///
  /// Acts only while transport admission is closed for [captureId]: a late
  /// or repeated resume of an aborted or earlier capture neither reopens a
  /// later capture's admission nor reconnects, and returns false.
  Future<bool> resumePriorPolicy(
    bool previouslyConnected, {
    required String captureId,
  }) async {
    if (!_admission._openFor(captureId)) return false;
    _priorPolicy.remove(captureId);
    if (previouslyConnected) await _reconnect();
    return true;
  }

  static Future<void> _reloadSharedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
  }
}
