import 'dart:convert';
import 'dart:io';

import 'package:alkion/domain/evidence.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/main.dart';
import 'package:alkion/session/notification_action.dart';
import 'package:alkion/store/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../integration_test/android_documents_test.dart' as documents;
import '../../../integration_test/android_restore_test.dart' as protocol;
import '../../../tool/alkion_store_recovery.dart' as fixtures;
import '../../../tool/alkion_verify_backup.dart' as receiving;

const run = 'cccccccccccccccccccccccccccccccc';
const source = 'dddddddddddddddddddddddddddddddddddddddd';
const producerRun = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const producerSource = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final hash = 'e' * 64;

class CheckpointStop implements Exception {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixtureRoot, temporary, inbox;
  late File backupFile, oppositeBackupFile;
  late VerifiedBackup backup;
  late Map<String, Object?> facts,
      receivingReport,
      oppositeReceivingReport,
      input;

  setUpAll(() async {
    fixtureRoot = await Directory.systemTemp.createTemp(
      'restore-protocol-source-',
    );
    final store = await fixtures.syntheticStore(
      Directory(p.join(fixtureRoot.path, 'source')),
      caseName: 'workflow-autosave',
    );
    try {
      facts = await documents.seedDocumentsFixture(store);
      final output = await Directory(
        p.join(fixtureRoot.path, 'backups'),
      ).create();
      final receipt = await createBackup(store, output);
      backupFile = File(receipt.path);
      backup = receipt.verified;
    } finally {
      await store.close();
    }
    receivingReport = await receiving.verifyReceivedBackup(
      input: backupFile.path,
      output: p.join(fixtureRoot.path, 'receiving-inspection'),
    );
    // Host-only semantic fixture: an installed campaign must instead supply
    // the independently produced actual other-variant SAF copy and raw reports.
    final oppositeManifest = protocol.restoreMap(
      jsonDecode(jsonEncode(backup.manifest)),
    );
    (oppositeManifest['tool']
        as Map)['application_id'] = protocol.restoreVariant == 'dev'
        ? 'dev.animusstudio.alkion'
        : 'dev.animusstudio.alkion.dev';
    oppositeBackupFile =
        await File(
          p.join(fixtureRoot.path, 'host-semantic-opposite.alkionbackup'),
        ).writeAsBytes(
          backupContainer(oppositeManifest, backup.databaseBytes),
          flush: true,
        );
    oppositeReceivingReport = await receiving.verifyReceivedBackup(
      input: oppositeBackupFile.path,
      output: p.join(fixtureRoot.path, 'opposite-receiving-inspection'),
    );
  });
  tearDownAll(() => fixtureRoot.delete(recursive: true));
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('restore-protocol-test-');
    inbox = await Directory(p.join(temporary.path, 'inbox')).create();
    await backupFile.copy(p.join(inbox.path, 'received.alkionbackup'));
    await oppositeBackupFile.copy(p.join(inbox.path, 'opposite.alkionbackup'));
    // Synthetic receipt shapes for protocol controls; these do not attest an
    // installed documents/provider campaign or any Android process death.
    const outcomes = {
      'open-cancel': 'cancelled',
      'open-good': 'fully_verified',
      'open-denied': 'document_permission_denied',
      'open-error': 'document_io_failed',
      'open-short': 'document_length_mismatch',
      'open-over-limit': 'document_resource_limit',
      'open-corrupt': 'backup_digest_mismatch',
      'save-cancel': 'cancelled',
      'save-good': 'provider_copy_fully_verified_on_this_device',
      'save-write-denied': 'document_permission_denied',
      'save-write-interrupted': 'document_io_failed',
      'save-readback-denied': 'document_permission_denied',
      'save-readback-changed': 'document_readback_mismatch',
    };
    input = {
      'format': 'alkion-android-restore-input/1',
      'run_id': run,
      'source_commit': source,
      'application_id': AlkionIdentity.applicationId,
      'variant': protocol.restoreVariant,
      'producer_run_id': producerRun,
      'producer_source_commit': producerSource,
      'length': await backupFile.length(),
      'sha256': backup.containerSha256,
      'proof_chain': {
        for (final name in [
          'disposable',
          'driver',
          'updates',
          'lifecycle',
          'documents',
          'provider_save_good',
          'receiving',
        ])
          name: hash,
      },
      'documents': {
        'format': 'alkion-android-documents-proof/1',
        'phase': 'documents-provider',
        'complete': true,
        'result': 'PASS',
        'run_id': producerRun,
        'source_commit': producerSource,
        'application_id': AlkionIdentity.applicationId,
        'variant': protocol.restoreVariant,
        'provider_package': 'dev.animusstudio.alkion.synthetic.documents',
        'provider_authority':
            'dev.animusstudio.alkion.synthetic.documents.provider',
        'fixture': facts,
        'cases': <String, Object?>{
          for (final e in outcomes.entries)
            e.key: {
              'result': 'PASS',
              'outcome': e.value,
              'originals_preserved': true,
              'selected_generation_unchanged': true,
            },
        },
      },
      'receiving': receivingReport,
    };
    final oppositeReport = protocol.restoreMap(
      jsonDecode(jsonEncode(input['documents'])),
    );
    oppositeReport['application_id'] = protocol.restoreVariant == 'dev'
        ? 'dev.animusstudio.alkion'
        : 'dev.animusstudio.alkion.dev';
    oppositeReport['variant'] = protocol.restoreVariant == 'dev'
        ? 'supported'
        : 'dev';
    final rawDocuments = localBytes(oppositeReport),
        rawReceiving = localBytes(oppositeReceivingReport);
    await File(
      p.join(inbox.path, 'opposite-documents.json'),
    ).writeAsBytes(rawDocuments, flush: true);
    await File(
      p.join(inbox.path, 'opposite-receiving.json'),
    ).writeAsBytes(rawReceiving, flush: true);
    input['opposite'] = {
      'format': 'alkion-android-opposite-input/1',
      'application_id': oppositeReport['application_id'],
      'variant': oppositeReport['variant'],
      'producer_run_id': producerRun,
      'producer_source_commit': producerSource,
      'length': await oppositeBackupFile.length(),
      'sha256': protocol.restoreDigest(await oppositeBackupFile.readAsBytes()),
      'documents_sha256': protocol.restoreDigest(rawDocuments),
      'receiving_sha256': protocol.restoreDigest(rawReceiving),
      'proof_chain': {
        ...protocol.restoreMap(input['proof_chain']),
        'documents': protocol.restoreDigest(rawDocuments),
        'receiving': protocol.restoreDigest(rawReceiving),
      },
    };
  });
  tearDown(() => temporary.delete(recursive: true));

  Future<String> writeInput() async {
    final bytes = localBytes(input);
    await File(
      p.join(inbox.path, 'input.json'),
    ).writeAsBytes(bytes, flush: true);
    return protocol.restoreDigest(bytes);
  }

  Future<String> request(int n, {String? prior, String? inputHash}) async {
    final value = {
      'format': 'alkion-android-restore-request/1',
      'run_id': run,
      'source_commit': source,
      'application_id': AlkionIdentity.applicationId,
      'variant': protocol.restoreVariant,
      'sequence': n,
      'action': protocol.restoreSteps[n - 1],
      'input_sha256': inputHash ?? await writeInput(),
      'prior_receipt_sha256': prior,
    };
    final raw = localBytes(value), digest = protocol.restoreDigest(raw);
    await File(
      p.join(inbox.path, 'request-${n.toString().padLeft(3, '0')}.json'),
    ).writeAsBytes(raw, flush: true);
    await File(p.join(inbox.path, 'current.json')).writeAsBytes(
      localBytes({
        'format': 'alkion-android-restore-pointer/1',
        'sequence': n,
        'request_sha256': digest,
      }),
      flush: true,
    );
    return digest;
  }

  test(
    'received real rich backup validates without creating a target',
    () async {
      await request(1);
      final result = await protocol.RestoreProtocol.read(
        inbox,
        run: run,
        source: source,
      );
      expect(result.backup.containerSha256, backup.containerSha256);
      expect(result.history, isEmpty);
      expect(temporary.listSync().map((e) => p.basename(e.path)), ['inbox']);
      await result.claim();
      await expectLater(
        protocol.RestoreProtocol.read(inbox, run: run, source: source),
        throwsStateError,
      );
      expect(File(p.join(inbox.path, 'claim-001.json')).existsSync(), isTrue);
    },
  );

  for (final change in [
    'flat-case',
    'failed-case',
    'wrong-profile',
    'wrong-container',
    'foreign-source',
    'extra-program',
  ]) {
    test('invalid $change is preserved and refused before claim', () async {
      if (change == 'flat-case') {
        ((input['documents'] as Map)['cases'] as Map)['save-good'] = 'PASS';
      }
      if (change == 'failed-case') {
        (((input['documents'] as Map)['cases'] as Map)['save-good']
                as Map)['originals_preserved'] =
            false;
      }
      if (change == 'wrong-profile') {
        (input['documents'] as Map)['fixture'] = {
          ...facts,
          'source_profile_id': 'foreign-profile',
        };
      }
      if (change == 'wrong-container') {
        input['sha256'] = hash;
      }
      if (change == 'foreign-source') {
        input['source_commit'] = producerSource;
      }
      await request(1);
      if (change == 'extra-program') {
        final path = File(p.join(inbox.path, 'request-001.json'));
        final value = jsonDecode(await path.readAsString()) as Map;
        value['program'] = 'touch arbitrary';
        final bytes = localBytes(value);
        await path.writeAsBytes(bytes);
        final pointer = File(p.join(inbox.path, 'current.json'));
        final pvalue = jsonDecode(await pointer.readAsString()) as Map;
        pvalue['request_sha256'] = protocol.restoreDigest(bytes);
        await pointer.writeAsBytes(localBytes(pvalue));
      }
      final before = await protocol.restoreTree(temporary);
      await expectLater(
        protocol.RestoreProtocol.read(inbox, run: run, source: source),
        throwsA(anything),
      );
      expect(await protocol.restoreTree(temporary), before);
    });
  }

  test(
    'raw prior receipt chain enforces new PID and exact request bytes',
    () async {
      final first = await request(1);
      final inputHash = protocol.restoreDigest(
        await File(p.join(inbox.path, 'input.json')).readAsBytes(),
      );
      final receipt = {
        'format': 'alkion-android-restore-proof/1',
        'run_id': run,
        'source_commit': source,
        'application_id': AlkionIdentity.applicationId,
        'variant': protocol.restoreVariant,
        'sequence': 1,
        'action': 'preflight',
        'request_sha256': first,
        'input_sha256': inputHash,
        'pid': 123,
        'complete': true,
        'closed': true,
        'result': 'PASS',
        'evidence': {},
      };
      final bytes = localBytes(receipt);
      await File(p.join(inbox.path, 'receipt-001.json')).writeAsBytes(bytes);
      await request(
        2,
        prior: protocol.restoreDigest(bytes),
        inputHash: inputHash,
      );
      final result = await protocol.RestoreProtocol.read(
        inbox,
        run: run,
        source: source,
        currentPid: 124,
      );
      expect(result.history.single['pid'], 123);
      await expectLater(
        protocol.RestoreProtocol.read(
          inbox,
          run: run,
          source: source,
          currentPid: 123,
        ),
        throwsStateError,
      );
      await File(
        p.join(inbox.path, 'request-001.json'),
      ).writeAsString('changed bytes');
      await expectLater(
        protocol.RestoreProtocol.read(
          inbox,
          run: run,
          source: source,
          currentPid: 124,
        ),
        throwsA(anything),
      );
    },
  );

  for (final change in ['flat-case', 'foreign-package', 'bytes']) {
    test(
      'opposite actual-ingress contract rejects $change before claim',
      () async {
        final other = protocol.restoreMap(input['opposite']);
        if (change == 'bytes') {
          await File(
            p.join(inbox.path, 'opposite.alkionbackup'),
          ).writeAsBytes([1, 2, 3]);
        } else {
          final file = File(p.join(inbox.path, 'opposite-documents.json'));
          final report = protocol.restoreMap(
            jsonDecode(await file.readAsString()),
          );
          if (change == 'flat-case') {
            (report['cases'] as Map)['save-good'] = 'PASS';
          } else {
            report['application_id'] = AlkionIdentity.applicationId;
          }
          final raw = localBytes(report);
          await file.writeAsBytes(raw);
          other['documents_sha256'] = protocol.restoreDigest(raw);
          (other['proof_chain'] as Map)['documents'] = protocol.restoreDigest(
            raw,
          );
          input['opposite'] = other;
        }
        await request(1);
        final before = await protocol.restoreTree(temporary);
        await expectLater(
          protocol.RestoreProtocol.read(inbox, run: run, source: source),
          throwsA(anything),
        );
        expect(await protocol.restoreTree(temporary), before);
      },
    );
  }

  Future<(Directory, Map<String, Object?>)> sixStops() async {
    final parent = await Directory(p.join(temporary.path, 'receiver')).create();
    final root = Directory(p.join(parent.path, AlkionIdentity.applicationId));
    Map<String, Object?>? previous;
    for (var index = 0; index < 6; index++) {
      final boundary = protocol.restoreSteps[index + 2];
      final service = RestoreService(
        root,
        checkpoint: (phase) async {
          if (phase == boundary) throw CheckpointStop();
        },
      );
      await expectLater(
        index < 3
            ? service.restore(backupFile)
            : service.completeFresh(previous!['pending_id'] as String),
        throwsA(isA<CheckpointStop>()),
      );
      final current = await protocol.freshRestoreSnapshot(root);
      expect(current['can_complete'], index >= 2);
      if (previous != null) {
        protocol.preserveFreshSnapshot(
          previous,
          current,
          requireSamePending: index >= 3,
        );
      }
      previous = current;
    }
    return (root, previous!);
  }

  test(
    'six injected production stops retain one preparation and exact attempts; closed oracle precedes delegate',
    () async {
      final (root, snapshot) = await sixStops();
      await RestoreService(
        root,
      ).completeFresh(snapshot['pending_id'] as String);
      var delegated = false;
      final before = await protocol.verifyFreshBeforeRelaunch(
        root,
        backup,
        facts,
        snapshot,
        () async {
          // Opening here also proves the exact oracle released store ownership.
          final state = await protocol.closedRestoreState(root);
          expect(documents.documentsFixtureViolations(state, facts), isEmpty);
          delegated = true;
        },
      );
      expect(delegated, isTrue);
      expect(
        (await protocol.closedRestoreState(root)).digest(),
        before.state.digest(),
      );
      expect(before.pins['preparation_base64'], snapshot['preparation_base64']);
      expect(before.pins['stages'], snapshot['stages']);
      expect(
        (snapshot['stages'] as Map).keys
            .where((v) => '$v'.endsWith('alkion.sqlite'))
            .length,
        2,
      );
      await expectLater(
        RestoreService(root).completeFresh(snapshot['pending_id'] as String),
        throwsA(
          isA<StoreException>().having(
            (e) => e.category,
            'category',
            'restore_not_pending',
          ),
        ),
      );
    },
  );

  for (final remove in [false, true]) {
    test(
      '${remove ? 'deleted' : 'changed'} orphan refuses before first store open/delegate',
      () async {
        final (root, snapshot) = await sixStops();
        await RestoreService(
          root,
        ).completeFresh(snapshot['pending_id'] as String);
        final intent = snapshot['intent'] as Map;
        final selected = p.join(
          'profiles',
          backup.profileId,
          (intent['staged'] as Map)['database'] as String,
        );
        final orphan = (snapshot['stages'] as Map).keys
            .cast<String>()
            .singleWhere(
              (path) => path.endsWith('alkion.sqlite') && path != selected,
            );
        final file = File(p.join(root.path, orphan));
        if (remove) {
          await file.delete();
        } else {
          await file.writeAsBytes([19, 255, 7], flush: true);
        }
        final before = await protocol.restoreTree(root.parent);
        var delegated = false;
        await expectLater(
          protocol.verifyFreshBeforeRelaunch(
            root,
            backup,
            facts,
            snapshot,
            () async {
              delegated = true;
            },
          ),
          throwsStateError,
        );
        expect(delegated, isFalse);
        // Complete physical equality also rejects an early normal SQLite open.
        expect(await protocol.restoreTree(root.parent), before);
      },
    );
  }

  test(
    'resolved completed callback is a fixed installed action with unchanged state',
    () async {
      final (root, snapshot) = await sixStops();
      await RestoreService(
        root,
      ).completeFresh(snapshot['pending_id'] as String);
      final verification = await protocol.verifyFreshBeforeRelaunch(
        root,
        backup,
        facts,
        snapshot,
        () async {},
      );
      expect(
        protocol.restoreSteps.indexOf('completed-refusal'),
        protocol.restoreSteps.indexOf('complete') + 1,
      );
      expect(
        protocol.restoreSteps.indexOf('cold-1'),
        protocol.restoreSteps.indexOf('completed-refusal') + 1,
      );
      final result = await protocol.completedFreshRefusal(
        root,
        snapshot['pending_id'] as String,
        verification.state,
      );
      expect(result['resolved_id'], snapshot['pending_id']);
      expect(result['outcome'], 'restore_not_pending');
      expect(result['unchanged'], isTrue);
      await expectLater(
        protocol.completedFreshRefusal(
          root,
          'rs-${'0' * 32}',
          verification.state,
        ),
        throwsStateError,
      );
      expect(
        (await protocol.closedRestoreState(root)).digest(),
        verification.state.digest(),
      );
    },
  );

  test(
    'changed restored setting blocks the original relaunch and stays retained',
    () async {
      final (root, snapshot) = await sixStops();
      await RestoreService(
        root,
      ).completeFresh(snapshot['pending_id'] as String);
      final store = await protocol.openRestored(root);
      try {
        await store.writeTransaction((tx) async {
          final row = await tx.localState(
            LocalStateKind.semanticSetting,
            'settings',
          );
          await tx.putLocalState(
            LocalStateKind.semanticSetting,
            'settings',
            localBytes({'mode': 'wrong'}),
            expectedRevision: row!['revision'] as int,
          );
        });
      } finally {
        await store.close();
      }
      final changed = await protocol.closedRestoreState(root);
      var delegated = false;
      await expectLater(
        protocol.verifyFreshBeforeRelaunch(
          root,
          backup,
          facts,
          snapshot,
          () async {
            delegated = true;
          },
        ),
        throwsStateError,
      );
      expect(delegated, isFalse);
      expect(
        (await protocol.closedRestoreState(root)).digest(),
        changed.digest(),
      );
    },
  );

  test(
    'actual production action issuance is bounded; unrelated local state fails',
    () async {
      final (root, snapshot) = await sixStops();
      await RestoreService(
        root,
      ).completeFresh(snapshot['pending_id'] as String);
      final before = await protocol.closedRestoreState(root),
          started = DateTime.now().toUtc();
      final store = await protocol.openRestored(root);
      try {
        expect(await issueNotificationAction(store), isNotNull);
      } finally {
        await store.close();
      }
      final after = await protocol.closedRestoreState(root);
      expect(
        protocol.adoptionViolations(
          before,
          after,
          started: started,
          finished: DateTime.now().toUtc(),
          expectAction: true,
        ),
        isEmpty,
      );
      final invalid = CoveredState({
        for (final e in after.tables.entries)
          e.key: e.value.map((r) => Map<String, Object?>.from(r)).toList(),
      }, after.keys);
      invalid.tables['local_state']!.singleWhere(
        (r) => r['state_kind'] == 'semanticSetting',
      )['revision'] = 99;
      expect(
        protocol.adoptionViolations(
          before,
          invalid,
          started: started,
          finished: DateTime.now().toUtc(),
          expectAction: true,
        ),
        isNotEmpty,
      );
    },
  );

  test(
    'real runtime expiry clears only exact draft/timer deadline fields',
    () async {
      final (root, snapshot) = await sixStops();
      await RestoreService(
        root,
      ).completeFresh(snapshot['pending_id'] as String);
      final store = await protocol.openRestored(root);
      try {
        final past = DateTime.now()
            .toUtc()
            .subtract(const Duration(seconds: 5))
            .toIso8601String();
        await store.writeTransaction((tx) async {
          for (final kind in [LocalStateKind.draft, LocalStateKind.timer]) {
            final row = await tx.localState(kind, 'active');
            final payload =
                jsonDecode(
                      utf8.decode((row!['payload_bytes'] as List).cast<int>()),
                    )
                    as Map;
            payload['restStart'] = past;
            payload['restTotal'] = 1;
            await tx.putLocalState(
              kind,
              'active',
              localBytes(payload),
              expectedRevision: row['revision'] as int,
            );
          }
        });
      } finally {
        await store.close();
      }
      // Both rows need one identical absolute start; the draft owns that truth.
      final before = await protocol.closedRestoreState(root),
          started = DateTime.now().toUtc();
      final runtime = await AlkionRuntime.open(root);
      try {
        await runtime.flushPersistence();
      } finally {
        await runtime.close();
      }
      final after = await protocol.closedRestoreState(root);
      // Concrete observed queue counts are diagnostic evidence, not a fixed
      // revision allowance. Exact payload/identity and every other row still
      // have to pass the production-adoption oracle below.
      stdout.writeln(
        'Observed natural expiry saves: ${jsonEncode(protocol.adoptionSaveCounts(before, after))}',
      );
      expect(
        protocol.adoptionViolations(
          before,
          after,
          started: started,
          finished: DateTime.now().toUtc(),
          expectAction: false,
        ),
        isEmpty,
      );
    },
  );

  test(
    'real refusal probes preserve foreign/corrupt/newer/nonempty/linked targets',
    () async {
      final results = await protocol.receivingRefusals(
        inbox,
        backup,
        protocol.restoreMap(input['opposite']),
      );
      expect(results.length, 6);
      expect(
        results.values.map((r) => (r as Map)['result']),
        everyElement('PASS'),
      );
      expect(
        await File(p.join(inbox.path, 'received.alkionbackup')).readAsBytes(),
        await backupFile.readAsBytes(),
      );
    },
  );
}
