import 'dart:io';

import 'package:alkion/domain/local_action.dart';
import 'package:alkion/main.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/store/generation_selection.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/ui/alkion_recovery/recovery_app.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/alkion_backup_recovery.dart' as proof;

/// Restore during a workout is refused under the session launch fence, over a
/// real runtime and real SQLite: nothing is presented, closed or restored.
void main() {
  late Directory temp;
  late Directory root;
  late AlkionRuntime runtime;
  late List<Widget> presented;
  late RuntimeRecoveryHost host;
  late String backupPath;

  String profileDirectory() =>
      Directory(p.join(root.path, 'profiles')).listSync().single.path;

  Future<void> expectUntouched() async {
    expect(presented, isEmpty, reason: 'no screen replaced the app');
    expect(runtime.store.admission, isNot(StoreAdmission.closed));
    expect(selectedRestoreId(profileDirectory()), isNull);
    expect(pendingRestoreIds(profileDirectory()), isEmpty);
    // The store still accepts work.
    await proof.bodyweight(
      runtime.store,
      'op-after-refusal-${DateTime.now().microsecondsSinceEpoch}',
      'bw-after-refusal-${DateTime.now().microsecondsSinceEpoch}',
      LocalActionKind.bodyweightRecord,
      0,
      '72.00',
    );
  }

  Future<void> open(WidgetTester tester) => tester.runAsync(() async {
    temp = await Directory.systemTemp.createTemp('alkion-restore-fence-');
    root = proof.supportRootOf(temp);
    runtime = await AlkionRuntime.open(root);
    presented = [];
    final backups = await Directory(p.join(temp.path, 'backups')).create();
    host = RuntimeRecoveryHost(
      runtime,
      relaunch: () async {},
      present: presented.add,
      backupDirectory: () async => backups,
    );
    await proof.bodyweight(
      runtime.store,
      'op-before',
      'bw-before',
      LocalActionKind.bodyweightRecord,
      0,
      '70.00',
    );
    expect(await host.lastBackupCreated(), isNull);
    final receipt = await host.createBackup();
    backupPath = receipt.path;
    // The host reads the newest backup's time from its file name.
    expect(
      (await host.lastBackupCreated())!.toIso8601String().substring(0, 19),
      receipt.verified.createdAt.substring(0, 19),
    );
  });

  Future<void> close(WidgetTester tester) => tester.runAsync(() async {
    if (runtime.store.admission != StoreAdmission.closed) {
      await runtime.close();
    }
    await temp.delete(recursive: true);
  });

  testWidgets(
    'a registered workout refuses restore before verification, presenting nothing',
    (tester) async {
      await open(tester);
      try {
        await tester.runAsync(() async {
          final controller = ActiveSessionController(
            draftStore: runtime.sessions.draftStore,
          )..seedEmpty(name: 'Synthetic workout', focus: '');
          runtime.sessions.register(controller);
          try {
            expect(host.workoutActive, isTrue);
            await expectLater(
              host.restoreBackup(backupPath),
              throwsA(
                isA<StoreException>().having(
                  (e) => e.category,
                  'category',
                  'workout_active',
                ),
              ),
            );
            await expectUntouched();
            // The refusal did not take the launch fence.
            expect(runtime.sessions.launching, isFalse);
          } finally {
            runtime.sessions.clear();
            controller.dispose();
          }
          // After the workout ends, restore works as before.
          expect(host.workoutActive, isFalse);
          await host.restoreBackup(backupPath);
          expect(runtime.store.admission, StoreAdmission.closed);
          expect(presented.first, isA<AlkionRestoringApp>());
          expect(presented.last, isA<AlkionRecoveryApp>());
          expect((presented.last as AlkionRecoveryApp).error, isNull);
          expect(selectedRestoreId(profileDirectory()), isNotNull);
        });
      } finally {
        await close(tester);
      }
    },
  );

  testWidgets('a workout launch in progress refuses restore', (tester) async {
    await open(tester);
    try {
      await tester.runAsync(() async {
        expect(runtime.sessions.tryBeginLaunch(), isTrue);
        try {
          expect(host.workoutActive, isTrue);
          await expectLater(
            host.restoreBackup(backupPath),
            throwsA(
              isA<StoreException>().having(
                (e) => e.category,
                'category',
                'workout_active',
              ),
            ),
          );
          await expectUntouched();
          // The restore did not release a launch it never held.
          expect(runtime.sessions.launching, isTrue);
        } finally {
          runtime.sessions.endLaunch();
        }
      });
    } finally {
      await close(tester);
    }
  });

  testWidgets(
    'restore holds the launch fence while verifying and releases it on failure',
    (tester) async {
      await open(tester);
      try {
        await tester.runAsync(() async {
          // A missing file fails verification; the fence is held until then.
          final failing = host.restoreBackup(
            p.join(temp.path, 'absent.alkionbackup'),
          );
          expect(runtime.sessions.launching, isTrue);
          expect(
            runtime.sessions.tryBeginLaunch(),
            isFalse,
            reason: 'a workout cannot start while the restore verifies',
          );
          await expectLater(failing, throwsA(isA<StoreException>()));
          expect(runtime.sessions.launching, isFalse);
          await expectUntouched();
          // A concurrent start during a successful restore is refused too.
          final restoring = host.restoreBackup(backupPath);
          expect(runtime.sessions.tryBeginLaunch(), isFalse);
          await restoring;
          expect(runtime.sessions.hasActive, isFalse);
          expect(selectedRestoreId(profileDirectory()), isNotNull);
        });
      } finally {
        await close(tester);
      }
    },
  );
}
