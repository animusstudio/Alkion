import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/domain/evidence.dart';
import 'package:alkion/export/exclusive_publish.dart';
import 'package:alkion/files/android_documents.dart';
import 'package:alkion/files/document_access.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/identity/directory_durability.dart';
import 'package:alkion/main.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/session/notification_action.dart';
import 'package:alkion/store/generation_selection.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/ui/alkion_recovery/first_start_screen.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../tool/alkion_backup_recovery.dart'
    as oracle
    show restoreViolations, stateJson, stateFromJson;
import 'android_documents_test.dart'
    as documents
    show documentsFixtureViolations;

const restoreRun = String.fromEnvironment('ALKION_PROOF_RUN');
const restoreSource = String.fromEnvironment('ALKION_PROOF_SOURCE');
const restoreSteps = [
  'preflight',
  'refusals',
  'fresh-preparation',
  'restore-staged-bytes',
  'restore-staged',
  'restore-intent',
  'restore-selected',
  'restore-before-identity',
  'complete',
  'completed-refusal',
  'cold-1',
  'cold-2',
];
const _bound = 8 * 1024 * 1024;
final _hex = RegExp(r'^[a-f0-9]{64}$');
String get restoreVariant =>
    AlkionIdentity.applicationId.endsWith('.dev') ? 'dev' : 'supported';
void must(bool value, String reason) {
  if (!value) throw StateError(reason);
}

String restoreDigest(List<int> bytes) => sha256.convert(bytes).toString();
bool sameRestoreValue(Object? a, Object? b) =>
    base64Encode(localBytes(a)) == base64Encode(localBytes(b));
Map<String, Object?> restoreMap(Object? value) =>
    Map<String, Object?>.from(value as Map);

void _keys(Map value, Set<String> expected) => must(
  value.length == expected.length && expected.every(value.containsKey),
  'Unexpected protocol fields',
);

Future<Uint8List> restoreRegular(File file, {int limit = _bound}) async {
  var path = file.absolute.path;
  must(p.normalize(path) == path, 'Noncanonical protocol path');
  while (true) {
    must(
      FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.link,
      'Linked protocol path',
    );
    if (p.dirname(path) == path) break;
    path = p.dirname(path);
  }
  must(
    FileSystemEntity.typeSync(file.path, followLinks: false) ==
            FileSystemEntityType.file &&
        await file.length() <= limit,
    'Missing, linked or oversized protocol file',
  );
  return file.readAsBytes();
}

/// Hard-link publication refuses replacement; even partial receipts are retained.
Future<void> restorePublish(File file, Map<String, Object?> value) async {
  final partial = File('${file.path}.partial-$pid');
  must(
    FileSystemEntity.typeSync(partial.path, followLinks: false) ==
        FileSystemEntityType.notFound,
    'Receipt partial already exists',
  );
  await partial.writeAsBytes(localBytes(value), flush: true);
  must(linkExclusive(partial.path, file.path), 'Receipt already exists');
  flushDirectory(file.parent.path);
}

const _documentOutcomes = {
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

/// This validates received bytes/facts. Device/APK/UID and actual provider trace
/// attestation belong to the separately reviewed host, never to these flags.
Future<VerifiedBackup> validateRestoreInput(
  Directory directory,
  Map<String, Object?> input, {
  required String run,
  required String source,
}) async {
  _keys(input, {
    'format',
    'run_id',
    'source_commit',
    'application_id',
    'variant',
    'producer_run_id',
    'producer_source_commit',
    'length',
    'sha256',
    'documents',
    'receiving',
    'proof_chain',
    'opposite',
  });
  must(
    input['format'] == 'alkion-android-restore-input/1' &&
        input['run_id'] == run &&
        input['source_commit'] == source &&
        input['application_id'] == AlkionIdentity.applicationId &&
        input['variant'] == restoreVariant &&
        RegExp(r'^[a-f0-9]{32}$').hasMatch('${input['producer_run_id']}') &&
        RegExp(
          r'^[a-f0-9]{40}$',
        ).hasMatch('${input['producer_source_commit']}'),
    'Foreign received-input binding',
  );
  final chain = restoreMap(input['proof_chain']);
  _keys(chain, {
    'disposable',
    'driver',
    'updates',
    'lifecycle',
    'documents',
    'provider_save_good',
    'receiving',
  });
  must(
    chain.values.every((v) => v is String && _hex.hasMatch(v)),
    'Missing exact prior-proof digests',
  );
  final verified = await validateRestoreEvidence(
    await restoreRegular(File(p.join(directory.path, 'received.alkionbackup'))),
    restoreMap(input['documents']),
    restoreMap(input['receiving']),
    input,
    applicationId: AlkionIdentity.applicationId,
    variant: restoreVariant,
  );
  verified.requireWriterVariant();
  await validateOppositeInput(directory, restoreMap(input['opposite']));
  return verified;
}

Future<VerifiedBackup> validateRestoreEvidence(
  Uint8List bytes,
  Map<String, Object?> report,
  Map<String, Object?> receiving,
  Map<String, Object?> evidence, {
  required String applicationId,
  required String variant,
}) async {
  must(
    report['format'] == 'alkion-android-documents-proof/1' &&
        report['phase'] == 'documents-provider' &&
        report['complete'] == true &&
        report['result'] == 'PASS' &&
        report['error'] == null &&
        report['failed_case'] == null &&
        report['failures'] == null &&
        report['application_id'] == applicationId &&
        report['variant'] == variant &&
        report['provider_package'] ==
            'dev.animusstudio.alkion.synthetic.documents' &&
        report['provider_authority'] ==
            'dev.animusstudio.alkion.synthetic.documents.provider' &&
        report['run_id'] == evidence['producer_run_id'] &&
        report['source_commit'] == evidence['producer_source_commit'],
    'Producer terminal report failed or foreign',
  );
  final cases = restoreMap(report['cases']);
  _keys(cases, _documentOutcomes.keys.toSet());
  for (final entry in _documentOutcomes.entries) {
    final item = restoreMap(cases[entry.key]);
    must(
      item['result'] == 'PASS' &&
          item['outcome'] == entry.value &&
          item['originals_preserved'] == true &&
          item['selected_generation_unchanged'] == true,
      'Producer case is not a passing nested object: ${entry.key}',
    );
  }
  must(
    evidence['length'] == bytes.length &&
        evidence['sha256'] == restoreDigest(bytes),
    'Received input changed',
  );
  final container = restoreMap(receiving['container']);
  must(
    receiving['format'] == 'alkion-receiving-verification/1' &&
        receiving['result'] == 'verified' &&
        receiving['inventory_result'] == 'all_covered_rows_match' &&
        container['length'] == bytes.length &&
        container['sha256'] == evidence['sha256'],
    'Receiving verifier receipt mismatch',
  );
  final verified = await verifyBackupBytes(bytes);
  final facts = restoreMap(report['fixture']);
  must(
    (verified.manifest['tool'] as Map)['application_id'] == applicationId &&
        sameRestoreValue(receiving['tool'], verified.manifest['tool']) &&
        sameRestoreValue(
          verified.facts.state.manifestInventory(),
          facts['inventory'],
        ) &&
        sameRestoreValue(receiving['inventory'], facts['inventory']) &&
        sameRestoreValue(receiving['schema'], verified.facts.schema) &&
        verified.profileId == facts['source_profile_id'] &&
        verified.installationId == facts['source_installation_id'] &&
        verified.generation == facts['source_generation'] &&
        documents
            .documentsFixtureViolations(verified.facts.state, facts)
            .isEmpty,
    'Received backup lacks exact rich source fixture',
  );
  return verified;
}

Future<VerifiedBackup> validateOppositeInput(
  Directory directory,
  Map<String, Object?> input,
) async {
  _keys(input, {
    'format',
    'application_id',
    'variant',
    'producer_run_id',
    'producer_source_commit',
    'length',
    'sha256',
    'documents_sha256',
    'receiving_sha256',
    'proof_chain',
  });
  final variant = restoreVariant == 'dev' ? 'supported' : 'dev';
  final package = variant == 'dev'
      ? 'dev.animusstudio.alkion.dev'
      : 'dev.animusstudio.alkion';
  must(
    input['format'] == 'alkion-android-opposite-input/1' &&
        input['application_id'] == package &&
        input['variant'] == variant &&
        RegExp(r'^[a-f0-9]{32}$').hasMatch('${input['producer_run_id']}') &&
        RegExp(
          r'^[a-f0-9]{40}$',
        ).hasMatch('${input['producer_source_commit']}'),
    'Opposite ingress does not bind the actual other variant',
  );
  final chain = restoreMap(input['proof_chain']);
  _keys(chain, {
    'disposable',
    'driver',
    'updates',
    'lifecycle',
    'documents',
    'provider_save_good',
    'receiving',
  });
  must(
    chain.values.every((v) => v is String && _hex.hasMatch(v)),
    'Opposite prior-proof digests missing',
  );
  final rawDocuments = await restoreRegular(
    File(p.join(directory.path, 'opposite-documents.json')),
  );
  final rawReceiving = await restoreRegular(
    File(p.join(directory.path, 'opposite-receiving.json')),
  );
  must(
    restoreDigest(rawDocuments) == input['documents_sha256'] &&
        restoreDigest(rawReceiving) == input['receiving_sha256'] &&
        chain['documents'] == input['documents_sha256'] &&
        chain['receiving'] == input['receiving_sha256'],
    'Opposite raw producer/receiving evidence changed',
  );
  return validateRestoreEvidence(
    await restoreRegular(File(p.join(directory.path, 'opposite.alkionbackup'))),
    restoreMap(jsonDecode(utf8.decode(rawDocuments))),
    restoreMap(jsonDecode(utf8.decode(rawReceiving))),
    input,
    applicationId: package,
    variant: variant,
  );
}

/// Fixed request order and raw hash chain; no request supplies a path/program.
final class RestoreProtocol {
  RestoreProtocol._(
    this.directory,
    this.request,
    this.input,
    this.backup,
    this.history,
    this.requestHash,
    this.inputHash,
  );
  final Directory directory;
  final Map<String, Object?> request, input;
  final VerifiedBackup backup;
  final List<Map<String, Object?>> history;
  final String requestHash, inputHash;
  int get sequence => request['sequence'] as int;
  String get action => restoreSteps[sequence - 1];
  String number(int n) => n.toString().padLeft(3, '0');
  File file(String stem, int n) =>
      File(p.join(directory.path, '$stem-${number(n)}.json'));
  Map<String, Object?> envelope(String format) => {
    'format': format,
    'run_id': request['run_id'],
    'source_commit': request['source_commit'],
    'application_id': AlkionIdentity.applicationId,
    'variant': restoreVariant,
    'sequence': sequence,
    'action': action,
    'request_sha256': requestHash,
    'input_sha256': inputHash,
    'pid': pid,
  };

  static Future<RestoreProtocol> read(
    Directory directory, {
    required String run,
    required String source,
    int? currentPid,
  }) async {
    must(
      RegExp(r'^[a-f0-9]{32}$').hasMatch(run) &&
          RegExp(r'^[a-f0-9]{40}$').hasMatch(source),
      'Explicit compiled run/source required',
    );
    final pointer = restoreMap(
      jsonDecode(
        utf8.decode(
          await restoreRegular(
            File(p.join(directory.path, 'current.json')),
            limit: 1024,
          ),
        ),
      ),
    );
    _keys(pointer, {'format', 'sequence', 'request_sha256'});
    final sequence = pointer['sequence'];
    must(
      pointer['format'] == 'alkion-android-restore-pointer/1' &&
          sequence is int &&
          sequence >= 1 &&
          sequence <= restoreSteps.length &&
          _hex.hasMatch('${pointer['request_sha256']}'),
      'Invalid current request pointer',
    );
    final n = sequence as int;
    final inputBytes = await restoreRegular(
      File(p.join(directory.path, 'input.json')),
    );
    final input = restoreMap(jsonDecode(utf8.decode(inputBytes)));
    final inputHash = restoreDigest(inputBytes);
    final history = <Map<String, Object?>>[];
    String? prior;
    Map<String, Object?>? current;
    String? currentHash;
    for (var index = 1; index <= n; index++) {
      final label = index.toString().padLeft(3, '0');
      final raw = await restoreRegular(
        File(p.join(directory.path, 'request-$label.json')),
        limit: 4096,
      );
      final request = restoreMap(jsonDecode(utf8.decode(raw)));
      _keys(request, {
        'format',
        'run_id',
        'source_commit',
        'application_id',
        'variant',
        'sequence',
        'action',
        'input_sha256',
        'prior_receipt_sha256',
      });
      must(
        request['format'] == 'alkion-android-restore-request/1' &&
            request['run_id'] == run &&
            request['source_commit'] == source &&
            request['application_id'] == AlkionIdentity.applicationId &&
            request['variant'] == restoreVariant &&
            request['sequence'] == index &&
            request['action'] == restoreSteps[index - 1] &&
            request['input_sha256'] == inputHash &&
            request['prior_receipt_sha256'] == prior,
        'Stale/foreign/out-of-order request',
      );
      if (index == n) {
        current = request;
        currentHash = restoreDigest(raw);
        break;
      }
      final receiptBytes = await restoreRegular(
        File(p.join(directory.path, 'receipt-$label.json')),
      );
      must(
        FileSystemEntity.typeSync(
              p.join(directory.path, 'failure-$label.json'),
              followLinks: false,
            ) ==
            FileSystemEntityType.notFound,
        'Prior framework failure retained',
      );
      final receipt = restoreMap(jsonDecode(utf8.decode(receiptBytes)));
      final barrier = index >= 3 && index <= 8;
      must(
        receipt['format'] ==
                (barrier
                    ? 'alkion-android-restore-checkpoint/1'
                    : 'alkion-android-restore-proof/1') &&
            receipt['run_id'] == run &&
            receipt['source_commit'] == source &&
            receipt['application_id'] == AlkionIdentity.applicationId &&
            receipt['variant'] == restoreVariant &&
            receipt['sequence'] == index &&
            receipt['action'] == restoreSteps[index - 1] &&
            receipt['request_sha256'] == restoreDigest(raw) &&
            receipt['input_sha256'] == inputHash &&
            receipt['pid'] is int &&
            receipt['pid'] != (currentPid ?? pid) &&
            history.every((old) => old['pid'] != receipt['pid']) &&
            (barrier
                ? receipt['complete'] == false && receipt['result'] == 'BARRIER'
                : receipt['complete'] == true &&
                      receipt['result'] == 'PASS' &&
                      receipt['closed'] == true),
        'Prior receipt failed, changed, replayed or same process',
      );
      history.add(receipt);
      prior = restoreDigest(receiptBytes);
    }
    must(
      currentHash == pointer['request_sha256'] &&
          FileSystemEntity.typeSync(
                p.join(
                  directory.path,
                  'claim-${n.toString().padLeft(3, '0')}.json',
                ),
                followLinks: false,
              ) ==
              FileSystemEntityType.notFound &&
          FileSystemEntity.typeSync(
                p.join(
                  directory.path,
                  'receipt-${n.toString().padLeft(3, '0')}.json',
                ),
                followLinks: false,
              ) ==
              FileSystemEntityType.notFound,
      'Replayed request or pointer digest mismatch',
    );
    final verified = await validateRestoreInput(
      directory,
      input,
      run: run,
      source: source,
    );
    return RestoreProtocol._(
      directory,
      current!,
      input,
      verified,
      history,
      currentHash!,
      inputHash,
    );
  }

  Future<void> claim() => restorePublish(
    file('claim', sequence),
    envelope('alkion-android-restore-claim/1'),
  );
  Future<void> immutableInput() async {
    must(
      restoreDigest(
                await restoreRegular(
                  File(p.join(directory.path, 'input.json')),
                ),
              ) ==
              inputHash &&
          restoreDigest(
                await restoreRegular(
                  File(p.join(directory.path, 'received.alkionbackup')),
                ),
              ) ==
              input['sha256'],
      'Immutable receiving ingress changed',
    );
    final other = restoreMap(input['opposite']);
    for (final file in {
      'opposite.alkionbackup': 'sha256',
      'opposite-documents.json': 'documents_sha256',
      'opposite-receiving.json': 'receiving_sha256',
    }.entries) {
      must(
        restoreDigest(
              await restoreRegular(File(p.join(directory.path, file.key))),
            ) ==
            other[file.value],
        'Immutable opposite ingress changed',
      );
    }
  }
}

Future<LocalStore> openRestored(Directory root) async {
  final profile = await AlkionProfile.existing(supportRoot: root);
  must(profile != null, 'Expected published restored identity');
  return LocalStore.open(
    profile: profile!,
    expectedProfileId: profile.profileId,
    schema: workflowSchemaRegistry(),
  );
}

Future<CoveredState> restoreCovered(LocalStore store) =>
    store.readTransaction((tx) => readCoveredState((sql) => tx.getAll(sql)));
Future<CoveredState> closedRestoreState(Directory root) async {
  final store = await openRestored(root);
  try {
    return await restoreCovered(store);
  } finally {
    await store.close();
  }
}

/// Read-only checkpoint snapshot; preparation and all earlier attempts are pins.
Future<Map<String, Object?>> freshRestoreSnapshot(Directory root) async {
  final service = RestoreService(root);
  final state = await service.freshState();
  must(
    state != null && !state.canStartLocal,
    'Fresh restore unexpectedly allows local start',
  );
  must(
    !File(p.join(root.path, 'local-profile.json')).existsSync(),
    'Blank/early identity published',
  );
  var refused = false;
  try {
    await AlkionProfile.open(supportRoot: root);
  } on GenerationSelectionException catch (e) {
    refused = e.category == 'fresh_restore_interrupted';
  }
  must(refused, 'Fresh preparation did not refuse unrelated identity creation');
  return {
    ...await readRetainedRestorePins(root),
    'pending_id': state!.pending?.restoreId,
    'can_complete': state.canComplete,
    if (state.canComplete) 'intent': state.pending!.intent,
  };
}

/// Reads bytes only: usable after identity publication but before any normal
/// store open can change the selected SQLite file or recover its sidecars.
Future<Map<String, Object?>> readRetainedRestorePins(Directory root) async {
  final preparation = await restoreRegular(
    File(
      p.join(
        freshPreparationDirectory(root.path, AlkionIdentity.applicationId),
        'preparation.json',
      ),
    ),
    limit: 16384,
  );
  final stages = <String, Object?>{};
  if (root.existsSync()) {
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      must(entity is! Link, 'Linked fresh staging');
      if (entity is File &&
          {'alkion.sqlite', 'intent.json'}.contains(p.basename(entity.path))) {
        stages[p.relative(entity.path, from: root.path)] = restoreDigest(
          await restoreRegular(entity),
        );
      }
    }
  }
  return {'preparation_base64': base64Encode(preparation), 'stages': stages};
}

void preserveFreshSnapshot(
  Map<String, Object?> before,
  Map<String, Object?> after, {
  required bool requireSamePending,
}) {
  must(
    before['preparation_base64'] == after['preparation_base64'],
    'Preparation changed',
  );
  final stages = restoreMap(after['stages']);
  must(
    restoreMap(before['stages']).entries.every((e) => stages[e.key] == e.value),
    'Prior staging/intent changed or disappeared',
  );
  if (requireSamePending) {
    must(
      before['pending_id'] == after['pending_id'],
      'Pending restore changed',
    );
  }
}

void verifyClosedFresh(
  VerifiedBackup backup,
  Map<String, Object?> facts,
  CoveredState restored,
  Map<String, Object?> intent,
  Map<String, Object?> snapshot,
) {
  final preparation = restoreMap(
    jsonDecode(
      utf8.decode(base64Decode(snapshot['preparation_base64'] as String)),
    ),
  );
  final profile = restored.tables['profile_state']!.single;
  must(
    profile['profile_id'] == backup.profileId &&
        profile['installation_id'] != backup.installationId &&
        profile['installation_id'] == preparation['installation_id'] &&
        intent['restore_id'] == snapshot['pending_id'] &&
        oracle
            .restoreViolations(
              backup: backup.facts.state,
              previous: null,
              restored: restored,
              intent: intent,
            )
            .isEmpty &&
        documents.documentsFixtureViolations(restored, facts).isEmpty,
    'Exact closed fresh restore oracle failed before runtime adoption',
  );
}

Future<({CoveredState state, Map<String, Object?> pins})>
verifyFreshBeforeRelaunch(
  Directory root,
  VerifiedBackup backup,
  Map<String, Object?> facts,
  Map<String, Object?> snapshot,
  Future<void> Function() relaunch,
) async {
  final pins = await readRetainedRestorePins(root);
  preserveFreshSnapshot(snapshot, pins, requireSamePending: false);
  must(
    sameRestoreValue(snapshot['stages'], pins['stages']),
    'Staging inventory changed before first normal store open',
  );
  final before = await closedRestoreState(root);
  verifyClosedFresh(
    backup,
    facts,
    before,
    restoreMap(snapshot['intent']),
    snapshot,
  );
  await relaunch();
  return (state: before, pins: pins);
}

Future<Map<String, Object?>> completedFreshRefusal(
  Directory root,
  String resolvedId,
  CoveredState baseline,
) async {
  final profile = await AlkionProfile.existing(supportRoot: root);
  must(profile != null, 'Completed refusal requires the restored identity');
  final directory = await profile!.profileDirectory(
    expectedProfileId: profile.profileId,
  );
  must(
    selectedRestoreId(directory) == resolvedId,
    'Resolved ID does not match actual selected restore',
  );
  must(
    (await closedRestoreState(root)).digest() == baseline.digest(),
    'Completed-refusal baseline changed',
  );
  final preparation = Directory(
    freshPreparationDirectory(root.path, AlkionIdentity.applicationId),
  );
  final before = await restoreTree(root),
      prepBefore = await restoreTree(preparation);
  String? category;
  try {
    await RestoreService(root).completeFresh(resolvedId);
  } on StoreException catch (e) {
    category = e.category;
  }
  must(
    category == 'restore_not_pending' &&
        sameRestoreValue(before, await restoreTree(root)) &&
        sameRestoreValue(prepBefore, await restoreTree(preparation)),
    'Completed fresh callback did not refuse with exact retained bytes',
  );
  final after = await closedRestoreState(root);
  must(
    after.digest() == baseline.digest(),
    'Completed fresh callback changed covered state',
  );
  return {
    'resolved_id': resolvedId,
    'outcome': category,
    'unchanged': true,
    'baseline': oracle.stateJson(after),
    'inventory': after.manifestInventory(),
  };
}

Map<String, Object?> restorePayload(Map<String, Object?> row) => restoreMap(
  jsonDecode(utf8.decode(sqlValue(row['payload_bytes']) as List<int>)),
);

/// Only an issued action and an observed absolute-deadline expiry may differ.
/// Every other covered row, including all other local_state rows, stays exact.
List<String> adoptionViolations(
  CoveredState before,
  CoveredState after, {
  required DateTime started,
  required DateTime finished,
  required bool expectAction,
}) {
  final errors = <String>[];
  for (final table in preservedTables.where((t) => t != 'local_state')) {
    if (!sameRestoreValue(before.tables[table], after.tables[table])) {
      errors.add('$table changed');
    }
  }
  Map<String, Map<String, Object?>> locals(CoveredState s) => {
    for (final row in s.tables['local_state']!)
      '${row['state_kind']}/${row['state_key']}': row,
  };
  final old = locals(before), current = locals(after);
  final d = restorePayload(old['draft/active']!),
      t = restorePayload(old['timer/active']!);
  final start = d['restStart'] == null
      ? null
      : DateTime.parse(d['restStart'] as String);
  final due = start?.add(Duration(seconds: d['restTotal'] as int));
  final expired = due != null && !finished.isBefore(due);
  final actualDraft = current['draft/active'];
  final didExpire =
      actualDraft != null &&
      restorePayload(actualDraft)['restStart'] == null &&
      start != null;
  final draftDelta =
      (current['draft/active']!['revision'] as int) -
      (old['draft/active']!['revision'] as int);
  final timerDelta =
      (current['timer/active']!['revision'] as int) -
      (old['timer/active']!['revision'] as int);
  if (didExpire && (draftDelta <= 0 || draftDelta != timerDelta)) {
    errors.add('expiry did not use paired positive draft/timer save revisions');
  }
  bool timestamp(Object? v) {
    final at = v is String ? DateTime.tryParse(v) : null;
    return at != null && !at.isBefore(started) && !at.isAfter(finished);
  }

  for (final entry in old.entries.where(
    (e) => e.key != 'timer/$notificationActionKey',
  )) {
    final actual = current.remove(entry.key);
    if (actual == null) {
      errors.add('${entry.key} removed');
      continue;
    }
    if (didExpire && {'draft/active', 'timer/active'}.contains(entry.key)) {
      final payload =
          Map<String, Object?>.from(entry.key == 'draft/active' ? d : t)
            ..addAll({
              'restStart': null,
              'restTotal': 0,
              'restEndedAt': due?.toIso8601String(),
            });
      final expected = {
        ...entry.value,
        'revision': (entry.value['revision'] as int) + draftDelta,
        'payload_bytes': {'blob_base64': base64Encode(localBytes(payload))},
        'updated_at': actual['updated_at'],
      };
      if (!expired ||
          !timestamp(actual['updated_at']) ||
          !sameRestoreValue(actual, expected)) {
        errors.add('${entry.key} invalid expiry');
      }
    } else if (!sameRestoreValue(actual, entry.value)) {
      errors.add('${entry.key} changed');
    }
  }
  if (due != null && !started.isBefore(due) && !didExpire) {
    errors.add('expired timer not reconciled');
  }
  final action = current.remove('timer/$notificationActionKey');
  final oldAction = old['timer/$notificationActionKey'];
  if (!expectAction) {
    if (!sameRestoreValue(action, oldAction)) {
      errors.add('unexpected action issuance');
    }
  } else {
    final decoded = action == null
        ? null
        : NotificationAction.decode(
            jsonEncode(restorePayload(action)['action']),
          );
    final expectedTimer = after.tables['local_state']!.singleWhere(
      (r) => r['state_kind'] == 'timer' && r['state_key'] == 'active',
    );
    final expectedDraft = restorePayload(
      after.tables['local_state']!.singleWhere(
        (r) => r['state_kind'] == 'draft' && r['state_key'] == 'active',
      ),
    );
    if (action == null ||
        decoded == null ||
        action['status'] != 'issued' ||
        decoded.profileId !=
            after.tables['profile_state']!.single['profile_id'] ||
        decoded.applicationId != AlkionIdentity.applicationId ||
        decoded.generation != expectedTimer['generation'] ||
        decoded.draftId != expectedDraft['draftId'] ||
        decoded.restStart != expectedDraft['restStart'] ||
        decoded.timerRevision != expectedTimer['revision'] ||
        !RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
        ).hasMatch(decoded.token) ||
        !sameRestoreValue(restorePayload(action), {
          'action': decoded.toJson(),
        })) {
      errors.add('action not bound to selected owner/timer');
    } else if (!sameRestoreValue(action, oldAction)) {
      final base = oldAction?['revision'] as int? ?? 0;
      if (!timestamp(action['updated_at']) ||
          action['generation'] != expectedTimer['generation'] ||
          action['profile_id'] != expectedTimer['profile_id'] ||
          ![base + 1, if (didExpire) base + 2].contains(action['revision']) ||
          (oldAction != null && !didExpire)) {
        errors.add('action revision/issuance drift');
      }
    }
  }
  if (current.isNotEmpty) errors.add('unexpected local state: ${current.keys}');
  return errors;
}

Map<String, Object?> adoptionSaveCounts(
  CoveredState before,
  CoveredState after,
) => {
  for (final kind in ['draft', 'timer'])
    kind: {
      'before': before.tables['local_state']!.singleWhere(
        (r) => r['state_kind'] == kind && r['state_key'] == 'active',
      )['revision'],
      'after': after.tables['local_state']!.singleWhere(
        (r) => r['state_kind'] == kind && r['state_key'] == 'active',
      )['revision'],
      'delta':
          (after.tables['local_state']!.singleWhere(
                (r) => r['state_kind'] == kind && r['state_key'] == 'active',
              )['revision']
              as int) -
          (before.tables['local_state']!.singleWhere(
                (r) => r['state_kind'] == kind && r['state_key'] == 'active',
              )['revision']
              as int),
    },
};

Future<Map<String, String>> restoreTree(Directory root) async {
  if (!root.existsSync()) return {};
  final result = <String, String>{};
  for (final e in root.listSync(recursive: true, followLinks: false)) {
    final key = p.relative(e.path, from: root.path);
    result[key] = e is Link
        ? 'link:${e.targetSync()}'
        : e is File
        ? restoreDigest(await e.readAsBytes())
        : 'directory';
  }
  return result;
}

/// Separate fixed synthetic targets; no failed target is deleted or repaired.
Future<Map<String, Object?>> receivingRefusals(
  Directory directory,
  VerifiedBackup backup,
  Map<String, Object?> opposite,
) async {
  await validateOppositeInput(directory, opposite);
  final probes = Directory(p.join(directory.path, 'probes'));
  must(!probes.existsSync(), 'Refusal probes already exist');
  await probes.create();
  final inputs = await Directory(p.join(probes.path, 'inputs')).create();
  final good = File(p.join(directory.path, 'received.alkionbackup'));
  final foreign = File(p.join(directory.path, 'opposite.alkionbackup'));
  final corruptBytes = await good.readAsBytes();
  corruptBytes[corruptBytes.length - 1] ^= 1;
  final corrupt = await File(
    p.join(inputs.path, 'corrupt.alkionbackup'),
  ).writeAsBytes(corruptBytes, flush: true);
  final raw = await File(
    p.join(inputs.path, 'newer.sqlite'),
  ).writeAsBytes(backup.databaseBytes, flush: true);
  final db = sqlite.sqlite3.open(raw.path);
  db.execute('PRAGMA user_version=999');
  db.close();
  final newerBytes = await raw.readAsBytes();
  final newerManifest = restoreMap(jsonDecode(jsonEncode(backup.manifest)));
  (newerManifest['schema'] as Map)['user_version'] = 999;
  newerManifest['database'] = {
    'length': newerBytes.length,
    'sha256': restoreDigest(newerBytes),
  };
  final newer = await File(
    p.join(inputs.path, 'newer.alkionbackup'),
  ).writeAsBytes(backupContainer(newerManifest, newerBytes), flush: true);
  final result = <String, Object?>{};
  for (final name in [
    'foreign-variant',
    'corrupt',
    'newer',
    'nonempty',
    'linked',
    'foreign-profile',
  ]) {
    final parent = await Directory(p.join(probes.path, name)).create();
    final root = Directory(p.join(parent.path, AlkionIdentity.applicationId));
    if (name == 'nonempty') {
      await root.create();
      await File(
        p.join(root.path, 'sentinel'),
      ).writeAsBytes([0, 255, 7], flush: true);
    }
    if (name == 'linked') {
      final target = await Directory(p.join(parent.path, 'retained')).create();
      await File(
        p.join(target.path, 'sentinel'),
      ).writeAsBytes([0, 255, 8], flush: true);
      await Link(root.path).create(target.path);
    }
    if (name == 'foreign-profile') {
      final profile = await AlkionProfile.open(supportRoot: root);
      final store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: workflowSchemaRegistry(),
      );
      await store.close();
    }
    final before = await restoreTree(parent),
        inputBefore = await restoreTree(inputs);
    final input = switch (name) {
      'foreign-variant' => foreign,
      'corrupt' => corrupt,
      'newer' => newer,
      _ => good,
    };
    String? category;
    try {
      await RestoreService(root).restore(input);
    } on StoreException catch (e) {
      category = e.category;
    } on FileSystemException {
      category = 'linked_path';
    } on FormatException catch (e) {
      if (name != 'linked' || e.message != 'Symlink in Alkion storage path') {
        rethrow;
      }
      category = 'linked_path';
    }
    final expected = switch (name) {
      'foreign-variant' => 'backup_foreign_variant',
      'corrupt' => 'backup_digest_mismatch',
      'newer' => 'backup_newer_schema',
      'nonempty' => 'restore_target_not_empty',
      'foreign-profile' => 'foreign_profile',
      _ => 'linked_path',
    };
    must(
      category == expected &&
          sameRestoreValue(before, await restoreTree(parent)) &&
          sameRestoreValue(inputBefore, await restoreTree(inputs)) &&
          restoreDigest(await restoreRegular(foreign)) == opposite['sha256'],
      'Refusal $name failed or changed retained state: $category',
    );
    result[name] = {'result': 'PASS', 'outcome': category, 'preserved': true};
  }
  return result;
}

final class _PinnedDocuments implements DocumentAccess {
  _PinnedDocuments(this.protocol);
  final RestoreProtocol protocol;
  @override
  Future<DocumentFile?> open({
    required int maxBytes,
    List<String> mimeTypes = const ['application/octet-stream'],
  }) async {
    final selected = await AndroidDocuments.instance.open(
      maxBytes: maxBytes,
      mimeTypes: mimeTypes,
    );
    if (selected != null) {
      must(
        selected.length == protocol.input['length'] &&
            selected.sha256 == protocol.input['sha256'] &&
            restoreDigest(await restoreRegular(File(selected.path))) ==
                protocol.input['sha256'],
        'Picker selected different receiving bytes',
      );
    }
    return selected;
  }

  @override
  Future<DocumentSave?> save(
    File source, {
    required String filename,
    required int maxBytes,
    String mimeType = 'application/octet-stream',
  }) => Future.error(StateError('Receiving proof has no Save route'));
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  RestoreProtocol? protocol;
  var closed = false;
  final detail = <String, Object?>{};
  unawaited(
    binding.allTestsPassed.future.then((passed) async {
      final value = protocol;
      if (value == null) return;
      Object? inputError;
      try {
        await value.immutableInput();
      } catch (e) {
        inputError = e;
      }
      final target = value.file('receipt', value.sequence);
      await restorePublish(
        target.existsSync() ? value.file('failure', value.sequence) : target,
        {
          ...value.envelope('alkion-android-restore-proof/1'),
          'complete': true,
          'closed': closed,
          'result': passed && closed && inputError == null ? 'PASS' : 'FAIL',
          'evidence': detail,
          if (inputError != null) 'error': '$inputError',
          if (!passed)
            'failures': binding.failureMethodsDetails
                .map((f) => f.details)
                .toList(),
          'unrun': [
            'host_process_death_attestation',
            'same_profile_replacement',
            'keep_current',
            'actual_old_notification_payload',
            'owner_device',
            'physical_power_loss',
          ],
        },
      );
    }),
  );
  testWidgets(
    'fresh receiving restore fixed protocol',
    (tester) async {
      late Directory root;
      await tester.runAsync(() async {
        must(Platform.isAndroid, 'Installed Android runtime required');
        root = await checkedAlkionSupportRoot();
        final directory = Directory(
          p.join(root.parent.path, 'android-restore-proof', restoreRun),
        );
        protocol = await RestoreProtocol.read(
          directory,
          run: restoreRun,
          source: restoreSource,
        );
        await protocol!.claim();
      });
      final value = protocol!;
      final facts = restoreMap(restoreMap(value.input['documents'])['fixture']);
      final service = RestoreService(root);
      if (value.action == 'preflight') {
        await tester.runAsync(() async {
          must(
            !root.existsSync() &&
                !Directory(
                  freshPreparationDirectory(
                    root.path,
                    AlkionIdentity.applicationId,
                  ),
                ).existsSync(),
            'Receiver canonical target/preparation must be absent',
          );
          final state = (await service.freshState())!;
          must(
            state.canStartLocal && !root.existsSync(),
            'Preflight created an identity/root',
          );
          detail['input_verified'] = true;
          closed = true;
        });
        return;
      }
      if (value.action == 'refusals') {
        await tester.runAsync(() async {
          detail['cases'] = await receivingRefusals(
            value.directory,
            value.backup,
            restoreMap(value.input['opposite']),
          );
          must(
            !root.existsSync(),
            'Refusal probes changed receiving canonical root',
          );
          closed = true;
        });
        return;
      }
      if (value.action == 'completed-refusal') {
        await tester.runAsync(() async {
          final prior = restoreMap(value.history.last['evidence']);
          final fresh = restoreMap(prior['fresh']);
          must(
            (fresh['intent'] as Map)['restore_id'] == fresh['pending_id'],
            'Completed callback lacks the exact resolved intent',
          );
          detail.addAll(
            await completedFreshRefusal(
              root,
              fresh['pending_id'] as String,
              oracle.stateFromJson(restoreMap(prior['baseline'])),
            ),
          );
          detail['fresh'] = fresh;
          closed = true;
        });
        return;
      }
      if (value.action.startsWith('cold-')) {
        await tester.runAsync(() async {
          final prior = restoreMap(value.history.last['evidence']);
          final baseline = oracle.stateFromJson(restoreMap(prior['baseline']));
          final before = await closedRestoreState(root);
          must(
            before.digest() == baseline.digest(),
            'Cold-launch pre-adoption baseline changed',
          );
          final started = DateTime.now().toUtc();
          final runtime = await AlkionRuntime.open(root);
          try {
            await runtime.flushPersistence();
          } finally {
            await runtime.close();
          }
          final after = await closedRestoreState(root);
          final ended = DateTime.now().toUtc();
          must(
            adoptionViolations(
              before,
              after,
              started: started,
              finished: ended,
              expectAction: true,
            ).isEmpty,
            'Cold runtime changed rows beyond bounded deadline/action adoption',
          );
          must(
            after.digest() == baseline.digest(),
            'Cold launch differs from established baseline',
          );
          detail.addAll({
            'baseline': oracle.stateJson(after),
            'inventory': after.manifestInventory(),
            'adoption_save_counts': adoptionSaveCounts(before, after),
            'previous_pid': value.history.last['pid'],
            'cold_process': true,
          });
          closed = true;
        });
        return;
      }
      final prior = value.sequence > 3
          ? restoreMap(restoreMap(value.history.last['evidence'])['fresh'])
          : null;
      await tester.runAsync(() async {
        if (prior != null) {
          preserveFreshSnapshot(
            prior,
            await freshRestoreSnapshot(root),
            requireSamePending: value.sequence >= 6,
          );
        }
      });
      final barrier = Completer<void>(), complete = Completer<void>();
      CoveredState? selectedBefore;
      Map<String, Object?>? observedPins;
      DateTime? adoptionStarted;
      Future<void> checkpoint(String phase) async {
        if (value.action != phase) return;
        final snapshot = await freshRestoreSnapshot(root);
        if (prior != null) {
          preserveFreshSnapshot(
            prior,
            snapshot,
            requireSamePending: value.sequence >= 6,
          );
        }
        must(
          snapshot['can_complete'] == (value.sequence >= 5),
          'Wrong reselection/completion boundary',
        );
        await value.immutableInput();
        await restorePublish(value.file('receipt', value.sequence), {
          ...value.envelope('alkion-android-restore-checkpoint/1'),
          'complete': false,
          'closed': false,
          'result': 'BARRIER',
          'evidence': {'fresh': snapshot},
          'death_proven': false,
        });
        barrier.complete();
        await Completer<void>().future;
      }

      late AlkionFirstStartApp first;
      AlkionApp? adopted;
      await tester.runAsync(
        () => launchAlkion(
          root,
          present: (app) {
            if (app is AlkionFirstStartApp) {
              first = app;
            } else if (app is AlkionApp && value.action == 'complete') {
              adopted = app;
            } else {
              throw StateError(
                'Unexpected production first-start/relaunch surface',
              );
            }
          },
        ),
      );
      final screen = AlkionFirstStartApp(
        service: RestoreService(root, checkpoint: checkpoint),
        state: first.state,
        startLocal: first.startLocal,
        documents: _PinnedDocuments(value),
        relaunch: () async {
          must(
            value.action == 'complete',
            'Unexpected completion instead of checkpoint',
          );
          final verification = await verifyFreshBeforeRelaunch(
            root,
            value.backup,
            facts,
            prior!,
            () async {
              adoptionStarted = DateTime.now().toUtc();
              await first.relaunch();
            },
          );
          selectedBefore = verification.state;
          observedPins = verification.pins;
          complete.complete();
        },
      );
      await tester.pumpWidget(screen);
      await tester.pump();
      if (!first.state.canStartLocal) {
        must(
          find.byKey(const Key('first-start-local')).evaluate().isEmpty &&
              find.byKey(const Key('restore-keep-current')).evaluate().isEmpty,
          'Fresh pending UI offers unrelated local/Keep choice',
        );
      }
      if (first.state.canComplete) {
        await tester.tap(find.byKey(const Key('first-restore-complete')));
      } else {
        await tester.runAsync(
          () => restorePublish(value.file('picker', value.sequence), {
            ...value.envelope('alkion-android-restore-picker/1'),
            'input_sha256': value.input['sha256'],
          }),
        );
        await tester.tap(find.byKey(const Key('first-restore')));
        for (
          var i = 0;
          i < 900 && find.byType(TextButton).evaluate().length < 2;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
        }
        must(
          find.byType(TextButton).evaluate().length == 2,
          'Production restore confirmation unavailable',
        );
        await tester.tap(find.byType(TextButton).last);
      }
      if (value.action != 'complete') {
        await tester.runAsync(
          () => barrier.future.timeout(const Duration(seconds: 90)),
        );
        // Receipt is a barrier, never a death proof or terminal success. Host must
        // kill this exact PID before any later request may be admitted.
        await tester.runAsync(() => Completer<void>().future);
      } else {
        await tester.runAsync(() async {
          await complete.future.timeout(const Duration(seconds: 90));
          final runtime = adopted!.runtime;
          try {
            await runtime.flushPersistence();
          } finally {
            await runtime.close();
          }
          final after = await closedRestoreState(root);
          must(
            adoptionViolations(
              selectedBefore!,
              after,
              started: adoptionStarted!,
              finished: DateTime.now().toUtc(),
              expectAction: true,
            ).isEmpty,
            'Runtime adoption exceeded exact permitted deltas',
          );
          detail.addAll({
            'closed_restore': oracle.stateJson(selectedBefore!),
            'baseline': oracle.stateJson(after),
            'inventory': after.manifestInventory(),
            'adoption_save_counts': adoptionSaveCounts(selectedBefore!, after),
            'fresh': prior,
            'observed_pins_before_first_store_open': observedPins,
          });
          closed = true;
        });
        await tester.pumpWidget(const SizedBox());
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
