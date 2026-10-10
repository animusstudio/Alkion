import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import 'capture_artifact.dart';
import 'capture_coordinator.dart';
import 'capture_export.dart';
import 'capture_manifest.dart';

/// One store of a capture, as the capture screen shows it: its safe name,
/// role and status and a safe code ([note]: an exclusion reason or a
/// failure detail). Never contents, values or keys.
@immutable
class CaptureStoreLine {
  const CaptureStoreLine({
    required this.name,
    required this.role,
    required this.status,
    this.note,
  });

  final String name;
  final String role;
  final String status;
  final String? note;

  /// Bytes kept exactly as stored, which a later review interprets: raw
  /// files (a draft or finished workout, even a malformed one) and opaque
  /// preserved versions.
  bool get reviewLater =>
      status == CaptureStatus.captured &&
      (role == CaptureRole.draft ||
          role == CaptureRole.lastFinished ||
          role == CaptureRole.opaque);
}

/// A published capture as the screen shows it.
@immutable
class CaptureSummary {
  const CaptureSummary({
    required this.captureId,
    required this.manifestSha256,
    required this.capturedAt,
    required this.stores,
  });

  final String captureId;
  final String manifestSha256;
  final String capturedAt;
  final List<CaptureStoreLine> stores;
}

/// Why the last capture attempt produced no capture.
@immutable
class CaptureFailure {
  const CaptureFailure({
    required this.code,
    this.remediation,
    this.blockers = const [],
    this.keptPrivately = false,
  });

  final String code;

  /// `save_or_cancel_forms`, `free_space`, `retry_after_resume`, or null.
  final String? remediation;

  /// Safe codes that kept a sealed capture from being usable.
  final List<String> blockers;

  /// A sealed but unusable copy stays in private staging for diagnosis.
  final bool keptPrivately;
}

/// What the capture screen shows: the coordinator's recovery state, the
/// published capture it names (if any), and the last attempt's failure.
@immutable
class CaptureView {
  const CaptureView({
    required this.code,
    this.stage,
    this.captureId,
    this.decision = CaptureDecision.none,
    this.summary,
    this.failure,
  });

  /// The coordinator's safe recovery code (`none`, `resumed`, `local_hold`,
  /// `awaiting_resume_decision`, `capture_interrupted`, ...).
  final String code;
  final String? stage;
  final String? captureId;

  /// What it takes to return the source to ordinary use.
  final CaptureDecision decision;

  /// The published, re-verified capture this state names.
  final CaptureSummary? summary;
  final CaptureFailure? failure;

  /// Capture is impossible on this platform or build.
  bool get unsupported =>
      code == 'platform_unavailable' || code == 'unsupported';

  /// The source is not in ordinary use until an explicit decision.
  bool get held => decision == CaptureDecision.resumeOriginal;

  bool get interrupted => code == 'capture_interrupted';

  bool get localHold => code == 'local_hold';

  CaptureView withFailure(CaptureFailure? failure) => CaptureView(
        code: code,
        stage: stage,
        captureId: captureId,
        decision: decision,
        summary: summary,
        failure: failure,
      );
}

/// What the capture screen can ask for. Every call returns a fresh view
/// and never throws for an expected refusal.
abstract interface class CaptureBackend {
  /// A capture can be started here (the running app; not capture-first
  /// startup, which has no open sources).
  bool get canCapture;

  /// A verified capture can be copied to a chosen directory (Linux).
  bool get canExportToDirectory;

  Future<CaptureView> inspect();
  Future<CaptureView> capture(CaptureMode mode);

  /// The explicit decision that returns [captureId]'s source to ordinary
  /// use.
  Future<CaptureView> resumeOriginal(String captureId);

  Future<ExportAttempt> exportToDirectory(Directory parent,
      {ExportCancellation? cancellation});
}

/// Digest of an explicit decision the person made on this device, as the
/// coordinator records it with the gate release.
String captureDecisionDigest({
  required String captureId,
  required String decision,
  required DateTime decidedAt,
}) =>
    crypto.sha256
        .convert(utf8.encode(jsonEncode({
          'capture_id': captureId,
          'decided_at': decidedAt.toUtc().toIso8601String(),
          'decided_by': 'owner_on_device',
          'decision': decision,
        })))
        .toString();

/// [CaptureBackend] over the real coordinator.
class CoordinatorCaptureBackend implements CaptureBackend {
  CoordinatorCaptureBackend(
    this.coordinator, {
    bool? exportToDirectory,
    DateTime Function()? clock,
  })  : canExportToDirectory = exportToDirectory ?? Platform.isLinux,
        _clock = clock ?? DateTime.now;

  final CaptureCoordinator coordinator;
  final DateTime Function() _clock;

  @override
  final bool canExportToDirectory;

  @override
  bool get canCapture => coordinator.sources != null;

  /// The capture the current view names, kept for export only.
  CertifiedCapture? _certified;

  @override
  Future<CaptureView> inspect() async {
    final CaptureRecovery r;
    try {
      r = await coordinator.recover();
    } catch (_) {
      _certified = null;
      return const CaptureView(
          code: 'recovery_failed', decision: CaptureDecision.ownerReview);
    }
    _certified = r.capture;
    final id = r.captureId;
    if (r.code == 'resumed' &&
        r.capture == null &&
        id != null &&
        FileSystemEntity.typeSync(
                '${coordinator.locations.captures.path}/$id',
                followLinks: false) !=
            FileSystemEntityType.notFound) {
      // Released, and a published directory for the capture the journal
      // names exists, but it no longer certifies: never shown or copied.
      return CaptureView(
          code: 'published_divergence', stage: r.stage?.wire, captureId: id);
    }
    return CaptureView(
      code: r.code,
      stage: r.stage?.wire,
      captureId: r.captureId,
      decision: r.decision,
      summary: await _summarize(r.capture),
    );
  }

  @override
  Future<CaptureView> capture(CaptureMode mode) async {
    CaptureFailure? failure;
    try {
      await coordinator.capture(mode: mode);
    } on CaptureNotCertified catch (e) {
      failure = CaptureFailure(
        code: e.code,
        remediation: e.remediation,
        blockers: e.exploratory?.blockers ?? const [],
        keptPrivately: e.exploratory != null,
      );
    } catch (_) {
      failure = const CaptureFailure(code: 'capture_failed');
    }
    final view = await inspect();
    return view.withFailure(failure);
  }

  @override
  Future<CaptureView> resumeOriginal(String captureId) async {
    CaptureFailure? failure;
    try {
      await coordinator.resumeOriginal(
        captureId: captureId,
        decisionDigest: captureDecisionDigest(
          captureId: captureId,
          decision: 'resume_original',
          decidedAt: _clock(),
        ),
      );
    } on CaptureNotCertified catch (e) {
      failure = CaptureFailure(code: e.code);
    } catch (_) {
      failure = const CaptureFailure(code: 'resume_failed');
    }
    final view = await inspect();
    return view.withFailure(failure);
  }

  @override
  Future<ExportAttempt> exportToDirectory(Directory parent,
      {ExportCancellation? cancellation}) async {
    final certified = _certified;
    if (certified == null || !canExportToDirectory) {
      return const ExportAttempt(
        manifestSha256: '',
        transportStatus: ExportTransportStatus.failed,
        code: 'no_verified_capture',
      );
    }
    return exportCapture(
      certified,
      destination: ExportDestination.directory(parent),
      cancellation: cancellation,
      files: coordinator.files,
    );
  }

  static Future<CaptureSummary?> _summarize(CertifiedCapture? capture) async {
    if (capture == null) return null;
    try {
      final verified = await verifyCaptureDirectory(capture.directory);
      if (verified.manifestSha256 != capture.manifestSha256) return null;
      final m = verified.manifest;
      return CaptureSummary(
        captureId: capture.captureId,
        manifestSha256: capture.manifestSha256,
        capturedAt: m.capturedAt,
        stores: [
          for (final s in m.stores)
            CaptureStoreLine(
              name: s.name,
              role: s.role,
              status: s.status,
              note: s.reason ?? s.detail,
            ),
        ],
      );
    } catch (_) {
      return null;
    }
  }
}

/// What the capture screen is doing right now.
enum CaptureActivity { idle, inspecting, capturing, resuming, exporting }

/// App-wide state of the capture screen: one backend, one activity at a
/// time. Nothing here starts a capture, a release or an export on its own:
/// each is a method the person's explicit, confirmed action calls.
class CaptureService extends ChangeNotifier {
  CaptureService(this.backend, {bool Function()? hasActiveWorkout})
      : hasActiveWorkout = hasActiveWorkout ?? _none;

  final CaptureBackend backend;

  /// Whether a live workout is open, so a local hold's confirmation can
  /// warn that its changes would not be saved while held.
  final bool Function() hasActiveWorkout;

  static bool _none() => false;

  CaptureView? _view;
  CaptureView? get view => _view;

  CaptureActivity _activity = CaptureActivity.idle;
  CaptureActivity get activity => _activity;
  bool get busy => _activity != CaptureActivity.idle;

  ExportAttempt? _lastExport;
  ExportAttempt? get lastExport => _lastExport;

  ExportCancellation? _cancellation;

  Future<T> _run<T>(CaptureActivity activity, Future<T> Function() body) async {
    _activity = activity;
    notifyListeners();
    try {
      return await body();
    } finally {
      _activity = CaptureActivity.idle;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    if (busy) return;
    await _run(CaptureActivity.inspecting, () async {
      _view = await backend.inspect();
    });
  }

  /// Starts one capture in [mode] (after the person confirmed it).
  Future<void> capture(CaptureMode mode) async {
    if (busy || !backend.canCapture) return;
    await _run(CaptureActivity.capturing, () async {
      _lastExport = null;
      _view = await backend.capture(mode);
    });
  }

  /// The explicit decision to return the source to ordinary use. Returns
  /// whether the source is released.
  Future<bool> resumeOriginal() async {
    final id = _view?.captureId;
    if (busy || id == null) return false;
    return _run(CaptureActivity.resuming, () async {
      _view = await backend.resumeOriginal(id);
      return !(_view!.held);
    });
  }

  /// Copies the current capture into [path], an existing directory.
  Future<ExportAttempt?> exportTo(String path) async {
    if (busy || _view?.summary == null || !backend.canExportToDirectory) {
      return null;
    }
    final cancellation = _cancellation = ExportCancellation();
    return _run(CaptureActivity.exporting, () async {
      try {
        _lastExport = await backend.exportToDirectory(Directory(path),
            cancellation: cancellation);
      } catch (_) {
        _lastExport = ExportAttempt(
          manifestSha256: _view!.summary!.manifestSha256,
          transportStatus: ExportTransportStatus.failed,
          code: 'export_failed',
        );
      } finally {
        _cancellation = null;
      }
      if (_lastExport?.code == 'capture_changed') {
        // The private capture no longer matches its certification: show
        // what the coordinator makes of it now, never the stale success.
        _view = await backend.inspect();
      }
      return _lastExport;
    });
  }

  void cancelExport() => _cancellation?.cancel();
}
