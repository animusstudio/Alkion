// Host tests for the capture coordinator: the six boundary steps in order,
// durable journal stages, no-replace publication, and restart recovery that
// never releases a hold by itself and never splices fresh stores into an
// interrupted attempt.
//
// The source is a real (synthetic) PowerSync database, draft file and
// preferences in a disposable directory laid out like the application-support
// directory. The gate is test/support/gate_model.dart and the durable file
// primitives are test/support/fake_capture_files.dart: Dart models of the
// native protocol, so nothing here qualifies native locking or durability.
// Native sync evidence comes from the registered method bound through the
// test seam (so it can be observed); the profile is the registered Linux
// profile, qualified against the real database.
//
// A "restart" drops everything a process keeps in memory (tickets, the live
// hold, transport admission, the session ledger, the coordinator) and keeps
// what is durable (the gate record, the journal, the files).
//
// `rehearsal_accepts_certified_capture` runs the Hub's pinned Go rehearsal
// over a published capture; it needs REPS_REHEARSAL_BIN (see
// `make -C app capture-go-compat`) and is skipped without one.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:reps_capture_platform/reps_capture_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workout_tracker/capture/capture_artifact.dart'
    show verifyCaptureDirectory;
import 'package:workout_tracker/capture/capture_coordinator.dart';
import 'package:workout_tracker/capture/capture_journal.dart'
    hide CaptureFileDigest;
import 'package:workout_tracker/capture/capture_profile.dart';
import 'package:workout_tracker/capture/capture_startup.dart';
import 'package:workout_tracker/capture/capture_transport.dart';
import 'package:workout_tracker/capture/native_sync_quiescence.dart';
import 'package:workout_tracker/capture/session_capture_hooks.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';
import 'package:workout_tracker/capture/startup_inventory.dart';
import 'package:workout_tracker/data/active_session_draft.dart';
import 'package:workout_tracker/data/models.dart';
import 'package:workout_tracker/session/active_session_controller.dart';
import 'package:workout_tracker/session/session_manager.dart';
import 'package:workout_tracker/sync/schema.dart';

import '../support/fake_capture_files.dart';
import '../support/fake_stores.dart';
import '../support/gate_model.dart';

const _user = '00000000-0000-4000-8000-000000000001';
const _exercise = '00000000-0000-4000-8000-0000000000e1';

/// Bytes on disk before the capture: an old, half-written draft.
final _preCaptureDraft =
    utf8.encode('{"sessionId":null,"startedAt":"2026-10-10T09');

final _clockNow = DateTime(2026, 10, 10, 10, 30, 5, 120);

/// A simulated process death at a capture step.
class _Crash implements Exception {
  const _Crash(this.step);
  final String step;
  @override
  String toString() => '_Crash($step)';
}

/// The registered native method, observed: logs its disconnect.
class _SpySync implements NativeSyncMethod {
  _SpySync(this.log);

  final void Function(String) log;
  final _real = nativeSyncMethodById(candidateNativeSyncMethodId)!;

  @override
  String get methodId => _real.methodId;

  @override
  Future<void> disconnect(PowerSyncDatabase database) {
    log('sync:disconnect');
    return _real.disconnect(database);
  }

  @override
  Future<void> awaitNativeApplyDrained(PowerSyncDatabase database) async {
    await _real.awaitNativeApplyDrained(database);
    log('sync:apply_drained');
  }
}

/// The production transport (registered adapter, production evidence),
/// logging when its network drain starts and ends.
class _LoggingTransport extends CaptureTransport {
  _LoggingTransport({
    required super.database,
    required super.profile,
    required super.quiescence,
    required super.reconnect,
    required this.log,
  });

  final void Function(String) log;

  @override
  Future<TransportPauseEvidence> pauseAndDrain(
    SourcePreparation preparation, {
    required Duration timeout,
  }) async {
    log('sync:pause_start');
    final evidence = await super.pauseAndDrain(preparation, timeout: timeout);
    log('sync:pause_done');
    return evidence;
  }
}

/// A transport that claims every evidence is current.
class _TrustMeTransport extends CaptureTransport {
  _TrustMeTransport({
    required super.database,
    required super.profile,
    required super.quiescence,
  }) : super(reconnect: () async {});

  @override
  bool isCurrent(TransportPauseEvidence evidence, SourcePreparation p) => true;
}

/// A file-backed draft store that logs its saves.
class _LoggingDraftStore extends DraftStore {
  _LoggingDraftStore(Directory dir, this.log)
      : super(directory: () async => dir);

  final void Function(String) log;

  @override
  Future<void> save(SessionDraft draft) async {
    await super.save(draft);
    log('draft:save');
  }
}

/// A transport whose drain reports native evidence observed under other
/// circumstances than the coordinator's own preparation.
class _SwappedEvidenceTransport extends CaptureTransport {
  _SwappedEvidenceTransport({
    required super.database,
    required super.profile,
    required super.quiescence,
    required this.swap,
  }) : super(reconnect: () async {});

  final Future<NativeSyncPauseEvidence> Function(SourcePreparation) swap;

  @override
  Future<TransportPauseEvidence> pauseAndDrain(
    SourcePreparation preparation, {
    required Duration timeout,
  }) async {
    final real = await super.pauseAndDrain(preparation, timeout: timeout);
    return TransportPauseEvidence(
      uploadPaused: real.uploadPaused,
      downloadPaused: true,
      nativeSync: await swap(preparation),
      uncertainUploads: real.uncertainUploads,
      previouslyConnected: real.previouslyConnected,
    );
  }
}

/// Hooks whose recorded replacement claims another pre-flush version.
class _LyingHooks extends SessionCaptureHooks {
  _LyingHooks({
    required super.manager,
    required super.preservation,
    required this.before,
  });

  final RawFileObservation before;

  @override
  RawReplacement? get lastFlush {
    final real = super.lastFlush;
    if (real == null) return null;
    return RawReplacement(
      role: real.role,
      before: before,
      temporaryBefore: real.temporaryBefore,
      after: real.after,
    );
  }
}

/// Ordinary boot steps that only count.
class _Steps implements OrdinaryStartupSteps {
  final ran = <String>[];
  @override
  Future<void> loadSettings() async => ran.add('settings');
  @override
  Future<void> openDatabase() async => ran.add('database');
  @override
  Future<void> initIdentity() async => ran.add('identity');
  @override
  Future<void> runBootMigrations() async => ran.add('migrations');
  @override
  Future<void> prepareSessions() async => ran.add('sessions');
  @override
  Future<void> connect() async => ran.add('connect');
}

const _bench = Exercise(
  id: _exercise, name: 'Bench', slug: 'bench', muscleGroup: 'chest',
  compound: true, plateStepKg: 2.5, isTemplate: false,
);

SessionDraft _draft() => SessionDraft(
      templateId: 't',
      name: 'Upper A',
      focus: '',
      startedAt: DateTime(2026, 10, 10, 9, 30),
      blocks: [
        BlockState(
          exercise: _bench,
          resolved: const ResolvedSlot(
              exercise: _bench, workSets: 2, warmupSets: 0,
              repLow: 8, repHigh: 10, rirLow: 1, rirHigh: 2),
          warmupSets: [],
          workingSets: [
            SetState(id: 'a1000000-0000-4000-8000-0000000000a1',
                weightKg: 62.5, reps: 8, rir: 1, isWarmup: false, done: true),
          ],
          expanded: true,
        ),
      ],
    );

Matcher _blocked(String code) => throwsA(
    isA<CaptureBlocked>().having((e) => e.code, 'code', code));

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

/// Every entry under [dir] (links not followed) with its SHA-256.
Map<String, String> _tree(Directory dir) => {
      for (final e in dir.listSync(recursive: true, followLinks: false))
        p.relative(e.path, from: dir.path): switch (e) {
          File f => _sha(f.readAsBytesSync()),
          Link l => 'link:${l.targetSync()}',
          _ => 'dir',
        },
    };

/// One disposable installation and the in-memory state of its "process".
class _Installation {
  _Installation._(this.source, this.serial);

  final Directory source;
  final int serial;
  final events = <String>[];
  late final CaptureLocations locations = CaptureLocations(source);
  late final GateModel model;
  late final FakeCaptureFiles fakeFiles;
  late final SourceWriteGate gate;
  late final PowerSyncDatabase database;
  late SessionManager manager;
  late SessionCaptureHooks hooks;
  ActiveSessionController? controller;
  var reconnects = 0;

  static Future<_Installation> create(int serial, {bool liveDraft = true}) async {
    SharedPreferences.setMockInitialValues({
      'unit': 'kg',
      'identity.current_user_id': _user,
      'identity.onboarding_complete': true,
      'settings.sync_enabled': false,
      'settings.rest_compound_seconds': 180,
    });
    final dir = await Directory.systemTemp.createTemp('reps-coordinator');
    final i = _Installation._(dir, serial);
    i.model = GateModel('coordinator-$serial')..log = i.events.add;
    i.fakeFiles = FakeCaptureFiles('coordinator-$serial')..log = i.events.add;
    i.gate = i.model.gate(i.locations.gate);
    appSourceGate = i.gate;
    i.database = PowerSyncDatabase(
        schema: schema, path: p.join(dir.path, 'workout-tracker.db'));
    await i.database.initialize();
    await i._seed();
    File(p.join(dir.path, DraftStore.fileName))
        .writeAsBytesSync(_preCaptureDraft, flush: true);
    i._startProcess(liveDraft: liveDraft);
    return i;
  }

  Future<void> _seed() async {
    await database.writeTransaction((tx) async {
      await tx.execute('INSERT INTO "ps_data__exercises" (id, data) VALUES (?, ?)', [
        _exercise,
        jsonEncode({
          'name': 'Bench Press', 'slug': 'bench-press', 'muscle_group': 'chest',
          'is_template': 1, 'created_by': null,
          'created_at': '2026-01-01T00:00:00Z', 'equip': 'barbell',
          'compound': 1, 'base_weight_kg': '20.00', 'plate_step_kg': '2.50',
        }),
      ]);
    });
    await database.writeTransaction((tx) async {
      await tx.execute(
        'INSERT INTO sessions (id, user_id, date, split_label, created_at, '
        'duration_min) VALUES (?, ?, ?, ?, ?, ?)',
        ['d1000000-0000-4000-8000-000000000001', _user, '2026-10-01',
          'Custom', '2026-10-01T10:00:00.000Z', 45],
      );
      await tx.execute(
        'INSERT INTO sets (id, session_id, exercise_id, user_id, set_number, '
        'weight_kg, reps, rir, is_warmup, is_top_set, is_pr, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        ['e1000000-0000-4000-8000-000000000001',
          'd1000000-0000-4000-8000-000000000001', _exercise, _user, 1, '62.5',
          8, 1, 0, 1, 0, '2026-10-01T10:20:00.000Z'],
      );
    });
  }

  /// The in-memory side of a process: session manager, hooks, live draft.
  void _startProcess({required bool liveDraft}) {
    manager = SessionManager(finishedStore: FakeFinishedSessionStore());
    hooks = SessionCaptureHooks(manager: manager, preservation: preservation);
    controller = null;
    if (liveDraft) {
      final c = ActiveSessionController.fromDraft(_draft(),
          draftStore: _LoggingDraftStore(source, events.add));
      manager.register(c);
      controller = c;
    }
  }

  RawPreservation get preservation => RawPreservation(locations.preparation,
      base: source, files: fakeFiles.files);

  CaptureJournal get journal =>
      CaptureJournal(locations.journal, base: source, files: fakeFiles.files);

  CaptureTransport transport(QualifiedProfile profile) => _LoggingTransport(
        database: database,
        profile: profile,
        quiescence:
            NativeSyncQuiescence(qualification: nativeSyncQualificationFor(profile)!),
        reconnect: () async => reconnects++,
        log: events.add,
      );

  CaptureCoordinator coordinator({
    FutureOr<void> Function(String step)? onStep,
    CaptureTransport Function(QualifiedProfile)? transportFor,
    SessionCaptureHooks? hooks,
    Duration drainTimeout = const Duration(seconds: 5),
    bool sources = true,
  }) =>
      CaptureCoordinator(
        locations: locations,
        gate: gate,
        files: fakeFiles.files,
        sources: !sources
            ? null
            : CaptureSourceBindings(
                database: database,
                hooks: hooks ?? this.hooks,
                transportFor: transportFor ?? transport,
                packageInfo: () async => PackageInfo(
                  appName: 'Reps',
                  packageName: 'io.github.psychonaut0.reps',
                  version: '0.18.1',
                  buildNumber: '37',
                ),
              ),
        clock: () => _clockNow,
        drainTimeout: drainTimeout,
        onStep: (step) {
          events.add('step:$step');
          return onStep?.call(step);
        },
      );

  /// Simulated process death and restart: only durable state survives.
  void restart({bool liveDraft = false}) {
    model.simulateRestart();
    CaptureCoordinator.forgetProcessStateForTesting();
    TransportAdmission.instance.resetForTesting();
    SessionWriteLedger.instance.resetForTesting();
    UnsavedEditors.instance.resetForTesting();
    controller?.dispose();
    manager.dispose();
    _startProcess(liveDraft: liveDraft);
  }

  /// Startup as `main` runs it, with coordinator recovery.
  Future<(StartupOutcome, _Steps)> startup() async {
    final steps = _Steps();
    final coordinator = this.coordinator(sources: false);
    final outcome = await runCaptureAwareStartup(
      journal: journal,
      probeGate: () => probeSourceGate(gate, base: source, files: fakeFiles.files),
      source: source,
      preservation: preservation,
      files: const [],
      steps: steps,
      now: _clockNow,
      recover: coordinator.recoverForStartup,
    );
    return (outcome, steps);
  }

  Future<CaptureJournalState?> readJournal() => journal.read();

  File get draftFile => File(p.join(source.path, DraftStore.fileName));

  /// The source as it is stored: raw rows, queue, sequence, files and
  /// preferences. Reads never go through the gate.
  Future<Map<String, Object?>> sourceState() async {
    final tables = <String, Object?>{};
    for (final t in captureTables) {
      tables[t] = [
        for (final r in await database
            .getAll('SELECT id, data FROM "ps_data__$t" ORDER BY id'))
          [r['id'], r['data']],
      ];
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return {
      'tables': tables,
      'queue': [
        for (final r in await database
            .getAll('SELECT id, tx_id, data FROM ps_crud ORDER BY id'))
          [r['id'], r['tx_id'], r['data']],
      ],
      'sequence': [
        for (final r in await database.getAll(
            "SELECT seq FROM sqlite_sequence WHERE name = 'ps_crud'"))
          r['seq'],
      ],
      'draft': draftFile.existsSync() ? _sha(draftFile.readAsBytesSync()) : null,
      'prefs': {for (final k in prefs.getKeys()) k: prefs.get(k)},
    };
  }

  var _disposed = false;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    controller?.dispose();
    manager.dispose();
    await database.close();
    model.detach();
    fakeFiles.detach();
    if (await source.exists()) await source.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var serial = 0;
  late _Installation i;

  Future<_Installation> install({bool liveDraft = true}) async =>
      i = await _Installation.create(++serial, liveDraft: liveDraft);

  setUp(() {
    CaptureCoordinator.forgetProcessStateForTesting();
    TransportAdmission.instance.resetForTesting();
    SessionWriteLedger.instance.resetForTesting();
    UnsavedEditors.instance.resetForTesting();
  });

  tearDown(() async {
    appSourceGate = null;
    await i.dispose();
    TransportAdmission.instance.resetForTesting();
    SessionWriteLedger.instance.resetForTesting();
    UnsavedEditors.instance.resetForTesting();
  });

  int at(String event) {
    final index = i.events.indexOf(event);
    expect(index, isNonNegative, reason: '$event never happened');
    return index;
  }

  int firstWhere(bool Function(String) test, String what) {
    final index = i.events.indexWhere(test);
    expect(index, isNonNegative, reason: '$what never happened');
    return index;
  }

  test('prepare_drain_hold_read_publish_in_order', () async {
    await install();
    final before = await i.sourceState();
    final certified = await i.coordinator().capture(mode: CaptureMode.rehearsal);

    // 1. Prepare: the journal names the attempt before admission closes.
    expect(at('step:journal:preparing'), lessThan(at('gate:prepare')));
    // Pre-capture draft bytes are preserved before any editor commit or
    // autosave/flush can overwrite them.
    final preserved = firstWhere(
        (e) => e.endsWith('/blobs/${_sha(_preCaptureDraft)}'),
        'pre-capture draft preservation');
    expect(preserved, lessThan(at('step:editor_committed')));
    expect(preserved, lessThan(at('draft:save')));
    // 2-4. Local drain (the one flush), then network/background drain, then
    // the exclusive hold, then preferences reload after the gate drain.
    expect(at('draft:save'), lessThan(at('sync:pause_start')));
    expect(at('sync:pause_done'), lessThan(at('step:journal:held')));
    expect(at('step:journal:held'), lessThan(at('gate:drain')));
    expect(at('gate:drain'), lessThan(at('step:preferences_reloaded')));
    // 5. Current native evidence and the live hold precede and follow the
    // single read.
    expect(at('step:native_current_before_read'), lessThan(at('step:read')));
    expect(at('step:journal:copying'), lessThan(at('step:read')));
    expect(at('step:read'), lessThan(at('step:native_current_after_read')));
    // 6. Seal, record, publish without replacing, persist, verify, and only
    // then durably allow resumption before releasing.
    expect(at('step:native_current_after_read'), lessThan(at('step:journal:sealed')));
    expect(at('step:journal:sealed'),
        lessThan(firstWhere((e) => e.startsWith('files:publishNoReplace'), 'publish')));
    expect(firstWhere((e) => e.startsWith('files:publishNoReplace'), 'publish'),
        lessThan(at('step:journal:published')));
    expect(at('step:journal:published'), lessThan(at('step:final_verified')));
    expect(at('step:final_verified'), lessThan(at('step:journal:resume_allowed')));
    expect(at('step:journal:resume_allowed'), lessThan(at('gate:release')));
    expect(at('gate:release'), lessThan(at('step:journal:resumed')));
    expect(i.model.calls.where((c) => c == 'prepare'), hasLength(1));

    // The handoff: id, manifest digest, immutable final directory, profile.
    final finalDir = Directory(p.join(i.locations.captures.path, certified.captureId));
    expect(certified.directory.path, finalDir.path);
    final manifestBytes = File(p.join(finalDir.path, 'manifest.json')).readAsBytesSync();
    expect(certified.manifestSha256, _sha(manifestBytes));
    expect(
        certified.profileEvidenceDigest,
        qualifiedSourceProfiles
            .singleWhere((q) => q.runtime.platform == 'linux')
            .evidenceDigest);
    final manifest = jsonDecode(utf8.decode(manifestBytes)) as Map<String, Object?>;
    final capturedAt = manifest['captured_at']! as String;
    expect(capturedAt.endsWith('Z'), true);
    expect(capturedAt, _clockNow.toUtc().toIso8601String());
    expect(manifest.keys.toSet(), {
      'format', 'version', 'capture_id', 'captured_at', 'source', 'boundary',
      'stores', 'counts',
    });
    expect((manifest['boundary']! as Map).values.where((v) => v == true),
        hasLength(5));
    final verified = await verifyCaptureDirectory(finalDir);
    expect(verified.manifestSha256, certified.manifestSha256);

    // The journal recorded every digest and ended resumed.
    final journal = (await i.readJournal())!;
    expect(journal.stage, CaptureStage.resumed);
    expect(journal.captureId, certified.captureId);
    expect(journal.manifestSha256, certified.manifestSha256);
    expect({for (final e in journal.files.entries) e.key: e.value.sha256},
        {for (final e in verified.files.entries) e.key: e.value.sha256});
    expect(journal.gateGeneration, i.model.generation);
    expect(journal.mode, CaptureMode.rehearsal);

    // Declared opaque evidence carries the coordinator's facts; no new
    // manifest keys.
    final evidence = jsonDecode(File(p.join(finalDir.path,
            'stores', 'capture-evidence.json'))
        .readAsStringSync()) as Map<String, Object?>;
    final coordinator = evidence['coordinator']! as Map<String, Object?>;
    expect(coordinator['mode'], 'rehearsal');
    expect(coordinator['gate_generation'], journal.gateGeneration);
    expect(coordinator['hold_before_read'], 'held');
    expect(coordinator['hold_after_read'], 'held');
    expect(coordinator['native_sync_current_before_read'], true);
    expect(coordinator['native_sync_current_after_read'], true);
    expect(coordinator['flush_before_matches_settled'], true);
    final native = (evidence['transport']! as Map)['native_sync']! as Map;
    expect(native['method_id'], candidateNativeSyncMethodId);
    expect(native['qualification_evidence_digest'],
        linuxNativeSyncQualificationRecord.evidenceDigest);
    expect((evidence['transport']! as Map)['uncertain_uploads'], isEmpty);
    expect((evidence['replacements']! as List), hasLength(1));

    // The pre-capture bytes are in the capture, unchanged, as an opaque
    // version; the flushed draft is the authoritative one.
    final stores = (manifest['stores']! as List).cast<Map<String, Object?>>();
    final preFlush = stores.singleWhere((s) => s['name'] == 'active_draft_pre_flush');
    expect(preFlush['sha256'], _sha(_preCaptureDraft));
    final draft = stores.singleWhere((s) => s['name'] == 'active_draft');
    expect(draft['sha256'], _sha(i.draftFile.readAsBytesSync()));

    // Source: only the requested flush changed anything.
    final after = await i.sourceState();
    expect({...after}..remove('draft'), {...before}..remove('draft'));
    expect(after['draft'], isNot(before['draft']));
    // Released: admission open, callbacks resumed, prior policy (off) kept.
    expect(i.model.state, 'open');
    expect(i.controller!.callbacksFrozen, false);
    expect(TransportAdmission.instance.isOpen, true);
    expect(i.reconnects, 0);
    // The staging directory moved; nothing partial is left beside it.
    expect(Directory(p.join(i.locations.staging.path, certified.captureId)).existsSync(),
        false);
  });

  test('stale_native_evidence_prevents_read', () async {
    await install(liveDraft: false);
    final before = await i.sourceState();

    Future<void> expectNoRead(CaptureCoordinator coordinator) async {
      final reads = i.events.where((e) => e == 'step:read').length;
      await expectLater(
          coordinator.capture(mode: CaptureMode.rehearsal),
          throwsA(isA<CaptureBlocked>().having(
              (e) => e.code, 'code', startsWith('native_sync_'))));
      expect(i.events.where((e) => e == 'step:read').length, reads,
          reason: 'nothing was read');
      expect(i.locations.staging.existsSync() &&
              i.locations.staging.listSync().isNotEmpty,
          false);
      expect(i.locations.captures.existsSync() &&
              i.locations.captures.listSync().isNotEmpty,
          false);
      // The attempt was abandoned by a recorded decision and the source
      // released.
      expect((await i.readJournal())!.stage, CaptureStage.resumed);
      expect((await i.readJournal())!.manifestSha256, isNull);
      expect(i.model.state, 'open');
      expect(TransportAdmission.instance.isOpen, true);
      expect(await i.sourceState(), before);
    }

    // Connection epoch: the app's connect path ran after the observation.
    await expectNoRead(i.coordinator(onStep: (step) {
      if (step == 'preferences_reloaded') nativeSyncConnectionWillChange(i.database);
    }));

    // Evidence or hold that change during the read block publication: the
    // read happened, nothing is staged or published.
    Future<void> expectNoPublication(String code, Future<void> Function() change) async {
      final reads = i.events.where((e) => e == 'step:read').length;
      await expectLater(
          i.coordinator(onStep: (step) async {
            if (step == 'journal:copying') await change();
          }).capture(mode: CaptureMode.rehearsal),
          _blocked(code));
      expect(i.events.where((e) => e == 'step:read').length, reads + 1);
      expect(i.events.where((e) => e.startsWith('files:publishNoReplace')), isEmpty);
      expect(i.locations.staging.existsSync() &&
              i.locations.staging.listSync().isNotEmpty,
          false);
      expect((await i.readJournal())!.stage, CaptureStage.resumed);
      expect(i.model.state, 'open');
      expect(await i.sourceState(), before);
    }

    await expectNoPublication('native_sync_stale',
        () async => nativeSyncConnectionWillChange(i.database));
    await expectNoPublication('hold_lost', () async {
      final j = (await i.readJournal())!;
      await i.gate.release(SourceHold(j.captureId, j.gateGeneration!),
          decisionDigest: '7' * 64);
    });

    final registered = nativeSyncQualificationFor(await qualifyCaptureProfile(
        i.database,
        qualifiedSourceProfiles
            .singleWhere((q) => q.runtime.platform == 'linux')
            .runtime))!;
    final production = NativeSyncQuiescence(qualification: registered);

    // Evidence for another capture, another gate generation, another
    // database instance.
    for (final swap in <Future<NativeSyncPauseEvidence> Function(
        SourcePreparation, QualifiedProfile)>[
      (prep, profile) => production.disconnectAndObserve(i.database, profile,
          captureId: '00000000-0000-4000-8000-0000000000ff',
          gateGeneration: prep.generation,
          timeout: const Duration(seconds: 5)),
      (prep, profile) => production.disconnectAndObserve(i.database, profile,
          captureId: prep.captureId,
          gateGeneration: prep.generation + 1,
          timeout: const Duration(seconds: 5)),
      (prep, profile) async {
        final other = PowerSyncDatabase(
            schema: schema, path: p.join(i.source.path, 'capture', 'other.db'));
        await other.initialize();
        addTearDown(other.close);
        return production.disconnectAndObserve(other, profile,
            captureId: prep.captureId,
            gateGeneration: prep.generation,
            timeout: const Duration(seconds: 5));
      },
    ]) {
      await expectNoRead(i.coordinator(
          transportFor: (profile) => _SwappedEvidenceTransport(
                database: i.database,
                profile: profile,
                quiescence: production,
                swap: (prep) => swap(prep, profile),
              )));
    }

    // Evidence current for a transport bound to another profile.
    await expectNoRead(i.coordinator(transportFor: (profile) {
      final other = QualifiedProfile.forTesting(
          runtime: profile.runtime,
          profileId: profile.profileId,
          evidenceDigest: 'f' * 64);
      return CaptureTransport(
        database: i.database,
        profile: other,
        quiescence: NativeSyncQuiescence.withMethodForTesting(
          qualification: NativeSyncQualification(
            platform: 'linux',
            profileEvidenceDigest: other.evidenceDigest,
            methodId: candidateNativeSyncMethodId,
            qualificationEvidenceDigest: 'e' * 64,
          ),
          method: _SpySync(i.events.add),
        ),
        reconnect: () async {},
      );
    }));

    // Test-seam evidence (the registered qualification and the real method,
    // bound through the seam) behind a transport that vouches for any
    // evidence: the coordinator verifies with its own production adapter,
    // so a seam never reads, let alone certifies.
    await expectNoRead(i.coordinator(
        transportFor: (profile) => _TrustMeTransport(
              database: i.database,
              profile: profile,
              quiescence: NativeSyncQuiescence.withMethodForTesting(
                qualification: nativeSyncQualificationFor(profile)!,
                method: _SpySync(i.events.add),
              ),
            )));

    // No registered method at all: nothing attests the pause, nothing reads.
    await expectNoRead(i.coordinator(
        transportFor: (profile) => CaptureTransport(
              database: i.database,
              profile: profile,
              quiescence: null,
              reconnect: () async {},
            )));
  });

  test('second_capture_rejected', () async {
    await install();
    final reached = Completer<void>();
    final proceed = Completer<void>();
    final first = i.coordinator(onStep: (step) async {
      if (step == 'journal:held') {
        reached.complete();
        await proceed.future;
      }
    });
    final running = first.capture(mode: CaptureMode.rehearsal);
    await reached.future;
    final journal = (await i.readJournal())!;
    final ticketsBefore = Map.of(i.model.tickets);

    // The same coordinator, and another one over the same journal.
    await expectLater(first.capture(mode: CaptureMode.rehearsal),
        _blocked('capture_in_progress'));
    await expectLater(i.coordinator().capture(mode: CaptureMode.rehearsal),
        _blocked('capture_in_progress'));
    expect(i.model.calls.where((c) => c == 'prepare'), hasLength(1));
    expect(i.model.tickets, ticketsBefore, reason: 'no second ticket');
    expect((await i.readJournal())!.captureId, journal.captureId);
    expect((await first.recover()).code, 'capture_running');

    proceed.complete();
    final certified = await running;
    expect(certified.captureId, journal.captureId);

    // Another process holds a capture this one has no journal for.
    i.events.clear();
    final prep = await i.gate.closeAdmission('00000000-0000-4000-8000-00000000abcd');
    final journalBytes = i.locations.journal.readAsBytesSync();
    await expectLater(i.coordinator().capture(mode: CaptureMode.rehearsal),
        _blocked('capture_in_progress'));
    expect(i.model.calls.where((c) => c == 'prepare'), hasLength(2));
    expect(i.locations.journal.readAsBytesSync(), journalBytes,
        reason: 'the journal is not touched');
    await i.gate.release(SourceHold(prep.captureId, prep.generation),
        decisionDigest: 'a' * 64);
  });

  test('sealed_match_adopted_divergence_refused', () async {
    await install();

    Future<CaptureJournalState> crashAt(String crashStep) async {
      await expectLater(
          i.coordinator(onStep: (step) {
            if (step == crashStep) throw _Crash(step);
          }).capture(mode: CaptureMode.rehearsal),
          throwsA(isA<_Crash>()));
      i.restart();
      return (await i.readJournal())!;
    }

    // Crash after the rename, before `published` was persisted: the final
    // directory is adopted only after full verification.
    final sealedJournal = await crashAt('published_renamed');
    expect(sealedJournal.stage, CaptureStage.sealed);
    final sealedDigest = sealedJournal.manifestSha256!;
    final recovered = await i.coordinator().recover();
    expect(recovered.stage, CaptureStage.published);
    expect(recovered.code, 'awaiting_resume_decision');
    expect(recovered.decision, CaptureDecision.resumeOriginal);
    final finalCaptureDigest = recovered.capture!.manifestSha256;
    expect(finalCaptureDigest, sealedDigest);
    expect((await i.readJournal())!.stage, CaptureStage.published);
    // A retry returns the same verified artifact.
    expect((await i.coordinator().recover()).capture!.manifestSha256, sealedDigest);
    expect(i.model.state, 'held', reason: 'restart never releases');
    await i.coordinator().resumeOriginal(
        captureId: sealedJournal.captureId, decisionDigest: '1' * 64);

    // Crash right after `sealed`: staging bytes diverge from the recorded
    // hashes. Recovery refuses, keeps everything and overwrites nothing.
    final divergent = await crashAt('journal:sealed');
    final staging = Directory(p.join(i.locations.staging.path, divergent.captureId));
    final sql = File(p.join(staging.path, 'stores', 'sql.json'));
    final tampered = sql.readAsBytesSync()..[0] ^= 0x01;
    sql.writeAsBytesSync(tampered, flush: true);
    final stagingTree = _tree(staging);
    final journalBytes = i.locations.journal.readAsBytesSync();
    for (var attempt = 0; attempt < 2; attempt++) {
      final r = await i.coordinator().recover();
      expect(r.code, 'sealed_divergence');
      expect(r.stage, CaptureStage.sealed);
      expect(r.capture, isNull);
      expect(r.decision, CaptureDecision.resumeOriginal);
    }
    expect(_tree(staging), stagingTree);
    expect(i.locations.journal.readAsBytesSync(), journalBytes);
    expect(Directory(p.join(i.locations.captures.path, divergent.captureId)).existsSync(),
        false);
    expect(i.model.state, 'held');
    await i.coordinator().resumeOriginal(
        captureId: divergent.captureId, decisionDigest: '2' * 64);
    expect((await i.readJournal())!.manifestSha256, divergent.manifestSha256,
        reason: 'recorded hashes are never overwritten');
    expect(_tree(staging), stagingTree, reason: 'nothing is cleaned up');

    // A conflicting destination blocks and is never overwritten.
    final conflicted = await crashAt('journal:sealed');
    final destination =
        Directory(p.join(i.locations.captures.path, conflicted.captureId))
          ..createSync(recursive: true);
    File(p.join(destination.path, 'manifest.json')).writeAsStringSync('{}');
    final destinationTree = _tree(destination);
    final conflictStaging =
        Directory(p.join(i.locations.staging.path, conflicted.captureId));
    final conflictStagingTree = _tree(conflictStaging);
    final r = await i.coordinator().recover();
    expect(r.code, 'destination_conflict');
    expect(r.capture, isNull);
    expect(_tree(destination), destinationTree);
    expect(_tree(conflictStaging), conflictStagingTree);
    expect((await i.readJournal())!.stage, CaptureStage.sealed);
    await i.coordinator().resumeOriginal(
        captureId: conflicted.captureId, decisionDigest: '3' * 64);

    // Crash right after `sealed` with intact staging: publication finishes
    // because the hold stayed recorded, and stops at `published`.
    final intact = await crashAt('journal:sealed');
    final finished = await i.coordinator().recover();
    expect(finished.stage, CaptureStage.published);
    expect(finished.capture!.manifestSha256, intact.manifestSha256);

    // ...but not once the hold is gone.
    await i.coordinator().resumeOriginal(
        captureId: intact.captureId, decisionDigest: '4' * 64);
    final lost = await crashAt('journal:sealed');
    await i.gate.release(SourceHold(lost.captureId, lost.gateGeneration!),
        decisionDigest: '5' * 64);
    final noHold = await i.coordinator().recover();
    expect(noHold.code, 'hold_lost');
    expect(noHold.capture, isNull);
    expect(Directory(p.join(i.locations.captures.path, lost.captureId)).existsSync(),
        false);
  });

  test('published_waits_for_resume_decision', () async {
    await install();
    await expectLater(
        i.coordinator(onStep: (step) {
          if (step == 'journal:published') throw const _Crash('published');
        }).capture(mode: CaptureMode.rehearsal),
        throwsA(isA<_Crash>()));
    i.restart();
    final journal = (await i.readJournal())!;
    final finalDir = Directory(p.join(i.locations.captures.path, journal.captureId));
    final finalTree = _tree(finalDir);
    final before = await i.sourceState();

    for (var restart = 0; restart < 2; restart++) {
      final (outcome, steps) = await i.startup();
      expect(steps.ran, isEmpty);
      final held = (outcome as CaptureRecoveryRequired).recovery;
      expect(held.stage, 'published');
      expect(held.code, 'awaiting_resume_decision');
      expect(held.decision, 'resume_original');
      await expectLater(
          runSourceWrite('test.write', (_) async {}),
          throwsA(isA<SourceGateException>()
              .having((e) => e.code, 'code', 'admission_closed')));
      final recovered = await i.coordinator().recover();
      expect(recovered.capture!.manifestSha256, journal.manifestSha256);
      i.restart();
    }

    // A decision for another capture changes nothing.
    await expectLater(
        i.coordinator().resumeOriginal(
            captureId: '00000000-0000-4000-8000-00000000beef',
            decisionDigest: 'c' * 64),
        throwsA(isA<CaptureBlocked>()));
    expect(i.model.state, 'held');

    await i.coordinator()
        .resumeOriginal(captureId: journal.captureId, decisionDigest: 'd' * 64);
    expect(i.model.state, 'open');
    expect(i.model.decisions, contains('d' * 64));
    expect((await i.readJournal())!.stage, CaptureStage.resumed);
    final (outcome, steps) = await i.startup();
    expect(outcome, isA<StartupAllowed>());
    expect(steps.ran, hasLength(6));
    expect(_tree(finalDir), finalTree);
    expect(await i.sourceState(), before);
  });

  test('resume_allowed_completes_release_at_startup', () async {
    await install();
    await expectLater(
        i.coordinator(onStep: (step) {
          if (step == 'journal:resume_allowed') throw const _Crash('resume');
        }).capture(mode: CaptureMode.rehearsal),
        throwsA(isA<_Crash>()));
    i.restart();
    expect(i.model.state, 'held');
    final (outcome, steps) = await i.startup();
    expect(outcome, isA<StartupAllowed>());
    expect(steps.ran, hasLength(6));
    expect(i.model.state, 'open');
    expect((await i.readJournal())!.stage, CaptureStage.resumed);
  });

  test('local_hold_survives_two_restarts', () async {
    await install();
    final certified = await i.coordinator().capture(mode: CaptureMode.localHold);
    expect((await i.readJournal())!.stage, CaptureStage.localHold);
    expect(i.model.state, 'held');
    expect(TransportAdmission.instance.isOpen, false);
    expect(i.controller!.callbacksFrozen, true);
    final admitted = i.model.admitted.length;
    final before = await i.sourceState();

    for (var restart = 0; restart < 2; restart++) {
      i.restart(liveDraft: true);
      final (outcome, steps) = await i.startup();
      expect(steps.ran, isEmpty);
      final held = (outcome as CaptureRecoveryRequired).recovery;
      expect(held.stage, 'local_hold');
      final recovered = await i.coordinator().recover();
      expect(recovered.stage, CaptureStage.localHold);
      expect(recovered.capture!.manifestSha256, certified.manifestSha256);
      expect(recovered.decision, CaptureDecision.resumeOriginal);
      await expectLater(runSourceWrite('test.write', (_) async {}),
          throwsA(isA<SourceGateException>()));
    }
    final admissionsAfterTwoHeldRestarts = i.model.admitted.length - admitted;
    expect(admissionsAfterTwoHeldRestarts, 0);
    expect(i.model.state, 'held');
    expect(await i.sourceState(), before);

    await i.coordinator().resumeOriginal(
        captureId: certified.captureId, decisionDigest: 'e' * 64);
    expect(i.model.state, 'open');
    final (outcome, _) = await i.startup();
    expect(outcome, isA<StartupAllowed>());
    expect((await verifyCaptureDirectory(certified.directory)).manifestSha256,
        certified.manifestSha256);
  });

  test('timeout_or_cancel_preserves_source', () async {
    await install();
    final before = await i.sourceState();

    // A drain timeout: an admitted operation never finishes in time.
    final stuck = Completer<void>();
    final pending = runSourceWrite('test.stuck', (_) => stuck.future);
    var successAfterDrainTimeout = false;
    try {
      await i.coordinator(drainTimeout: const Duration(milliseconds: 300))
          .capture(mode: CaptureMode.rehearsal);
      successAfterDrainTimeout = true;
    } on CaptureBlocked catch (e) {
      expect(e.code, 'drain_timeout');
      expect(e.exploratory, isNull);
    }
    expect(successAfterDrainTimeout, false);
    expect(i.events, isNot(contains('step:read')));
    stuck.complete();
    await pending;
    final timedOut = (await i.readJournal())!;
    expect(timedOut.stage, CaptureStage.resumed);
    expect(timedOut.manifestSha256, isNull);
    expect(i.model.state, 'open');
    expect(i.model.idle, true, reason: 'the preparation ticket was completed');
    expect(TransportAdmission.instance.isOpen, true);
    expect(i.controller!.callbacksFrozen, false);
    final afterTimeout = await i.sourceState();
    expect({...afterTimeout}..remove('draft'), {...before}..remove('draft'));

    // Work left by a dead process: never acknowledged or released
    // automatically.
    i.model.drainCode = 'recovery_required';
    final c = i.coordinator();
    await expectLater(c.capture(mode: CaptureMode.rehearsal),
        throwsA(isA<CaptureBlocked>()
            .having((e) => e.code, 'code', 'recovery_required')
            .having((e) => e.decision, 'decision', CaptureDecision.resumeOriginal)));
    final interrupted = (await i.readJournal())!;
    expect(interrupted.stage, CaptureStage.held);
    expect(i.model.calls, isNot(contains('acknowledgeInterrupted')));
    expect(i.model.state, 'preparing');
    expect(TransportAdmission.instance.isOpen, false);
    expect(i.controller!.callbacksFrozen, true);
    var r = await c.recover();
    expect(r.code, 'capture_interrupted');
    expect(r.capture, isNull);
    // Another coordinator of this process records the decision: it also
    // resumes what this process froze and closed.
    await i.coordinator().resumeOriginal(
        captureId: interrupted.captureId, decisionDigest: 'f' * 64);
    expect(i.controller!.callbacksFrozen, false);
    expect(i.model.calls, contains('acknowledgeInterrupted'));
    expect(i.model.state, 'open');
    expect(TransportAdmission.instance.isOpen, true);

    // Interrupted while copying (process death): acknowledgements are lost,
    // so nothing is ever certified for that attempt.
    await expectLater(
        i.coordinator(onStep: (step) {
          if (step == 'staged') throw const _Crash('staged');
        }).capture(mode: CaptureMode.rehearsal),
        throwsA(isA<_Crash>()));
    i.restart(liveDraft: true);
    final lost = (await i.readJournal())!;
    expect(lost.stage, CaptureStage.copying);
    final oldStaging = Directory(p.join(i.locations.staging.path, lost.captureId));
    final oldTree = _tree(oldStaging);
    final sourceAfterCrash = await i.sourceState();
    for (var attempt = 0; attempt < 2; attempt++) {
      r = await i.coordinator().recover();
      expect(r.code, 'capture_interrupted');
      expect(r.stage, CaptureStage.copying);
      expect(r.capture, isNull);
      expect(r.decision, CaptureDecision.resumeOriginal);
      expect(await i.sourceState(), sourceAfterCrash);
    }
    final (held, steps) = await i.startup();
    expect(held, isA<CaptureRecoveryRequired>());
    expect(steps.ran, isEmpty);
    await i.coordinator()
        .resumeOriginal(captureId: lost.captureId, decisionDigest: '9' * 64);
    expect(await i.sourceState(), sourceAfterCrash);

    // A fresh attempt gets a new id and its own hashes; the old output stays.
    final fresh = await i.coordinator().capture(mode: CaptureMode.rehearsal);
    expect(fresh.captureId, isNot(lost.captureId));
    expect(_tree(oldStaging), oldTree);
    expect(Directory(p.join(i.locations.captures.path, lost.captureId)).existsSync(),
        false);
  });

  test('blocked_boundaries_never_certify', () async {
    await install();
    final before = await i.sourceState();

    // An open form with unsaved edits: refused before anything is written.
    final form = UnsavedEditors.instance.register('plan_day', () => true);
    await expectLater(i.coordinator().capture(mode: CaptureMode.rehearsal),
        throwsA(isA<CaptureBlocked>()
            .having((e) => e.code, 'code', 'unsaved_editor_input')
            .having((e) => e.remediation, 'remediation', 'save_or_cancel_forms')));
    expect(i.locations.journal.existsSync(), false);
    expect(i.model.calls, isNot(contains('prepare')));
    UnsavedEditors.instance.unregister(form);

    // A sticky persistence failure: blocked with a remediation, released.
    SessionWriteLedger.instance
        .recordFailure('finished', const FileSystemException('disk full'));
    await expectLater(i.coordinator().capture(mode: CaptureMode.rehearsal),
        throwsA(isA<CaptureBlocked>()
            .having((e) => e.code, 'code', 'persistence_failed')
            .having((e) => e.remediation, 'remediation', 'retry_after_resume')));
    expect((await i.readJournal())!.stage, CaptureStage.resumed);
    expect(i.model.state, 'open');
    SessionWriteLedger.instance.resetForTesting();

    // Not enough private space: nothing is staged, nothing evicted.
    i.fakeFiles.availableBytes = 1024;
    await expectLater(i.coordinator().capture(mode: CaptureMode.rehearsal),
        _blocked('insufficient_space'));
    expect(i.locations.staging.existsSync() &&
            i.locations.staging.listSync().isNotEmpty,
        false);
    i.fakeFiles.availableBytes = 1 << 40;

    // A flush whose recorded pre-flush version is not what was on disk.
    final other = File(p.join(i.source.path, 'capture', 'other-bytes'))
      ..createSync(recursive: true)
      ..writeAsStringSync('not the draft');
    final lying = _LyingHooks(
        manager: i.manager,
        preservation: i.preservation,
        before: await readRawFile(other));
    other.deleteSync();
    await expectLater(
        i.coordinator(hooks: lying).capture(mode: CaptureMode.rehearsal),
        _blocked('flush_before_mismatch'));

    // An unknown file beside the stores: sealed for diagnosis, never
    // published or certified.
    File(p.join(i.source.path, 'stray.bin')).writeAsStringSync('?');
    try {
      await i.coordinator().capture(mode: CaptureMode.rehearsal);
      fail('an unusable capture was certified');
    } on CaptureBlocked catch (e) {
      expect(e.code, 'capture_unusable');
      final exploratory = e.exploratory!;
      expect(exploratory.blockers, contains('unknown_source_entry'));
      expect(exploratory.directory.path,
          p.join(i.locations.staging.path, exploratory.captureId));
      expect(await verifyCaptureDirectory(exploratory.directory),
          isA<Object>());
      expect(Directory(p.join(i.locations.captures.path, exploratory.captureId))
          .existsSync(), false);
    }
    File(p.join(i.source.path, 'stray.bin')).deleteSync();
    expect(i.model.state, 'open');
    final after = await i.sourceState();
    expect({...after}..remove('draft'), {...before}..remove('draft'));

    // A publication that cannot refuse replacement blocks at `sealed`.
    i.fakeFiles.failMethods['publishNoReplace'] = 'unsupported';
    await expectLater(i.coordinator().capture(mode: CaptureMode.rehearsal),
        _blocked('publish_failed'));
    expect((await i.readJournal())!.stage, CaptureStage.sealed);
    expect(i.model.state, 'held');
  });

  test('interrupted_preparing_and_held_recover_with_new_id', () async {
    await install();
    final before = await i.sourceState();
    final ids = <String>{};

    for (final crashStep in ['journal:preparing', 'journal:held']) {
      await expectLater(
          i.coordinator(onStep: (step) {
            if (step == crashStep) throw _Crash(step);
          }).capture(mode: CaptureMode.rehearsal),
          throwsA(isA<_Crash>()));
      i.restart();
      final lost = (await i.readJournal())!;
      ids.add(lost.captureId);
      if (crashStep == 'journal:preparing') {
        // Persisted before admission closed: nothing is recorded yet.
        expect(lost.stage, CaptureStage.preparing);
        expect(lost.gateGeneration, isNull);
        expect(i.model.state, 'open');
      } else {
        // Admission closed, hold never taken, the ticket died with the
        // process.
        expect(lost.stage, CaptureStage.held);
        expect(i.model.state, 'preparing');
        expect(i.model.idle, true);
      }
      final crashed = await i.sourceState();
      for (var attempt = 0; attempt < 2; attempt++) {
        final (outcome, steps) = await i.startup();
        expect(steps.ran, isEmpty);
        final held = (outcome as CaptureRecoveryRequired).recovery;
        expect(held.code, 'capture_interrupted');
        expect(held.stage, lost.stage.wire);
        expect(held.decision, 'resume_original');
        expect(await i.sourceState(), crashed);
      }
      await i.coordinator().resumeOriginal(
          captureId: lost.captureId, decisionDigest: '6' * 64);
      expect(i.model.state, 'open');
      expect((await i.readJournal())!.stage, CaptureStage.resumed);
      expect((await i.readJournal())!.manifestSha256, isNull);
      expect(await i.sourceState(), crashed);
      final (outcome, steps) = await i.startup();
      expect(outcome, isA<StartupAllowed>());
      expect(steps.ran, hasLength(6));
      i.restart(liveDraft: true);
    }

    final fresh = await i.coordinator().capture(mode: CaptureMode.rehearsal);
    expect(ids, isNot(contains(fresh.captureId)));
    final after = await i.sourceState();
    expect({...after}..remove('draft'), {...before}..remove('draft'));
  });

  test('null_generation_release_matches_only_its_capture', () async {
    await install();
    // An earlier capture, so the attempt below is not at generation 1.
    await i.coordinator().capture(mode: CaptureMode.rehearsal);
    i.restart(liveDraft: true);
    final before = await i.sourceState();

    // The journal write that records the generation fails: the attempt is
    // `preparing` without one while the gate records it.
    Future<CaptureJournalState> failGenerationWrite() async {
      var journalWrites = 0;
      i.fakeFiles.failWrite = (path) =>
          path == i.locations.journal.path && ++journalWrites == 2
              ? 'io_error'
              : null;
      await expectLater(i.coordinator().capture(mode: CaptureMode.rehearsal),
          throwsA(isA<CaptureBlocked>()
              .having((e) => e.code, 'code', 'journal_write_failed')
              .having((e) => e.decision, 'decision',
                  CaptureDecision.resumeOriginal)));
      i.fakeFiles.failWrite = null;
      i.restart(liveDraft: true);
      final j = (await i.readJournal())!;
      expect(j.stage, CaptureStage.preparing);
      expect(j.gateGeneration, isNull);
      expect(i.model.capture, j.captureId);
      return j;
    }

    final ours = await failGenerationWrite();
    final generation = i.model.generation;
    expect(generation, greaterThan(1));
    final scanned = i.model.calls.where((c) => c == 'verifyHold').length;
    await i.coordinator()
        .resumeOriginal(captureId: ours.captureId, decisionDigest: '8' * 64);
    expect(i.model.calls.where((c) => c == 'verifyHold').length - scanned,
        greaterThanOrEqualTo(generation),
        reason: 'the generation was found by searching');
    expect(i.model.state, 'open');
    expect(i.model.decisions.last, '8' * 64);
    expect((await i.readJournal())!.stage, CaptureStage.resumed);
    expect(await i.sourceState(), {...before, 'draft': (await i.sourceState())['draft']});

    // The same gap while the gate records ANOTHER capture: nothing matches
    // this capture id at any generation, so nothing is released.
    final orphan = await failGenerationWrite();
    await i.gate.release(SourceHold(orphan.captureId, i.model.generation),
        decisionDigest: 'a' * 64);
    const foreign = '00000000-0000-4000-8000-00000000f00d';
    await i.gate.closeAdmission(foreign);
    final foreignGeneration = i.model.generation;
    final releases = i.model.calls.where((c) => c == 'release').length;
    await expectLater(
        i.coordinator().resumeOriginal(
            captureId: orphan.captureId, decisionDigest: '9' * 64),
        throwsA(isA<CaptureBlocked>()
            .having((e) => e.code, 'code', 'gate_generation_unknown')));
    expect(i.model.capture, foreign);
    expect(i.model.state, 'preparing');
    expect(i.model.generation, foreignGeneration);
    expect(i.model.calls.where((c) => c == 'release').length, releases,
        reason: 'no release was attempted for another capture');
    final after = await i.sourceState();
    expect({...after}..remove('draft'), {...before}..remove('draft'));
  });

  test('recorded_resumption_completes_before_next_capture', () async {
    await install();
    final before = await i.sourceState();
    // Released, but `resumed` was never recorded.
    await expectLater(
        i.coordinator(onStep: (step) {
          if (step == 'released') throw const _Crash('released');
        }).capture(mode: CaptureMode.rehearsal),
        throwsA(isA<_Crash>()));
    i.restart(liveDraft: true);
    final recorded = (await i.readJournal())!;
    expect(recorded.stage, CaptureStage.resumeAllowed);
    expect(i.model.state, 'open');
    // Startup is not held by it...
    final (outcome, steps) = await i.startup();
    expect(outcome, isA<StartupAllowed>());
    expect(steps.ran, hasLength(6));
    expect((await i.readJournal())!.stage, CaptureStage.resumeAllowed);
    // ...and the next capture completes it instead of refusing.
    final next = await i.coordinator().capture(mode: CaptureMode.rehearsal);
    expect(next.captureId, isNot(recorded.captureId));
    expect((await i.readJournal())!.captureId, next.captureId);
    // The earlier capture is still there and still verifies.
    final earlier = Directory(p.join(i.locations.captures.path, recorded.captureId));
    expect((await verifyCaptureDirectory(earlier)).manifestSha256,
        recorded.manifestSha256);
    final after = await i.sourceState();
    expect({...after}..remove('draft'), {...before}..remove('draft'));
  });

  test('refused_attempt_never_rolls_back_another_journal', () async {
    await install();
    await i.coordinator().capture(mode: CaptureMode.rehearsal);
    final settled = i.locations.journal.readAsBytesSync();
    const foreign = '00000000-0000-4000-8000-00000000f00d';

    // Another process closes admission between our `preparing` write and
    // our `prepare`: refused, and our claim is withdrawn exactly.
    var hooked = false;
    await expectLater(
        i.coordinator(onStep: (step) async {
          if (step == 'journal:preparing' && !hooked) {
            hooked = true;
            await i.gate.closeAdmission(foreign);
          }
        }).capture(mode: CaptureMode.rehearsal),
        _blocked('capture_in_progress'));
    expect(i.locations.journal.readAsBytesSync(), settled);
    await i.gate.release(SourceHold(foreign, i.model.generation),
        decisionDigest: 'a' * 64);

    // The other process also wrote its own journal meanwhile: ours is not
    // restored over it.
    hooked = false;
    late CaptureJournalState theirs;
    await expectLater(
        i.coordinator(onStep: (step) async {
          if (step == 'journal:preparing' && !hooked) {
            hooked = true;
            final mine = (await i.readJournal())!;
            await i.gate.closeAdmission(foreign);
            theirs = CaptureJournalState(
              captureId: foreign,
              installation: mine.installation,
              producerVersion: mine.producerVersion,
              runtimeVersions: mine.runtimeVersions,
              storeVersions: mine.storeVersions,
              mode: CaptureMode.rehearsal,
              stage: CaptureStage.preparing,
              gateGeneration: i.model.generation,
              priorSyncIntent: PriorSyncIntent.unknown,
              inventory: const [],
              files: const {},
              manifestSha256: null,
            );
            await i.journal.write(theirs);
          }
        }).capture(mode: CaptureMode.rehearsal),
        _blocked('capture_in_progress'));
    final now = (await i.readJournal())!;
    expect(now.captureId, foreign);
    expect(now.stage, CaptureStage.preparing);
    expect(now.gateGeneration, theirs.gateGeneration);
    expect(i.model.capture, foreign);
  });

  test('platform_without_plugin_is_unsupported', () async {
    await install(liveDraft: false);
    // No handler answers this channel: the build has no capture plugin.
    const unanswered = RepsCapturePlatform(
        channel: MethodChannel('reps/capture/test/unanswered'));
    final unplugged =
        SourceWriteGate(stateDirectory: i.locations.gate, platform: unanswered);
    final coordinator = CaptureCoordinator(
      locations: i.locations,
      gate: unplugged,
      files: const CaptureFiles(platform: unanswered),
      sources: CaptureSourceBindings(
        database: i.database,
        hooks: i.hooks,
        transportFor: i.transport,
        packageInfo: () async => PackageInfo(
            appName: 'Reps',
            packageName: 'io.github.psychonaut0.reps',
            version: '0.18.1',
            buildNumber: '37'),
      ),
    );
    await expectLater(
        coordinator.capture(mode: CaptureMode.rehearsal),
        throwsA(isA<CaptureUnsupported>()
            .having((e) => e.code, 'code', 'platform_unavailable')));
    expect(i.locations.journal.existsSync(), false);
    expect((await coordinator.recover()).code, 'platform_unavailable');
  });

  test('sdk_version_constant_matches_lockfile', () {
    final lock = File('pubspec.lock').readAsStringSync();
    final entry = RegExp(r'\n  powersync:\n(?:    .*\n)*?    version: "([^"]+)"')
        .firstMatch(lock)!;
    expect(capturePowerSyncSdkVersion, entry.group(1));
  });

  test('rehearsal_accepts_certified_capture', () async {
    await install();
    final certified = await i.coordinator().capture(mode: CaptureMode.rehearsal);
    final work = await Directory.systemTemp.createTemp('reps-coordinator-go');
    addTearDown(() => work.delete(recursive: true));
    final run = await Process.run(Platform.environment['REPS_REHEARSAL_BIN']!, [
      '-capture', certified.directory.path,
      '-work', p.join(work.path, 'run'),
    ]);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    final summary = jsonDecode(run.stdout as String) as Map<String, Object?>;
    expect(summary['staging_valid'], isTrue);
    expect(summary['exploratory'], isFalse);
    expect(summary['cutover_ready'], isFalse);
    expect((summary['findings']! as Map)['blocking'], 0);
    expect(_tree(certified.directory), isNotEmpty);
    expect((await verifyCaptureDirectory(certified.directory)).manifestSha256,
        certified.manifestSha256);
  },
      skip: Platform.environment['REPS_REHEARSAL_BIN'] == null
          ? 'needs REPS_REHEARSAL_BIN (make -C app capture-go-compat)'
          : false);
}
