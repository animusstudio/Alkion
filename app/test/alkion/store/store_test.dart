import 'dart:io';
import 'dart:convert';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/store/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../tool/alkion_store_recovery.dart'
    show syntheticStore, proofAction, executeAction, expectFailure;

void main() {
  test(
    'real adapter action, immutable evidence and reopen preserve complete state',
    () async {
      final root = await Directory.systemTemp.createTemp('alkion-store-unit-');
      var store = await syntheticStore(root);
      try {
        final action = proofAction(store);
        final first = await executeAction(store, action);
        expect((await executeAction(store, action)).replayed, isTrue);
        final before = await store.inventory();
        await expectFailure(
          () => executeAction(store, proofAction(store, value: 'bad')),
          category: 'operation_id_reuse',
        );
        expect(
          inventoryDigest(await store.inventory()),
          inventoryDigest(before),
        );
        expect(jsonDecode(utf8.decode(first.bytes)), {
          'record_id': 'exercise-1',
          'revision': 1,
        });
        await store.close();
        store = await syntheticStore(root);
        expect(
          inventoryDigest(await store.inventory()),
          inventoryDigest(before),
        );
      } finally {
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'true deferred COMMIT error recovers pool before queued writer',
    () async {
      final root = await Directory.systemTemp.createTemp('alkion-commit-unit-');
      final store = await syntheticStore(root);
      try {
        final action = proofAction(
          store,
          dependencies: [
            OperationDependency(
              store.profileId,
              GrantFamily.workouts,
              'missing',
            ),
          ],
        );
        final phases = <RecoveryPhase>[];
        final sub = store.recoveryEvents.listen(phases.add);
        await expectFailure(() => executeAction(store, action));
        expect(store.poolEpoch, 1);
        expect(store.admission, StoreAdmission.open);
        expect((await store.getAll('SELECT * FROM exercises')), isEmpty);
        expect((await store.getAll('SELECT * FROM operations')), isEmpty);
        expect(phases, [
          RecoveryPhase.admissionClosed,
          RecoveryPhase.watchesCancelled,
          RecoveryPhase.poolClosed,
          RecoveryPhase.validated,
          RecoveryPhase.ready,
        ]);
        await store.writeTransaction(
          (tx) => tx.putLocalState(
            LocalStateKind.semanticSetting,
            'language',
            localBytes('it'),
            expectedRevision: 0,
          ),
        );
        await expectFailure(
          () => store.writeTransaction(
            (tx) => tx.putLocalState(
              LocalStateKind.semanticSetting,
              'language',
              localBytes('de'),
              expectedRevision: 0,
            ),
          ),
          category: 'stale_local_state',
        );
        await sub.cancel();
      } finally {
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'profile and generation are refused before callback disclosure',
    () async {
      final root = await Directory.systemTemp.createTemp('alkion-scope-unit-');
      final store = await syntheticStore(root);
      try {
        var entered = false;
        await expectFailure(
          () => store.readTransaction((tx) async {
            entered = true;
            return null;
          }, expected: const StoreToken('foreign', 1)),
          category: 'foreign_profile',
        );
        await store.fenceForReplacement();
        await expectFailure(
          () => store.writeTransaction((tx) async {
            entered = true;
            return null;
          }),
          category: 'stale_generation',
        );
        expect(entered, isFalse);
      } finally {
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );
}
