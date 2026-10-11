// The data capture screen and the startup recovery screen at {320, 412}dp ×
// {1.0, 2.0}× × {en, de, it} (plus es at the narrowest), in every state they
// can show: no overflow, no build exception, no word split.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:workout_tracker/capture/capture_coordinator.dart';
import 'package:workout_tracker/capture/capture_export.dart';
import 'package:workout_tracker/capture/capture_service.dart';
import 'package:workout_tracker/capture/capture_startup.dart';
import 'package:workout_tracker/l10n/app_localizations.dart';
import 'package:workout_tracker/theme/app_theme.dart';
import 'package:workout_tracker/theme/tokens.dart';
import 'package:workout_tracker/ui/capture_recovery_screen.dart';
import 'package:workout_tracker/ui/capture_screen.dart';

import '../support/screen_harness.dart';

const _id = '3f1c2a4e-8b7d-4c6a-9e2f-1a2b3c4d5e6f';
const _digest =
    'a3c1e0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0a2c4e6b8d0f2a4c6e8b0d2f4a6c8';

const _summary = CaptureSummary(
  captureId: _id,
  manifestSha256: _digest,
  capturedAt: '2026-10-10T10:30:05Z',
  stores: [
    CaptureStoreLine(name: 'sql', role: 'sql_snapshot', status: 'captured'),
    CaptureStoreLine(name: 'queue', role: 'upload_queue', status: 'captured'),
    CaptureStoreLine(name: 'draft', role: 'active_draft', status: 'captured'),
    CaptureStoreLine(
        name: 'last_finished', role: 'last_finished', status: 'absent'),
    CaptureStoreLine(
        name: 'preserved_draft_v1', role: 'opaque', status: 'captured'),
    CaptureStoreLine(
        name: 'secure_storage',
        role: 'excluded',
        status: 'excluded',
        note: 'credentials'),
    CaptureStoreLine(
        name: 'unknown_file',
        role: 'opaque',
        status: 'inspection_failed',
        note: 'unpreservable.listed_not_readable'),
  ],
);

class _Backend implements CaptureBackend {
  _Backend(this.view, {this.canCapture = true});

  final CaptureView view;
  @override
  final bool canCapture;
  @override
  bool get canExportToDirectory => true;

  @override
  Future<CaptureView> inspect() async => view;
  @override
  Future<CaptureView> capture(CaptureMode mode) async => view;
  @override
  Future<CaptureView> resumeOriginal(String captureId) async => view;
  @override
  Future<ExportAttempt> exportToDirectory(Directory parent,
          {ExportCancellation? cancellation}) async =>
      ExportAttempt(
        manifestSha256: _digest,
        transportStatus: ExportTransportStatus.sent,
        receiptVerified: true,
        location: Directory('${parent.path}/reps-capture-$_id'),
      );
}

final _states = <String, CaptureView>{
  'idle': const CaptureView(code: 'none'),
  'saved': const CaptureView(code: 'resumed', summary: _summary),
  'local hold': const CaptureView(
      code: 'local_hold',
      stage: 'local_hold',
      captureId: _id,
      decision: CaptureDecision.resumeOriginal,
      summary: _summary),
  'interrupted': const CaptureView(
      code: 'capture_interrupted',
      stage: 'copying',
      captureId: _id,
      decision: CaptureDecision.resumeOriginal),
  'blocked': const CaptureView(
      code: 'none',
      failure: CaptureFailure(
          code: 'unsaved_editor_input',
          remediation: 'save_or_cancel_forms',
          blockers: ['queue_entry_invalid', 'upload_queue_row_id_invalid'],
          keptPrivately: true)),
  'needs review': const CaptureView(
      code: 'gate_without_journal', decision: CaptureDecision.ownerReview),
  'unsupported': const CaptureView(code: 'platform_unavailable'),
};

Widget _app(Widget home, Locale locale) => MaterialApp(
      theme: buildTheme(Brightness.dark, accents[0]),
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

Future<void> _screen(WidgetTester tester, LayoutCondition c, String state) async {
  setPhone(tester, width: c.width, textScale: c.textScale);
  final service = CaptureService(_Backend(_states[state]!));
  await service.refresh();
  if (state == 'saved') {
    await service.exportTo(
        '/home/someone/Documents/a-rather-long-destination-folder-name');
  }
  await tester.pumpWidget(_app(CaptureScreen(service: service), c.locale));
  await tester.pumpAndSettle();
  await expectLayoutHoldsWhileScrolling(
      tester, find.byType(CaptureScreen), 'Capture $state ${describeCondition(c)}');
}

Future<void> _startup(WidgetTester tester, LayoutCondition c,
    CaptureRecoveryState recovery, CaptureView view) async {
  setPhone(tester, width: c.width, textScale: c.textScale);
  final service = CaptureService(_Backend(view, canCapture: false));
  await tester.pumpWidget(_app(
      CaptureRecoveryScreen(
          recovery: recovery, service: service, onResolved: () async {}),
      c.locale));
  await tester.pumpAndSettle();
  await expectLayoutHoldsWhileScrolling(tester,
      find.byType(CaptureRecoveryScreen), 'Startup ${recovery.code} ${describeCondition(c)}');
}

void main() {
  final conditions = [
    ...layoutConditions,
    (width: 320.0, textScale: 2.0, locale: const Locale('es')),
  ];
  for (final c in conditions) {
    for (final state in _states.keys) {
      testWidgets('Capture $state holds at ${describeCondition(c)}',
          (tester) => _screen(tester, c, state));
    }
    testWidgets('Startup local hold holds at ${describeCondition(c)}',
        (tester) => _startup(
              tester,
              c,
              const CaptureRecoveryState(
                  code: 'local_hold', stage: 'local_hold', captureId: _id,
                  decision: 'resume_original'),
              _states['local hold']!,
            ));
    testWidgets('Startup interrupted holds at ${describeCondition(c)}',
        (tester) => _startup(
              tester,
              c,
              const CaptureRecoveryState(
                  code: 'capture_interrupted', stage: 'held', captureId: _id,
                  decision: 'resume_original'),
              _states['interrupted']!,
            ));
    testWidgets('Startup preservation failure holds at ${describeCondition(c)}',
        (tester) => _startup(
              tester,
              c,
              const CaptureRecoveryState(code: 'preservation_failed'),
              const CaptureView(code: 'none'),
            ));
  }
}
