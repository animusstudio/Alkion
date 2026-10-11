// Host tests for the private capture journal: strict versioned decoding,
// the closed stage set, no credentials or server URLs, and persistence only
// through the durable file primitive (host stand-in; see
// test/support/fake_capture_files.dart).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:workout_tracker/capture/capture_journal.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';
import 'package:workout_tracker/capture/startup_inventory.dart';

import '../support/fake_capture_files.dart';

CaptureJournalState _state({
  CaptureStage stage = CaptureStage.held,
  Map<String, String> installation = const {
    'platform': 'linux',
    'application_id': 'io.github.psychonaut0.reps',
  },
  Map<String, String> runtime = const {'flutter': '3.44.0'},
}) =>
    CaptureJournalState(
      captureId: '3f1c2a4e-8b7d-4c6a-9e2f-1a2b3c4d5e6f',
      installation: installation,
      producerVersion: '0.18.1+37',
      runtimeVersions: runtime,
      storeVersions: const {'session_draft': 'reps-session-draft/0.18'},
      mode: CaptureMode.localHold,
      stage: stage,
      gateGeneration: 4,
      priorSyncIntent: PriorSyncIntent.enabled,
      inventory: const [
        InventoryEntry(
          role: 'draft',
          name: 'workout-draft.json',
          authoritative: true,
          status: 'captured',
          length: 2,
          sha256:
              'b5b3d3a6a6c0e06fbbb0c5e1e1a7b0d5c0a4f1bb4a0e7b0b7c3bdbd2c47a3e1f',
          preserved: true,
          reason: 'inventory',
        ),
      ],
      files: const {
        'stores/session-draft.json': CaptureFileDigest(
          sha256:
              'b5b3d3a6a6c0e06fbbb0c5e1e1a7b0d5c0a4f1bb4a0e7b0b7c3bdbd2c47a3e1f',
          length: 2,
        ),
      },
      manifestSha256:
          '0d5c0a4f1bb4a0e7b0b7c3bdbd2c47a3e1fb5b3d3a6a6c0e06fbbb0c5e1e1a7b',
    );

Matcher _journalCode(String code) => throwsA(
    isA<CaptureJournalException>().having((e) => e.code, 'code', code));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late File file;
  late FakeCaptureFiles fake;
  late CaptureJournal journal;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('capture_journal_test');
    file = File(p.join(dir.path, 'capture', 'journal.json'));
    fake = FakeCaptureFiles('journal');
    journal = CaptureJournal(file, base: dir, files: fake.files);
  });

  tearDown(() {
    fake.detach();
    Process.runSync('chmod', ['-R', 'u+rwX', dir.path]);
    dir.deleteSync(recursive: true);
  });

  test('stage_set_is_closed_and_exact', () {
    expect(CaptureStage.values.map((s) => s.wire), [
      'preparing',
      'held',
      'copying',
      'sealed',
      'published',
      'resume_allowed',
      'resumed',
      'local_hold',
    ]);
    expect(
      CaptureStage.values.where((s) => !s.blocksStartup).map((s) => s.wire),
      ['resume_allowed', 'resumed'],
    );
    expect(CaptureMode.values.map((m) => m.wire), ['rehearsal', 'local_hold']);
  });

  test('absent_journal_reads_null', () async {
    expect(await journal.read(), isNull);
  });

  test('write_is_durable_and_round_trips', () async {
    final state = _state();
    await journal.write(state);
    expect(fake.writes, [file.path]);
    final read = await journal.read();
    expect(read!.toJson(), state.toJson());
    final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(raw['format'], 'reps-capture-journal');
    expect(raw['version'], 1);
    expect(raw['stage'], 'held');
    expect(raw['mode'], 'local_hold');
    expect(raw['prior_sync_intent'], 'enabled');
  });

  test('failed_durable_write_is_never_success', () async {
    fake.failWith = 'io_error';
    await expectLater(
      journal.write(_state()),
      throwsA(isA<SourceGateException>()
          .having((e) => e.code, 'code', 'io_error')),
    );
    expect(file.existsSync(), isFalse);
    // Without a native primitive the journal cannot be written at all.
    await expectLater(
      CaptureJournal(file, base: dir).write(_state()),
      throwsA(isA<SourceGateException>()
          .having((e) => e.code, 'code', 'platform_unavailable')),
    );
  });

  test('credentials_and_server_urls_are_refused', () async {
    for (final bad in [
      _state(installation: {'server_url': 'host'}),
      _state(installation: {'email': 'someone'}),
      _state(installation: {'access_token': 'abc'}),
      _state(runtime: {'refresh_token': 'abc'}),
      _state(installation: {'platform': 'https://example.invalid'}),
      _state(installation: {'platform': 'a@b.example'}),
    ]) {
      await expectLater(
          journal.write(bad), _journalCode('journal_unsafe_value'));
    }
    expect(fake.writes, isEmpty);
  });

  test('unknown_or_malformed_journal_is_refused', () async {
    await journal.write(_state());
    final base = _state().toJson();
    final cases = <String, Object>{
      'journal_unknown_version': {...base, 'version': 2},
      'journal_unknown_stage': {...base, 'stage': 'paused'},
      'journal_malformed': {...base, 'surprise': true},
    };
    for (final MapEntry(key: code, value: json) in cases.entries) {
      file.writeAsStringSync(jsonEncode(json));
      await expectLater(journal.read(), _journalCode(code));
    }
    for (final bad in [
      {...base, 'format': 'other'},
      {...base, 'capture_id': 'not-a-uuid'},
      {...base, 'mode': 'paused'},
      {...base, 'gate_generation': -1},
      {...base, 'installation': {'server_url': 'host'}},
    ]) {
      file.writeAsStringSync(jsonEncode(bad));
      await expectLater(journal.read(), _journalCode('journal_malformed'));
    }
    file.writeAsBytesSync([0xff, 0x7b]);
    await expectLater(journal.read(), _journalCode('journal_malformed'));

    Process.runSync('chmod', ['000', file.path]);
    await expectLater(journal.read(), _journalCode('journal_unreadable'));
    Process.runSync('chmod', ['600', file.path]);

    file.deleteSync();
    Link(file.path).createSync(p.join(dir.path, 'elsewhere.json'));
    await expectLater(journal.read(), _journalCode('journal_unreadable'));
  });
}
