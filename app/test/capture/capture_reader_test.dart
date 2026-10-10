// Host tests for the capture store readers: one read transaction for the
// seven tables, the upload queue and its bookkeeping; exact queue text and
// integral ids; raw draft/finished bytes under their roles; typed
// preferences with explicit dispositions. Every value is synthetic.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:workout_tracker/capture/capture_artifact.dart';
import 'package:workout_tracker/capture/capture_manifest.dart';
import 'package:workout_tracker/capture/capture_profile.dart';
import 'package:workout_tracker/capture/capture_reader.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';
import 'package:workout_tracker/capture/startup_inventory.dart';

import '../support/capture_fixture.dart';

const _captureId = '9c000000-0000-4000-8000-0000000000a1';
const _hold = SourceHold(_captureId, 7);

const _allAttested = CaptureBoundary(
  sqlSnapshot: 'single_read_transaction',
  mutationPaused: true,
  uploadPaused: true,
  downloadPaused: true,
  editorInputCommitted: true,
  autosaveFlushed: true,
);

QualifiedSourceProfile get _linuxProfile => qualifiedSourceProfiles
    .singleWhere((p) => p.runtime.platform == Platform.operatingSystem);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixtures = <CaptureFixture>[];
  final opened = <PowerSyncDatabase>[];
  final scratch = <Directory>[];

  Future<Directory> tempDir(String name) async {
    final d = await Directory.systemTemp.createTemp(name);
    scratch.add(d);
    return d;
  }

  Future<(CaptureFixture, PowerSyncDatabase, QualifiedProfile)> source({
    bool queue = true,
  }) async {
    final f = await CaptureFixture.create(queue: queue);
    fixtures.add(f);
    final database = await f.openNormally();
    opened.add(database);
    final profile =
        await qualifyCaptureProfile(database, _linuxProfile.runtime);
    return (f, database, profile);
  }

  RawPreservation preservationFor(CaptureFixture f) => RawPreservation(
        Directory(p.join(f.dir.path, 'capture', 'preparation')),
        base: f.dir,
      );

  Future<CapturePayload> read(
    CaptureFixture f,
    PowerSyncDatabase database,
    QualifiedProfile profile, {
    StartupInventory inventory = const StartupInventory([]),
    List<RawReplacement> replacements = const [],
    Future<Map<String, Object>> Function()? preferences,
    Set<String> reviewed = const {},
    Future<void> Function()? onSnapshotOpened,
  }) =>
      readCapturePayload(
        database,
        _hold,
        profile,
        inventory,
        source: f.dir,
        preservation: preservationFor(f),
        replacements: replacements,
        readPreferences: preferences,
        reviewedUnknownPreferences: reviewed,
        onSnapshotOpened: onSnapshotOpened,
      );

  Future<SealedCapture> seal(CapturePayload payload) async {
    final staging = await tempDir('reps-capture-staging');
    final manifest = captureManifestFor(
      payload,
      capturedAt: DateTime.utc(2026, 10, 10, 8, 30),
      boundary: _allAttested,
    );
    return writeAndVerifyCapture(staging, payload, manifest);
  }

  /// Every file under [dir] (recursively) and its SHA-256.
  Map<String, String> tree(Directory dir) => {
        for (final f in dir.listSync(recursive: true).whereType<File>())
          p.relative(f.path, from: dir.path):
              sha256.convert(f.readAsBytesSync()).toString(),
      };

  tearDown(() async {
    for (final d in opened) {
      await d.close();
    }
    opened.clear();
    for (final f in fixtures) {
      await f.dispose();
    }
    fixtures.clear();
    for (final d in scratch) {
      if (await d.exists()) await d.delete(recursive: true);
    }
    scratch.clear();
  });

  test('tables_queue_and_bookkeeping_share_snapshot', () async {
    final (f, database, profile) = await source();
    final before = await f.snapshot();

    // A write that commits while the reader's transaction is open: a new
    // session, its queue entry and the advanced sequence must all be
    // invisible to that read, or all visible to a later one.
    // A second connection to the same file stands in for another writer.
    final writer = await f.openNormally();
    opened.add(writer);
    var concurrentWriteCommitted = false;
    final payload = await read(f, database, profile, onSnapshotOpened: () async {
      await writer.execute(
        'INSERT INTO sessions (id, user_id, date, split_label) '
        'VALUES (?, ?, ?, ?)',
        ['s-concurrent', fixtureUserId, '2026-10-04', 'Late'],
      );
      concurrentWriteCommitted = true;
    });
    expect(concurrentWriteCommitted, isTrue);

    expect(payload.sql.status, CaptureStatus.captured);
    expect(payload.sql.tables.keys.toList(), captureTables);
    for (final table in captureTables) {
      final ids = [for (final r in payload.sql.tables[table]!) r['id']! as String];
      expect(ids, [...ids]..sort(), reason: '$table rows are ordered by id');
      expect(
        ids,
        [for (final r in before.rawRows[table]!) (jsonDecode(r) as List).first],
        reason: '$table holds exactly the snapshot rows',
      );
    }
    // Raw values, owner, template and derived columns are kept as stored.
    final legacy = payload.sql.tables['exercises']!
        .singleWhere((r) => r['id'] == 'own-ex-legacy');
    expect(legacy['is_template'], isNull);
    expect(legacy['base_weight_kg'], '');
    final set = payload.sql.tables['sets']!.singleWhere((r) => r['id'] == 'set-1-2');
    expect(set['weight_kg'], '80');
    expect(set['is_top_set'], 0);
    expect(set['user_id'], fixtureUserId);
    expect(payload.sql.tables['sessions']!.map((r) => r['id']),
        isNot(contains('s-concurrent')));

    expect(payload.queue.status, CaptureStatus.captured);
    expect(payload.queue.entries.map((e) => e.clientId).toList(),
        [for (final r in before.queueText) (jsonDecode(r) as List)[0]]);
    expect(payload.queue.crudSequence,
        (jsonDecode(before.crudSequence.single) as List).single.toString());
    expect(payload.queue.localTargetOp,
        (jsonDecode(before.localTargetOp.single) as List).single);
    expect(payload.queue.coverage,
        {'crud_sequence': 'observed', 'local_target_op': 'observed'});

    // A later read sees the write in all three places at once.
    final after = await read(f, database, profile);
    expect(after.sql.tables['sessions']!.map((r) => r['id']),
        contains('s-concurrent'));
    expect(after.queue.entries, hasLength(payload.queue.entries.length + 1));
    expect(int.parse(after.queue.crudSequence!),
        int.parse(payload.queue.crudSequence!) + 1);

    // Reading changed nothing in the source.
    final unchanged = await f.snapshot();
    expect(unchanged.sourceFileDigests, before.sourceFileDigests);

    // An empty, never-written queue: explicit empty entries and no observed
    // bookkeeping rows, which is coverage, not a failure.
    final (g, emptyDb, emptyProfile) = await source(queue: false);
    final empty = await read(g, emptyDb, emptyProfile);
    expect(empty.queue.status, CaptureStatus.captured);
    expect(empty.queue.entries, isEmpty);
    expect(empty.queue.crudSequence, isNull);
    expect(empty.queue.localTargetOp, isNull);
    expect(empty.queue.coverage,
        {'crud_sequence': 'no_row', 'local_target_op': 'no_row'});

    // Inaccessible bookkeeping is a failed extraction, never zero/absent.
    final (h, brokenDb, _) = await source();
    await brokenDb.execute('ALTER TABLE ps_buckets RENAME TO ps_buckets_moved');
    final observed = await observeCaptureDatabase(brokenDb);
    final brokenProfile = QualifiedProfile.forTesting(
      runtime: CaptureRuntime(
        appVersion: _linuxProfile.runtime.appVersion,
        platform: _linuxProfile.runtime.platform,
        sdkVersion: _linuxProfile.runtime.sdkVersion,
        coreVersion: observed.coreVersion,
        schemaFingerprint: observed.schema.value,
        producerRevision: captureProducerRevision,
      ),
      profileId: 'test-moved-buckets',
      evidenceDigest: 'f' * 64,
    );
    final broken = await read(h, brokenDb, brokenProfile);
    expect(broken.sql.status, CaptureStatus.captured);
    expect(broken.queue.status, CaptureStatus.inspectionFailed);
    expect(broken.queue.detail, 'bookkeeping_unreadable');
    expect(broken.queue.entries, isEmpty);
    expect(broken.queue.crudSequence, isNull);
    expect(broken.blockers, contains('upload_queue_inspection_failed'));

    // A stored key no view column exposes (a server column this schema
    // lacks) stays in the row with its exact value, reported unavailable.
    await database.execute(
        "UPDATE ps_data__muscle_targets SET data = json_set(data, "
        "'\$.server_note', 'kept', '\$.server_rank', 9007199254740993) "
        "WHERE id = 'synced-mt-chest'");
    final extra = await read(f, database, profile);
    final chest = extra.sql.tables['muscle_targets']!
        .singleWhere((r) => r['id'] == 'synced-mt-chest');
    expect(chest['server_note'], 'kept');
    expect(chest['server_rank'], 9007199254740993);
    expect(chest['target_sets'], 12);
    expect(extra.sql.unknownColumns,
        {'muscle_targets': ['server_note', 'server_rank']});
    expect((extra.evidence['sql']! as Map)['unknown_columns'], {
      'muscle_targets': {
        'count': 2,
        'names': ['server_note', 'server_rank'],
      },
    });
    // One whose name collides with a column under case folding, or whose
    // value is structured, cannot be represented exactly: unsupported.
    await database.execute(
        "UPDATE ps_data__muscle_targets SET data = json_set(data, "
        "'\$.Muscle', 'x') WHERE id = 'synced-mt-chest'");
    final collided = await read(f, database, profile);
    expect(collided.sql.status, CaptureStatus.unsupported);
    expect(collided.sql.detail, 'column_case_collision');
    await database.execute(
        "UPDATE ps_data__muscle_targets SET data = json_set(json_remove(data, "
        "'\$.Muscle'), '\$.server_meta', json('{\"a\":1}')) "
        "WHERE id = 'synced-mt-chest'");
    final structured = await read(f, database, profile);
    expect(structured.sql.status, CaptureStatus.unsupported);
    expect(structured.sql.detail, 'unknown_column_structured');
    expect(structured.blockers, contains('sql_snapshot_unsupported'));

    // An unknown table is layout drift: nothing is read from the database.
    await database.execute('CREATE TABLE unexpected_store (x TEXT)');
    final drifted = await read(f, database, profile);
    expect(drifted.sql.status, CaptureStatus.unsupported);
    expect(drifted.sql.detail, 'schema_unqualified');
    expect(drifted.sql.tables, isEmpty);
    expect(drifted.queue.status, CaptureStatus.unsupported);
    expect(drifted.queue.entries, isEmpty);
    expect(drifted.blockers,
        containsAll(['sql_snapshot_unsupported', 'upload_queue_unsupported']));
  });

  test('queue_text_and_large_ids_unchanged', () async {
    final (f, database, profile) = await source();
    // Original text with whitespace, unknown fields and a newline, under an
    // id beyond 2^53 that a double cannot represent.
    const originalCrudText = '{ "op":"PATCH", "type":"sets",\n'
        '  "id":"set-1-2", "data":{"rir":null, "reps":6},'
        ' "metadata":"m-1", "future_field" : [1, 2.50] }';
    await database.execute(
      'INSERT INTO ps_crud (id, tx_id, data) VALUES (?, ?, ?)',
      [9007199254740993, 9007199254740995, originalCrudText],
    );
    final before = await f.snapshot();

    final payload = await read(f, database, profile);
    expect(payload.queue.status, CaptureStatus.captured);
    final raw = [for (final r in before.queueText) jsonDecode(r) as List];
    expect(payload.queue.entries.map((e) => [e.clientId, e.txId, e.data]),
        raw, reason: 'every ps_crud row, id/tx_id/data as stored');
    final last = payload.queue.entries.last;
    expect(last.clientId, 9007199254740993);
    expect(last.data, originalCrudText);
    expect(payload.queue.crudSequence, '9007199254740993');

    // Transaction boundaries are contiguous runs; the queued delete of an
    // absent row is kept.
    final runs = <int?>[];
    for (final e in payload.queue.entries) {
      if (runs.isEmpty || runs.last != e.txId) runs.add(e.txId);
    }
    expect(runs.toSet(), hasLength(runs.length));
    expect(runs.length, greaterThan(2));
    final delete = payload.queue.entries.singleWhere((e) =>
        (jsonDecode(e.data!) as Map)['op'] == 'DELETE' &&
        (jsonDecode(e.data!) as Map)['id'] == 'bw-2');
    expect(delete.txId, isNotNull);
    expect(payload.sql.tables['bodyweight_logs']!.map((r) => r['id']),
        isNot(contains('bw-2')));

    // The produced bytes carry the integer literally and the text unchanged.
    final sealed = await seal(payload);
    final queueBytes = File(p.join(sealed.directory.path, 'stores',
            'upload_queue.json'))
        .readAsStringSync();
    expect(queueBytes, contains('"client_id":9007199254740993'));
    expect(queueBytes, contains('"tx_id":9007199254740995'));
    expect(queueBytes, contains('"crud_sequence":9007199254740993'));
    final queueEntry =
        ((jsonDecode(queueBytes) as Map)['entries'] as List).last as Map;
    expect(queueEntry['client_id'], 9007199254740993);
    expect(queueEntry['data'], originalCrudText);
    final manifest = jsonDecode(File(p.join(sealed.directory.path,
            'manifest.json'))
        .readAsStringSync()) as Map<String, Object?>;
    expect((manifest['counts']! as Map)['queue_entries'],
        payload.queue.entries.length);

    // The reader never goes through the SDK's upload-queue reconstructions.
    final readerSource =
        File('lib/capture/capture_reader.dart').readAsStringSync();
    for (final banned in [
      'CrudEntry',
      'CrudTransaction',
      'getCrudBatch',
      'getNextCrudTransaction',
      'pendingUploadCount',
      'getUploadQueueStats',
    ]) {
      expect(readerSource, isNot(contains(banned)), reason: banned);
    }

    // An id the v1 reader cannot parse (over 18 characters) is reported
    // unsupported instead of producing a capture it would reject.
    await database.execute(
      'INSERT INTO ps_crud (id, tx_id, data) VALUES (?, ?, ?)',
      [1000000000000000000, 9007199254740996, originalCrudText],
    );
    final beyond = await read(f, database, profile);
    expect(beyond.queue.status, CaptureStatus.unsupported);
    expect(beyond.queue.detail, 'queue_id_beyond_reader');
    expect(beyond.queue.entries, isEmpty);
  });

  test('malformed_files_are_raw_roles', () async {
    final (f, database, profile) = await source();
    final preservation = preservationFor(f);
    // A malformed finished snapshot preserved at startup that has since been
    // overwritten, and the draft's bytes from before the capture's flush.
    final startupFinished = utf8.encode('{"sessionId":"s-0","finishedAt":');
    final preFlush = utf8.encode('{"pre":"flush"');
    for (final bytes in [startupFinished, preFlush]) {
      final blob = preservation.blobFile(sha256.convert(bytes).toString());
      await blob.parent.create(recursive: true);
      await blob.writeAsBytes(bytes, flush: true);
    }
    final preFlushDir = await tempDir('reps-preflush');
    final preFlushFile = File(p.join(preFlushDir.path, 'workout-draft.json'))
      ..writeAsBytesSync(preFlush);
    final draftFile = File(p.join(f.dir.path, 'workout-draft.json'));
    final replacement = RawReplacement(
      role: 'draft',
      before: await readRawFile(preFlushFile),
      temporaryBefore: null,
      after: await readRawFile(draftFile),
    );
    final inventory = StartupInventory([
      InventoryEntry(
        role: 'finished',
        name: 'workout-last-finished.json',
        authoritative: true,
        status: RawFileStatus.captured,
        length: startupFinished.length,
        sha256: sha256.convert(startupFinished).toString(),
        preserved: true,
        reason: 'malformed',
      ),
    ]);
    final before = await f.snapshot();

    final payload = await read(f, database, profile,
        inventory: inventory, replacements: [replacement]);

    // Authoritative bytes under their roles, byte for byte, never decoded.
    expect(payload.draft.status, CaptureStatus.captured);
    expect(payload.draft.bytes, fixtureRawFiles['workout-draft.json']);
    expect(payload.lastFinished.status, CaptureStatus.captured);
    expect(payload.lastFinished.bytes,
        fixtureRawFiles['workout-last-finished.json']);
    // Orphan .tmp, pre-flush and earlier startup versions are opaque.
    final opaque = {for (final o in payload.opaque) o.name: o};
    expect(opaque['active_draft_tmp']!.bytes,
        fixtureRawFiles['workout-draft.json.tmp']);
    expect(opaque['active_draft_pre_flush']!.bytes, preFlush);
    final startupName =
        'last_finished_preserved_${sha256.convert(startupFinished).toString().substring(0, 12)}';
    expect(opaque[startupName]!.bytes, startupFinished);
    expect(opaque.keys, isNot(contains('capture_evidence')),
        reason: 'evidence is written by the artifact writer');
    // The replacement relation is evidence, not a rewrite.
    final replacements = payload.evidence['replacements']! as List;
    expect(replacements.single,
        containsPair('relation', 'replaced_by'));
    expect(payload.blockers, isEmpty);

    // Credentials, caches and replica bookkeeping are declared, not copied.
    expect(
      {for (final e in payload.exclusions) e.name: e.reason},
      {
        'secure_storage': 'credentials',
        'sqlite_database': 'replica_bookkeeping',
        'sqlite_wal': 'replica_bookkeeping',
        'sqlite_shm': 'replica_bookkeeping',
      },
    );

    // Nothing in the source was decoded, deleted, renamed or promoted.
    final after = await f.snapshot();
    expect(after.sourceFileDigests, before.sourceFileDigests);
    expect(after.fileNames, before.fileNames);
    expect(after.sqliteFileDigests.keys, before.sqliteFileDigests.keys);

    // A draft rewritten after the flush cannot be attested.
    draftFile.writeAsStringSync('{"changed":true}');
    final changed = await read(f, database, profile,
        inventory: inventory, replacements: [replacement]);
    expect(changed.blockers, contains('active_draft_changed_after_flush'));
    draftFile.writeAsBytesSync(fixtureRawFiles['workout-draft.json']!);

    // Verified absence only; a link is never followed.
    File(p.join(f.dir.path, 'workout-last-finished.json')).deleteSync();
    final target = File(p.join(preFlushDir.path, 'elsewhere.json'))
      ..writeAsStringSync('{}');
    draftFile.deleteSync();
    Link(draftFile.path).createSync(target.path);
    final linked = await read(f, database, profile);
    expect(linked.lastFinished.status, CaptureStatus.absent);
    expect(linked.lastFinished.bytes, isNull);
    expect(linked.draft.status, CaptureStatus.unsupported);
    expect(linked.draft.bytes, isNull);
    expect(linked.blockers, contains('active_draft_unsupported'));
    expect(target.readAsStringSync(), '{}');
  });

  test('typed_safe_unknown_preferences_preserved', () async {
    final (f, database, profile) = await source();
    SharedPreferences.setMockInitialValues({
      'unit': 'lb',
      'accent': 4283215696,
      'settings.rest_compound_seconds': 150,
      'identity.onboarding_complete': false,
      'identity.current_user_id': '00000000-0000-4000-8000-000000000001',
      'absorb.template_ids': ['c-id', 'a-id', 'b-id'],
      'server_url': 'https://reps.example.invalid:8443/base',
      'settings.sync_enabled': false,
      'rest.total': 90,
      'legacy.ratio': 2.0,
    });

    final payload = await read(f, database, profile,
        reviewed: {'legacy.ratio'});

    expect(payload.preferences.status, CaptureStatus.captured);
    expect(
      [
        for (final e in payload.preferences.entries) [e.key, e.type, e.value],
      ],
      [
        ['absorb.template_ids', 'string_list', ['c-id', 'a-id', 'b-id']],
        ['accent', 'int', 4283215696],
        ['identity.current_user_id', 'string',
          '00000000-0000-4000-8000-000000000001'],
        ['identity.onboarding_complete', 'bool', false],
        ['legacy.ratio', 'double', 2.0],
        ['rest.total', 'int', 90],
        ['server_url', 'string', 'https://reps.example.invalid:8443/base'],
        ['settings.rest_compound_seconds', 'int', 150],
        ['settings.sync_enabled', 'bool', false],
        ['unit', 'string', 'lb'],
      ],
      reason: 'stored entries only, no displayed defaults, prefix removed',
    );
    expect(payload.preferences.entries.firstWhere((e) => e.key == 'legacy.ratio').value,
        isA<double>());
    expect(payload.preferences.dispositions, {
      'absorb.template_ids': 'local_identity',
      'accent': 'device_preference',
      'identity.current_user_id': 'local_identity',
      'identity.onboarding_complete': 'local_identity',
      'legacy.ratio': 'reviewed_unknown',
      'rest.total': 'volatile_runtime',
      'server_url': 'installation_wiring',
      'settings.rest_compound_seconds': 'data_setting',
      'settings.sync_enabled': 'installation_wiring',
      'unit': 'data_setting',
    });
    expect(payload.blockers, isEmpty);

    final sealed = await seal(payload);
    final text = File(p.join(sealed.directory.path, 'stores',
            'preferences.json'))
        .readAsStringSync();
    expect(text, contains('{"key":"legacy.ratio","type":"double","value":2.0}'));
    expect(text,
        contains('"value":["c-id","a-id","b-id"]'));
    expect(text, isNot(contains('flutter.')));
  });

  test('unsafe_unknown_or_url_blocks', () async {
    final (f, database, profile) = await source();
    const token = 'synthetic-token-value-123';
    Future<CapturePayload> withPrefs(Map<String, Object> raw,
        {Set<String> reviewed = const {}}) {
      final store = InMemorySharedPreferencesStore.withData(raw);
      return read(f, database, profile,
          reviewed: reviewed,
          preferences: () => store.getAllWithParameters(
              GetAllParameters(filter: PreferencesFilter(prefix: ''))));
    }

    Future<void> expectBlocked(Map<String, Object> raw, String code,
        {Set<String> reviewed = const {}}) async {
      final copy = Map.of(raw);
      final payload = await withPrefs(raw, reviewed: reviewed);
      expect(payload.preferences.status, CaptureStatus.unsupported,
          reason: code);
      expect(payload.preferences.detail, contains(code));
      expect(payload.preferences.entries, isEmpty,
          reason: 'never a silently redacted store');
      expect(payload.blockers, contains('preferences_$code'));
      expect(raw, copy, reason: 'the source is not touched');
      // Nothing secret reaches the artifact, not even the evidence.
      final sealed = await seal(payload);
      expect(sealed.usable, isFalse);
      for (final file in sealed.directory
          .listSync(recursive: true)
          .whereType<File>()) {
        final bytes = file.readAsStringSync();
        expect(bytes, isNot(contains(token)), reason: file.path);
        expect(bytes, isNot(contains('secret-pw')), reason: file.path);
      }
      final manifest = jsonDecode(File(p.join(sealed.directory.path,
              'manifest.json'))
          .readAsStringSync()) as Map;
      final prefs = (manifest['stores'] as List)
          .cast<Map>()
          .singleWhere((s) => s['role'] == 'preferences');
      expect(prefs['status'], 'unsupported');
      expect(prefs.containsKey('path'), isFalse);
    }

    for (final key in ['access_token', 'refresh_token', 'email']) {
      await expectBlocked(
          {'flutter.unit': 'kg', 'flutter.$key': token}, 'credential_key');
    }
    for (final url in [
      'https://user:secret-pw@reps.example.invalid',
      'https://reps.example.invalid/?token=$token',
      'https://reps.example.invalid/#$token',
      'reps.example.invalid',
      'ftp://reps.example.invalid',
    ]) {
      await expectBlocked({'flutter.server_url': url},
          'credential_bearing_server_url');
    }
    await expectBlocked({'flutter.other.thing': token}, 'unknown_key');
    await expectBlocked({'foreign_plugin_key': token}, 'unprefixed_key');
    await expectBlocked({'flutter.unit': double.infinity}, 'unsupported_value');
    await expectBlocked(
        {'flutter.accent': 1000000000000000000}, 'unsupported_value');
    await expectBlocked({'flutter.absorb.template_ids': <Object>['a', 1]},
        'unsupported_value');

    // The same unknown key passes once it has an explicit safe disposition.
    final reviewed = await withPrefs({'flutter.other.thing': 'x'},
        reviewed: {'other.thing'});
    expect(reviewed.preferences.status, CaptureStatus.captured);
    expect(reviewed.preferences.entries.single.key, 'other.thing');
    // A reviewed disposition never admits a credential key.
    final credential = await withPrefs({'flutter.email': token},
        reviewed: {'email'});
    expect(credential.preferences.status, CaptureStatus.unsupported);

    // An unknown file beside the stores has no disposition: blocked, and
    // left where it is.
    final stray = File(p.join(f.dir.path, 'notes.txt'))..writeAsStringSync(token);
    final strayPayload = await withPrefs({'flutter.unit': 'kg'});
    expect(strayPayload.blockers, contains('unknown_source_entry'));
    expect(jsonEncode(strayPayload.evidence), isNot(contains('notes.txt')));
    expect(stray.readAsStringSync(), token);
    final sealed = await seal(strayPayload);
    expect(sealed.usable, isFalse);
    expect(tree(sealed.directory).keys, isNot(contains('stores/notes.txt')));
  });

  test('sync_history_needs_positive_evidence', () async {
    final (f, database, profile) = await source();
    SharedPreferences.setMockInitialValues({'unit': 'kg'});
    final legacy = await read(f, database, profile);
    expect(legacy.syncHistory, 'unknown',
        reason: 'an empty or disabled sync is not never_connected');
    SharedPreferences.setMockInitialValues(
        {'sync.last_synced_at_ms': 1760000000000});
    final synced = await read(f, database, profile);
    expect(synced.syncHistory, 'connected');
    expect(synced.evidence['sync_history'],
        {'value': 'connected', 'evidence': ['last_synced_preference']});
  });
}
