import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/animus/adapters/http.dart';
import 'package:alkion/animus/config.dart';
import 'package:alkion/animus/connection.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/ports.dart';
import 'package:alkion/animus/probe.dart';
import 'package:alkion/animus/recovery_review.dart';
import 'package:alkion/animus/remote_recovery_repository.dart';
import 'package:alkion/animus/workout_send.dart';
import 'package:alkion/animus/workout_upload_repository.dart';
import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/store/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import '../../tool/alkion_store_recovery.dart' show syntheticProfile;

/// Opt-in actual API/SQLite pairing. The private operator fixture owns a fresh
/// synthetic service, PostgreSQL restore and scenario controls. Only public
/// configuration, public request bytes and scenario names cross this bridge.
/// It supplies signed synthetic sessions; browser/provider lifecycle and device
/// recovery require their own qualification. No API reply is fabricated here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final input = Platform.environment['ANIMUS_PAIRED_RECOVERY_FIXTURE'];
  test(
    'actual recovery API preserves surviving/lost receipts and local evidence',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final fixture = _Fixture(input!);
      final root = await Directory.systemTemp.createTemp(
        'alkion-paired-recovery-',
      );
      final profile = await syntheticProfile(root);
      var store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
      );
      final receipts = <String, String>{};
      final owners = <_Owner>[];
      final reviews = <AnimusRecoveryReview>[];
      _Owner owner(Map<String, String> values, LocalStore database) {
        final value = _Owner(fixture, values, database);
        owners.add(value);
        return value;
      }

      AnimusRecoveryReview review(_Owner current, {LocalDatabase? database}) {
        final value = AnimusRecoveryReview(
          database: database ?? current.store,
          installationId: current.store.profile.installationId,
          connection: current.connection,
        );
        reviews.add(value);
        return value;
      }

      void passed(String key, bool value) {
        receipts[key] = value ? 'PASS' : 'FAIL';
        expect(value, true, reason: key);
      }

      try {
        final held = _HeldFinishHttp();
        final first = _Owner(fixture, fixture.values, store, http: held);
        owners.add(first);
        passed(
          'construction_is_inert',
          (await fixture.audit()).length == 1 &&
              await store
                  .getAll('SELECT * FROM animus_exchange_intents')
                  .then((v) => v.isEmpty),
        );
        await first.connect();
        passed(
          'actual_discovery_and_reader_verified',
          first.connection.state == AnimusConnectionState.verified,
        );
        final oldG = fixture.data['generation'] as String;
        final (surviving, exercise) = await _workout(store);
        final selected = await first.sender.select(surviving);
        expect(selected.issue, isNull);
        await first.sender.send(selected);
        passed(
          'first_workout_acknowledged',
          (await first.sender.selectionFor(surviving))?.readBackVerified ==
              true,
        );
        final uploads = WorkoutUploadRepository(store, profile.installationId);
        final oldSelection = (await uploads.load(surviving))!;
        final oldAttempt = (await uploads.attempt(oldSelection.operationId))!;
        await fixture.command('snapshot');

        // This workout shares the already acknowledged definition. The backup
        // contains that definition, so exact reviewed finish remains admissible.
        final (lost, _) = await _workout(store, exerciseId: exercise);
        final pending = await first.sender.select(lost);
        expect(pending.issue, isNull);
        held.arm();
        final sending = first.sender.send(pending);
        await held.entered.future.timeout(const Duration(seconds: 10));
        final lostSelection = (await uploads.load(lost))!;
        final lostAttempt = (await uploads.attempt(lostSelection.operationId))!;
        final attempts = await _rows(store, 'operation_attempts');
        final outcomes = await _rows(store, 'attempt_outcomes');
        final restored = await fixture.command('restore');
        final newG = restored['generation'] as String;
        expect(newG, isNot(oldG));
        await first.connection.verify();
        final binding = RemoteRecoveryBinding.fromWorkoutBinding(
          workoutBinding(
            profile.installationId,
            store.token,
            first.config,
            first.connection.identity!,
          ),
        );
        passed(
          'unsettled_original_exchange_fences_before_late_actual_reply',
          !(await RemoteRecoveryRepository(store).state(binding.id)).ready,
        );
        final values = {
          ...fixture.values,
          'ALKION_ANIMUS_READ_ADMISSION': restored['read_admission'] as String,
        };
        final current = owner(values, store);
        await current.connect();
        final failedAdoption = review(current, database: _AdoptionFault(store));
        await failedAdoption.compare();
        expect(failedAdoption.issue, isNull);
        final stage = failedAdoption.snapshot!.stage!;
        passed(
          'actual_current_G_view_staged_before_old_reply_delivery',
          stage.verified && stage.generation == newG,
        );
        final originalExchange = (await store.getAll(
          "SELECT * FROM animus_exchange_intents WHERE path_kind='action' AND operation_id=? AND attempt_id=?",
          [lostAttempt.operationId, lostAttempt.id],
        )).single;
        expect(originalExchange['request_generation'], oldG);
        expect(originalExchange['operation_generation'], oldG);
        expect(
          originalExchange['request_hash'],
          lostAttempt.row['request_hash'],
        );
        expect(originalExchange['state'], 'archived');
        final heldResponse = held.genuineResponse!;
        expect(heldResponse.statusCode, 200);
        expect(heldResponse.headers['x-hub-recovery-generation'], oldG);
        final evidenceBeforeRelease = await _evidenceWithIntent(store);
        final priorEvidenceIds = evidenceBeforeRelease
            .map((row) => row['evidence_id'] as String)
            .toSet();
        bool isNewHeldReply(Map<String, dynamic> row) => _isNewHeldReply(
          row,
          priorEvidenceIds: priorEvidenceIds,
          originalExchange: originalExchange,
          heldResponse: heldResponse,
        );
        // Earlier discovery/read/write evidence must never satisfy this proof.
        expect(evidenceBeforeRelease, isNotEmpty);
        expect(evidenceBeforeRelease.where(isNewHeldReply), isEmpty);
        held.release.complete();
        await sending;
        final evidenceAfterRelease = await _evidenceWithIntent(store);
        passed(
          'late_reply_appends_without_acknowledging_old_attempt',
          await _rows(store, 'attempt_outcomes').then((v) => v == outcomes) &&
              evidenceAfterRelease.where(isNewHeldReply).length == 1 &&
              evidenceAfterRelease.length == evidenceBeforeRelease.length + 1 &&
              (await RemoteRecoveryRepository(
                    store,
                  ).reviewSnapshot(binding))?.stage?.id ==
                  stage.id &&
              !(await RemoteRecoveryRepository(store).state(binding.id)).ready,
        );
        passed(
          'exact_attempts_survive_capture',
          await _rows(store, 'operation_attempts') == attempts,
        );

        // Current credentials plus the old restored reader remain denied.
        final auth = await fixture.authorize(first.config);
        final http = IoAnimusHttpPort();
        Future<AnimusHttpResponse> direct(String reader) => http.get(
          uri: first.config.definitionUri,
          headers: {
            'Authorization': 'Bearer ${auth.accessToken}',
            'X-Hub-Read-Admission': reader,
            'X-Hub-Recovery-Generation': newG,
          },
          maxResponseBytes: 65536,
          timeout: const Duration(seconds: 10),
        );
        final staleReader = await direct(first.config.readAdmission);
        passed(
          'restored_reader_denied_without_G_disclosure',
          staleReader.statusCode == 403 &&
              !staleReader.headers.containsKey('x-hub-recovery-generation'),
        );
        await fixture.command('revoke_grant');
        final revoked = await direct(values['ALKION_ANIMUS_READ_ADMISSION']!);
        passed(
          'revoked_grant_denied_without_G_disclosure',
          revoked.statusCode == 403 &&
              !revoked.headers.containsKey('x-hub-recovery-generation'),
        );
        await fixture.command('reissue_grant');
        passed(
          'new_reader_current_grant_reads_at_current_G',
          (await direct(values['ALKION_ANIMUS_READ_ADMISSION']!)).statusCode ==
              200,
        );
        Future<AnimusHttpResponse> status(
          WorkoutUploadAttempt attempt,
        ) => http.get(
          uri: first.config.apiOrigin.replace(
            path:
                '/v1/data-spaces/${first.config.dataSpaceId}/training/operations/workouts/${attempt.operationId}',
            queryParameters: {'operation_generation': oldG},
          ),
          headers: {
            'Authorization': 'Bearer ${auth.accessToken}',
            'X-Hub-Read-Admission': values['ALKION_ANIMUS_READ_ADMISSION']!,
            'X-Hub-Recovery-Generation': newG,
          },
          maxResponseBytes: 65536,
          timeout: const Duration(seconds: 10),
        );
        final survivingStatus = await status(oldAttempt),
            missingStatus = await status(lostAttempt);
        passed(
          'actual_status_distinguishes_surviving_and_missing_old_receipts',
          survivingStatus.statusCode == 200 &&
              missingStatus.statusCode == 409 &&
              (jsonDecode(utf8.decode(missingStatus.body)) as Map)['error'] ==
                  'operation_recovery_required',
        );
        await http.close();

        passed(
          'finite_actual_comparison_keeps_surviving_and_missing_targets',
          stage.verified &&
              stage.generation == newG &&
              stage.inventory['coverage'] == 'incomplete-known-targets' &&
              stage.count(RecoveryComparison.unchanged) > 0 &&
              stage.comparisons.containsKey(
                'workouts/${lostAttempt.command['target']['id']}',
              ),
        );
        await failedAdoption.adopt(stage.id);
        passed(
          'actual_reads_then_local_COMMIT_failure_keeps_old_G',
          failedAdoption.issue == RecoveryReviewIssue.localRecovery &&
              (await RemoteRecoveryRepository(
                    store,
                  ).state(binding.id)).generation ==
                  oldG &&
              !(await RemoteRecoveryRepository(store).state(binding.id)).ready,
        );
        await failedAdoption.close();
        await first.close();
        await current.close();
        await store.close();
        store = await LocalStore.open(
          profile: profile,
          expectedProfileId: profile.profileId,
        );
        passed(
          'fresh_SQLite_handle_retains_exact_attempts_and_fence',
          await _rows(store, 'operation_attempts') == attempts &&
              !(await RemoteRecoveryRepository(store).state(binding.id)).ready,
        );
        final reopened = owner(values, store);
        await reopened.connect();
        final recovery = review(reopened);
        await recovery.compare();
        expect(recovery.issue, isNull);
        await recovery.adopt(recovery.snapshot!.stage!.id);
        passed(
          'explicit_atomic_adoption_keeps_old_operations_blocked',
          recovery.snapshot!.adopted &&
              await RemoteRecoveryRepository(
                store,
              ).operationBlocked(binding.id, lostAttempt.operationId) &&
              await RemoteRecoveryRepository(
                    store,
                  ).operationOrigin(lostAttempt.operationId) ==
                  oldG,
        );

        final beforeReplay = (await fixture.command('counts'))['receipts'];
        final surviveScope = (await recovery.prepareRetry(surviving))!;
        await recovery.retryReviewed(surviveScope);
        passed(
          'surviving_old_receipt_acknowledges_under_current_access',
          recovery.reviewedReply &&
              (await fixture.command('counts'))['receipts'] == beforeReplay,
        );
        final replayAudit = await fixture.audit();
        final actualReplay = replayAudit.lastWhere(
          (r) => r['method'] == 'POST',
        );
        passed(
          'surviving_retry_keeps_exact_bytes_ID_O',
          actualReplay['request_base64'] == base64Encode(oldAttempt.bytes) &&
              actualReplay['operation_generation'] == oldG &&
              actualReplay['request_generation'] == newG,
        );

        await fixture.command(
          'review_blocked',
          attempt: lostAttempt,
          origin: oldG,
        );
        final missingScope = (await recovery.prepareRetry(lost))!;
        await recovery.retryReviewed(missingScope);
        passed(
          'missing_old_receipt_stays_uncertain_after_retain_blocked',
          !recovery.reviewedReply &&
              (await fixture.audit()).last['status'] == 409 &&
              (await fixture.command('counts'))['receipts'] == beforeReplay,
        );
        // The reviewed one-shot is consumed locally even when denied.
        final afterDenied = (await fixture.audit()).length;
        await recovery.retryReviewed(missingScope);
        passed(
          'one_confirmation_cannot_repeat_denied_request',
          (await fixture.audit()).length == afterDenied,
        );
        await recovery.compare();
        await recovery.adopt(recovery.snapshot!.stage!.id);
        await fixture.command(
          'review_apply_once',
          attempt: lostAttempt,
          origin: oldG,
        );
        final scope = (await recovery.prepareRetry(lost))!;
        await recovery.retryReviewed(scope);
        final applied = await fixture.command('counts');
        passed(
          'scoped_apply_once_commits_missing_original_exactly_once',
          recovery.reviewedReply &&
              applied['receipts'] == (beforeReplay as int) + 1 &&
              applied['consumed_reviews'] == 1,
        );
        final appliedAudit = await fixture.audit();
        final action = appliedAudit.lastWhere((r) => r['method'] == 'POST');
        passed(
          'apply_once_keeps_exact_request_ID_hash_O',
          action['request_base64'] == base64Encode(lostAttempt.bytes) &&
              action['operation_generation'] == oldG &&
              action['request_generation'] == newG &&
              await _rows(store, 'operation_attempts') == attempts,
        );
        final calls = appliedAudit.length;
        await recovery.retryReviewed(scope);
        passed(
          'same_local_scope_performs_no_second_API_exchange',
          (await fixture.audit()).length == calls,
        );

        await store.writeTransaction(
          (tx) => tx.putLocalState(
            LocalStateKind.draft,
            'paired-exact-blob',
            Uint8List.fromList([0, 255, 128, 17]),
            expectedRevision: 0,
          ),
        );
        final backup = await createBackup(
          store,
          await Directory('${root.path}/backup').create(),
        );
        await File(
          backup.path,
        ).copy('${File(input).parent.path}/client-evidence.alkion-backup');
        final verified = await verifyBackupFile(
          File(backup.path),
          workDirectory: root,
        );
        passed(
          'verified_backup_retains_archives_intents_and_reply_evidence',
          verified.facts.state.tables['animus_recovery_archives']!.isNotEmpty &&
              verified
                  .facts
                  .state
                  .tables['animus_exchange_intents']!
                  .isNotEmpty &&
              verified
                  .facts
                  .state
                  .tables['animus_response_evidence']!
                  .isNotEmpty,
        );
        final destination = Directory(
          '${root.path}/restored/dev.animusstudio.alkion.dev',
        );
        await destination.parent.create();
        await RestoreService(
          destination,
          workDirectory: root,
        ).restore(File(backup.path));
        final restoredProfile = await AlkionProfile.open(
          supportRoot: destination,
        );
        final received = await LocalStore.open(
          profile: restoredProfile,
          expectedProfileId: restoredProfile.profileId,
        );
        try {
          passed(
            'restored_SQLite_preserves_original_request_bytes_and_hashes',
            await _rows(received, 'operation_attempts') == attempts &&
                await _rows(received, 'animus_response_evidence') ==
                    await _rows(store, 'animus_response_evidence'),
          );
          await expectLater(
            RemoteRecoveryRepository(received).requireReady(binding.id),
            throwsA(isA<StoreException>()),
          );
          passed(
            'cross_local_generation_attachment_restore_stays_blocked',
            true,
          );
        } finally {
          await received.close();
        }
        await _sameGenerationLocalRestore(fixture, values, root, passed);
      } finally {
        for (final review in reviews) {
          await review.close();
          review.dispose();
        }
        for (final owner in owners) {
          await owner.close();
        }
        await store.close();
        await File(
          '${File(input).parent.path}/client-results.json',
        ).writeAsString(
          jsonEncode({
            'format': 'alkion-paired-recovery-results/1',
            'checks': receipts,
          }),
          flush: true,
        );
        await File(
          '${File(input).parent.path}/client-api-exchanges.json',
        ).writeAsString(jsonEncode(await fixture.audit()), flush: true);
        await root.delete(recursive: true);
      }
    }, _DirectHttp()),
    skip: input == null
        ? 'explicit disposable paired recovery fixture required'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test('late reply proof rejects earlier and uncorrelated evidence', () {
    final response = AnimusHttpResponse(
      statusCode: 200,
      headers: {'x-hub-recovery-generation': 'old-G'},
      body: [0, 255, 128, 17],
    );
    final intent = <String, dynamic>{
      'exchange_id': 'original-exchange',
      'attempt_id': 'original-attempt',
      'operation_id': 'original-operation',
      'request_generation': 'old-G',
      'operation_generation': 'old-G',
      'request_hash': 'original-hash',
      'path_kind': 'action',
      'method': 'POST',
      'family': 'workouts',
    };
    final matching = <String, dynamic>{
      ...intent,
      'evidence_id': 'prior-evidence',
      'response_generation': 'old-G',
      'http_status': 200,
      'body_bytes': response.body,
    };
    bool matches(Map<String, dynamic> row) => _isNewHeldReply(
      row,
      priorEvidenceIds: {'prior-evidence'},
      originalExchange: intent,
      heldResponse: response,
    );
    expect(
      matches(matching),
      false,
    ); // Even identical prior evidence is insufficient.
    final appended = {...matching, 'evidence_id': 'new-evidence'};
    expect(matches(appended), true);
    for (final field in intent.keys) {
      expect(matches({...appended, field: 'different'}), false, reason: field);
    }
    expect(matches({...appended, 'response_generation': 'new-G'}), false);
    expect(matches({...appended, 'http_status': 409}), false);
    expect(
      matches({
        ...appended,
        'body_bytes': [0, 255, 128, 18],
      }),
      false,
    );
  });
}

Future<List<Map<String, dynamic>>> _evidenceWithIntent(
  LocalStore store,
) async => (await store.getAll(
  '''SELECT i.*,e.evidence_id,e.response_generation,e.http_status,e.body_bytes
    FROM animus_response_evidence e JOIN animus_exchange_intents i
    ON i.profile_id=e.profile_id AND i.exchange_id=e.exchange_id''',
)).map((row) => Map<String, dynamic>.from(row)).toList();

bool _isNewHeldReply(
  Map<String, dynamic> row, {
  required Set<String> priorEvidenceIds,
  required Map<String, dynamic> originalExchange,
  required AnimusHttpResponse heldResponse,
}) =>
    !priorEvidenceIds.contains(row['evidence_id']) &&
    originalExchange.entries.every((entry) => row[entry.key] == entry.value) &&
    row['response_generation'] ==
        heldResponse.headers['x-hub-recovery-generation'] &&
    row['http_status'] == heldResponse.statusCode &&
    row['body_bytes'] is List &&
    base64Encode((row['body_bytes'] as List).cast<int>()) ==
        base64Encode(heldResponse.body);

Future<void> _sameGenerationLocalRestore(
  _Fixture fixture,
  Map<String, String> values,
  Directory root,
  void Function(String, bool) passed,
) async {
  final offlineRoot = await Directory(
    '${root.path}/offline-before-attachment',
  ).create();
  final profile = await syntheticProfile(offlineRoot);
  final original = await LocalStore.open(
    profile: profile,
    expectedProfileId: profile.profileId,
  );
  final (workout, exercise) = await _workout(original);
  final backup = await createBackup(
    original,
    await Directory('${root.path}/offline-backup').create(),
  );
  final later = _Owner(fixture, values, original);
  await later.connect();
  final selection = await later.sender.select(workout);
  await later.sender.send(selection);
  expect((await later.sender.selectionFor(workout))!.readBackVerified, true);
  await later.close();
  await original.close();
  final destination = Directory(
    '${root.path}/offline-received/dev.animusstudio.alkion.dev',
  );
  await destination.parent.create();
  await RestoreService(
    destination,
    workDirectory: root,
  ).restore(File(backup.path));
  final restoredProfile = await AlkionProfile.open(supportRoot: destination);
  final store = await LocalStore.open(
    profile: restoredProfile,
    expectedProfileId: restoredProfile.profileId,
  );
  final current = _Owner(fixture, values, store);
  final review = AnimusRecoveryReview(
    database: store,
    installationId: restoredProfile.installationId,
    connection: current.connection,
  );
  try {
    await current.connect();
    expect(await store.getAll('SELECT * FROM operation_attempts'), isEmpty);
    await review.compare();
    expect(review.issue, isNull);
    final stage = review.snapshot!.stage!;
    expect(
      stage.inventory['blocked_local_records'],
      containsAll(['workout/$workout', 'exercise/$exercise']),
    );
    await review.adopt(stage.id);
    final count = (await fixture.audit())
        .where((v) => v['method'] == 'POST')
        .length;
    final blocked = await current.sender.select(workout);
    passed(
      'backup_before_attachment_same_G_unknown_history_blocks_old_record',
      blocked.issue == AnimusWorkoutSendIssue.recoveryBlocked &&
          (await fixture.audit()).where((v) => v['method'] == 'POST').length ==
              count,
    );
    final (newWorkout, _) = await _workout(store);
    passed(
      'new_unrelated_post_adoption_work_prepares_at_current_G',
      (await current.sender.select(newWorkout)).issue == null,
    );
  } finally {
    await review.close();
    review.dispose();
    await current.close();
    await store.close();
  }
}

Future<String> _rows(LocalStore store, String table) async {
  final rows = await store.getAll('SELECT * FROM $table');
  Object? encode(Object? value) =>
      value is Uint8List ? {'blob': base64Encode(value)} : value;
  final encoded = rows.map((row) {
    final keys = row.keys.toList()..sort();
    return jsonEncode({for (final key in keys) key: encode(row[key])});
  }).toList()..sort();
  return jsonEncode(encoded);
}

final class _Owner {
  _Owner(
    _Fixture fixture,
    Map<String, String> values,
    this.store, {
    AnimusUploadHttpPort? http,
  }) {
    config = AnimusConfig.fromEnvironment(
      values,
      platform: AnimusPlatform.linux,
    )!;
    connection = AnimusConnectionController(
      config: config,
      auth: _FixtureAuth(fixture, config),
      probe: AnimusProbe(
        config: config,
        http: IoAnimusHttpPort(),
        database: () => store,
        installationId: store.profile.installationId,
      ),
    );
    sender = AnimusWorkoutSender(
      http: http,
      database: store,
      installationId: store.profile.installationId,
      connection: connection,
    );
  }
  final LocalStore store;
  late final AnimusConfig config;
  late final AnimusConnectionController connection;
  late final AnimusWorkoutSender sender;
  Future<void> connect() async {
    await connection.connect();
    await connection.confirm();
  }

  Future<void> close() async {
    await sender.close();
    await connection.close();
  }
}

final class _Fixture {
  _Fixture(String path)
    : data = Map<String, dynamic>.from(
        jsonDecode(File(path).readAsStringSync()) as Map,
      ) {
    if (data['format'] != 'alkion-paired-recovery-fixture/1' ||
        Uri.parse(data['bridge'] as String).host != '127.0.0.1') {
      throw const FormatException('Explicit loopback fixture required');
    }
  }
  final Map<String, dynamic> data;
  Map<String, String> get values =>
      Map<String, String>.from(data['configuration'] as Map);
  Future<Map<String, dynamic>> command(
    String scenario, {
    WorkoutUploadAttempt? attempt,
    String? origin,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse(data['bridge'] as String));
      request.headers.set('X-Fixture-Key', data['bridge_key'] as String);
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'scenario': scenario,
          if (attempt != null) 'request_base64': base64Encode(attempt.bytes),
          if (origin != null) 'operation_generation': origin,
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) {
        throw StateError('paired fixture scenario failed: $scenario');
      }
      return Map<String, dynamic>.from(
        jsonDecode(await utf8.decoder.bind(response).join()) as Map,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<List<Map<String, dynamic>>> audit() async =>
      ((await command('audit'))['exchanges'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
  Future<AnimusAuthSession> authorize(AnimusConfig config) async {
    final response = await command('authorize');
    return AnimusAuthSession(
      identity: AnimusIdentity(
        issuer: config.issuer,
        subject: response['subject'] as String,
      ),
      accessToken: response['access_token'] as String,
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
    );
  }
}

/// Synthetic signed bearer handoff only. Browser/OIDC lifecycle is outside C-T4.
final class _FixtureAuth implements AnimusAuthPort {
  _FixtureAuth(this.fixture, this.config);
  final _Fixture fixture;
  final AnimusConfig config;
  @override
  Future<AnimusAuthSession?> authorize({
    AnimusAuthIntent intent = AnimusAuthIntent.signIn,
  }) => fixture.authorize(config);
  @override
  Future<AnimusAuthSession?> restore() => fixture.authorize(config);
  @override
  Future<AnimusAuthSession?> refresh() => fixture.authorize(config);
  @override
  Future<void> retain(AnimusAuthSession session) async {}
  @override
  Future<void> cancel() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> close() async {}
}

/// A real deferred FK failure rejects SQLite COMMIT after adoption changed G.
final class _AdoptionFault implements LocalDatabase {
  _AdoptionFault(this.store);
  final LocalStore store;
  bool armed = true;
  @override
  String get profileId => store.profileId;
  @override
  StoreToken get token => store.token;
  @override
  Future<T> readTransaction<T>(
    Future<T> Function(LocalRead) callback, {
    StoreToken? expected,
  }) => store.readTransaction(callback, expected: expected);
  @override
  Future<T> writeTransaction<T>(
    Future<T> Function(LocalTransaction) callback, {
    StoreToken? expected,
  }) => store.writeTransaction((tx) async {
    final before = await tx.getOptional(
      'SELECT state FROM animus_remote_attachments LIMIT 1',
    );
    final value = await callback(tx);
    final after = await tx.getOptional(
      'SELECT state FROM animus_remote_attachments LIMIT 1',
    );
    if (armed &&
        before?['state'] == 'recovery_required' &&
        after?['state'] == 'ready') {
      armed = false;
      await tx.execute('INSERT INTO operation_dependencies VALUES(?,?,?,?)', [
        tx.profileId,
        'workouts',
        'missing-owner',
        'missing-dependency',
      ]);
    }
    return value;
  }, expected: expected);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<(String, String)> _workout(
  LocalStore store, {
  String? exerciseId,
}) async {
  const uuid = Uuid();
  if (exerciseId == null) {
    final exercises = ExerciseRepository.local(store);
    final action = exercises.prepareExercise(
      ExerciseDraft(
        name: 'Paired synthetic ${uuid.v4()}',
        muscleGroup: '',
        compound: false,
        plateStepKg: 2.5,
      ),
    );
    await exercises.commitPrepared(action);
    exerciseId = action.action.target.id;
  }
  final session = uuid.v4(), draft = uuid.v4();
  var revision = 0;
  await store.writeTransaction((tx) async {
    final prior = await tx.localState(LocalStateKind.draft, 'active');
    revision = (prior?['revision'] as int? ?? 0) + 1;
    await tx.putLocalState(
      LocalStateKind.draft,
      'active',
      localBytes({'draftId': draft}),
      expectedRevision: revision - 1,
    );
  });
  final workouts = WorkoutRepository.local(store);
  final action = workouts.prepareFinish(
    write: SessionWrite(
      id: session,
      dateIso: '2030-01-01',
      splitLabel: 'Paired synthetic workout',
      durationMin: 1,
      sets: [
        SetWrite(
          id: uuid.v4(),
          exerciseId: exerciseId,
          setNumber: 1,
          weightKg: '60.00',
          reps: 8,
          rir: 2,
          isWarmup: false,
        ),
      ],
    ),
    baseRevision: 0,
    setBases: {},
    recovery: {'synthetic': true},
    draftRevision: revision,
    draftId: draft,
    finishTimeEvidence: {
      'format': 'alkion-native-finish-time/1',
      'finished_at': '2030-01-01T12:00:00Z',
      'offset_minutes': 0,
      'timezone': 'synthetic-utc',
      'elapsed_seconds': 60,
    },
  );
  await workouts.commitPrepared(action);
  return (session, exerciseId);
}

final class _DirectHttp extends HttpOverrides {}

/// Delay only delivery of a genuine, completely received HTTP result. The API
/// response owner and transaction have completed before the service restore.
final class _HeldFinishHttp implements AnimusUploadHttpPort {
  final _http = IoAnimusHttpPort();
  final entered = Completer<void>();
  final release = Completer<void>();
  AnimusHttpResponse? genuineResponse;
  bool _armed = false;
  void arm() => _armed = true;
  @override
  Future<AnimusHttpResponse> get({
    required Uri uri,
    required Map<String, String> headers,
    required int maxResponseBytes,
    required Duration timeout,
  }) => _http.get(
    uri: uri,
    headers: headers,
    maxResponseBytes: maxResponseBytes,
    timeout: timeout,
  );
  @override
  Future<AnimusHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required int maxResponseBytes,
    required Duration timeout,
  }) async {
    final response = await _http.post(
      uri: uri,
      headers: headers,
      body: body,
      maxResponseBytes: maxResponseBytes,
      timeout: timeout,
    );
    if (_armed &&
        (jsonDecode(utf8.decode(body)) as Map).containsKey('workout')) {
      _armed = false;
      genuineResponse = AnimusHttpResponse(
        statusCode: response.statusCode,
        headers: Map<String, String>.unmodifiable(response.headers),
        body: List<int>.unmodifiable(response.body),
      );
      entered.complete();
      await release.future;
    }
    return response;
  }

  @override
  Future<void> cancel() async {
    if (!release.isCompleted) release.complete();
    await _http.cancel();
  }

  @override
  Future<void> close() async {
    if (!release.isCompleted) release.complete();
    await _http.close();
  }
}
