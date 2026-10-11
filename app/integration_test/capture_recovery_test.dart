// Cross-store interruption, fault and Go-compatibility qualification on one
// explicitly chosen device, writing named synthetic outputs:
//   make -C app capture-recovery CAPTURE_DEVICE=linux \
//     CAPTURE_OUTPUT=/tmp/reps-capture-synthetic
//
// Every installation is a fresh, marked synthetic directory under the system
// temp directory (integration_test/support/capture_installation.dart); the
// real application-support directory, secure storage and credentials are
// never touched. The native gate, durable files, PowerSync SDK/core and the
// registered native sync adapter are real; nothing mocks a passing lock.
//
// Outputs in CAPTURE_OUTPUT (a fresh directory the Make target checked):
//   synthetic-capture/            certified capture, Go must accept (exit 0)
//   review-malformed-draft/       certified capture, Go review finding
//   exploratory-queue-blocked/    EXPLORATORY (never certified) capture the
//                                 producer refused; Go must block (exit 2)
//   acceptance.json               sanitized: runtime, profile, digests,
//                                 faults, results, cutover_ready: false
// The Go rehearsal itself runs outside Flutter
// (scripts/verify-capture-rehearsal.py), into a separate work directory.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:reps_capture_platform/reps_capture_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workout_tracker/auth/auth_store.dart';
import 'package:workout_tracker/capture/capture_artifact.dart'
    show verifyCaptureDirectory;
import 'package:workout_tracker/capture/capture_coordinator.dart';
import 'package:workout_tracker/capture/capture_export.dart';
import 'package:workout_tracker/capture/capture_journal.dart'
    show CaptureJournal;
import 'package:workout_tracker/capture/capture_profile.dart';
import 'package:workout_tracker/capture/capture_startup.dart';
import 'package:workout_tracker/capture/capture_transport.dart';
import 'package:workout_tracker/capture/native_sync_quiescence.dart';
import 'package:workout_tracker/capture/session_capture_hooks.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';
import 'package:workout_tracker/capture/startup_inventory.dart';
import 'package:workout_tracker/data/finished_session_store.dart';
import 'package:workout_tracker/session/session_manager.dart';
import 'package:workout_tracker/sync/connector.dart';
import 'package:workout_tracker/sync/db.dart' show changeSyncConnection;
import 'package:workout_tracker/sync/schema.dart';

import '../test/support/capture_faults.dart';
import 'support/background_gate.dart';
import 'support/capture_installation.dart';
import 'support/gate_helper_process.dart';
import 'support/native_sync_fixture.dart';
import 'support/recovery_child.dart';

const _captureOutput = String.fromEnvironment('CAPTURE_OUTPUT');

/// Fixed for the interrupted attempts, so every run of the same boundary
/// produces the same manifest bytes.
const _killCaptureId = '7c000000-0000-4000-8000-0000000000a1';

/// What the acceptance JSON records: safe codes, digests and results only.
final _acceptance = <String, Object?>{
  'format': 'reps-capture-acceptance',
  'version': 1,
  'cutover_ready': false,
  'note':
      'Synthetic qualification only. A certified capture attests the '
      'local capture boundary and integrity, never global writer authority, '
      'transfer receipt or cutover readiness.',
};
final _results = <String, String>{};
final _captures = <Map<String, Object?>>[];
final _faultCases = <Map<String, Object?>>[];
final _interruptions = <Map<String, Object?>>[];

/// The filesystem reports [bytes] free: what a nearly full disk looks like
/// to the coordinator's space check. Every other call is the real native
/// one.
class _ReportedSpace extends RepsCapturePlatform {
  const _ReportedSpace(this.bytes);

  final int bytes;

  @override
  Future<Map<String, Object?>> invoke(
    String method,
    Map<String, Object?> arguments,
  ) async {
    final real = await super.invoke(method, arguments);
    if (method == 'availableBytes' && real['code'] == 'ok') {
      return {...real, 'bytes': bytes};
    }
    return real;
  }
}

/// The app's connector, with credentials from the synthetic sync service.
class _FixtureConnector extends WorkoutConnector {
  _FixtureConnector(super.auth, this._fixture);

  final NativeSyncFixture _fixture;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    TransportAdmission.instance.ensureOpen('sync.credentials');
    return _fixture.credentials;
  }
}

/// A loopback `/sync/upload` service answering each request by [script]:
/// `lose` (the connection drops after the request arrived, no response),
/// `held_503` / `held_ok` (held until [release], then 503 / 200), `ok`
/// (200). Requests past the script are answered 503.
class _UploadService {
  _UploadService._(this._server, this._script);

  final HttpServer _server;
  final List<String> _script;
  var requests = 0;
  final _arrived = <int, Completer<void>>{};
  final _released = <int, Completer<void>>{};

  String get base => 'http://${_server.address.host}:${_server.port}';

  static Future<_UploadService> start(List<String> script) async {
    final s = _UploadService._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      script,
    );
    s._server.listen(s._handle);
    return s;
  }

  /// Completes when request [n] (1-based) has arrived.
  Future<void> arrived(int n) => (_arrived[n] ??= Completer<void>()).future;

  /// Lets held request [n] be answered.
  void release(int n) {
    final c = _released[n] ??= Completer<void>();
    if (!c.isCompleted) c.complete();
  }

  Future<void> _handle(HttpRequest request) async {
    await request.drain<void>();
    if (request.uri.path != '/sync/upload') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final n = ++requests;
    final arrived = _arrived[n] ??= Completer<void>();
    if (!arrived.isCompleted) arrived.complete();
    final mode = n <= _script.length ? _script[n - 1] : '503';
    if (mode == 'lose') {
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.destroy();
      return;
    }
    if (mode.startsWith('held_')) {
      await (_released[n] ??= Completer<void>()).future;
    }
    final ok = mode == 'ok' || mode == 'held_ok';
    request.response
      ..statusCode = ok ? HttpStatus.ok : HttpStatus.serviceUnavailable
      ..write(ok ? '{}' : 'busy');
    await request.response.close();
  }

  Future<void> close() async {
    for (final c in _released.values) {
      if (!c.isCompleted) c.complete();
    }
    for (var n = 1; n <= requests; n++) {
      release(n);
    }
    await _server.close(force: true);
  }
}

Future<void> _until(
  bool Function() condition,
  String what, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('never reached: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _chmod(String mode, String path) async {
  final r = await Process.run('chmod', [mode, path]);
  if (r.exitCode != 0) throw StateError('chmod failed: ${r.stderr}');
}

Map<String, Object?> _summary(CaptureRecovery r) => {
  'code': r.code,
  'stage': r.stage?.wire,
  'capture_id': r.captureId,
  'manifest_sha256': r.capture?.manifestSha256,
  'decision': r.decision.wire,
};

/// Everything under the private capture area except the gate's own state
/// files (which a probe may touch).
Map<String, String> _captureArea(SyntheticInstallation i) =>
    {...treeDigest(i.locations.root)}
      ..removeWhere((k, _) => k == 'gate' || k.startsWith('gate/'));

/// The source must equal [before] except the draft, which may only be the
/// pre-capture bytes or the one requested flush.
void _expectAllowedSource(
  Map<String, Object?> after,
  Map<String, Object?> before,
  Set<String?> allowedDrafts,
  String reason,
) {
  Map<String, Object?> withoutDraft(Map<String, Object?> s) => {
    ...s,
    'files': {...(s['files']! as Map)}..remove('workout-draft.json'),
  };
  expect(withoutDraft(after), withoutDraft(before), reason: reason);
  expect(
    allowedDrafts,
    contains((after['files']! as Map)['workout-draft.json']),
    reason: '$reason: draft',
  );
}

/// Every final capture directory verifies in full and matches the journal.
Future<void> _expectNoPartialFinals(
  SyntheticInstallation i,
  String reason,
) async {
  final journal = await CaptureJournal(
    i.locations.journal,
    base: i.source,
  ).read();
  final finalPartialDirectories = <String>[];
  for (final d in i.finalDirectories()) {
    try {
      final v = await verifyCaptureDirectory(d);
      if (p.basename(d.path) == journal?.captureId &&
          v.manifestSha256 != journal?.manifestSha256) {
        finalPartialDirectories.add(p.basename(d.path));
      }
    } catch (_) {
      finalPartialDirectories.add(p.basename(d.path));
    }
  }
  expect(finalPartialDirectories, isEmpty, reason: reason);
}

Future<QualifiedProfile> _linuxProfile() async {
  final probe = await Directory.systemTemp.createTemp('reps-recovery-profile');
  try {
    final db = PowerSyncDatabase(
      schema: schema,
      path: p.join(probe.path, 'workout-tracker.db'),
    );
    await db.initialize();
    try {
      return await qualifyCaptureProfile(
        db,
        qualifiedSourceProfiles
            .singleWhere((q) => q.runtime.platform == Platform.operatingSystem)
            .runtime,
      );
    } finally {
      await db.close();
    }
  } finally {
    await probe.delete(recursive: true);
  }
}

Future<void> _resetProcessState() async {
  CaptureCoordinator.forgetProcessStateForTesting();
  TransportAdmission.instance.resetForTesting();
  SessionWriteLedger.instance.resetForTesting();
  UnsavedEditors.instance.resetForTesting();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;
  final cleanup = <Future<void> Function()>[];

  setUpAll(() async {
    expect(
      _captureOutput,
      isNotEmpty,
      reason: 'run through make -C app capture-recovery',
    );
    final out = Directory(_captureOutput);
    expect(
      out.existsSync() && out.listSync().isEmpty,
      isTrue,
      reason: 'CAPTURE_OUTPUT must be a fresh, empty directory',
    );
    work = await Directory.systemTemp.createTemp('reps-capture-recovery');
    if (Platform.isLinux) {
      final profile = await _linuxProfile();
      final qualification = nativeSyncQualificationFor(profile);
      final info = await PackageInfo.fromPlatform();
      _acceptance['runtime'] = {
        'platform': profile.runtime.platform,
        'app_version': '${info.version}+${info.buildNumber}',
        'sdk_version': capturePowerSyncSdkVersion,
        'core_version': profile.runtime.coreVersion,
        'producer_revision': captureProducerRevision,
        'build_mode': 'debug',
      };
      _acceptance['profile'] = {
        'profile_id': profile.profileId,
        'evidence_digest': profile.evidenceDigest,
        'native_sync_method': qualification?.methodId,
        'native_sync_qualification_digest':
            qualification?.qualificationEvidenceDigest,
      };
    } else {
      _acceptance['runtime'] = {'platform': Platform.operatingSystem};
      _acceptance['profile'] = null;
    }
  });

  tearDownAll(() async {
    _acceptance['results'] = _results;
    _acceptance['captures'] = _captures;
    _acceptance['faults'] = _faultCases;
    _acceptance['interruptions'] = _interruptions;
    final out = File(p.join(_captureOutput, 'acceptance.json'));
    out.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(_acceptance)}\n',
      flush: true,
    );
    if (await work.exists()) {
      await Process.run('chmod', ['-R', 'u+rwX', work.path]);
      await work.delete(recursive: true);
    }
  });

  setUp(_resetProcessState);

  tearDown(() async {
    for (final c in cleanup.reversed) {
      await c();
    }
    cleanup.clear();
    appSourceGate = null;
    await _resetProcessState();
  });

  Future<SyntheticInstallation> installation(
    String name, {
    SyntheticDraft draft = SyntheticDraft.live,
    bool blockedQueue = false,
  }) async {
    final root = Directory(p.join(work.path, name))..createSync();
    return SyntheticInstallation.create(
      root,
      draft: draft,
      blockedQueue: blockedQueue,
    );
  }

  /// Opens [i] as this process's app: its preferences, database and a
  /// process over the real native gate.
  Future<InstallationProcess> open(
    SyntheticInstallation i, {
    bool liveDraft = false,
  }) async {
    i.usePreferences();
    final db = PowerSyncDatabase(schema: schema, path: i.databasePath);
    await db.initialize();
    final process = InstallationProcess(i, db, liveDraft: liveDraft);
    await process.prepareGate();
    cleanup.add(() async {
      process.dispose();
      if (!db.closed) await db.close();
    });
    return process;
  }

  test(
    'kill_each_boundary_and_restart_twice',
    () async {
      if (!Platform.isLinux) {
        _results['kill_each_boundary_and_restart_twice'] = 'unsupported';
        markTestSkipped('process interruption runs on the Linux fixture only');
        return;
      }
      expect(
        recoveryChildExecutable,
        isNotEmpty,
        reason: 'CAPTURE_CHILD (make -C app capture-recovery)',
      );
      final template = await installation('kill-template');
      final before = await template.sourceState();
      final preCaptureDraft =
          (before['files']! as Map)['workout-draft.json'] as String?;

      // Reference runs, uninterrupted, in the child process.
      var serial = 0;
      Future<SyntheticInstallation> copy() async => template.copyTo(
        Directory(p.join(work.path, 'kill-${serial++}'))..createSync(),
      );
      final refRehearsal = await copy();
      final rehearsal = await runRecoveryChild(
        refRehearsal,
        mode: 'rehearsal',
        liveDraft: true,
        captureId: _killCaptureId,
      );
      expect(rehearsal.outcome, startsWith('done certified $_killCaptureId'));
      expect(rehearsal.exitCode, 0);
      final referenceDigest = rehearsal.manifestSha256!;
      final flushedDraft =
          ((await refRehearsal.sourceState())['files']!
                  as Map)['workout-draft.json']
              as String?;
      expect(flushedDraft, isNot(preCaptureDraft));
      final refHold = await copy();
      final hold = await runRecoveryChild(
        refHold,
        mode: 'local_hold',
        liveDraft: true,
        captureId: _killCaptureId,
        resume: true,
      );
      expect(hold.outcome, endsWith(' resumed'));
      expect(hold.exitCode, 0);
      // The coordinator's evidence names the mode, so each mode has its own
      // reference manifest.
      final referenceDigests = {
        'rehearsal': referenceDigest,
        'local_hold': hold.manifestSha256!,
      };
      for (final i in [refRehearsal, refHold]) {
        await _expectNoPartialFinals(i, 'reference');
      }

      final sealedAt = hold.hits.indexOf('journal_flush:sealed');
      expect(sealedAt, isNonNegative);
      final cases = [
        for (final (b, n, _) in interruptionPoints(rehearsal.hits))
          ('rehearsal', b, n),
        for (final (b, n, k) in interruptionPoints(hold.hits))
          if (k >= sealedAt) ('local_hold', b, n),
      ];
      expect(cases.length, greaterThan(40));

      final codes = <String>{};
      for (final (mode, boundary, occurrence) in cases) {
        final reason = '$mode @ $boundary#$occurrence';
        await _resetProcessState();
        final i = await copy();
        final run = await runRecoveryChild(
          i,
          mode: mode,
          liveDraft: true,
          captureId: _killCaptureId,
          resume: mode == 'local_hold',
          blockAt: boundary,
          blockOccurrence: occurrence,
        );
        expect(run.outcome, 'blocked $boundary $occurrence', reason: reason);
        expect(run.killed, isTrue, reason: reason);
        expect(
          run.exitCode,
          -ProcessSignal.sigkill.signalNumber,
          reason: '$reason: the child must have died by SIGKILL',
        );
        final killedJournal = await CaptureJournal(
          i.locations.journal,
          base: i.source,
        ).read();

        // What the dead process left: only the requested draft flush.
        _expectAllowedSource(await i.sourceState(), before, {
          preCaptureDraft,
          flushedDraft,
        }, reason);
        await _expectNoPartialFinals(i, reason);

        // Two restarts: the same recovery answer, nothing changed by the
        // second, and startup held exactly while a decision is owed.
        final gate = SourceWriteGate(stateDirectory: i.locations.gate);
        final first = await recoveryCoordinator(i).recover();
        final areaAfterFirst = _captureArea(i);
        final probeAfterFirst = await probeSourceGate(gate, base: i.source);
        final second = await recoveryCoordinator(i).recover();
        expect(_summary(second), _summary(first), reason: reason);
        expect(_captureArea(i), areaAfterFirst, reason: reason);
        expect(
          await probeSourceGate(gate, base: i.source),
          probeAfterFirst,
          reason: reason,
        );
        codes.add(first.code);
        for (var restart = 0; restart < 2; restart++) {
          final (outcome, ran) = await syntheticStartup(i);
          if (second.decision == CaptureDecision.none) {
            expect(outcome, isA<StartupAllowed>(), reason: reason);
            expect(ran, hasLength(6), reason: reason);
          } else {
            expect(outcome, isA<CaptureRecoveryRequired>(), reason: reason);
            expect(ran, isEmpty, reason: reason);
          }
        }

        // A recovered capture is the immutable one the reference produced.
        final recorded = await CaptureJournal(
          i.locations.journal,
          base: i.source,
        ).read();
        final expectedDigest = referenceDigests[mode]!;
        if (first.capture != null) {
          expect(first.capture!.manifestSha256, expectedDigest, reason: reason);
          expect(recorded!.manifestSha256, expectedDigest, reason: reason);
        }
        await _expectNoPartialFinals(i, reason);
        for (final d in i.finalDirectories()) {
          expect(
            (await verifyCaptureDirectory(d)).manifestSha256,
            expectedDigest,
            reason: reason,
          );
        }

        // A recorded hold is never released by a restart; a local hold only
        // by the explicit decision.
        final stage = recorded?.stage;
        final holds =
            stage == CaptureStage.copying ||
            stage == CaptureStage.sealed ||
            stage == CaptureStage.published ||
            stage == CaptureStage.localHold ||
            (stage == CaptureStage.held && recorded!.gateGeneration != null);
        if (holds) expect(probeAfterFirst, 'mismatch', reason: reason);
        if (mode == 'local_hold' &&
            {
              CaptureStage.published,
              CaptureStage.localHold,
            }.contains(killedJournal?.stage)) {
          expect(stage, CaptureStage.localHold, reason: reason);
          expect(probeAfterFirst, 'mismatch', reason: reason);
        }

        // The explicit decision returns the source to use; a new capture in
        // this process gets a new id and changes nothing published before.
        if (second.decision == CaptureDecision.resumeOriginal) {
          await recoveryCoordinator(i).resumeOriginal(
            captureId: second.captureId!,
            decisionDigest: 'd' * 64,
          );
        }
        expect(
          await probeSourceGate(gate, base: i.source),
          'open',
          reason: reason,
        );
        final published = {
          for (final d in i.finalDirectories())
            p.basename(d.path): treeDigest(d),
        };
        final process = await open(i, liveDraft: true);
        final fresh = await process.coordinator().capture(
          mode: CaptureMode.rehearsal,
        );
        expect(fresh.captureId, isNot(_killCaptureId), reason: reason);
        for (final MapEntry(key: id, value: tree) in published.entries) {
          expect(
            treeDigest(Directory(p.join(i.locations.captures.path, id))),
            tree,
            reason: reason,
          );
        }
        for (final c in cleanup.reversed) {
          await c();
        }
        cleanup.clear();

        _interruptions.add({
          'mode': mode,
          'boundary': boundary,
          'occurrence': occurrence,
          'child_exit_status': run.exitCode,
          'died_by_sigkill': run.diedBySigkill,
          'stage_at_kill': killedJournal?.stage.wire,
          'recovery_code': first.code,
          'recovery_stage': first.stage?.wire,
          'decision': second.decision.wire,
          'recovered_digest_matches': first.capture == null
              ? null
              : first.capture!.manifestSha256 == expectedDigest,
          'restarts': 2,
          'result': 'pass',
        });
        await Process.run('chmod', ['-R', 'u+rwX', i.root.path]);
        await i.root.delete(recursive: true);
      }
      expect(
        codes,
        containsAll([
          'capture_interrupted',
          'awaiting_resume_decision',
          'local_hold',
          'resumed',
        ]),
      );
      _acceptance['interruption_reference'] = {
        'capture_id': _killCaptureId,
        'manifest_sha256': referenceDigests,
        'boundaries': cases.length,
      };
      _results['kill_each_boundary_and_restart_twice'] = 'pass';
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );

  test(
    'foreground_background_native_writer_races',
    () async {
      if (!Platform.isLinux) {
        _results['foreground_background_native_writer_races'] = 'unsupported';
        markTestSkipped('the native gate and sync adapter exist on Linux only');
        return;
      }
      // PowerSync applies no downloaded checkpoint while local uploads are
      // pending, so the upload race and the native apply race run on two
      // fixtures, one capture each.
      final profile = await _linuxProfile();
      SharedPreferences.setMockInitialValues({'unit': 'kg'});
      FlutterSecureStorage.setMockInitialValues({});

      Map<String, Object?> store(CertifiedCapture c, String name) =>
          jsonDecode(
                File(
                  p.join(c.directory.path, 'stores', name),
                ).readAsStringSync(),
              )
              as Map<String, Object?>;

      CaptureCoordinator coordinatorFor(
        NativeSyncFixture f,
        ScriptedCaptureFaults faults,
        void Function() reconnected,
      ) {
        final locations = CaptureLocations(f.directory);
        final manager = SessionManager(finishedStore: _NoFinished());
        cleanup.add(() async => manager.dispose());
        return CaptureCoordinator(
          locations: locations,
          gate: SourceWriteGate(stateDirectory: locations.gate),
          faults: faults,
          drainTimeout: const Duration(seconds: 90),
          sources: CaptureSourceBindings(
            database: f.database,
            hooks: SessionCaptureHooks(
              manager: manager,
              preservation: RawPreservation(
                locations.preparation,
                base: f.directory,
              ),
            ),
            transportFor: (profile) => CaptureTransport.forProfile(
              database: f.database,
              profile: profile,
              reconnect: () async => reconnected(),
            ),
          ),
        );
      }

      Future<SourceWriteGate> gateFor(NativeSyncFixture f) async {
        final locations = CaptureLocations(f.directory);
        await const CaptureFiles().ensureDirectory(
          locations.gate,
          base: f.directory,
        );
        return appSourceGate = SourceWriteGate(stateDirectory: locations.gate);
      }

      // 1. Uploads and writers of every engine.
      final f = await openNativeSyncFixture(profile);
      cleanup.add(f.close);
      final locations = CaptureLocations(f.directory);
      await gateFor(f);
      final previousApi = apiBaseUrl;
      cleanup.add(() async => apiBaseUrl = previousApi);
      final service = await _UploadService.start(['lose', 'held_503']);
      cleanup.add(service.close);
      apiBaseUrl = service.base;
      final auth = AuthStore(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'access_token': 'SYNTHETIC-ACCESS',
              'refresh_token': 'SYNTHETIC-REFRESH',
            }),
            200,
          ),
        ),
      );
      await auth.login('synthetic@example.invalid', 'synthetic-password');

      // Local writes waiting to upload (UUID rows, two transactions).
      await f.database.execute(
        'INSERT INTO exercises (id, name, slug) VALUES (?, ?, ?)',
        ['a2000000-0000-4000-8000-000000000001', 'Local one', 'local-one'],
      );
      await f.database.execute(
        'INSERT INTO exercises (id, name, slug) VALUES (?, ?, ?)',
        ['a2000000-0000-4000-8000-000000000002', 'Local two', 'local-two'],
      );

      // Opted-in sync through the app's own connect path: the first upload
      // loses its response, the retry is held at the service.
      final connector = _FixtureConnector(auth, f);
      await changeSyncConnection(
        'sync.connect',
        (d) => f.connect(connector: connector),
        connects: true,
        database: f.database,
      );
      await service.arrived(2).timeout(const Duration(seconds: 30));

      // A foreground write admitted before the capture, still running.
      final foregroundHeld = Completer<void>();
      final foregroundWrote = Completer<void>();
      final foreground = runSourceWrite('test.foreground_admitted', (_) async {
        await f.database.execute(
          'INSERT INTO bodyweight_logs (id, date, weight_kg) VALUES (?, ?, ?)',
          ['a4000000-0000-4000-8000-000000000001', '2026-10-09', '71.0'],
        );
        foregroundWrote.complete();
        await foregroundHeld.future;
      });
      await foregroundWrote.future;
      // A background-engine write admitted before the capture, still running.
      final background = await BackgroundGate.spawn(locations.gate);
      cleanup.add(() async => background.kill());
      expect(await background.write(holdOpen: true), 'admitted');
      final queueBefore = await f.queue();
      expect(queueBefore, hasLength(3));

      final faults = ScriptedCaptureFaults();
      bool reached(String b) => faults.hits.contains(b);
      var reconnects = 0;
      final capturing = coordinatorFor(
        f,
        faults,
        () => reconnects++,
      ).capture(mode: CaptureMode.rehearsal);
      await _until(() => reached('admission_closed'), 'admission closed');

      // Late writers of every engine are refused; nothing reaches the source.
      await expectLater(
        runSourceWrite(
          'test.foreground_late',
          (_) => f.database.execute(
            'INSERT INTO bodyweight_logs (id, date, weight_kg) VALUES (?, ?, ?)',
            ['a4000000-0000-4000-8000-000000000002', '2026-10-09', '72.0'],
          ),
        ),
        throwsA(
          isA<SourceGateException>().having(
            (e) => e.code,
            'code',
            'admission_closed',
          ),
        ),
      );
      expect(await background.write(), startsWith('rejected:admission_closed'));
      final helper = await GateHelperProcess.start();
      cleanup.add(helper.close);
      expect(
        (await helper.call('admit', locations.gate.path, 'other'))['code'],
        'admission_closed',
      );
      expect(TransportAdmission.instance.isOpen, isFalse);
      await expectLater(
        connector.uploadData(f.database),
        throwsA(isA<SourceGateException>()),
      );
      expect(service.requests, 2, reason: 'a refused upload never goes out');

      // The held upload keeps the network drain open until it settles.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(
        reached('network_drained'),
        isFalse,
        reason: 'an admitted upload is still out',
      );
      service.release(2);
      await _until(() => reached('journal_renamed:held'), 'held recorded');
      expect(service.requests, 2, reason: 'retries are refused, not sent');
      // Admitted foreground and background work keeps the hold from being
      // taken until it finishes.
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(reached('hold_acquired'), isFalse);
      expect(await background.finishHeld(), 'finished:1');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(reached('hold_acquired'), isFalse);
      foregroundHeld.complete();
      await foreground;
      final certified = await capturing;

      // One snapshot: the queue exactly as before (nothing dequeued), the
      // admitted foreground row, never the refused one.
      expect([
        for (final e
            in (store(certified, 'upload_queue.json')['entries']! as List)
                .cast<Map>())
          {'id': e['client_id'], 'tx_id': e['tx_id'], 'data': e['data']},
      ], queueBefore);
      final sql = File(
        p.join(certified.directory.path, 'stores', 'sql.json'),
      ).readAsStringSync();
      expect(sql, contains('a4000000-0000-4000-8000-000000000001'));
      expect(sql, isNot(contains('a4000000-0000-4000-8000-000000000002')));
      final evidence = store(certified, 'capture-evidence.json');
      final transport = evidence['transport']! as Map<String, Object?>;
      final uncertain = (transport['uncertain_uploads']! as List).cast<Map>();
      expect(
        uncertain,
        hasLength(1),
        reason: 'the lost response stays uncertain; the 503 does not',
      );
      expect(uncertain.single['code'], 'ClientException');
      expect(uncertain.single['disposition'], 'uncertain');
      expect(transport['previously_connected'], isTrue);
      expect(jsonEncode(evidence), isNot(contains('SYNTHETIC-ACCESS')));

      // Released by the recorded rehearsal decision: prior (connected) policy
      // restored once, every engine admitted again, the queue never dequeued.
      expect(reconnects, 1);
      expect(TransportAdmission.instance.isOpen, isTrue);
      expect(await background.write(), startsWith('written:'));
      expect(await f.queue(), queueBefore);
      expect(
        await f.database.getOptional(
          'SELECT id FROM bodyweight_logs WHERE id = ?',
          ['a4000000-0000-4000-8000-000000000002'],
        ),
        isNull,
      );

      // Each further fixture stands for another installation (another app
      // process): transport bookkeeping keyed by queue transaction id does
      // not carry over between databases.
      Future<
        (NativeSyncFixture, _UploadService, _FixtureConnector, List<Object?>)
      >
      uploadFixture(List<String> script, List<String> rowIds) async {
        TransportAdmission.instance.resetForTesting();
        final u = await openNativeSyncFixture(profile);
        cleanup.add(u.close);
        await gateFor(u);
        final svc = await _UploadService.start(script);
        cleanup.add(svc.close);
        apiBaseUrl = svc.base;
        for (final id in rowIds) {
          await u.database.execute(
            'INSERT INTO exercises (id, name, slug) VALUES (?, ?, ?)',
            [id, 'Local $id', 'local-$id'],
          );
        }
        final queued = await u.queue();
        expect(queued, hasLength(rowIds.length));
        return (u, svc, _FixtureConnector(auth, u), queued);
      }

      Future<void> connectUploads(NativeSyncFixture u, _FixtureConnector c) =>
          changeSyncConnection(
            'sync.connect',
            (_) => u.connect(connector: c),
            connects: true,
            database: u.database,
          );

      List<Map<String, Object?>> capturedQueue(CertifiedCapture c) => [
        for (final e
            in (store(c, 'upload_queue.json')['entries']! as List).cast<Map>())
          {'id': e['client_id'], 'tx_id': e['tx_id'], 'data': e['data']},
      ];

      List<Map> uncertainOf(CertifiedCapture c) =>
          (((store(c, 'capture-evidence.json')['transport']!
                      as Map)['uncertain_uploads'])!
                  as List)
              .cast<Map>();

      // 1b. The server accepts (2xx) while the local queue completion is
      //     paused (the shared writer is held, so `complete()` waits): the
      //     capture neither drains nor reads until the completion settles,
      //     and the completed batch is simply no longer queued.
      final (pc, pcService, pcConnector, pcQueue) = await uploadFixture(
        ['held_ok'],
        [
          'a5000000-0000-4000-8000-000000000001',
          'a5000000-0000-4000-8000-000000000002',
        ],
      );
      await connectUploads(pc, pcConnector);
      await pcService.arrived(1).timeout(const Duration(seconds: 30));
      final writerHeld = Completer<void>();
      final writerRelease = Completer<void>();
      final writer = pc.database.writeLock((_) async {
        writerHeld.complete();
        await writerRelease.future;
      });
      await writerHeld.future;
      pcService.release(1);
      // The 2xx reached the connector; its complete() now waits.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final pcFaults = ScriptedCaptureFaults();
      var pcReconnects = 0;
      final pcCapturing = coordinatorFor(
        pc,
        pcFaults,
        () => pcReconnects++,
      ).capture(mode: CaptureMode.rehearsal);
      await _until(
        () => pcFaults.hits.contains('admission_closed'),
        'admission closed',
      );
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(
        pcFaults.hits.contains('network_drained'),
        isFalse,
        reason: 'an accepted upload whose completion is paused is not idle',
      );
      expect(pcFaults.hits.contains('read'), isFalse);
      writerRelease.complete();
      await writer;
      final completed = await pcCapturing;
      final firstTx = pcQueue.first as Map;
      final remaining = [
        for (final r in pcQueue.cast<Map<String, Object?>>())
          if (r['tx_id'] != firstTx['tx_id']) r,
      ];
      expect(remaining, hasLength(1));
      expect(
        capturedQueue(completed),
        remaining,
        reason: 'the admitted upload completed before the boundary',
      );
      expect(await pc.queue(), remaining);
      expect(uncertainOf(completed), isEmpty);
      expect(pcService.requests, 1, reason: 'later uploads were refused');
      expect(pcReconnects, 1);

      // 1c. The server accepts (2xx) but the local completion fails (a
      //     synthetic trigger makes the queue DELETE abort): the batch stays
      //     queued and is reported `complete_failed`, never as accepted.
      final (cf, cfService, cfConnector, cfQueue) = await uploadFixture(
        ['ok', 'held_503'],
        [
          'a6000000-0000-4000-8000-000000000001',
          'a6000000-0000-4000-8000-000000000002',
        ],
      );
      await cf.database.execute(
        'CREATE TRIGGER synthetic_complete_failure BEFORE DELETE ON ps_crud '
        "BEGIN SELECT RAISE(ABORT, 'synthetic completion failure'); END",
      );
      await connectUploads(cf, cfConnector);
      // Request 1 was accepted and its completion failed; request 2 is the
      // SDK's retry of the same batch, held at the service.
      await cfService.arrived(2).timeout(const Duration(seconds: 30));
      expect(await cf.queue(), cfQueue);
      // The trigger is not part of any qualified layout; the capture runs on
      // the ordinary schema.
      await cf.database.execute('DROP TRIGGER synthetic_complete_failure');
      final cfFaults = ScriptedCaptureFaults();
      final cfCapturing = coordinatorFor(
        cf,
        cfFaults,
        () {},
      ).capture(mode: CaptureMode.rehearsal);
      await _until(
        () => cfFaults.hits.contains('admission_closed'),
        'admission closed',
      );
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(cfFaults.hits.contains('network_drained'), isFalse);
      cfService.release(2);
      final failed = await cfCapturing;
      expect(capturedQueue(failed), cfQueue, reason: 'nothing was dequeued');
      expect(await cf.queue(), cfQueue);
      final cfFirst = cfQueue.first as Map;
      final completeFailed = uncertainOf(failed);
      expect(completeFailed, hasLength(1));
      expect(completeFailed.single['code'], 'complete_failed');
      expect(completeFailed.single['disposition'], 'uncertain');
      expect(completeFailed.single['transaction_id'], cfFirst['tx_id']);
      expect(completeFailed.single['crud_ids'], [cfFirst['id']]);
      expect(cfService.requests, 2);

      // 2. A native download apply pending behind the shared writer.
      final d = await openNativeSyncFixture(profile);
      cleanup.add(d.close);
      await gateFor(d);
      await changeSyncConnection(
        'sync.connect',
        (_) => d.connect(),
        connects: true,
        database: d.database,
      );
      await d.deliverCheckpoint([
        const SyntheticRow('a3000000-0000-4000-8000-000000000001', 'Down one'),
      ]);
      await d.stageCheckpoint([
        const SyntheticRow('a3000000-0000-4000-8000-000000000002', 'Down two'),
      ]);
      await d.pauseNextApply();
      await d.waitUntilApplyPaused(
        unappliedIds: ['a3000000-0000-4000-8000-000000000002'],
      );
      final downloadFaults = ScriptedCaptureFaults();
      var downloadReconnects = 0;
      final downloading = coordinatorFor(
        d,
        downloadFaults,
        () => downloadReconnects++,
      ).capture(mode: CaptureMode.rehearsal);
      await _until(
        () => downloadFaults.hits.contains('admission_closed'),
        'admission closed',
      );
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(
        downloadFaults.hits.contains('network_drained'),
        isFalse,
        reason: 'the native apply is still pending',
      );
      expect(downloadFaults.hits.contains('read'), isFalse);
      await d.releaseApply();
      final downloaded = await downloading;
      final downloadedSql = File(
        p.join(downloaded.directory.path, 'stores', 'sql.json'),
      ).readAsStringSync();
      // The paused row was applied before the disconnect completed, so the
      // single read sees it together with the (empty) queue.
      for (final id in [
        'a3000000-0000-4000-8000-000000000001',
        'a3000000-0000-4000-8000-000000000002',
      ]) {
        expect(downloadedSql, contains(id));
      }
      expect(store(downloaded, 'upload_queue.json')['entries'], isEmpty);
      expect(await d.queue(), isEmpty);
      final native =
          (store(downloaded, 'capture-evidence.json')['transport']!
                  as Map)['native_sync']!
              as Map;
      expect(native['disconnect_completed'], isTrue);
      expect(native['native_apply_drained'], isTrue);
      expect(downloadReconnects, 1);

      _acceptance['races'] = {
        'admitted_before_boundary': ['foreground_sql', 'background_engine'],
        'refused_after_admission_closed': [
          'foreground_sql',
          'background_engine',
          'other_process',
          'upload',
        ],
        'upload_response_lost': 'uncertain',
        'upload_held_then_503': 'not_uncertain',
        'upload_2xx_completion_paused': 'drain_waited_then_dequeued',
        'upload_2xx_completion_failed':
            'complete_failed_uncertain_still_queued',
        'native_apply_paused': 'applied_before_disconnect_completed',
        'queue_unchanged': true,
        'captures': [
          {
            'capture_id': certified.captureId,
            'manifest_sha256': certified.manifestSha256,
          },
          {
            'capture_id': downloaded.captureId,
            'manifest_sha256': downloaded.manifestSha256,
          },
          {
            'capture_id': completed.captureId,
            'manifest_sha256': completed.manifestSha256,
          },
          {
            'capture_id': failed.captureId,
            'manifest_sha256': failed.manifestSha256,
          },
        ],
        'result': 'pass',
      };
      _results['foreground_background_native_writer_races'] = 'pass';
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'full_disk_permission_unreadable_and_limit_faults',
    () async {
      if (!Platform.isLinux) {
        _results['full_disk_permission_unreadable_and_limit_faults'] =
            'unsupported';
        markTestSkipped('the native gate exists on Linux only');
        return;
      }
      final template = await installation(
        'fault-template',
        draft: SyntheticDraft.malformed,
      );
      var serial = 0;

      /// Runs one capture under [fault], undoes it with [undo], checks what
      /// is left, recovers twice, and retries.
      Future<void> fault(
        String name, {
        Future<void> Function(SyntheticInstallation i)? apply,
        Future<void> Function(SyntheticInstallation i)? undo,
        CaptureFiles? files,
        ScriptedCaptureFaults Function(SyntheticInstallation i)? faults,
        CaptureTransport Function(
          InstallationProcess process,
          QualifiedProfile profile,
        )?
        transportFor,
        String? secret,
        bool retry = true,
      }) async {
        await _resetProcessState();
        final i = await template.copyTo(
          Directory(p.join(work.path, 'fault-${serial++}'))..createSync(),
        );
        final process = await open(i);
        final before = await i.sourceState();
        await apply?.call(i);
        // The faulted source itself, before the capture: bytes where
        // readable, and size/mode/mtime of every entry either way.
        final applied = {...await i.sourceState(), 'stats': i.entryStats()};
        final scripted = faults?.call(i) ?? ScriptedCaptureFaults();
        CaptureNotCertified? refused;
        try {
          await process
              .coordinator(
                files: files ?? const CaptureFiles(),
                faults: scripted,
                transportFor: transportFor == null
                    ? null
                    : (profile) => transportFor(process, profile),
              )
              .capture(mode: CaptureMode.rehearsal);
        } on CaptureNotCertified catch (e) {
          refused = e;
        }
        expect(refused, isNotNull, reason: '$name was certified');
        // Before the fault is undone: the faulted item (and everything
        // else) is exactly as it was, not truncated, cleaned up or removed.
        final faulted = {...await i.sourceState(), 'stats': i.entryStats()};
        expect(
          faulted,
          applied,
          reason: '$name: the faulted source must be unchanged',
        );
        await undo?.call(i);

        // Nothing partial is final, nothing was truncated or cleaned up, and
        // no credential reached any written byte.
        await _expectNoPartialFinals(i, name);
        if (refused!.stage != CaptureStage.sealed) {
          expect(i.finalDirectories(), isEmpty, reason: name);
        }
        _expectAllowedSource(await i.sourceState(), before, {
          (before['files']! as Map)['workout-draft.json'] as String?,
        }, name);
        if (secret != null) {
          for (final e in i.locations.root.listSync(recursive: true)) {
            if (e is File) {
              expect(
                utf8.decode(e.readAsBytesSync(), allowMalformed: true),
                isNot(contains(secret)),
                reason: '$name leaked into ${e.path}',
              );
            }
          }
        }
        final exploratory = refused.exploratory;
        if (exploratory != null) {
          expect(
            p.isWithin(i.locations.staging.path, exploratory.directory.path),
            isTrue,
          );
          expect(
            i.finalDirectories().map((d) => p.basename(d.path)),
            isNot(contains(exploratory.captureId)),
          );
        }

        // Two recoveries agree; the decision they ask for is taken.
        final first = await recoveryCoordinator(i).recover();
        final second = await recoveryCoordinator(i).recover();
        expect(_summary(second), _summary(first), reason: name);
        if (first.capture != null) {
          final j = await CaptureJournal(
            i.locations.journal,
            base: i.source,
          ).read();
          expect(
            first.capture!.manifestSha256,
            j!.manifestSha256,
            reason: name,
          );
        }
        await _expectNoPartialFinals(i, name);
        if (second.decision == CaptureDecision.resumeOriginal) {
          await recoveryCoordinator(i).resumeOriginal(
            captureId: second.captureId!,
            decisionDigest: 'e' * 64,
          );
        }
        final gateState = await probeSourceGate(
          SourceWriteGate(stateDirectory: i.locations.gate),
          base: i.source,
        );
        expect(gateState, 'open', reason: name);

        // With the fault gone, the same installation captures again.
        String? retried;
        if (retry) {
          await _resetProcessState();
          final again = await process.coordinator().capture(
            mode: CaptureMode.rehearsal,
          );
          retried = again.manifestSha256;
          await _expectNoPartialFinals(i, name);
        }
        _faultCases.add({
          'fault': name,
          'code': refused.code,
          'detail_code': refused.detail,
          'stage': refused.stage?.wire,
          'decision': refused.decision.wire,
          'kind': refused.exploratory == null ? 'refused' : 'exploratory',
          'recovery_code': first.code,
          'recovered_digest': first.capture?.manifestSha256,
          'retry_certified_digest': retried,
          'source_read': scripted.hits.contains('read'),
          'result': 'pass',
        });
        for (final c in cleanup.reversed) {
          await c();
        }
        cleanup.clear();
        await Process.run('chmod', ['-R', 'u+rwX', i.root.path]);
      }

      // Full disk: the file system reports less than the artifact needs.
      await fault(
        'insufficient_space',
        files: const CaptureFiles(platform: _ReportedSpace(4096)),
      );
      expect(_faultCases.last['code'], 'insufficient_space');

      // A write refused mid-staging (permissions, as a full disk would fail
      // the same write): never a truncated success.
      await fault(
        'staging_write_refused',
        faults: (i) {
          var done = false;
          return ScriptedCaptureFaults(
            onHit: (b, _) async {
              if (!done && b.startsWith('store_flushed:')) {
                done = true;
                final staging = i.locations.staging.listSync().single.path;
                await _chmod('0500', p.join(staging, 'stores'));
              }
            },
          );
        },
      );
      expect(_faultCases.last['code'], 'staging_failed');

      // Publication refused by permissions: held at `sealed`, then finished
      // by recovery once the directory is writable again.
      await fault(
        'publication_refused',
        faults: (i) => ScriptedCaptureFaults(
          onHit: (b, _) async {
            if (b == 'publication_rename') {
              await _chmod('0500', i.locations.captures.path);
            }
          },
        ),
        undo: (i) => _chmod('0700', i.locations.captures.path),
      );
      expect(_faultCases.last['code'], 'publish_failed');
      expect(_faultCases.last['stage'], 'sealed');
      expect(_faultCases.last['recovery_code'], 'awaiting_resume_decision');

      // An unreadable store.
      await fault(
        'unreadable_draft',
        apply: (i) => _chmod('0000', i.draftFile.path),
        undo: (i) => _chmod('0600', i.draftFile.path),
      );

      // A store over the per-store limit (sparse, 64 MiB + 1).
      await fault(
        'store_over_limit',
        apply: (i) async {
          final raf = i.draftFile.openSync(mode: FileMode.append);
          raf.truncateSync((64 << 20) + 1);
          raf.closeSync();
        },
        undo: (i) async =>
            i.draftFile.writeAsBytesSync(malformedDraftBytes, flush: true),
        retry: true,
      );

      // A symbolic link and an unlisted file beside the stores.
      await fault(
        'symlink_in_source',
        apply: (i) async => Link(
          p.join(i.source.path, 'linked.json'),
        ).createSync(i.draftFile.path),
        undo: (i) async =>
            Link(p.join(i.source.path, 'linked.json')).deleteSync(),
      );
      await fault(
        'unlisted_file',
        apply: (i) async =>
            File(p.join(i.source.path, 'stray.bin')).writeAsStringSync('?'),
        undo: (i) async =>
            File(p.join(i.source.path, 'stray.bin')).deleteSync(),
      );

      // A credential-bearing preference: refused, and the value appears in no
      // written byte.
      const secret = 'SYNTHETIC-ACCESS-SECRET-0001';
      await fault(
        'credential_preference',
        secret: secret,
        apply: (i) async {
          i.usePreferences();
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('access_token', secret);
        },
        undo: (i) async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove('access_token');
        },
      );

      // No registered native sync method: the pause is unattested and the
      // source is never read.
      await fault(
        'native_qualification_missing',
        faults: (_) => ScriptedCaptureFaults(),
        transportFor: (process, profile) => CaptureTransport(
          database: process.database,
          profile: profile,
          quiescence: null,
          reconnect: () async {},
        ),
      );
      expect(_faultCases.last['code'], 'native_sync_unqualified');
      expect(_faultCases.last['source_read'], isFalse);

      _results['full_disk_permission_unreadable_and_limit_faults'] = 'pass';
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'go_rehearsal_raw_digests_and_dispositions',
    () async {
      if (!Platform.isLinux) {
        _results['go_rehearsal_raw_digests_and_dispositions'] = 'unsupported';
        markTestSkipped('certified captures are produced on Linux only');
        return;
      }
      final out = Directory(_captureOutput);

      /// Publishes [capture] into the output under [name] through the
      /// production export (copy, no-replace publication, receiving check).
      Future<Directory> export(CertifiedCapture capture, String name) async {
        final attempt = await exportCapture(
          capture,
          destination: ExportDestination.directory(out),
        );
        expect(attempt.receiptVerified, isTrue);
        final renamed = await attempt.location!.rename(p.join(out.path, name));
        return Directory(renamed.path);
      }

      Future<Map<String, Object?>> record(
        String name,
        Directory dir,
        SyntheticInstallation i, {
        required String kind,
        required Map<String, Object?> expected,
        List<String> producerBlockers = const [],
      }) async {
        final verified = await verifyCaptureDirectory(dir);
        final manifest =
            jsonDecode(
                  File(p.join(dir.path, 'manifest.json')).readAsStringSync(),
                )
                as Map<String, Object?>;
        final stores = {
          for (final s in (manifest['stores']! as List).cast<Map>())
            s['name'] as String: s,
        };
        // Producer checks: raw files and queue text exactly as the source.
        final source = await i.sourceState();
        final draftSha =
            (source['files']! as Map)['workout-draft.json'] as String?;
        final draftStore = stores['active_draft']!;
        if (draftSha != null) {
          expect(draftStore['sha256'], draftSha, reason: '$name draft');
        }
        final queueSource = await i.queueDigests();
        final queueStore =
            jsonDecode(
                  File(
                    p.join(dir.path, 'stores', 'upload_queue.json'),
                  ).readAsStringSync(),
                )
                as Map<String, Object?>;
        final queueCaptured = [
          for (final e in (queueStore['entries']! as List).cast<Map>())
            {
              'client_id': e['client_id'],
              'tx_id': e['tx_id'],
              'data_sha256': sha256Of(utf8.encode(e['data'] as String)),
            },
        ];
        expect(queueCaptured, queueSource, reason: '$name queue');
        final entry = <String, Object?>{
          'name': name,
          'path': name,
          'kind': kind,
          'capture_id': manifest['capture_id'],
          'manifest_sha256': verified.manifestSha256,
          'tree_sha256': {
            for (final e in treeDigest(dir).entries)
              if (e.value != 'dir') e.key: e.value,
          },
          'stores': {
            for (final MapEntry(:key, :value) in stores.entries)
              key: {
                'role': value['role'],
                'status': value['status'],
                if (value['sha256'] != null) 'sha256': value['sha256'],
              },
          },
          'raw_files': {if (draftSha != null) 'active_draft': draftSha},
          'queue': queueSource,
          'producer_blockers': producerBlockers,
          'expected': expected,
          'cutover_ready': false,
        };
        _captures.add(entry);
        return entry;
      }

      // 1. Valid: seven tables, a non-empty queue, an unknown column, the
      //    running workout's flushed draft. Certified.
      final valid = await installation('go-valid', draft: SyntheticDraft.none);
      var process = await open(valid, liveDraft: true);
      final certified = await process.coordinator().capture(
        mode: CaptureMode.rehearsal,
      );
      final validDir = await export(certified, 'synthetic-capture');
      await record(
        'synthetic-capture',
        validDir,
        valid,
        kind: 'certified',
        expected: {
          'exit': 0,
          'staging_valid': true,
          'exploratory': false,
          'blocking': 0,
          'findings_include': ['unknown_column_preserved'],
          'items': {'column:exercises.legacy_note': 'preserved_unavailable'},
        },
      );
      for (final c in cleanup.reversed) {
        await c();
      }
      cleanup.clear();

      // 2. A malformed draft kept for recovery review. Certified.
      await _resetProcessState();
      final review = await installation(
        'go-review',
        draft: SyntheticDraft.malformed,
      );
      process = await open(review);
      final reviewed = await process.coordinator().capture(
        mode: CaptureMode.rehearsal,
      );
      final reviewDir = await export(reviewed, 'review-malformed-draft');
      expect(
        (await review.sourceState())['files'],
        containsPair('workout-draft.json', sha256Of(malformedDraftBytes)),
      );
      await record(
        'review-malformed-draft',
        reviewDir,
        review,
        kind: 'certified',
        expected: {
          'exit': 0,
          'staging_valid': true,
          'exploratory': false,
          'blocking': 0,
          'findings_include': ['draft_malformed'],
          'items': {'store:active_draft': 'preserved_for_recovery_review'},
        },
      );
      for (final c in cleanup.reversed) {
        await c();
      }
      cleanup.clear();

      // 3. A queued operation the reader cannot attribute: the producer
      //    refuses to certify and keeps an EXPLORATORY capture for diagnosis.
      await _resetProcessState();
      final blocked = await installation(
        'go-blocked',
        draft: SyntheticDraft.none,
        blockedQueue: true,
      );
      process = await open(blocked);
      CaptureBlocked? refusal;
      try {
        await process.coordinator().capture(mode: CaptureMode.rehearsal);
      } on CaptureBlocked catch (e) {
        refusal = e;
      }
      expect(refusal?.code, 'capture_unusable');
      final exploratory = refusal!.exploratory!;
      expect(blocked.finalDirectories(), isEmpty);
      final exploratoryDir = Directory(
        p.join(out.path, 'exploratory-queue-blocked'),
      );
      await copyTree(exploratory.directory, exploratoryDir);
      expect(treeDigest(exploratoryDir), treeDigest(exploratory.directory));
      await record(
        'exploratory-queue-blocked',
        exploratoryDir,
        blocked,
        kind: 'exploratory',
        producerBlockers: exploratory.blockers,
        expected: {
          'exit': 2,
          'staging_valid': false,
          'blocking_include': ['queue_entry_invalid'],
        },
      );
      for (final c in cleanup.reversed) {
        await c();
      }
      cleanup.clear();

      // What the Go rehearsal must leave: these exact bytes.
      for (final c in _captures) {
        final dir = Directory(p.join(out.path, c['path']! as String));
        expect({
          for (final e in treeDigest(dir).entries)
            if (e.value != 'dir') e.key: e.value,
        }, c['tree_sha256']);
      }
      _results['go_rehearsal_raw_digests_and_dispositions'] = 'pass';
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

class _NoFinished extends FinishedSessionStore {
  @override
  Future<FinishedSession?> load() async => null;
  @override
  Future<void> save(FinishedSession f) async {}
  @override
  Future<void> clear() async {}
}
