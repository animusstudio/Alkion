import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../capture/capture_coordinator.dart' show CaptureDecision, CaptureMode;
import '../capture/capture_export.dart';
import '../capture/capture_manifest.dart' show CaptureStatus;
import '../capture/capture_service.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/card.dart';
import '../widgets/fit_label.dart';
import '../widgets/plan_form.dart';
import '../widgets/pressable.dart';
import '../widgets/w_dialog.dart';

/// Profile → Data capture: start a capture, see what it holds, decide how a
/// held or interrupted capture ends, and copy a verified capture out.
class CaptureScreen extends StatelessWidget {
  const CaptureScreen({super.key, required this.service, this.onClose});

  final CaptureService service;

  /// Back; defaults to popping this route.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final close = onClose ?? () => Navigator.of(context).maybePop();
    return Scaffold(
      backgroundColor: tokens.bg,
      body: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              color: tokens.bg,
              border: Border(bottom: BorderSide(color: tokens.line)),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  children: [
                    _BackButton(onTap: close),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FitLabel(
                        l.captureScreenTitle,
                        style: WorkoutType.display(
                            size: 19, weight: FontWeight.w700, color: tokens.text),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 48),
              children: [
                Text(l.captureIntro,
                    style: WorkoutType.body(size: 14, color: tokens.dim)),
                const SizedBox(height: 18),
                CapturePanel(service: service),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      button: true,
      label: AppLocalizations.of(context).commonBack,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                border: Border.all(color: tokens.line),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                color: tokens.surface,
              ),
              child: Icon(WIcons.back, size: 18, color: tokens.dim),
            ),
          ),
        ),
      ),
    );
  }
}

/// The capture state, decisions and export, shared by the Data capture
/// screen and the startup recovery screen.
///
/// [startup]: capture-first startup holds the app (no sources are open), so
/// no capture can start; the recovery screen above already states why and
/// shows the status, and [onResolved] runs once a decision released the
/// source (or the person asks to check again).
class CapturePanel extends StatefulWidget {
  const CapturePanel({
    super.key,
    required this.service,
    this.startup = false,
    this.onResolved,
  });

  final CaptureService service;
  final bool startup;
  final Future<void> Function()? onResolved;

  @override
  State<CapturePanel> createState() => _CapturePanelState();
}

class _CapturePanelState extends State<CapturePanel> {
  final _path = TextEditingController();

  CaptureService get _service => widget.service;

  @override
  void initState() {
    super.initState();
    // Always look again when shown: a restart or another screen may have
    // changed what the coordinator records.
    _refreshAfterFrame();
  }

  @override
  void didUpdateWidget(CapturePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) _refreshAfterFrame();
  }

  /// The service notifies its listeners synchronously when work starts, and
  /// those listeners (a provider above the app among them) must not be
  /// marked dirty while this route is still building: look after the frame.
  void _refreshAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_service.busy) _service.refresh();
    });
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<bool> _ask(String title, String message, String confirm) async {
    final ok = await showWConfirm(context,
        title: title, message: message, confirmLabel: confirm);
    return ok == true && mounted;
  }

  Future<void> _start(CaptureMode mode) async {
    final l = AppLocalizations.of(context);
    final hold = mode == CaptureMode.localHold;
    if (!await _ask(
      hold ? l.captureHoldConfirmTitle : l.captureStartConfirmTitle,
      hold
          ? _service.hasActiveWorkout()
              ? '${l.captureHoldConfirmBody}\n\n${l.captureHoldWorkoutWarning}'
              : l.captureHoldConfirmBody
          : l.captureStartConfirmBody,
      hold ? l.captureHoldConfirm : l.captureStartConfirm,
    )) {
      return;
    }
    await _service.capture(mode);
  }

  Future<void> _resume(CaptureView view, {bool thenCapture = false}) async {
    final l = AppLocalizations.of(context);
    final (title, body, confirm) = thenCapture
        ? (
            l.captureResumeAndCaptureTitle,
            l.captureResumeAndCaptureBody,
            l.captureResumeAndCaptureConfirm,
          )
        : view.localHold
            ? (l.captureReleaseTitle, l.captureReleaseBody, l.captureRelease)
            : (
                l.captureResumeTitle,
                view.interrupted
                    ? l.captureResumeInterruptedBody
                    : view.summary != null
                        ? l.captureResumeSavedBody
                        : l.captureResumeProblemBody,
                l.captureResume,
              );
    if (!await _ask(title, body, confirm)) return;
    final released = await _service.resumeOriginal();
    if (!released || !mounted) return;
    if (thenCapture) {
      await _service.capture(CaptureMode.rehearsal);
    } else if (widget.startup) {
      await widget.onResolved?.call();
    }
  }

  Future<void> _checkAgain() async {
    if (widget.startup && widget.onResolved != null) {
      await widget.onResolved!();
    } else {
      await _service.refresh();
    }
  }

  Future<void> _export(CaptureSummary summary) async {
    final l = AppLocalizations.of(context);
    final path = _path.text.trim();
    if (path.isEmpty) return;
    if (!await _ask(
      l.captureExportConfirmTitle,
      l.captureExportConfirmBody(exportDirectoryName(summary.captureId), path),
      l.captureExportConfirm,
    )) {
      return;
    }
    await _service.exportTo(path);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) => AnimatedSize(
        duration: Motion.of(context, Motion.base),
        curve: Motion.curve,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _children(context),
        ),
      ),
    );
  }

  List<Widget> _children(BuildContext context) {
    final l = AppLocalizations.of(context);
    final view = _service.view;
    final activity = _service.activity;
    const gap = SizedBox(height: 12);

    if (activity == CaptureActivity.capturing ||
        activity == CaptureActivity.resuming) {
      return [
        _Progress(
          key: const Key('capture-progress'),
          text: activity == CaptureActivity.capturing
              ? l.captureRunning
              : l.captureResuming,
        ),
      ];
    }
    if (view == null) {
      return [_Progress(text: l.captureChecking)];
    }

    final failure = view.failure;
    final out = <Widget>[];
    if (failure != null) {
      out
        ..add(_FailureCard(failure: failure, decision: view.decision))
        ..add(gap);
    }

    final state = _stateCard(context, view, showSummary: failure == null);
    if (state != null) out..add(state)..add(gap);

    final summary = failure == null ? view.summary : null;
    if (summary != null && !widget.startup) {
      out..add(_Coverage(summary: summary))..add(gap);
    }

    // The decisions that end a hold.
    if (view.held) {
      out.add(_Action(
        key: const Key('capture-resume'),
        label: view.localHold ? l.captureRelease : l.captureResume,
        primary: true,
        onTap: () => _resume(view),
      ));
      if (view.interrupted && _service.backend.canCapture) {
        out
          ..add(const SizedBox(height: 10))
          ..add(_Action(
            key: const Key('capture-resume-and-capture'),
            label: l.captureResumeAndCapture,
            onTap: () => _resume(view, thenCapture: true),
          ));
      }
      out.add(gap);
    }

    // A new capture: only where sources are open and nothing is held.
    final canStart = _service.backend.canCapture &&
        !widget.startup &&
        !view.unsupported &&
        !view.held &&
        view.decision != CaptureDecision.ownerReview;
    if (canStart) {
      out
        ..add(_Action(
          key: const Key('capture-start'),
          label: l.captureStart,
          primary: true,
          onTap: () => _start(CaptureMode.rehearsal),
        ))
        ..add(const SizedBox(height: 10))
        ..add(_Action(
          key: const Key('capture-start-hold'),
          label: l.captureStartHold,
          onTap: () => _start(CaptureMode.localHold),
        ))
        ..add(gap);
    }

    if (summary != null) {
      out
        ..add(_exportSection(context, summary))
        ..add(gap);
    }

    out.add(Align(
      alignment: Alignment.centerLeft,
      child: _Action(
        key: const Key('capture-check-again'),
        label: l.captureCheckAgain,
        quiet: true,
        onTap: _checkAgain,
      ),
    ));
    return out;
  }

  Widget? _stateCard(BuildContext context, CaptureView view,
      {required bool showSummary}) {
    final l = AppLocalizations.of(context);
    final status = widget.startup ? null : _statusOf(view);
    if (widget.startup && !view.held) return null;
    if (view.unsupported) {
      return _InfoCard(
          title: l.captureUnsupportedTitle,
          body: l.captureUnsupportedBody,
          status: status);
    }
    if (!view.held && view.code == 'published_divergence') {
      return _InfoCard(
          title: l.captureReviewTitle, body: l.captureDivergedBody, status: status);
    }
    if (view.decision == CaptureDecision.ownerReview) {
      return _InfoCard(
          title: l.captureReviewTitle, body: l.captureReviewBody, status: status);
    }
    if (view.localHold) {
      return _InfoCard(
          title: l.captureHeldTitle,
          body: l.captureHeldBody,
          status: status,
          emphasis: true);
    }
    if (view.code == 'awaiting_resume_decision') {
      return _InfoCard(
          title: l.captureAwaitingTitle,
          body: l.captureAwaitingBody,
          status: status,
          emphasis: true);
    }
    if (view.interrupted) {
      return _InfoCard(
          title: l.captureInterruptedTitle,
          body: l.captureInterruptedBody,
          status: status,
          emphasis: true);
    }
    if (view.held) {
      return _InfoCard(
          title: l.captureProblemTitle,
          body: l.captureProblemBody,
          status: status,
          emphasis: true);
    }
    if (view.summary != null && showSummary) {
      return _InfoCard(title: l.captureSavedTitle, body: l.captureSavedBody);
    }
    if (view.failure != null) return null;
    if (view.code == 'none') {
      return _InfoCard(title: l.captureIdleTitle, body: l.captureIdleBody);
    }
    if (view.code == 'resumed') {
      // Released, but the journal names no capture that can be shown: an
      // interrupted attempt that was resumed, or a newer attempt that
      // produced nothing while earlier captures stay on disk.
      return _InfoCard(
          title: l.captureNoneUsableTitle, body: l.captureNoneUsableBody);
    }
    return _InfoCard(
        title: l.captureReviewTitle, body: l.captureReviewBody, status: status);
  }

  static String _statusOf(CaptureView view) =>
      view.stage == null || view.stage == view.code
          ? view.code
          : '${view.code} · ${view.stage}';

  Widget _exportSection(BuildContext context, CaptureSummary summary) {
    final l = AppLocalizations.of(context);
    final tokens = context.tokens;
    if (!_service.backend.canExportToDirectory) {
      return _InfoCard(
          title: l.captureExportTitle, body: l.captureExportUnavailable);
    }
    final exporting = _service.activity == CaptureActivity.exporting;
    final last = _service.lastExport;
    return WCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FitLabel(l.captureExportTitle,
              maxLines: 2,
              style: WorkoutType.body(
                  size: 15, weight: FontWeight.w600, color: tokens.text)),
          const SizedBox(height: 6),
          Text(l.captureExportBody,
              style: WorkoutType.body(size: 13.5, color: tokens.dim)),
          const SizedBox(height: 14),
          Field(
            label: l.captureExportPath,
            child: TextInput(
              key: const Key('capture-export-path'),
              controller: _path,
              placeholder: l.captureExportPathHint,
            ),
          ),
          if (exporting) ...[
            _Progress(text: l.captureExportCopying),
            const SizedBox(height: 10),
            _Action(
              key: const Key('capture-export-cancel'),
              label: l.captureExportCancel,
              onTap: () async => _service.cancelExport(),
            ),
          ] else
            _Action(
              key: const Key('capture-export'),
              label: l.captureExportAction,
              primary: true,
              onTap: () => _export(summary),
            ),
          if (last != null && !exporting) ...[
            const SizedBox(height: 12),
            _ExportResult(attempt: last),
          ],
        ],
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // A static mark, not a spinner: no perpetual ticker on this screen.
    return WCard(
      child: Row(
        children: [
          Icon(WIcons.timer, size: 18, color: tokens.accentText),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: WorkoutType.body(size: 14, color: tokens.text)),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.body,
    this.status,
    this.emphasis = false,
  });

  final String title;
  final String body;
  final String? status;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    return WCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FitLabel(title,
              maxLines: 2,
              style: WorkoutType.display(
                  size: 18,
                  weight: FontWeight.w700,
                  color: emphasis ? tokens.accentText : tokens.text)),
          const SizedBox(height: 8),
          Text(body, style: WorkoutType.body(size: 14, color: tokens.text)),
          if (status != null) ...[
            const SizedBox(height: 10),
            SelectableText(l.captureRecoveryCode(status!),
                style: WorkoutType.mono(size: 11.5, color: tokens.dim)),
          ],
        ],
      ),
    );
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.failure, required this.decision});

  final CaptureFailure failure;

  /// The decision still needed after the failure.
  final CaptureDecision decision;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final resumeFailure = failure.code.startsWith('release_') ||
        failure.code == 'resume_failed' ||
        failure.code == 'decision_invalid' ||
        failure.code == 'capture_mismatch';
    final hint = switch (failure.remediation) {
      'save_or_cancel_forms' => l.captureBlockedForms,
      'free_space' => l.captureBlockedSpace,
      'retry_after_resume' => l.captureBlockedRetry,
      _ => null,
    };
    return WCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FitLabel(
              resumeFailure ? l.captureResumeFailedTitle : l.captureBlockedTitle,
              maxLines: 2,
              style: WorkoutType.display(
                  size: 18, weight: FontWeight.w700, color: tokens.danger)),
          const SizedBox(height: 8),
          Text(
              resumeFailure
                  ? l.captureResumeFailedBody
                  : decision == CaptureDecision.none
                      ? l.captureBlockedBody
                      : l.captureBlockedHeldBody,
              style: WorkoutType.body(size: 14, color: tokens.text)),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(hint, style: WorkoutType.body(size: 14, color: tokens.text)),
          ],
          if (failure.keptPrivately) ...[
            const SizedBox(height: 8),
            Text(l.captureBlockedKept,
                style: WorkoutType.body(size: 14, color: tokens.dim)),
          ],
          const SizedBox(height: 10),
          SelectableText(l.captureRecoveryCode(failure.code),
              style: WorkoutType.mono(size: 11.5, color: tokens.dim)),
          if (failure.blockers.isNotEmpty) ...[
            const SizedBox(height: 4),
            SelectableText(l.captureBlockedReasons(failure.blockers.join(', ')),
                style: WorkoutType.mono(size: 11.5, color: tokens.dim)),
          ],
        ],
      ),
    );
  }
}

class _Coverage extends StatelessWidget {
  const _Coverage({required this.summary});

  final CaptureSummary summary;

  String _label(AppLocalizations l, CaptureStoreLine s) {
    final note = s.note ?? '–';
    return switch (s.status) {
      CaptureStatus.captured =>
        s.reviewLater ? l.captureStoreReview : l.captureStoreCaptured,
      CaptureStatus.absent => l.captureStoreAbsent,
      CaptureStatus.excluded => l.captureStoreExcluded(note),
      CaptureStatus.inspectionFailed => l.captureStoreUnreadable(note),
      _ => l.captureStoreUnavailable(note),
    };
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final digest = summary.manifestSha256.length > 12
        ? '${summary.manifestSha256.substring(0, 12)}…'
        : summary.manifestSha256;
    return WCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FitLabel(l.captureCoverageTitle,
              maxLines: 2,
              style: WorkoutType.body(
                  size: 15, weight: FontWeight.w600, color: tokens.text)),
          const SizedBox(height: 6),
          SelectableText(l.captureDetails(summary.capturedAt, digest),
              style: WorkoutType.mono(size: 11.5, color: tokens.dim)),
          const SizedBox(height: 10),
          for (final s in summary.stores)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: SelectableText('${s.name} · ${_label(l, s)}',
                  style: WorkoutType.mono(
                      size: 12,
                      color: s.status == CaptureStatus.captured ||
                              s.status == CaptureStatus.absent ||
                              s.status == CaptureStatus.excluded
                          ? tokens.text
                          : tokens.danger)),
            ),
          const SizedBox(height: 6),
          Text(l.captureCoverageNote,
              style: WorkoutType.body(size: 13, color: tokens.dim)),
        ],
      ),
    );
  }
}

class _ExportResult extends StatelessWidget {
  const _ExportResult({required this.attempt});

  final ExportAttempt attempt;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final ok = attempt.transportStatus == ExportTransportStatus.sent &&
        attempt.receiptVerified;
    final lines = <Widget>[];
    if (ok) {
      lines
        ..add(Text(l.captureExportDone,
            style: WorkoutType.body(
                size: 14, weight: FontWeight.w600, color: tokens.accentText)))
        ..add(const SizedBox(height: 4));
      final location = attempt.location;
      if (location != null) {
        lines
          ..add(SelectableText(l.captureExportDoneAt(p.normalize(location.path)),
              style: WorkoutType.mono(size: 11.5, color: tokens.dim)))
          ..add(const SizedBox(height: 4));
      }
      lines.add(Text(l.captureExportDoneNote,
          style: WorkoutType.body(size: 13, color: tokens.dim)));
    } else if (attempt.transportStatus == ExportTransportStatus.cancelled) {
      lines.add(Text(l.captureExportCancelled,
          style: WorkoutType.body(size: 14, color: tokens.text)));
    } else {
      final code = attempt.code ?? attempt.transportStatus.wire;
      final message = switch (code) {
        // The private capture no longer matches what was certified.
        'capture_changed' => l.captureExportChanged,
        // A folder was published but did not verify where it is.
        'received_mismatch' => l.captureExportUnverified(
            attempt.location == null ? '–' : p.normalize(attempt.location!.path)),
        'destination_exists' => l.captureExportExists,
        _ => l.captureExportFailed(code),
      };
      lines.add(SelectableText(message,
          style: WorkoutType.body(size: 14, color: tokens.danger)));
      if (message != l.captureExportFailed(code)) {
        lines
          ..add(const SizedBox(height: 4))
          ..add(SelectableText(l.captureRecoveryCode(code),
              style: WorkoutType.mono(size: 11.5, color: tokens.dim)));
      }
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: lines);
  }
}

/// The capture screens' full-width accent action, for the startup recovery
/// screen.
class CaptureAction extends StatelessWidget {
  const CaptureAction({super.key, required this.label, required this.onTap});

  final String label;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) =>
      _Action(label: label, onTap: onTap, primary: true);
}

/// A full-width action: [primary] is the screen's accent action, the
/// default a quiet bordered one, [quiet] a text-only one. Its label may
/// take two lines and shrinks before it would split a word, so it holds at
/// narrow widths and large text.
class _Action extends StatelessWidget {
  const _Action({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.quiet = false,
  });

  final String label;
  final Future<void> Function() onTap;
  final bool primary;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: PressableScale(
          child: Container(
            constraints: BoxConstraints(minHeight: quiet ? 48 : 52),
            padding: EdgeInsets.symmetric(
                horizontal: quiet ? 4 : 16, vertical: 10),
            decoration: quiet
                ? null
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.radius),
                    color: primary ? tokens.accent : tokens.surface2,
                    border: primary ? null : Border.all(color: tokens.line),
                  ),
            alignment: quiet ? Alignment.centerLeft : Alignment.center,
            child: FitLabel(
              label,
              maxLines: 2,
              textAlign: quiet ? TextAlign.start : TextAlign.center,
              style: quiet
                  ? WorkoutType.body(
                      size: 14, weight: FontWeight.w600, color: tokens.accentText)
                  : WorkoutType.display(
                      size: 16,
                      weight: FontWeight.w700,
                      color: primary ? tokens.accentInk : tokens.text),
            ),
          ),
        ),
      ),
    );
  }
}
