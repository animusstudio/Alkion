// Host tests for capture-first startup: raw reads, preservation into the
// private preparation area, and the gate that runs before any destructive
// loader, identity generation, boot migration or connect.
//
// File primitives go through the host stand-in in
// test/support/fake_capture_files.dart (or the real, absent channel, which
// fails closed). These tests pin ordering and preservation logic; native
// durability is qualified separately.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:workout_tracker/capture/capture_journal.dart';
import 'package:workout_tracker/capture/capture_startup.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';
import 'package:workout_tracker/capture/startup_inventory.dart';
import 'package:workout_tracker/data/active_session_draft.dart';
import 'package:workout_tracker/data/finished_session_store.dart';
import 'package:workout_tracker/session/active_session_controller.dart';
import 'package:workout_tracker/session/session_manager.dart';

import '../support/fake_capture_files.dart';

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

/// Records every ordinary boot step it is asked to run.
class _SpySteps implements OrdinaryStartupSteps {
  final calls = <String>[];

  @override
  Future<void> loadSettings() async => calls.add('settings');

  @override
  Future<void> openDatabase() async => calls.add('openDatabase');

  @override
  Future<void> initIdentity() async => calls.add('identity');

  @override
  Future<void> runBootMigrations() async => calls.add('migrations');

  @override
  Future<void> prepareSessions() async => calls.add('sessions');

  @override
  Future<void> connect() async => calls.add('connect');
}

const _ordinary = [
  'settings',
  'openDatabase',
  'identity',
  'migrations',
  'sessions',
  'connect',
];

final _now = DateTime(2026, 10, 10, 12);

SessionDraft _draft(String name) => SessionDraft(
      templateId: null,
      name: name,
      focus: '',
      startedAt: DateTime(2026, 10, 10, 9),
      blocks: [],
    );

/// Finished long before [_now]: no longer resumable, so the ordinary loader
/// deletes it.
FinishedSession _expired() => FinishedSession(
      sessionId: 's-1',
      sessionDate: '2026-01-02',
      finishedAt: DateTime(2026, 1, 2, 9, 30),
      elapsedSeconds: 600,
      draft: _draft('Old'),
    );

CaptureJournalState _journal(CaptureStage stage) => CaptureJournalState(
      captureId: '3f1c2a4e-8b7d-4c6a-9e2f-1a2b3c4d5e6f',
      installation: const {
        'platform': 'linux',
        'application_id': 'io.github.psychonaut0.reps',
      },
      producerVersion: '0.18.1+37',
      runtimeVersions: const {'flutter': '3.44.0', 'powersync': '2.2.0'},
      storeVersions: const {'session_draft': 'reps-session-draft/0.18'},
      mode: CaptureMode.rehearsal,
      stage: stage,
      gateGeneration: 1,
      priorSyncIntent: PriorSyncIntent.disabled,
      inventory: const [],
      files: const {},
      manifestSha256: null,
    );

void _chmod(String mode, String path) {
  final r = Process.runSync('chmod', [mode, path]);
  if (r.exitCode != 0) throw StateError('chmod failed: ${r.stderr}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory source;
  late CaptureLocations locations;
  late FakeCaptureFiles fake;
  late File draftFile;
  late File draftTmp;
  late File finishedFile;

  setUp(() {
    root = Directory.systemTemp.createTempSync('startup_inventory_test');
    source = Directory(p.join(root.path, 'app-support'))..createSync();
    locations = CaptureLocations(source);
    fake = FakeCaptureFiles('startup');
    draftFile = File(p.join(source.path, DraftStore.fileName));
    draftTmp = File('${draftFile.path}.tmp');
    finishedFile = File(p.join(source.path, FinishedSessionStore.fileName));
  });

  tearDown(() {
    fake.detach();
    // Restore permissions so the temp tree can be removed.
    Process.runSync('chmod', ['-R', 'u+rwX', root.path]);
    root.deleteSync(recursive: true);
  });

  /// Runs the capture-aware startup over [source] with spies everywhere.
  /// The loaders run the real destructive store loaders; [beforeLoad] sees
  /// the preparation area at the moment a loader is entered.
  Future<StartupOutcome> start({
    required _SpySteps steps,
    required List<String> loads,
    CaptureFiles? preservationFiles,
    String gate = 'open',
    Future<void> Function(String role)? beforeLoad,
  }) async {
    final draftStore = DraftStore(directory: () async => source);
    final finishedStore = FinishedSessionStore(directory: () async => source);
    final manager = SessionManager(finishedStore: finishedStore);
    addTearDown(manager.dispose);
    return runCaptureAwareStartup(
      journal: CaptureJournal(
        locations.journal,
        base: source,
        files: fake.files,
      ),
      probeGate: () async => gate,
      source: source,
      preservation: RawPreservation(
        locations.preparation,
        base: source,
        files: preservationFiles ?? fake.files,
      ),
      files: [
        await draftStartupFile(draftStore, (now) async {
          loads.add('draft');
          await beforeLoad?.call('draft');
          await draftStore.load();
        }),
        await finishedStartupFile(finishedStore, (now) async {
          loads.add('finished');
          await beforeLoad?.call('finished');
          await manager.loadLastFinished(now: now);
        }),
      ],
      steps: steps,
      now: _now,
    );
  }

  test('raw_reads_never_decode_or_delete', () async {
    draftFile.writeAsBytesSync([0xff, 0x7b]);
    final captured = await readRawFile(draftFile);
    expect(captured.status, 'captured');
    expect(captured.bytes, [0xff, 0x7b]);
    expect(captured.sha256, _sha([0xff, 0x7b]));
    expect(captured.length, 2);

    final absent = await readRawFile(File(p.join(source.path, 'missing.json')));
    expect(absent.status, 'absent');
    expect(absent.bytes, isNull);

    final dir = Directory(p.join(source.path, 'a-directory'))..createSync();
    expect((await readRawFile(File(dir.path))).status, 'unsupported');

    final link = Link(p.join(source.path, 'linked.json'))
      ..createSync(draftFile.path);
    expect((await readRawFile(File(link.path))).status, 'unsupported');

    final oversized = await readRawFile(draftFile, maxBytes: 1);
    expect(oversized.status, 'inspection_failed');
    expect(oversized.detail, 'oversized');

    _chmod('000', draftFile.path);
    final unreadable = await readRawFile(draftFile);
    expect(unreadable.status, 'inspection_failed');
    expect(unreadable.bytes, isNull);
    _chmod('600', draftFile.path);

    // Nothing was decoded away, deleted or renamed.
    expect(draftFile.readAsBytesSync(), [0xff, 0x7b]);
    expect(link.existsSync(), isTrue);
    expect(dir.existsSync(), isTrue);
  });

  test('malformed_and_expired_bytes_precede_loader', () async {
    draftFile.writeAsBytesSync([0xff, 0x7b]);
    await FinishedSessionStore(directory: () async => source).save(_expired());
    final expiredBytes = finishedFile.readAsBytesSync();
    final orphan = utf8.encode('{"name":"half-writ');
    draftTmp.writeAsBytesSync(orphan);

    final preservation = RawPreservation(locations.preparation, base: source);
    final atLoad = <String, RawFileObservation>{};
    final steps = _SpySteps();
    final loads = <String>[];
    final outcome = await start(
      steps: steps,
      loads: loads,
      beforeLoad: (role) async {
        final sha = role == 'draft' ? _sha([0xff, 0x7b]) : _sha(expiredBytes);
        atLoad[role] = await readRawFile(preservation.blobFile(sha));
      },
    );

    expect(outcome, isA<StartupAllowed>());
    expect(steps.calls, _ordinary);
    expect(loads, ['draft', 'finished']);

    // The exact bytes were preserved before each destructive loader ran.
    final preservedDraft = atLoad['draft']!;
    expect(preservedDraft.bytes, [0xff, 0x7b]);
    expect(atLoad['finished']!.bytes, expiredBytes);

    // The ordinary loaders still did what they always did.
    expect(draftFile.existsSync(), isFalse);
    expect(finishedFile.existsSync(), isFalse);

    // The orphan temporary file is preserved as its own opaque version,
    // never promoted and never deleted.
    final orphanBlob = await readRawFile(preservation.blobFile(_sha(orphan)));
    expect(orphanBlob.bytes, orphan);
    expect(draftTmp.readAsBytesSync(), orphan);

    final inventory = (outcome as StartupAllowed).inventory;
    for (final e in inventory.entries.where((e) => e.authoritative)) {
      final authoritativePath = e.name;
      expect(authoritativePath.endsWith('.tmp'), false);
    }
    final tmpEntry =
        inventory.entries.singleWhere((e) => e.name.endsWith('.tmp') && e.role == 'draft');
    expect(tmpEntry.authoritative, isFalse);
    expect(tmpEntry.sha256, _sha(orphan));
    expect(tmpEntry.reason, 'orphan_tmp');
    expect(
      inventory.entries
          .singleWhere((e) => e.role == 'draft' && e.authoritative)
          .reason,
      'malformed',
    );
    expect(
      inventory.entries
          .singleWhere((e) => e.role == 'finished' && e.authoritative)
          .reason,
      'expired',
    );

    // A safe record says what was kept and why; it carries no bytes.
    final records = preservation.records.listSync().whereType<File>().toList();
    expect(records, hasLength(1));
    final record = records.single.readAsStringSync();
    expect(record, contains(_sha([0xff, 0x7b])));
    expect(record, isNot(contains('half-writ')));
  });

  test('preflush_and_tmp_versions_are_distinct', () async {
    final store = DraftStore(directory: () async => source);
    await store.save(_draft('A'));
    final a = draftFile.readAsBytesSync();
    final b = utf8.encode('{"name":"B-unfinished');
    draftTmp.writeAsBytesSync(b);

    final inventory = await inspectCaptureStartup(
      source,
      locations.preparation,
      files: fake.files,
    );
    final authoritative = inventory.entries
        .singleWhere((e) => e.role == 'draft' && e.authoritative);
    final temporary = inventory.entries
        .singleWhere((e) => e.role == 'draft' && !e.authoritative);
    expect(authoritative.name, DraftStore.fileName);
    expect(authoritative.sha256, _sha(a));
    expect(temporary.name, '${DraftStore.fileName}.tmp');
    expect(temporary.sha256, _sha(b));
    expect(temporary.sha256, isNot(authoritative.sha256));
    expect(authoritative.preserved && temporary.preserved, isTrue);
    expect(
      inventory.entries
          .singleWhere((e) => e.role == 'finished' && e.authoritative)
          .status,
      'absent',
    );

    // The one final flush: pre-flush, orphan and flushed bytes are three
    // distinct preserved versions with an explicit replacement relation.
    final preservation =
        RawPreservation(locations.preparation, base: source, files: fake.files);
    final replacement = await preservation.preserveAcrossFlush(
      role: 'draft',
      file: draftFile,
      temporary: draftTmp,
      flush: () => store.save(_draft('C')),
    );
    final c = draftFile.readAsBytesSync();
    expect(replacement.before.sha256, _sha(a));
    expect(replacement.temporaryBefore!.sha256, _sha(b));
    expect(replacement.after.sha256, _sha(c));
    expect({_sha(a), _sha(b), _sha(c)}, hasLength(3));
    for (final bytes in [a, b, c]) {
      expect((await readRawFile(preservation.blobFile(_sha(bytes)))).bytes,
          bytes);
    }
    expect(replacement.toJson(), containsPair('relation', 'replaced_by'));
    expect(replacement.toJson()['before'], containsPair('sha256', _sha(a)));
    expect(replacement.toJson()['after'], containsPair('sha256', _sha(c)));

    // Only a temporary file left: the authoritative role stays absent.
    draftFile.deleteSync();
    final d = utf8.encode('{"name":"D');
    draftTmp.writeAsBytesSync(d);
    final after = await inspectCaptureStartup(
      source,
      locations.preparation,
      files: fake.files,
    );
    expect(
      after.entries
          .singleWhere((e) => e.role == 'draft' && e.authoritative)
          .status,
      'absent',
    );
    expect(draftTmp.readAsBytesSync(), d);
    expect(draftFile.existsSync(), isFalse);
  });

  test('valid_live_draft_over_malformed_file_keeps_both_versions', () async {
    draftFile.writeAsBytesSync([0xff, 0x7b]);
    final store = DraftStore(directory: () async => source);
    final preservation =
        RawPreservation(locations.preparation, base: source, files: fake.files);

    final replacement = await preservation.preserveAcrossFlush(
      role: 'draft',
      file: draftFile,
      temporary: draftTmp,
      flush: () => store.save(_draft('Live')),
    );

    final flushed = draftFile.readAsBytesSync();
    expect(DraftStore.tryDecode(utf8.decode(flushed))!.name, 'Live');
    expect(replacement.before.sha256, _sha([0xff, 0x7b]));
    expect(replacement.after.sha256, _sha(flushed));
    expect((await readRawFile(preservation.blobFile(_sha([0xff, 0x7b])))).bytes,
        [0xff, 0x7b]);
    expect((await readRawFile(preservation.blobFile(_sha(flushed)))).bytes,
        flushed);
    final record = preservation.records
        .listSync()
        .whereType<File>()
        .map((f) => jsonDecode(f.readAsStringSync()) as Map<String, dynamic>)
        .singleWhere((r) => r['kind'] == 'replacement');
    expect(record['relation'], 'replaced_by');
    expect(record['before']['sha256'], _sha([0xff, 0x7b]));
    expect(record['after']['sha256'], _sha(flushed));
  });

  test('preflush_preservation_failure_blocks_the_flush', () async {
    draftFile.writeAsBytesSync([0xff, 0x7b]);
    var flushes = 0;
    final failing = RawPreservation(locations.preparation, base: source);
    await expectLater(
      failing.preserveAcrossFlush(
        role: 'draft',
        file: draftFile,
        temporary: draftTmp,
        flush: () async => flushes++,
      ),
      throwsA(isA<PreservationException>()),
    );
    _chmod('000', draftFile.path);
    await expectLater(
      RawPreservation(locations.preparation, base: source, files: fake.files)
          .preserveAcrossFlush(
        role: 'draft',
        file: draftFile,
        temporary: draftTmp,
        flush: () async => flushes++,
      ),
      throwsA(isA<PreservationException>()),
    );
    _chmod('600', draftFile.path);
    expect(flushes, 0);
    expect(draftFile.readAsBytesSync(), [0xff, 0x7b]);
  });

  test('failed_preservation_never_runs_loader', () async {
    draftFile.writeAsBytesSync([0xff, 0x7b]);
    await FinishedSessionStore(directory: () async => source).save(_expired());
    final expiredBytes = finishedFile.readAsBytesSync();

    // Capture-capable (the native gate answers `open`) but the durable write
    // fails: startup is held before any ordinary step, so no later save or
    // clear can destroy the bytes that were not kept.
    final failing = FakeCaptureFiles('failing')..failWith = 'io_error';
    addTearDown(failing.detach);
    final steps = _SpySteps();
    final loads = <String>[];
    final outcome = await start(
      steps: steps,
      loads: loads,
      preservationFiles: failing.files,
    );
    final destructiveLoaderCalls = loads.length;
    expect(destructiveLoaderCalls, 0);
    expect(steps.calls, isEmpty);
    expect(outcome, isA<CaptureRecoveryRequired>());
    final recovery = (outcome as CaptureRecoveryRequired).recovery;
    expect(recovery.code, 'preservation_failed');
    expect(
      recovery.inventory!.errors.map((e) => e.role).toSet(),
      {'draft', 'finished'},
    );
    expect(draftFile.readAsBytesSync(), [0xff, 0x7b]);
    expect(finishedFile.readAsBytesSync(), expiredBytes);

    // Unreadable is not absent: an unreadable snapshot holds startup even
    // when preservation works, while an absent draft would not.
    draftFile.deleteSync();
    _chmod('000', finishedFile.path);
    final unreadable = await readRawFile(finishedFile);
    expect(unreadable.status, 'inspection_failed');
    expect((await readRawFile(draftFile)).status, 'absent');
    final steps2 = _SpySteps();
    final loads2 = <String>[];
    final outcome2 = await start(steps: steps2, loads: loads2);
    expect(steps2.calls, isEmpty);
    expect(loads2, isEmpty);
    final recovery2 = (outcome2 as CaptureRecoveryRequired).recovery;
    expect(recovery2.code, 'preservation_failed');
    expect(
      recovery2.inventory!.entries
          .singleWhere((e) => e.role == 'finished' && e.authoritative)
          .status,
      'inspection_failed',
    );
    _chmod('600', finishedFile.path);
    expect(finishedFile.readAsBytesSync(), expiredBytes);

    // An orphan `.tmp` that cannot be kept also holds: the next save would
    // overwrite it.
    finishedFile.deleteSync();
    draftTmp.writeAsBytesSync(utf8.encode('{"name":"half'));
    _chmod('000', draftTmp.path);
    final steps3 = _SpySteps();
    final loads3 = <String>[];
    final outcome3 = await start(steps: steps3, loads: loads3);
    expect(
      (outcome3 as CaptureRecoveryRequired).recovery.code,
      'preservation_failed',
    );
    expect(steps3.calls, isEmpty);
    expect(loads3, isEmpty);
  });

  test('platform_without_plugin_skips_loader_and_boots', () async {
    draftFile.writeAsBytesSync([0xff, 0x7b]);
    await FinishedSessionStore(directory: () async => source).save(_expired());
    final expiredBytes = finishedFile.readAsBytesSync();

    // Not capture-capable (no plugin, as on Android builds): the copy fails,
    // the destructive loaders are skipped, the files stay byte-identical
    // and the app boots as before.
    final steps = _SpySteps();
    final loads = <String>[];
    final outcome = await start(
      steps: steps,
      loads: loads,
      gate: 'platform_unavailable',
      preservationFiles: const CaptureFiles(),
    );
    expect(loads, isEmpty);
    expect(outcome, isA<StartupAllowed>());
    expect((outcome as StartupAllowed).skippedLoaders, {'draft', 'finished'});
    expect(steps.calls, _ordinary);
    expect(draftFile.readAsBytesSync(), [0xff, 0x7b]);
    expect(finishedFile.readAsBytesSync(), expiredBytes);

    // A valid or absent store still loads there.
    draftFile.deleteSync();
    finishedFile.deleteSync();
    final loads2 = <String>[];
    final outcome2 = await start(
      steps: _SpySteps(),
      loads: loads2,
      gate: 'unsupported',
      preservationFiles: const CaptureFiles(),
    );
    expect(loads2, ['draft', 'finished']);
    expect((outcome2 as StartupAllowed).skippedLoaders, isEmpty);
  });

  test('probe_without_plugin_never_holds_startup', () async {
    // A gate directory that could never be created (its parent is a file).
    final blocker = File(p.join(locations.root.path, 'gate'));
    blocker.parent.createSync(recursive: true);
    blocker.writeAsStringSync('not a directory');
    final gate = SourceWriteGate(
      stateDirectory: Directory(p.join(blocker.path, 'state')),
    );

    // Without the plugin the probe answers before touching the file system.
    expect(
      await probeSourceGate(gate, base: source, files: const CaptureFiles()),
      'platform_unavailable',
    );
    expect(blocker.readAsStringSync(), 'not a directory');

    // Even with unreadable capture state on disk, such a startup is not
    // held by capture code.
    locations.journal.writeAsBytesSync([0xff, 0x7b]);
    final steps = _SpySteps();
    final draftStore = DraftStore(directory: () async => source);
    final finishedStore = FinishedSessionStore(directory: () async => source);
    final outcome = await runCaptureAwareStartup(
      journal: CaptureJournal(locations.journal, base: source),
      probeGate: () =>
          probeSourceGate(gate, base: source, files: const CaptureFiles()),
      source: source,
      preservation: RawPreservation(locations.preparation, base: source),
      files: [
        await draftStartupFile(draftStore, (_) async {}),
        await finishedStartupFile(finishedStore, (_) async {}),
      ],
      steps: steps,
      now: _now,
    );
    expect(outcome, isA<StartupAllowed>());
    expect(steps.calls, _ordinary);

    // With the plugin present, a directory the gate cannot use holds.
    final failing = FakeCaptureFiles('probe')..failWith = 'io_error';
    addTearDown(failing.detach);
    expect(
      await probeSourceGate(gate, base: source, files: failing.files),
      'io_error',
    );
  });

  test('journal_hold_precedes_identity_backfill_connect', () async {
    draftFile.writeAsBytesSync([0xff, 0x7b]);
    final journal =
        CaptureJournal(locations.journal, base: source, files: fake.files);

    const active = [
      CaptureStage.preparing,
      CaptureStage.held,
      CaptureStage.copying,
      CaptureStage.sealed,
      CaptureStage.published,
      CaptureStage.localHold,
    ];
    for (final stage in active) {
      await journal.write(_journal(stage));
      final steps = _SpySteps();
      final loads = <String>[];
      final outcome = await start(steps: steps, loads: loads);
      expect(outcome, isA<CaptureRecoveryRequired>(), reason: stage.wire);
      final recovery = (outcome as CaptureRecoveryRequired).recovery;
      expect(recovery.code, 'capture_active');
      expect(recovery.stage, stage.wire);
      expect(steps.calls, isEmpty, reason: stage.wire);
      expect(loads, isEmpty, reason: stage.wire);
    }

    // Unknown version, unknown stage and an unreadable journal are readable
    // recovery, never ordinary startup.
    final base = _journal(CaptureStage.held).toJson();
    final cases = <String, void Function()>{
      'journal_unknown_version': () => locations.journal
          .writeAsStringSync(jsonEncode({...base, 'version': 2})),
      'journal_unknown_stage': () => locations.journal
          .writeAsStringSync(jsonEncode({...base, 'stage': 'paused'})),
      'journal_malformed': () =>
          locations.journal.writeAsBytesSync([0xff, 0x7b]),
      'journal_unreadable': () => _chmod('000', locations.journal.path),
    };
    for (final MapEntry(key: code, value: arrange) in cases.entries) {
      _chmod('600', locations.journal.path);
      arrange();
      final steps = _SpySteps();
      final loads = <String>[];
      final outcome = await start(steps: steps, loads: loads);
      expect(outcome, isA<CaptureRecoveryRequired>(), reason: code);
      expect((outcome as CaptureRecoveryRequired).recovery.code, code);
      expect(steps.calls, isEmpty, reason: code);
      expect(loads, isEmpty, reason: code);
    }
    _chmod('600', locations.journal.path);
    locations.journal.deleteSync();

    // A native gate record without a journal also holds startup.
    final gateSteps = _SpySteps();
    final gateLoads = <String>[];
    final gated =
        await start(steps: gateSteps, loads: gateLoads, gate: 'mismatch');
    expect((gated as CaptureRecoveryRequired).recovery.code, 'gate_mismatch');
    expect(gateSteps.calls, isEmpty);
    expect(gateLoads, isEmpty);

    // The source stores were never touched by any held startup.
    expect(draftFile.readAsBytesSync(), [0xff, 0x7b]);

    // Resumable stages and a platform without the native gate start as
    // usual.
    for (final stage in [CaptureStage.resumeAllowed, CaptureStage.resumed]) {
      await journal.write(_journal(stage));
      final steps = _SpySteps();
      final outcome = await start(
        steps: steps,
        loads: <String>[],
        gate: 'platform_unavailable',
      );
      expect(outcome, isA<StartupAllowed>(), reason: stage.wire);
      expect(steps.calls, _ordinary);
    }
  });
}
