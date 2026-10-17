import 'dart:io';

import 'package:alkion/store/local_store.dart';
import 'package:alkion/files/document_access.dart';
import 'package:alkion/ui/alkion_transfer/transfer_screen.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../domains/local_screen_harness.dart';
import 'import_test.dart' show withoutRow;
import 'transfer_harness.dart';
import '../files/fake_documents.dart';

Future<void> noSeed(LocalStore store) async {}

Future<void> settleUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 120 && finder.evaluate().isEmpty; i++) {
    await settleReal(tester, ticks: 1);
  }
  expect(finder, findsWidgets);
}

/// Invokes the enabled button that shows [finder] directly; layout at narrow
/// width and large text is asserted separately through takeException.
Future<void> press(WidgetTester tester, Finder finder) async {
  final button = find.ancestor(
    of: finder,
    matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
  );
  final widget = tester.widget<ButtonStyleButton>(
    button.evaluate().isEmpty ? finder : button.first,
  );
  expect(widget.onPressed, isNotNull);
  widget.onPressed!();
  await tester.pump();
}

Future<void> dismissDialog(WidgetTester tester, Finder content) async {
  await settleUntil(tester, content);
  await settleUntil(tester, find.text('OK'));
  await tester.tap(find.text('OK').last);
  // Wait for the dialog route (and its barrier) to finish leaving.
  for (
    var i = 0;
    i < 60 && find.byType(ModalBarrier).evaluate().length > 1;
    i++
  ) {
    await settleReal(tester, ticks: 1);
  }
  await settleReal(tester, ticks: 3);
}

void main() {
  testWidgets('phone transfer surfaces fit all locales at 320dp and 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final h = ScreenHarness();
    await h.open(tester, seed: noSeed);
    try {
      for (final locale in const ['en', 'de', 'es', 'it']) {
        await tester.pumpWidget(
          h.wrap(
            AlkionTransferScreen(
              documents: FakeDocuments(Directory.systemTemp),
            ),
            locale: Locale(locale),
          ),
        );
        await settleUntil(tester, find.byKey(const Key('transfer-import')));
        await settleReal(tester, ticks: 3);
        expect(find.byKey(const Key('transfer-path')), findsNothing);
        expect(tester.takeException(), isNull, reason: locale);
      }
      await h.unmount(tester);
    } finally {
      await h.close();
    }
  });
  testWidgets(
    'phone import uses selected completed bytes; cancel changes no generation and repeated selection stays idempotent',
    (tester) async {
      final h = ScreenHarness();
      await h.open(tester, seed: noSeed);
      late Directory out;
      late FakeDocuments documents;
      await tester.runAsync(() async {
        out = await Directory.systemTemp.createTemp('alkion-transfer-picker-');
        documents = FakeDocuments(out);
      });
      try {
        await tester.pumpWidget(
          h.wrap(AlkionTransferScreen(documents: documents)),
        );
        await settleReal(tester);
        expect(find.byKey(const Key('transfer-path')), findsNothing);
        await press(tester, find.byKey(const Key('transfer-import')));
        await settleReal(tester, ticks: 4);
        expect(
          await tester.runAsync(
            () => h.database.getAll('SELECT * FROM import_generations'),
          ),
          isEmpty,
        );
        await tester.runAsync(() async {
          final file = await File(
            '${out.path}/selected.complete',
          ).writeAsBytes(fixture('full-rich-synthetic-v1.json'), flush: true);
          documents.selection = await inspectDocument(
            file,
            name: 'phone.json',
            maxBytes: 128 * 1024 * 1024,
          );
        });
        await press(tester, find.byKey(const Key('transfer-import')));
        await dismissDialog(tester, find.text('Import selected'));
        expect(documents.openedLimit, 128 * 1024 * 1024);
        await press(tester, find.byKey(const Key('transfer-import')));
        await dismissDialog(tester, find.text('Already imported'));
        final originals = await tester.runAsync(
          () => h.database.getAll('SELECT raw_bytes FROM source_artifacts'),
        );
        expect(originals, hasLength(1));
        expect(
          originals!.single['raw_bytes'],
          fixture('full-rich-synthetic-v1.json'),
        );
        expect(tester.takeException(), isNull);
        await h.unmount(tester);
      } finally {
        await h.close();
        await tester.runAsync(() => out.delete(recursive: true));
      }
    },
  );
  testWidgets(
    'transfer screen imports explicitly, applies validated settings and records successor deletion at 320dp and 2x text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final h = ScreenHarness();
      await h.open(tester, seed: noSeed);
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('alkion-transfer-ui-'),
      );
      final first =
          '${Directory.current.path}/test/fixtures/alkion/full-rich-synthetic-v1.json';
      final second = '${dir!.path}/changed.json';
      await tester.runAsync(
        () => File(second).writeAsBytes(
          withoutRow(fixture('full-rich-synthetic-v1.json'), '{"id": "set5"'),
          flush: true,
        ),
      );
      try {
        await tester.pumpWidget(h.wrap(const AlkionTransferScreen()));
        await settleReal(tester);
        expect(find.text('No pending reviews'), findsOneWidget);
        await tester.enterText(find.byKey(const Key('transfer-path')), first);
        await tester.enterText(
          find.byKey(const Key('transfer-namespace')),
          'ui-ns',
        );
        await press(tester, find.byKey(const Key('transfer-import')));
        await dismissDialog(tester, find.text('Import selected'));
        await settleUntil(tester, find.text('ui-ns · selected'));
        expect(h.units.unit, Unit.kg);
        await tester.ensureVisible(find.text('Apply imported settings'));
        await tester.pump();
        await press(tester, find.text('Apply imported settings'));
        await dismissDialog(tester, find.textContaining('not applied'));
        expect(h.units.unit, Unit.lb);
        expect(h.settings.mode, 'light');
        expect(h.settings.profileName, 'Synthetic Lifter');
        expect(h.settings.localeOverride, isNull);
        await tester.ensureVisible(find.byKey(const Key('transfer-path')));
        await tester.enterText(find.byKey(const Key('transfer-path')), second);
        await tester.ensureVisible(find.byKey(const Key('transfer-import')));
        await tester.pump();
        await press(tester, find.byKey(const Key('transfer-import')));
        await dismissDialog(tester, find.text('Import selected'));
        await settleUntil(tester, find.text('Missing from the latest import'));
        await tester.ensureVisible(find.text('Delete').first);
        await tester.pump();
        await press(tester, find.text('Delete').first);
        await settleUntil(tester, find.text('Delete this record?'));
        await tester.tap(find.text('Delete').last);
        await settleUntil(tester, find.text('No pending reviews'));
        final deleted = await tester.runAsync(
          () => h.database.getAll(
            'SELECT deleted FROM sets WHERE profile_id=? AND deleted=1',
            [h.database.profileId],
          ),
        );
        expect(deleted, hasLength(1));
        // A rejected file is reported, never shown as success.
        await tester.ensureVisible(find.byKey(const Key('transfer-path')));
        await tester.enterText(
          find.byKey(const Key('transfer-path')),
          '${dir.path}/missing.json',
        );
        await tester.ensureVisible(find.byKey(const Key('transfer-import')));
        await tester.pump();
        await press(tester, find.byKey(const Key('transfer-import')));
        await dismissDialog(tester, find.text('Import not staged'));
        expect(tester.takeException(), isNull);
      } finally {
        await h.unmount(tester);
        await h.close();
        await tester.runAsync(() => dir.delete(recursive: true));
      }
    },
  );
}
