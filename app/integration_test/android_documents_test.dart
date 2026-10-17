import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/files/android_documents.dart';
import 'package:alkion/files/document_access.dart';
import 'package:alkion/identity/alkion_flutter_identity.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/directory_durability.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/recovery_host.dart';
import 'package:alkion/store/local_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../tool/alkion_store_recovery.dart'
    as fixtures
    show syntheticStore, executeAction, proofAction;

const _run = String.fromEnvironment('ALKION_PROOF_RUN');
const _source = String.fromEnvironment('ALKION_PROOF_SOURCE');
const _provider = 'dev.animusstudio.alkion.synthetic.documents';
const _authority = '$_provider.provider';
final _variant = AlkionIdentity.applicationId == 'dev.animusstudio.alkion.dev'
    ? 'dev'
    : AlkionIdentity.applicationId == 'dev.animusstudio.alkion'
    ? 'supported'
    : 'invalid';
final _namespace = '$_run-$_variant';
const _fixtureBound = 8 * 1024 * 1024;
const _caseNames = [
  'open-cancel',
  'open-good',
  'open-denied',
  'open-error',
  'open-short',
  'open-over-limit',
  'open-corrupt',
  'save-cancel',
  'save-good',
  'save-write-denied',
  'save-write-interrupted',
  'save-readback-denied',
  'save-readback-changed',
];

void _require(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

Future<String> _digest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// No restore/startup is exercised by this phase. Save uses the production
/// delivery helper and full receiving verifier over completed private readback.
final class _BackupHost implements RecoveryHost {
  _BackupHost(this.store, this.receipt);
  final LocalStore store;
  final BackupReceipt receipt;
  int verifications = 0;
  @override
  String get profileId => store.profileId;
  @override
  Future<BackupReceipt> createBackup() async => receipt;
  @override
  Future<VerifiedBackup> verifyBackup(String path) {
    verifications++;
    return verifyBackupFile(File(path), schema: store.schema);
  }

  @override
  Future<void> restoreBackup(String path) =>
      Future.error(StateError('Restore is a separate installed proof phase'));
}

/// Owner-only file handshake. The future guarded harness alone copies arm and
/// observed receipts with run-as; no app/provider broadcast or control channel.
/// Relative names are fixed here, never taken from an ack. Every picker call
/// completes/asserts before an observed ack can qualify that case.
final class _PickerProof {
  _PickerProof(this.directory, this.base, this.report);
  final Directory directory, base;
  final Map<String, Object?> report;
  int sequence = 0;
  String current = 'seed';
  late int inputLength;
  late String inputDigest;

  Future<void> publish(String state, Map<String, Object?> detail) async {
    final value = {
      'format': 'alkion-android-documents-phase/1',
      'run_id': _run,
      'source_commit': _source,
      'application_id': AlkionIdentity.applicationId,
      'variant': _variant,
      'provider_package': _provider,
      'provider_authority': _authority,
      'sequence': sequence,
      'case': current,
      'state': state,
      ...detail,
    };
    final partial = File(p.join(directory.path, 'phase.partial'));
    await partial.writeAsString(jsonEncode(value), flush: true);
    await partial.rename(p.join(directory.path, 'phase.json'));
    flushDirectory(directory.path);
  }

  Future<Map<String, dynamic>> ack(String action) async {
    _require(
      const ['seeded', 'armed', 'observed'].contains(action),
      'Unknown ack',
    );
    final relative = 'ack-${sequence.toString().padLeft(3, '0')}-$action.json';
    final file = File(p.join(directory.path, relative));
    final end = DateTime.now().add(const Duration(seconds: 90));
    while (!await file.exists() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _require(
      FileSystemEntity.typeSync(file.path, followLinks: false) ==
              FileSystemEntityType.file &&
          await file.length() <= 32768,
      'Missing, linked or oversized $relative; preserve failed proof',
    );
    final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    _require(
      value['format'] == 'alkion-android-documents-ack/1' &&
          value['run_id'] == _run &&
          value['source_commit'] == _source &&
          value['application_id'] == AlkionIdentity.applicationId &&
          value['variant'] == _variant &&
          value['sequence'] == sequence &&
          value['case'] == current &&
          value['action'] == action,
      'Foreign/stale ack cannot advance the picker phase',
    );
    return value;
  }

  Future<void> seed(BackupReceipt receipt) async {
    inputLength = await File(receipt.path).length();
    inputDigest = receipt.verified.containerSha256;
    _require(
      inputLength > 128 * 1024 && inputLength <= _fixtureBound,
      'Synthetic input must exceed pipe capacity and fit fixture bound',
    );
    _require(p.isWithin(directory.path, receipt.path), 'Backup escaped proof');
    await publish('seed_provider', {
      'source_relative': p.relative(receipt.path, from: base.path),
      'length': inputLength,
      'sha256': inputDigest,
      'provider_control_relative': 'files/proof-runs/$_namespace/control.json',
      'provider_input_relative':
          'files/proof-runs/$_namespace/input.alkionbackup',
      'provider_control': {
        'format': 'alkion-synthetic-documents/1',
        'variant': _variant,
        'run_id': _run,
        'length': inputLength,
        'sha256': inputDigest,
      },
    });
    final seeded = await ack('seeded');
    _require(
      seeded['provider_input_sha256'] == inputDigest,
      'Harness must check the exact owner-seeded bytes',
    );
  }

  Future<T> picker<T>(String name, Future<T> Function() operation) async {
    _require(_caseNames.contains(name), 'Unknown fixed picker case');
    sequence++;
    current = name;
    final detail = {
      'intent': name.startsWith('open-')
          ? 'ACTION_OPEN_DOCUMENT'
          : 'ACTION_CREATE_DOCUMENT',
      'root_label': 'Alkion synthetic $_namespace',
      'document_label': '$_namespace-$name.alkionbackup',
      'picker_action': name.endsWith('-cancel') ? 'cancel' : 'select',
      'mime_type': 'application/octet-stream',
      'provider_receipt_relative':
          'files/proof-runs/$_namespace/receipts/$name.json',
    };
    await publish('awaiting_arm', detail);
    await ack('armed');
    await publish('picker', detail);
    return operation().timeout(const Duration(seconds: 60));
  }

  Future<void> observed(String outcome) async {
    await publish('awaiting_observed', {'production_outcome': outcome});
    final value = await ack('observed');
    _require(
      value['provider_input_sha256'] == inputDigest,
      'Provider original changed after $current',
    );
    final cancel = current.endsWith('-cancel');
    if (cancel) {
      _require(
        value['picker_cancelled'] == true && value['provider_receipt'] == null,
        'Cancellation requires actual picker evidence, not a provider success',
      );
      return;
    }
    final receipt = value['provider_receipt'] as Map;
    _require(
      receipt['format'] == 'alkion-synthetic-document-receipt/1' &&
          receipt['run_id'] == _run &&
          receipt['variant'] == _variant &&
          receipt['case'] == current &&
          receipt['input_sha256'] == inputDigest &&
          receipt['input_length'] == inputLength,
      'Provider receipt is not bound to this actual case/input',
    );
    final events = (receipt['events'] as List).cast<Map>();
    _require(
      events.isNotEmpty &&
          events.length <= 16 &&
          events.every((event) => event['operation'] != 'delete'),
      'Missing provider events or external deletion attempted',
    );
    bool event(
      String operation,
      String state, {
      bool pipe = false,
      bool exact = false,
    }) => events.any(
      (entry) =>
          entry['operation'] == operation &&
          entry['state'] == state &&
          (!pipe || entry['reliable_pipe'] == true) &&
          (!exact ||
              (entry['sha256'] == inputDigest &&
                  entry['length'] == inputLength)),
    );
    if (current.startsWith('save-')) {
      _require(
        receipt['output_retained'] == true && event('create', 'created'),
        'Created external output was not retained',
      );
    }
    final valid = switch (current) {
      'open-good' => event('read', 'complete', pipe: true, exact: true),
      'open-denied' => event('read', 'denied'),
      'open-error' => event('read', 'interrupted', pipe: true),
      'open-short' =>
        event('read', 'complete', pipe: true) &&
            events.any((e) => e['length'] == inputLength - 1),
      'open-over-limit' =>
        event('read', 'complete', pipe: true) ||
            event('read', 'peer_error', pipe: true),
      'open-corrupt' =>
        event('read', 'complete', pipe: true) &&
            events.any(
              (e) => e['sha256'] != inputDigest && e['length'] == inputLength,
            ),
      'save-good' =>
        event('write', 'complete', pipe: true, exact: true) &&
            event('read', 'complete', pipe: true, exact: true),
      'save-write-denied' => event('write', 'denied'),
      'save-write-interrupted' => event('write', 'interrupted', pipe: true),
      'save-readback-denied' =>
        event('write', 'complete', pipe: true, exact: true) &&
            event('read', 'denied'),
      'save-readback-changed' =>
        event('write', 'complete', pipe: true, exact: true) &&
            event('read', 'complete', pipe: true) &&
            events.any(
              (e) =>
                  e['operation'] == 'read' &&
                  e['sha256'] != inputDigest &&
                  e['length'] == inputLength,
            ),
      _ => false,
    };
    _require(valid, 'Actual provider trace did not exercise $current');
    (report['provider_receipts'] as Map<String, Object?>)[current] = receipt;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Directory? output;
  final report = <String, Object?>{
    'format': 'alkion-android-documents-proof/1',
    'phase': 'documents-provider',
    'run_id': _run,
    'source_commit': _source,
    'application_id': AlkionIdentity.applicationId,
    'variant': _variant,
    'provider_package': _provider,
    'provider_authority': _authority,
    'complete': false,
    'cases': <String, Object?>{},
    'provider_receipts': <String, Object?>{},
    'unrun': [
      'transfer_import_semantics',
      'uri_grant_revocation',
      'physical_disk_full',
      'fresh_receiver_restore',
      'app_process_interruption',
      'provider_process_death',
      'physical_off_device_verification',
      'owner_data',
    ],
  };
  unawaited(
    binding.allTestsPassed.future.then((passed) async {
      final directory = output;
      if (directory == null) return;
      report['complete'] = true;
      report['result'] =
          passed && (report['cases'] as Map).length == _caseNames.length
          ? 'PASS'
          : 'FAIL';
      if (!passed) {
        report['failures'] = binding.failureMethodsDetails
            .map(
              (failure) => {
                'method': failure.methodName,
                'details': failure.details,
              },
            )
            .toList();
      }
      final partial = File(p.join(directory.path, 'documents-report.partial'));
      await partial.writeAsString(jsonEncode(report), flush: true);
      await partial.rename(p.join(directory.path, 'documents-report.json'));
      flushDirectory(directory.path);
    }),
  );

  testWidgets(
    'real SAF provider streams, complete backup verification and retained originals',
    (tester) async {
      await tester.runAsync(() async {
        _require(
          Platform.isAndroid,
          'Actual Android runtime required; no mocked provider qualification',
        );
        _require(
          RegExp(r'^[a-f0-9]{32}$').hasMatch(_run) &&
              RegExp(r'^[a-f0-9]{40}$').hasMatch(_source) &&
              const ['dev', 'supported'].contains(_variant),
          'Explicit run/source binding required',
        );
        final storage = await AlkionFlutterIdentity.verifyPlatformIdentity();
        _require(
          storage != null,
          'Native Android identity/storage attestation required',
        );
        final base = storage!.checkedSupportDirectory(
          await getApplicationSupportDirectory(),
        );
        final parent = Directory(p.join(base.path, 'android-documents-proof'));
        _require(
          FileSystemEntity.typeSync(parent.path, followLinks: false) ==
              FileSystemEntityType.notFound,
          'A documents-proof installation cannot adopt prior proof storage',
        );
        final directory = await Directory(
          p.join(parent.path, _run),
        ).create(recursive: true);
        output = directory;
        final phase = _PickerProof(directory, base, report);
        final store = await fixtures.syntheticStore(
          Directory(p.join(directory.path, 'store')),
          caseName: 'workflow-autosave',
        );
        try {
          await fixtures.executeAction(store, fixtures.proofAction(store));
          final original = Uint8List.fromList(
            List.generate(256 * 1024, (index) => (index * 17 + 3) & 255),
          );
          await store.writeTransaction(
            (tx) => tx.putArtifact(
              id: 'synthetic-original',
              bytes: original,
              digest: sha256.convert(original).toString(),
              parserVersion: 'synthetic/1',
              format: 'synthetic-only',
              disposition: 'preserved',
            ),
          );
          final backups = await Directory(
            p.join(directory.path, 'backups'),
          ).create();
          final receipt = await createBackup(store, backups);
          final host = _BackupHost(store, receipt);
          final documents = AndroidDocuments.instance;
          final backupFile = File(receipt.path);
          final baseline = jsonEncode(await store.inventory());
          final artifactDigest = sha256.convert(original).toString();
          Future<void> originals() async {
            _require(
              await _digest(backupFile) == receipt.verified.containerSha256 &&
                  jsonEncode(await store.inventory()) == baseline,
              'Backup/current profile changed during provider operation',
            );
            final artifact = await store.get(
              'SELECT raw_bytes FROM source_artifacts WHERE artifact_id=?',
              ['synthetic-original'],
            );
            _require(
              sha256
                      .convert((artifact['raw_bytes'] as List).cast<int>())
                      .toString() ==
                  artifactDigest,
              'Preserved source artifact changed',
            );
          }

          await phase.seed(receipt);
          for (final name in _caseNames) {
            try {
              String outcome;
              if (name.startsWith('open-')) {
                final errors = {
                  'open-denied': 'document_permission_denied',
                  'open-error': 'document_io_failed',
                  'open-short': 'document_length_mismatch',
                  'open-over-limit': 'document_resource_limit',
                };
                DocumentFile? selected;
                DocumentException? failure;
                try {
                  selected = await phase.picker(
                    name,
                    () => documents.open(
                      maxBytes: name == 'open-over-limit'
                          ? 4096
                          : maxBackupBytes,
                    ),
                  );
                } on DocumentException catch (error) {
                  failure = error;
                }
                if (name == 'open-cancel') {
                  _require(
                    failure == null && selected == null,
                    'Cancelled picker became success/error',
                  );
                  outcome = 'cancelled';
                } else if (errors.containsKey(name)) {
                  _require(
                    selected == null && failure?.category == errors[name],
                    'Wrong native refusal: $failure',
                  );
                  outcome = failure!.category;
                } else {
                  _require(
                    failure == null &&
                        selected != null &&
                        selected.name == '$_namespace-$name.alkionbackup',
                    'Wrong/partial provider selection: $failure',
                  );
                  if (name == 'open-corrupt') {
                    StoreException? refused;
                    try {
                      await verifyBackupFile(File(selected!.path));
                    } on StoreException catch (error) {
                      refused = error;
                    }
                    _require(
                      refused?.category == 'backup_digest_mismatch',
                      'Corrupt complete input escaped full verifier',
                    );
                    outcome = 'backup_digest_mismatch';
                  } else {
                    final verified = await verifyBackupFile(
                      File(selected!.path),
                    );
                    _require(
                      verified.containerSha256 ==
                              receipt.verified.containerSha256 &&
                          verified.facts.state.digest() ==
                              receipt.verified.facts.state.digest(),
                      'Received backup changed',
                    );
                    outcome = 'fully_verified';
                  }
                }
              } else {
                final errors = {
                  'save-write-denied': 'document_permission_denied',
                  'save-write-interrupted': 'document_io_failed',
                  'save-readback-denied': 'document_permission_denied',
                  'save-readback-changed': 'document_readback_mismatch',
                };
                // The helper's filename is controlled by the immutable source.
                // A private exact copy gives each picker a unique fixed case label.
                final copy = await backupFile.copy(
                  p.join(backups.path, '$_namespace-$name.alkionbackup'),
                );
                final named = BackupReceipt(copy.path, receipt.verified);
                DocumentSave? saved;
                DocumentException? failure;
                final beforeVerify = host.verifications;
                try {
                  saved = await phase.picker(
                    name,
                    () => saveBackupCopy(host, named, documents),
                  );
                } on DocumentException catch (error) {
                  failure = error;
                }
                _require(
                  await _digest(copy) == receipt.verified.containerSha256,
                  'Named private original changed',
                );
                if (name == 'save-cancel') {
                  _require(
                    failure == null && saved == null,
                    'Cancelled save became verified',
                  );
                  outcome = 'cancelled';
                } else if (errors.containsKey(name)) {
                  _require(
                    saved == null &&
                        failure?.category == errors[name] &&
                        failure?.originalPath != null,
                    'Wrong save refusal or no retained private original: $failure',
                  );
                  final retained = File(failure!.originalPath!);
                  _require(
                    p.isWithin(base.path, retained.path) &&
                        await _digest(retained) ==
                            receipt.verified.containerSha256,
                    'Failed save did not retain exact completed private source',
                  );
                  await verifyBackupFile(retained);
                  outcome = failure.category;
                } else {
                  _require(
                    failure == null &&
                        saved != null &&
                        host.verifications == beforeVerify + 1,
                    'Save lacked actual completed provider readback/full verification: $failure',
                  );
                  _require(
                    saved!.readback.sha256 ==
                            receipt.verified.containerSha256 &&
                        saved.readback.length == phase.inputLength,
                    'Provider saved different bytes',
                  );
                  outcome = 'provider_copy_fully_verified_on_this_device';
                }
              }
              await originals();
              await phase.observed(outcome);
              (report['cases'] as Map<String, Object?>)[name] = {
                'result': 'PASS',
                'outcome': outcome,
                'originals_preserved': true,
                'selected_generation_unchanged': true,
              };
            } catch (error) {
              report['failed_case'] = name;
              report['error'] = '$error';
              await originals();
              await phase.publish('failed', {'error': '$error'});
              rethrow;
            }
          }
        } finally {
          await store.close();
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
