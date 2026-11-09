import 'dart:io';

import 'package:alkion/data/session_writer.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/main.dart';
import 'package:alkion/store/generation_selection.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/ui/alkion_recovery/recovery_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/alkion_backup_recovery.dart' as proof;
import '../domains/local_screen_harness.dart';

/// A runtime that fails to close during an in-app restore never strands the
/// user in `profile_in_use`: Reopen shows the same working runtime, or
/// retries the close and relaunches, or stays on a retryable error.
void main() {
  late Directory temp;
  late Directory root;
  late AlkionRuntime runtime;
  late List<Widget> presented;
  late String backupPath;
  var relaunches = 0;

  Future<void> relaunch() async {
    relaunches++;
    await launchAlkion(root, present: presented.add);
  }

  String profileDirectory() =>
      Directory(p.join(root.path, 'profiles')).listSync().single.path;

  Future<RuntimeRecoveryHost> open({
    Future<void> Function()? closeStore,
    void Function(Widget app)? onPresent,
  }) async {
    temp = await Directory.systemTemp.createTemp('alkion-close-failure-');
    root = proof.supportRootOf(temp);
    runtime = await AlkionRuntime.open(root);
    presented = [];
    relaunches = 0;
    final backups = await Directory(p.join(temp.path, 'backups')).create();
    final host = RuntimeRecoveryHost(
      runtime,
      relaunch: relaunch,
      present: (app) {
        presented.add(app);
        onPresent?.call(app);
      },
      backupDirectory: () async => backups,
      closeStore: closeStore,
    );
    await proof.bodyweight(
      runtime.store,
      'op-before',
      'bw-before',
      LocalActionKind.bodyweightRecord,
      0,
      '70.00',
    );
    backupPath = (await host.createBackup()).path;
    return host;
  }

  /// Presses the failed-close screen's Reopen through the real widget.
  Future<void> reopen(WidgetTester tester) async {
    final failed = presented.last as AlkionRecoveryApp;
    await tester.pumpWidget(failed);
    await tester.pump();
    final count = presented.length;
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('restore-reopen')),
    );
    await tester.runAsync(() async {
      button.onPressed!();
      for (var i = 0; i < 200 && presented.length == count; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
  }

  tearDown(UnsavedEditors.instance.resetForTesting);

  testWidgets(
    'a flush refusal before any owner is disposed re-presents the same working runtime',
    (tester) async {
      late RuntimeRecoveryHost host;
      await tester.runAsync(() async {
        host = await open(
          onPresent: (app) {
            // An editor torn down with the old UI owes a write that keeps
            // failing, so close()'s flush barrier refuses.
            if (app is AlkionRestoringApp) {
              UnsavedEditors.instance.owe(
                'synthetic-editor',
                'synthetic',
                () async => throw const StoreException('synthetic_write'),
              );
            }
          },
        );
        await host.restoreBackup(backupPath);
      });
      try {
        expect(presented.first, isA<AlkionRestoringApp>());
        final failed = presented.last as AlkionRecoveryApp;
        expect(failed.error, isA<StoreException>());
        expect(runtime.ownersDisposed, isFalse);
        expect(runtime.store.admission, isNot(StoreAdmission.closed));
        expect(selectedRestoreId(profileDirectory()), isNull);
        await tester.pumpWidget(failed);
        await tester.pump();
        expect(find.text('Restore not completed'), findsOneWidget);
        expect(find.textContaining('synthetic_write'), findsNothing);

        await reopen(tester);
        expect(relaunches, 0, reason: 'no second opener for a held store');
        final app = presented.last as AlkionApp;
        expect(app.runtime, same(runtime));
        expect(app.recovery, same(host));
        await tester.runAsync(() async {
          // The runtime still writes and, once the editor is gone, closes.
          await proof.bodyweight(
            runtime.store,
            'op-after-failed-close',
            'bw-after-failed-close',
            LocalActionKind.bodyweightRecord,
            0,
            '71.00',
          );
          UnsavedEditors.instance.resetForTesting();
          await runtime.close();
        });
        expect(runtime.store.admission, StoreAdmission.closed);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          if (runtime.store.admission != StoreAdmission.closed) {
            UnsavedEditors.instance.resetForTesting();
            await runtime.close();
          }
          await temp.delete(recursive: true);
        });
      }
    },
  );

  testWidgets(
    'a store close failure after owners are disposed retries the close, then relaunches',
    (tester) async {
      var failures = 2;
      await tester.runAsync(() async {
        final host = await open(
          closeStore: () async {
            if (failures > 0) {
              failures--;
              throw const StoreException('synthetic_close_failed');
            }
            await runtime.store.close();
          },
        );
        await host.restoreBackup(backupPath);
      });
      AlkionRuntime? reopened;
      try {
        expect(presented.last, isA<AlkionRecoveryApp>());
        expect(runtime.ownersDisposed, isTrue);
        expect(runtime.store.admission, isNot(StoreAdmission.closed));

        // The retried close fails again: a retryable error on the same
        // screen, no relaunch, so never `profile_in_use`.
        final failed = presented.last as AlkionRecoveryApp;
        await tester.pumpWidget(failed);
        await tester.pump();
        final button = tester.widget<FilledButton>(
          find.byKey(const Key('restore-reopen')),
        );
        await tester.runAsync(() async {
          button.onPressed!();
          for (var i = 0; i < 50 && failures > 0; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });
        for (var i = 0; i < 60; i++) {
          if (find.text('synthetic_close_failed').evaluate().length == 2) {
            break;
          }
          await settleReal(tester, ticks: 1);
        }
        // The body's and the retry's details lines; no exception text.
        expect(find.text('synthetic_close_failed'), findsNWidgets(2));
        expect(find.textContaining('StoreException'), findsNothing);
        expect(relaunches, 0);
        expect(presented.last, same(failed));

        // The next Reopen closes the store and relaunches a working app.
        await reopen(tester);
        expect(relaunches, 1);
        expect(runtime.store.admission, StoreAdmission.closed);
        expect(
          presented.last,
          isA<AlkionApp>(),
          reason: presented.last is AlkionPreflightApp
              ? '${(presented.last as AlkionPreflightApp).error}'
              : null,
        );
        reopened = (presented.last as AlkionApp).runtime;
        expect(reopened, isNot(same(runtime)));
        expect(selectedRestoreId(profileDirectory()), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await reopened?.close();
          if (runtime.store.admission != StoreAdmission.closed) {
            await runtime.store.close();
          }
          await temp.delete(recursive: true);
        });
      }
    },
  );
}
