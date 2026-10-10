// Widget tests for the data capture screen, the startup recovery decisions
// and the hold's visible effects (rest extension and writes unavailable).
//
// The screen talks to a CaptureBackend; here a scripted fake stands in for
// the coordinator, so these tests pin what the person sees and which
// explicit decisions reach the backend, not the boundary itself (that is
// test/capture/capture_coordinator_test.dart and capture_export_test.dart).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:workout_tracker/capture/capture_coordinator.dart';
import 'package:workout_tracker/capture/capture_export.dart';
import 'package:workout_tracker/capture/capture_service.dart';
import 'package:workout_tracker/capture/capture_startup.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';
import 'package:workout_tracker/session/active_session_controller.dart';
import 'package:workout_tracker/session/session_header.dart';
import 'package:workout_tracker/ui/capture_recovery_screen.dart';
import 'package:workout_tracker/ui/capture_screen.dart';
import 'package:workout_tracker/widgets/w_dialog.dart';

import '../support/l10n_harness.dart';

const _id = '3f1c2a4e-8b7d-4c6a-9e2f-1a2b3c4d5e6f';
const _digest =
    'a3c1e0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0a2c4e6b8d0f2a4c6e8b0d2f4a6c8';

final _summary = CaptureSummary(
  captureId: _id,
  manifestSha256: _digest,
  capturedAt: '2026-10-10T10:30:05Z',
  stores: const [
    CaptureStoreLine(name: 'sql', role: 'sql_snapshot', status: 'captured'),
    CaptureStoreLine(name: 'queue', role: 'upload_queue', status: 'captured'),
    CaptureStoreLine(
        name: 'draft', role: 'active_draft', status: 'captured'),
    CaptureStoreLine(
        name: 'last_finished', role: 'last_finished', status: 'absent'),
    CaptureStoreLine(
        name: 'secure_storage',
        role: 'excluded',
        status: 'excluded',
        note: 'credentials'),
    CaptureStoreLine(
        name: 'notifications',
        role: 'opaque',
        status: 'unsupported',
        note: 'volatile_runtime'),
  ],
);

const _idle = CaptureView(code: 'none');

CaptureView _held(String code, String stage) => CaptureView(
      code: code,
      stage: stage,
      captureId: _id,
      decision: CaptureDecision.resumeOriginal,
      summary: code == 'capture_interrupted' ? null : _summary,
    );

/// Scripted backend: records every call; capture/export complete when a
/// test says so.
class _FakeBackend implements CaptureBackend {
  _FakeBackend({
    this.view = _idle,
    this.canCapture = true,
    this.canExportToDirectory = true,
  });

  CaptureView view;
  @override
  final bool canCapture;
  @override
  final bool canExportToDirectory;

  final calls = <String>[];
  Completer<CaptureView>? pendingCapture;
  CaptureView Function(CaptureMode mode)? onCapture;
  CaptureView Function()? onResume;
  ExportAttempt Function(Directory parent)? onExport;

  @override
  Future<CaptureView> inspect() async {
    calls.add('inspect');
    return view;
  }

  @override
  Future<CaptureView> capture(CaptureMode mode) async {
    calls.add('capture:${mode.name}');
    final pending = pendingCapture = Completer<CaptureView>();
    final result = await pending.future;
    return view = result;
  }

  @override
  Future<CaptureView> resumeOriginal(String captureId) async {
    calls.add('resume:$captureId');
    return view = onResume?.call() ??
        CaptureView(code: 'resumed', summary: view.summary);
  }

  @override
  Future<ExportAttempt> exportToDirectory(Directory parent,
      {ExportCancellation? cancellation}) async {
    calls.add('export:${parent.path}');
    return onExport?.call(parent) ??
        ExportAttempt(
          manifestSha256: _digest,
          transportStatus: ExportTransportStatus.sent,
          receiptVerified: true,
          location: Directory('${parent.path}/reps-capture-$_id'),
        );
  }
}

/// Every string on screen, for wording checks.
String _allText(WidgetTester tester) => [
      for (final w in tester.widgetList<Text>(find.byType(Text)))
        w.data ?? w.textSpan?.toPlainText() ?? '',
      for (final w in tester.widgetList<SelectableText>(find.byType(SelectableText)))
        w.data ?? '',
    ].join('\n');

/// Words honest copy never uses for a local capture or copy.
final _overclaims = RegExp(
    r'migrat|backed up|backup|uploaded|was sent|been sent|received by|synced to',
    caseSensitive: false);

Future<void> _pumpScreen(WidgetTester tester, CaptureService service,
    {Locale locale = const Locale('en')}) async {
  await tester.binding.setSurfaceSize(const Size(412, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
      wrapL10n(CaptureScreen(service: service), locale: locale));
  await tester.pumpAndSettle();
}

Future<void> _confirm(WidgetTester tester, String confirmLabel) async {
  await tester.pumpAndSettle();
  final dialog = find.byWidgetPredicate(
      (w) => w.runtimeType.toString().startsWith('_WDialogBody'));
  expect(dialog, findsOneWidget, reason: 'expected a confirmation dialog');
  await tester.tap(find.descendant(of: dialog, matching: find.text(confirmLabel)));
  await tester.pumpAndSettle();
}

Future<void> _dismiss(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final dialog = find.byWidgetPredicate(
      (w) => w.runtimeType.toString().startsWith('_WDialogBody'));
  expect(dialog, findsOneWidget);
  await tester.tap(find.descendant(of: dialog, matching: find.text('Cancel')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no_login_or_network_needed', (tester) async {
    var networkRequests = 0;
    await HttpOverrides.runZoned(() async {
      final backend = _FakeBackend();
      final service = CaptureService(backend);
      // No AuthStore, SyncHealth or settings exist above this screen.
      await _pumpScreen(tester, service);
      expect(find.text('No capture yet'), findsOneWidget);
      // Nothing asks to sign in or connect.
      expect(_allText(tester),
          isNot(matches(RegExp(r'sign in|log in|connect to', caseSensitive: false))));

      // Capture is explicit: a confirmation, then visible progress.
      await tester.tap(find.byKey(const Key('capture-start')));
      await _dismiss(tester);
      expect(backend.calls, ['inspect']);
      await tester.tap(find.byKey(const Key('capture-start')));
      await _confirm(tester, 'Capture');
      expect(backend.calls.last, 'capture:rehearsal');
      expect(find.byKey(const Key('capture-progress')), findsOneWidget);
      expect(find.byKey(const Key('capture-start')), findsNothing);

      backend.pendingCapture!.complete(CaptureView(code: 'resumed', summary: _summary));
      await tester.pumpAndSettle();
      expect(find.text('Capture saved on this device'), findsOneWidget);
      // Coverage: captured, kept for later review, left out, unavailable.
      expect(find.textContaining('captured for later review'), findsOneWidget);
      expect(find.textContaining('left out · credentials'), findsOneWidget);
      expect(find.textContaining('unavailable · volatile_runtime'), findsOneWidget);
      expect(find.textContaining('not present'), findsOneWidget);
      expect(_allText(tester), isNot(matches(_overclaims)));
      expect(_allText(tester), isNot(contains(_id)));

      // An error is readable, with only a safe code.
      backend.view = const CaptureView(code: 'journal_unreadable',
          decision: CaptureDecision.ownerReview);
      await tester.tap(find.byKey(const Key('capture-check-again')));
      await tester.pumpAndSettle();
      expect(find.text('Needs a closer look'), findsOneWidget);
      expect(find.text('Status: journal_unreadable'), findsOneWidget);
      expect(find.byKey(const Key('capture-resume')), findsNothing);
    }, createHttpClient: (_) {
      networkRequests++;
      throw const SocketException('no network in this test');
    });
    expect(networkRequests, 0);
  });

  testWidgets('blocked_capture_has_no_success_or_export', (tester) async {
    final backend = _FakeBackend();
    final service = CaptureService(backend);
    await _pumpScreen(tester, service);

    // Unsaved Plan/History edits: Save or Cancel first, nothing auto-saved.
    await tester.tap(find.byKey(const Key('capture-start')));
    await _confirm(tester, 'Capture');
    backend.pendingCapture!.complete(const CaptureView(
      code: 'none',
      failure: CaptureFailure(
          code: 'unsaved_editor_input', remediation: 'save_or_cancel_forms'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Capture not made'), findsOneWidget);
    expect(find.textContaining('Save or cancel your open edits'), findsOneWidget);
    expect(find.text('Capture saved on this device'), findsNothing);
    expect(find.byKey(const Key('capture-export')), findsNothing);

    // A sealed but unusable (exploratory) capture is never offered.
    await tester.tap(find.byKey(const Key('capture-start')));
    await _confirm(tester, 'Capture');
    backend.pendingCapture!.complete(const CaptureView(
      code: 'resumed',
      failure: CaptureFailure(
          code: 'capture_unusable',
          blockers: ['queue_entry_invalid'],
          keptPrivately: true),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Capture not made'), findsOneWidget);
    expect(find.textContaining('not a usable capture'), findsOneWidget);
    expect(find.textContaining('queue_entry_invalid'), findsOneWidget);
    expect(find.text('Capture saved on this device'), findsNothing);
    expect(find.byKey(const Key('capture-export')), findsNothing);

    // Unsupported here (Android builds today): no capture, no export button.
    final android = CaptureService(_FakeBackend(
      view: const CaptureView(code: 'platform_unavailable'),
      canExportToDirectory: false,
    ));
    await _pumpScreen(tester, android);
    expect(find.text('Not available on this device'), findsOneWidget);
    expect(find.byKey(const Key('capture-start')), findsNothing);
    expect(find.byKey(const Key('capture-start-hold')), findsNothing);
    expect(find.byKey(const Key('capture-export')), findsNothing);

    // A saved capture on a device without the directory transport: the
    // export is shown as unavailable, never as a broken button.
    final noExport = CaptureService(_FakeBackend(
      view: CaptureView(code: 'resumed', summary: _summary),
      canExportToDirectory: false,
    ));
    await _pumpScreen(tester, noExport);
    expect(find.byKey(const Key('capture-export')), findsNothing);
    expect(find.textContaining("isn't available on this device"), findsOneWidget);
  });

  testWidgets('hold_shows_unavailable_rest_and_writes', (tester) async {
    // The live rest row: +30s is visibly unavailable and does nothing.
    var adds = 0;
    await tester.pumpWidget(wrapL10n(SessionHeader(
      draft: SessionDraft(templateId: 't', name: 'Lower B', focus: '',
          startedAt: DateTime(2026, 10, 10, 9), blocks: const []),
      elapsed: const Duration(minutes: 1),
      doneWork: 1, totalWork: 4, prCount: 0,
      restStart: DateTime.now(), restTotal: 90, showRestRow: true,
      nextLabel: 'Next · set 2',
      onMinimize: () {}, onMenu: () {}, onAdd30s: () => adds++, onSkip: () {},
      restExtensionAvailable: false,
    )));
    expect(find.text('+30s unavailable during data capture'), findsOneWidget);
    await tester.tap(find.byKey(const Key('rest-add')), warnIfMissed: false);
    expect(adds, 0);

    // The controller refuses an extension while a capture froze it.
    final c = ActiveSessionController.fromDraft(SessionDraft(templateId: 't',
        name: 'Lower B', focus: '', startedAt: DateTime(2026, 10, 10, 9),
        blocks: const []));
    c.startRest(90);
    c.freezeCallbacks(7);
    expect(c.captureFrozen.value, isTrue);
    c.addRestTime(30);
    expect(c.restTotal, 90);
    c.resumeCallbacks(DateTime.now());
    expect(c.captureFrozen.value, isFalse);
    c.addRestTime(30);
    expect(c.restTotal, 120);
    c.dispose();

    // A refused write says why instead of a raw error.
    await tester.pumpWidget(wrapL10n(Builder(
      builder: (context) => TextButton(
        onPressed: () => showWriteFailed(
            context, const SourceGateException('admission_closed', 'plan.save')),
        child: const Text('save'),
      ),
    )));
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    expect(find.text('Paused for data capture'), findsOneWidget);
    expect(find.textContaining("this change wasn't saved"), findsOneWidget);
    expect(find.textContaining('SourceGateException'), findsNothing);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // The capture screen during a local hold: paused saving is explained,
    // export stays available, and release is an explicit, confirmed decision.
    final backend = _FakeBackend(view: _held('local_hold', 'local_hold'));
    await _pumpScreen(tester, CaptureService(backend));
    expect(find.text('Local hold'), findsOneWidget);
    expect(find.textContaining('rest extensions are paused'), findsOneWidget);
    expect(find.byKey(const Key('capture-export')), findsOneWidget);
    expect(find.byKey(const Key('capture-start')), findsNothing);
    await tester.tap(find.byKey(const Key('capture-resume')));
    await _dismiss(tester);
    expect(backend.calls.where((c) => c.startsWith('resume')), isEmpty);
    expect(find.text('Local hold'), findsOneWidget);
    await tester.tap(find.byKey(const Key('capture-resume')));
    await _confirm(tester, 'Release hold');
    expect(backend.calls.last, 'resume:$_id');
    expect(find.text('Capture saved on this device'), findsOneWidget);
  });

  testWidgets('interrupted capture offers resume, and resume then capture',
      (tester) async {
    final backend = _FakeBackend(view: _held('capture_interrupted', 'held'));
    backend.onResume = () => const CaptureView(code: 'resumed');
    await _pumpScreen(tester, CaptureService(backend));
    expect(find.text('Capture interrupted'), findsOneWidget);
    expect(find.textContaining('not a usable capture'), findsOneWidget);
    expect(find.byKey(const Key('capture-export')), findsNothing);
    expect(find.byKey(const Key('capture-start')), findsNothing);

    await tester.tap(find.byKey(const Key('capture-resume-and-capture')));
    await _confirm(tester, 'Resume and capture');
    expect(backend.calls, ['inspect', 'resume:$_id', 'capture:rehearsal']);
    backend.pendingCapture!.complete(CaptureView(code: 'resumed', summary: _summary));
    await tester.pumpAndSettle();
    expect(find.text('Capture saved on this device'), findsOneWidget);
  });

  testWidgets('export needs a destination and confirmation, and says only what '
      'was checked', (tester) async {
    final backend = _FakeBackend(view: CaptureView(code: 'resumed', summary: _summary));
    await _pumpScreen(tester, CaptureService(backend));
    await tester.ensureVisible(find.byKey(const Key('capture-export')));
    // No destination yet: nothing happens.
    await tester.tap(find.byKey(const Key('capture-export')));
    await tester.pumpAndSettle();
    expect(backend.calls.where((c) => c.startsWith('export')), isEmpty);

    await tester.enterText(
        find.byKey(const Key('capture-export-path')), '/tmp/reps-dest');
    await tester.tap(find.byKey(const Key('capture-export')));
    await _dismiss(tester);
    expect(backend.calls.where((c) => c.startsWith('export')), isEmpty);
    await tester.tap(find.byKey(const Key('capture-export')));
    await _confirm(tester, 'Copy');
    expect(backend.calls.last, 'export:/tmp/reps-dest');
    expect(find.textContaining('Copy checked'), findsOneWidget);
    expect(find.textContaining('/tmp/reps-dest/reps-capture-$_id'), findsOneWidget);
    expect(_allText(tester), isNot(matches(_overclaims)));

    backend.onExport = (parent) => const ExportAttempt(
        manifestSha256: _digest,
        transportStatus: ExportTransportStatus.cancelled);
    await tester.tap(find.byKey(const Key('capture-export')));
    await _confirm(tester, 'Copy');
    expect(find.textContaining('Copy cancelled'), findsOneWidget);
    expect(find.textContaining('unchanged'), findsOneWidget);

    backend.onExport = (parent) => const ExportAttempt(
        manifestSha256: _digest,
        transportStatus: ExportTransportStatus.failed,
        code: 'destination_exists');
    await tester.tap(find.byKey(const Key('capture-export')));
    await _confirm(tester, 'Copy');
    expect(find.textContaining('destination_exists'), findsOneWidget);
    expect(find.textContaining('Copy checked'), findsNothing);
  });

  testWidgets('startup recovery offers the explicit decision', (tester) async {
    var resolved = 0;
    // Startup has no open sources: the coordinator cannot capture there.
    final backend = _FakeBackend(
        view: _held('capture_interrupted', 'copying'), canCapture: false);
    backend.onResume = () => const CaptureView(code: 'resumed');
    await tester.binding.setSurfaceSize(const Size(412, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(wrapL10n(CaptureRecoveryScreen(
      recovery: const CaptureRecoveryState(
          code: 'capture_interrupted', stage: 'copying',
          captureId: _id, decision: 'resume_original'),
      service: CaptureService(backend),
      onResolved: () async => resolved++,
    )));
    await tester.pumpAndSettle();
    expect(find.text('Status: capture_interrupted · copying'), findsOneWidget);
    // Startup has no running sources: no new capture is offered here.
    expect(find.byKey(const Key('capture-start')), findsNothing);
    await tester.tap(find.byKey(const Key('capture-resume')));
    await _dismiss(tester);
    expect(resolved, 0);
    await tester.tap(find.byKey(const Key('capture-resume')));
    await _confirm(tester, 'Resume original use');
    expect(backend.calls.last, 'resume:$_id');
    expect(resolved, 1);

    // A failed safety copy has no coordinator decision to offer.
    await tester.pumpWidget(wrapL10n(CaptureRecoveryScreen(
      recovery: const CaptureRecoveryState(code: 'preservation_failed'),
      service: CaptureService(_FakeBackend(
          view: const CaptureView(code: 'none'), canCapture: false)),
      onResolved: () async => resolved++,
    )));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('capture-resume')), findsNothing);
    expect(find.byKey(const Key('capture-check-again')), findsOneWidget);
  });
}
