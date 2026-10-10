// Host tests for the transport side of a capture: connector uploads are
// admitted operations that end only after their queue completion, a lost
// response stays uncertain, download/native apply counts as paused only with
// current native evidence, and no connect, logout, credential refresh or OTA
// install runs while a capture has admission closed.
//
// The gate is test/support/gate_model.dart, a Dart model of the native
// admission protocol. Positive native evidence comes from the registered
// production adapter over a real (synthetic) database; the negative cases
// use a controlled completion seam. None of this is native qualification.
//
// SyncStatus's constructor is @internal but is the only way to fake a status.
// ignore_for_file: invalid_use_of_internal_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ota_update/ota_update.dart';
import 'package:powersync/powersync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workout_tracker/auth/auth_store.dart';
import 'package:workout_tracker/capture/capture_profile.dart';
import 'package:workout_tracker/capture/capture_transport.dart';
import 'package:workout_tracker/capture/native_sync_quiescence.dart';
import 'package:workout_tracker/capture/session_capture_hooks.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';
import 'package:workout_tracker/main.dart' show logOutAndForget;
import 'package:workout_tracker/settings/settings_service.dart';
import 'package:workout_tracker/sync/connector.dart';
import 'package:workout_tracker/sync/db.dart';
import 'package:workout_tracker/sync/sync_health.dart';
import 'package:workout_tracker/update/update_installer.dart';

import '../support/capture_fixture.dart';
import '../support/gate_model.dart';

const _seamMethodId = 'host-contract/controlled-completions';

/// A completion seam whose disconnect and native-apply drain the test
/// releases by hand.
class _ControlledSync implements NativeSyncMethod {
  final disconnectReleased = Completer<void>();
  final applyDrained = Completer<void>();
  int disconnectCalls = 0;
  int drainCalls = 0;

  /// Runs once the disconnect was requested, before it is released.
  void Function()? onDisconnect;

  @override
  String get methodId => _seamMethodId;

  @override
  Future<void> disconnect(PowerSyncDatabase database) async {
    disconnectCalls++;
    onDisconnect?.call();
    await disconnectReleased.future;
    await database.disconnect();
  }

  @override
  Future<void> awaitNativeApplyDrained(PowerSyncDatabase database) {
    drainCalls++;
    return applyDrained.future;
  }

  void releaseAll() {
    if (!disconnectReleased.isCompleted) disconnectReleased.complete();
    if (!applyDrained.isCompleted) applyDrained.complete();
  }
}

/// The real registered method, observed: counts when the disconnect is
/// requested. Bound through the test seam, so its evidence is current only
/// for that seam adapter.
class _SpyRealSync implements NativeSyncMethod {
  final _real = nativeSyncMethodById(candidateNativeSyncMethodId)!;
  int disconnectCalls = 0;

  @override
  String get methodId => _real.methodId;

  @override
  Future<void> disconnect(PowerSyncDatabase database) {
    disconnectCalls++;
    return _real.disconnect(database);
  }

  @override
  Future<void> awaitNativeApplyDrained(PowerSyncDatabase database) =>
      _real.awaitNativeApplyDrained(database);
}

/// An AuthStore holding known tokens; [refreshes] counts /auth/refresh.
class _Auth {
  _Auth._(this.store, this.refreshes);

  final AuthStore store;
  final List<String> refreshes;

  static Future<_Auth> create() async {
    FlutterSecureStorage.setMockInitialValues({});
    final refreshes = <String>[];
    final store = AuthStore(
      client: MockClient((req) async {
        if (req.url.path == '/auth/refresh') refreshes.add(req.url.path);
        return http.Response(
          jsonEncode(
              {'access_token': 'ACCESS-SECRET', 'refresh_token': 'REFRESH-SECRET'}),
          200,
        );
      }),
    );
    await store.login('synthetic@example.invalid', 'synthetic-password');
    refreshes.clear();
    return _Auth._(store, refreshes);
  }
}

Future<List<int>> _queueIds(PowerSyncDatabase database) async => [
      for (final r in await database.getAll('SELECT id FROM ps_crud ORDER BY id'))
        r['id'] as int,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixtures = <CaptureFixture>[];
  final opened = <PowerSyncDatabase>[];
  late Directory gateDir;

  Future<(PowerSyncDatabase, QualifiedProfile)> openSource() async {
    final f = await CaptureFixture.create(queue: true);
    fixtures.add(f);
    final database = await f.openNormally();
    opened.add(database);
    final runtime = qualifiedSourceProfiles
        .singleWhere((p) => p.runtime.platform == Platform.operatingSystem)
        .runtime;
    return (database, await qualifyCaptureProfile(database, runtime));
  }

  NativeSyncQuiescence production(QualifiedProfile profile) =>
      NativeSyncQuiescence(qualification: nativeSyncQualificationFor(profile)!);

  NativeSyncQuiescence seam(QualifiedProfile profile, NativeSyncMethod method) =>
      NativeSyncQuiescence.withMethodForTesting(
        qualification: NativeSyncQualification(
          platform: profile.runtime.platform,
          profileEvidenceDigest: profile.evidenceDigest,
          methodId: _seamMethodId,
          qualificationEvidenceDigest: 'host-contract-only',
        ),
        method: method,
      );

  setUp(() async {
    gateDir = await Directory.systemTemp.createTemp('reps-transport-gate');
    TransportAdmission.instance.resetForTesting();
    SessionWriteLedger.instance.resetForTesting();
    appSourceGate = null;
  });

  tearDown(() async {
    appSourceGate = null;
    dbForTests = null;
    TransportAdmission.instance.resetForTesting();
    for (final d in opened) {
      await d.close();
    }
    opened.clear();
    for (final f in fixtures) {
      await f.dispose();
    }
    fixtures.clear();
    await gateDir.delete(recursive: true);
  });

  test('upload_ticket_includes_complete', () async {
    final (database, profile) = await openSource();
    final model = GateModel('upload');
    addTearDown(model.detach);
    final gate = model.gate(gateDir);
    appSourceGate = gate;

    final auth = await _Auth.create();
    final requestSeen = Completer<void>();
    final response = Completer<http.Response>();
    final uploads = <String>[];
    final connector = WorkoutConnector(auth.store,
        client: MockClient((req) async {
          uploads.add(req.url.path);
          if (!requestSeen.isCompleted) requestSeen.complete();
          return response.future;
        }));

    final queueBefore = await _queueIds(database);
    final firstTx = await database.getNextCrudTransaction();
    final txIds = [for (final c in firstTx!.crud) c.clientId];
    expect(queueBefore, isNotEmpty);

    // The SDK's upload loop calls the connector; the upload is admitted.
    final upload = connector.uploadData(database);
    await requestSeen.future;
    expect(model.admitted, contains('sync.upload'));

    // A capture closes admission and drains the transport while the
    // request is out.
    final preparation = await gate.closeAdmission('capture-upload');
    // Only the capture's own preparation ticket is left: no admitted work.
    bool uploadTicketGone() =>
        model.tickets.keys.every((id) => id == preparation.ticket.id);
    final spy = _SpyRealSync();
    final transport = CaptureTransport(
      database: database,
      profile: profile,
      quiescence: NativeSyncQuiescence.withMethodForTesting(
          qualification: nativeSyncQualificationFor(profile)!, method: spy),
      reconnect: () async => fail('nothing reconnects during capture'),
    );
    var drained = false;
    final pausing = transport
        .pauseAndDrain(preparation, timeout: const Duration(seconds: 20))
        .whenComplete(() => drained = true);

    // The server answers while the test holds the database writer, so the
    // queue completion (`transaction.complete()`) cannot run yet.
    final writerHeld = Completer<void>();
    final writerReleased = Completer<void>();
    final writer = database.writeLock((_) async {
      writerHeld.complete();
      await writerReleased.future;
    });
    await writerHeld.future;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(spy.disconnectCalls, 0,
        reason: 'the disconnect waits for the admitted upload');
    response.complete(http.Response('{}', 200));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final idleBeforeQueueCompletion = drained || uploadTicketGone();
    expect(idleBeforeQueueCompletion, false);
    expect(await _queueIds(database), queueBefore,
        reason: 'the batch is not completed until the writer is free');

    writerReleased.complete();
    await writer;
    await upload;
    final evidence = await pausing;
    expect(evidence.uploadPaused, true);
    expect(evidence.downloadPaused, true);
    expect(evidence.nativeSync, isNotNull);
    expect(evidence.uncertainUploads, isEmpty);
    expect(uploadTicketGone(), true,
        reason: 'the upload ticket ended with complete()');
    final queueAfter = await _queueIds(database);
    expect(queueAfter, [
      for (final id in queueBefore)
        if (!txIds.contains(id)) id,
    ]);

    // Admission stays closed: a new upload is refused before it reads the
    // queue, sends nothing and completes nothing.
    await expectLater(connector.uploadData(database),
        throwsA(isA<SourceGateException>()));
    expect(uploads, ['/sync/upload']);
    expect(await _queueIds(database), queueAfter);
    expect(transport.isCurrent(evidence, preparation), true);

    // Ordinary behavior returns with the prior policy only.
    await transport.resumePriorPolicy(false);
    expect(TransportAdmission.instance.isOpen, true);
  });

  test('lost_response_retains_uncertainty', () async {
    final (database, profile) = await openSource();
    final auth = await _Auth.create();
    var mode = 'lost';
    final connector = WorkoutConnector(auth.store,
        client: MockClient((req) async {
          switch (mode) {
            case 'lost':
              // The request went out; the answer never arrives.
              throw http.ClientException('connection reset by peer');
            case '503':
              return http.Response('busy', 503);
            case 'hang':
              return Completer<http.Response>().future;
          }
          return http.Response('{}', 200);
        }));
    final queueBefore = await _queueIds(database);
    final tx = (await database.getNextCrudTransaction())!;

    await expectLater(connector.uploadData(database), throwsA(anything));
    expect(await _queueIds(database), queueBefore,
        reason: 'a lost response never completes the batch');

    // A response that says "not accepted" is not uncertain.
    mode = '503';
    await expectLater(connector.uploadData(database), throwsA(anything));

    final transport = CaptureTransport(
      database: database,
      profile: profile,
      quiescence: production(profile),
      reconnect: () async {},
    );
    const preparation = SourcePreparation(
        'capture-lost', 1, SourceTicket('prep', 1));
    final evidence = await transport.pauseAndDrain(preparation,
        timeout: const Duration(seconds: 20));
    expect(evidence.uploadPaused, true);
    final uncertain = evidence.uncertainUploads.single;
    final lostResponseDisposition = uncertain.disposition;
    expect(lostResponseDisposition, 'uncertain');
    expect(uncertain.transactionId, tx.transactionId);
    expect(uncertain.crudIds, [for (final c in tx.crud) c.clientId]);
    expect(uncertain.code, 'ClientException');
    expect(await _queueIds(database), queueBefore);

    // Safe ids and codes only: no tokens, credentials or row contents.
    final safe = jsonEncode(evidence.toSafeJson());
    for (final secret in [
      'ACCESS-SECRET',
      'REFRESH-SECRET',
      'synthetic@example.invalid',
      'connection reset',
      ...[for (final c in tx.crud) jsonEncode(c.opData)],
    ]) {
      expect(safe.contains(secret), false, reason: 'leaked $secret');
    }

    // An upload still out when the bounded drain ends is uncertain too, and
    // the transport reports no pause.
    await transport.resumePriorPolicy(false);
    mode = 'hang';
    final hanging = connector.uploadData(database);
    unawaited(hanging.then((_) {}, onError: (Object _) {}));
    await pumpEventQueue();
    final timedOut = await transport.pauseAndDrain(
        const SourcePreparation('capture-hang', 2, SourceTicket('prep2', 2)),
        timeout: const Duration(milliseconds: 200));
    expect(timedOut.uploadPaused, false);
    expect(timedOut.downloadPaused, false);
    expect(timedOut.blockedCode, 'upload_drain_timeout');
    expect(
        timedOut.uncertainUploads.map((u) => u.code),
        containsAll(['ClientException', 'in_flight']));
  });

  test('native_apply_not_idle_blocks_attestation', () async {
    final (database, profile) = await openSource();
    const preparation =
        SourcePreparation('capture-native', 1, SourceTicket('prep', 1));

    // Disconnect completes, the native apply never drains: no pause.
    final method = _ControlledSync()..disconnectReleased.complete();
    final transport = CaptureTransport(
      database: database,
      profile: profile,
      quiescence: seam(profile, method),
      reconnect: () async {},
    );
    final evidence = await transport.pauseAndDrain(preparation,
        timeout: const Duration(milliseconds: 300));
    final certifiedDuringNativeApply = evidence.downloadPaused;
    expect(certifiedDuringNativeApply, false);
    expect(evidence.nativeSync, isNull);
    expect(evidence.blockedCode, 'native_sync_timeout');
    expect(method.drainCalls, 1);

    // No qualification for the profile: never paused, whatever the SDK
    // status or queue says.
    await transport.resumePriorPolicy(false);
    final unqualified = CaptureTransport(
      database: database,
      profile: profile,
      quiescence: null,
      reconnect: () async {},
    );
    expect(database.currentStatus.connected, false);
    final none = await unqualified.pauseAndDrain(preparation,
        timeout: const Duration(seconds: 5));
    expect(none.uploadPaused, true);
    expect(none.downloadPaused, false);
    expect(none.nativeSync, isNull);
    expect(none.blockedCode, 'native_sync_unqualified');
    expect(unqualified.isCurrent(none, preparation), false);
  });

  test('stale_native_evidence_blocks_attestation', () async {
    final (database, profile) = await openSource();
    final (otherDatabase, _) = await openSource();
    const preparation =
        SourcePreparation('capture-stale', 3, SourceTicket('prep', 3));
    final quiescence = production(profile);
    final transport = CaptureTransport(
      database: database,
      profile: profile,
      quiescence: quiescence,
      reconnect: () async {},
    );
    final evidence = await transport.pauseAndDrain(preparation,
        timeout: const Duration(seconds: 20));
    expect(evidence.downloadPaused, true);
    expect(transport.isCurrent(evidence, preparation), true);

    // Another capture or gate generation.
    expect(
        transport.isCurrent(evidence,
            const SourcePreparation('capture-other', 3, SourceTicket('p', 3))),
        false);
    expect(
        transport.isCurrent(evidence,
            const SourcePreparation('capture-stale', 4, SourceTicket('p', 4))),
        false);
    // Another database.
    final other = CaptureTransport(
      database: otherDatabase,
      profile: profile,
      quiescence: quiescence,
      reconnect: () async {},
    );
    expect(other.isCurrent(evidence, preparation), false);
    // Another adapter kind (a seam claiming the same qualification).
    final seamTransport = CaptureTransport(
      database: database,
      profile: profile,
      quiescence: NativeSyncQuiescence.withMethodForTesting(
          qualification: quiescence.qualification,
          method: _ControlledSync()..releaseAll()),
      reconnect: () async {},
    );
    expect(seamTransport.isCurrent(evidence, preparation), false);
    // A connection change after the observation (every connect path
    // reports it first).
    nativeSyncConnectionWillChange(database);
    expect(transport.isCurrent(evidence, preparation), false);

    // A connection change DURING the observation never yields a pause.
    await transport.resumePriorPolicy(false);
    final method = _ControlledSync();
    method.onDisconnect = () {
      nativeSyncConnectionWillChange(database);
      method.releaseAll();
    };
    final changing = CaptureTransport(
      database: database,
      profile: profile,
      quiescence: seam(profile, method),
      reconnect: () async {},
    );
    final changed = await changing.pauseAndDrain(preparation,
        timeout: const Duration(seconds: 5));
    expect(changed.downloadPaused, false);
    expect(changed.nativeSync, isNull);
    expect(changed.blockedCode, 'native_sync_connection_changed');
  });

  test('logout_reconnect_install_rejected_during_capture', () async {
    final (database, profile) = await openSource();
    dbForTests = database;
    SharedPreferences.setMockInitialValues({'settings.sync_enabled': true});
    final model = GateModel('account');
    addTearDown(model.detach);
    final gate = model.gate(gateDir);
    appSourceGate = gate;
    final auth = await _Auth.create();
    final settings = SettingsService();
    await settings.load();
    final health = SyncHealth(
      status: const Stream.empty(),
      initial: const SyncStatus(),
      pendingChanges: () async => 0,
      signedIn: () => true,
      syncEnabled: () => settings.syncEnabled,
    );

    // A capture has closed admission and drained the transport.
    final preparation = await gate.closeAdmission('capture-account');
    final transport = CaptureTransport(
      database: database,
      profile: profile,
      quiescence: production(profile),
      reconnect: () => connectSync(auth.store),
    );
    // Account changes are held from the first step, before any drain.
    transport.closeAdmission(preparation);
    await expectLater(auth.store.login('early@example.invalid', 'synthetic'),
        throwsA(isA<SourceGateException>()));
    expect(
        () => transport.closeAdmission(
            const SourcePreparation('capture-other', 9, SourceTicket('p', 9))),
        throwsA(isA<SourceGateException>()
            .having((e) => e.code, 'code', 'capture_in_progress')));
    final evidence = await transport.pauseAndDrain(preparation,
        timeout: const Duration(seconds: 20));
    expect(evidence.downloadPaused, true);
    final queueBefore = await _queueIds(database);

    Matcher refused() => throwsA(isA<SourceGateException>()
        .having((e) => e.code, 'code', 'admission_closed'));

    // Reconnect / connect (login attach, sign in again, boot resume).
    await expectLater(connectSync(auth.store), refused());
    await expectLater(disconnectSync(), refused());
    // Logout and local clear.
    await expectLater(disconnectAndClear(), refused());
    await expectLater(
        logOutAndForget(auth: auth.store, settings: settings, syncHealth: health),
        refused());
    expect(auth.store.email, 'synthetic@example.invalid');
    expect(settings.syncEnabled, true);
    expect(await _queueIds(database), queueBefore, reason: 'nothing cleared');
    // Credential refresh.
    final connector = WorkoutConnector(auth.store,
        client: MockClient((req) async => http.Response('{}', 401)));
    await expectLater(connector.fetchCredentials(), refused());
    await expectLater(auth.store.refresh(), refused());
    // Account switch.
    await expectLater(
        auth.store.login('other@example.invalid', 'synthetic'), refused());
    expect(auth.store.email, 'synthetic@example.invalid');
    expect(auth.refreshes, isEmpty);
    // OTA install.
    var executed = 0;
    final installer = UpdateInstaller(execute: (url) {
      executed++;
      return Stream<OtaEvent>.fromIterable(
          [OtaEvent(OtaStatus.INSTALLING, null)]);
    });
    await expectLater(installer.install('https://example.invalid/app.apk').toList(),
        refused());
    expect(executed, 0);

    // None of the refused paths changed the connection: the evidence is
    // still current.
    expect(transport.isCurrent(evidence, preparation), true);
    expect(model.admitted, isNot(contains('sync.connect')));

    // After release, connecting reports the connection change before it
    // changes anything, so the capture's evidence is no longer current.
    await gate.release(SourceHold(preparation.captureId, preparation.generation),
        decisionDigest: 'test');
    await transport.resumePriorPolicy(false);
    var currentWhenChanging = true;
    await changeSyncConnection('sync.test_change', (d) async {
      currentWhenChanging = transport.isCurrent(evidence, preparation);
    });
    expect(currentWhenChanging, false);
    expect(model.admitted, contains('sync.test_change'));
    var installed = await installer
        .install('https://example.invalid/app.apk')
        .toList();
    expect(installed, [-1]);
    expect(executed, 1);
  });
}
