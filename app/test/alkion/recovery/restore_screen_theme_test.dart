import 'dart:io';

import 'package:alkion/main.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/theme/app_theme.dart';
import 'package:alkion/theme/tokens.dart';
import 'package:alkion/ui/alkion_recovery/recovery_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/alkion_backup_recovery.dart' as proof;
import '../../session/session_manager_test.dart' show FakeWorkoutNotification;
import '../../support/app_fonts.dart';

void main() {
  setUpAll(preloadAppFonts);

  WorkoutTokens tokensOf(WidgetTester tester) =>
      tester.element(find.byType(Scaffold)).tokens;

  testWidgets(
    'restore result screens follow the user language, theme and accent',
    (tester) async {
      final accent = accents[3];
      await tester.pumpWidget(
        AlkionRecoveryApp.restored(
          relaunch: () async {},
          locale: const Locale('de'),
          brightness: Brightness.light,
          accent: accent,
        ),
      );
      expect(find.text('Wiederherstellung ausgewählt'), findsOneWidget);
      expect(tokensOf(tester).bg, WorkoutTokens.light(accent).bg);
      expect(tokensOf(tester).accent, accent);

      await tester.pumpWidget(
        AlkionRecoveryApp.failed(
          relaunch: () async {},
          error: const StoreException('backup_digest_mismatch'),
          locale: const Locale('de'),
          brightness: Brightness.light,
          accent: accent,
        ),
      );
      expect(
        find.text('Wiederherstellung nicht abgeschlossen'),
        findsOneWidget,
      );
      expect(tokensOf(tester).bg, WorkoutTokens.light(accent).bg);

      await tester.pumpWidget(
        AlkionRestoringApp(
          locale: const Locale('it'),
          brightness: Brightness.dark,
          accent: accent,
        ),
      );
      expect(
        find.textContaining('Ripristino del backup verificato'),
        findsOneWidget,
      );
      expect(tokensOf(tester).bg, WorkoutTokens.dark(accent).bg);
      expect(tokensOf(tester).accent, accent);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the interrupted-restore screen follows the system theme and language',
    (tester) async {
      tester.platformDispatcher.localesTestValue = const [Locale('es')];
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(
        AlkionRecoveryApp.interrupted(
          relaunch: () async {},
          service: RestoreService(Directory('/nonexistent')),
          pending: const [
            PendingRestore('rs-0123456789abcdef0123456789abcdef', {
              'backup': {'created_at': '2026-10-15T09:00:00Z'},
            }),
          ],
        ),
      );
      expect(find.text('Se interrumpió una restauración'), findsOneWidget);
      expect(tokensOf(tester).bg, WorkoutTokens.light(accents[0]).bg);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      // Past the MaterialApp theme cross-fade.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tokensOf(tester).bg, WorkoutTokens.dark(accents[0]).bg);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('in-app restore presents its screens in the user settings', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp(
        'alkion-restore-theme-',
      );
      final presented = <Widget>[];
      try {
        final runtime = await AlkionRuntime.open(
          proof.supportRootOf(temp),
          notifications: FakeWorkoutNotification(),
        );
        await runtime.settings.setMode('light');
        await runtime.settings.setAccent(accents[4]);
        await runtime.settings.setLocaleOverride('de');
        final backups = await Directory(p.join(temp.path, 'backups')).create();
        final host = RuntimeRecoveryHost(
          runtime,
          relaunch: () async {},
          present: presented.add,
          backupDirectory: () async => backups,
        );
        final receipt = await host.createBackup();
        await host.restoreBackup(receipt.path);
        final restoring = presented.first as AlkionRestoringApp;
        final result = presented.last as AlkionRecoveryApp;
        for (final (locale, brightness, accent) in [
          (restoring.locale, restoring.brightness, restoring.accent),
          (result.locale, result.brightness, result.accent),
        ]) {
          expect(locale, const Locale('de'));
          expect(brightness, Brightness.light);
          expect(accent, accents[4]);
        }
      } finally {
        await temp.delete(recursive: true);
      }
    });
  });
}
