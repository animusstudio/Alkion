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
    // Raw stored literals, owner, template and derived columns are kept.
    final legacy = payload.sql.tables['exercises']!
        .singleWhere((r) => r['id'] == 'own-ex-legacy');
    expect(legacy['is_template'], JsonLiteral('null'));
    expect(legacy['base_weight_kg'], JsonLiteral('""'));
    final set = payload.sql.tables['sets']!.singleWhere((r) => r['id'] == 'set-1-2');
    expect(set['weight_kg'], JsonLiteral('"80"'));
    expect(set['is_top_set'], JsonLiteral('0'));
    expect(set['user_id'], JsonLiteral('"$fixtureUserId"'));
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
    expect(chest['server_note'], JsonLiteral('"kept"'));
    expect(chest['server_rank'], JsonLiteral('9007199254740993'));
    expect(chest['target_sets'], JsonLiteral('12'));
    expect(extra.sql.unknownColumns,
        {'muscle_targets': ['server_note', 'server_rank']});
    expect((extra.evidence['sql']! as Map)['unknown_columns'], {
      'muscle_targets': {
        'count': 2,
        'names': ['server_note', 'server_rank'],
      },
    });
    // One whose name collides with a column under case folding cannot be
    // represented in one v1 row: unsupported.
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
    // A structured stored value is kept as its exact JSON text.
    final structured = await read(f, database, profile);
    expect(structured.sql.status, CaptureStatus.captured);
    expect(
        structured.sql.tables['muscle_targets']!
            .singleWhere((r) => r['id'] == 'synced-mt-chest')['server_meta'],
        JsonLiteral('{"a":1}'));

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

    // An id the v1 reader cannot parse (over 18 characters) is copied but
    // blocks a usable capture, which the reader would reject.
    await database.execute(
      'INSERT INTO ps_crud (id, tx_id, data) VALUES (?, ?, ?)',
      [1000000000000000000, 9007199254740996, originalCrudText],
    );
    final beyond = await read(f, database, profile);
    expect(beyond.queue.status, CaptureStatus.captured);
    expect(beyond.queue.entries.last.clientId, 1000000000000000000);
    expect(beyond.blockers, contains('upload_queue_id_beyond_reader'));
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
        'notification_plugin_cache': 'volatile_runtime',
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
  test('stored_literals_are_copied_exactly', () async {
    final (f, database, profile) = await source();
    // Stored row text as a server could have synced it: an integer column
    // holding text, a weight written as a number with its trailing zero, an
    // unknown member with an exponent, digits beyond 64 bits and a
    // structure; `updated_at` is missing.
    const stored = '{"session_id":"s-1","exercise_id":"tpl-ex-bench",'
        '"user_id":"synthetic-user-1","set_number":2,"weight_kg":62.50,'
        '"reps":"abc","rir":2,"is_warmup":0,"is_top_set":0,"is_pr":0,'
        '"created_at":"2026-10-01T10:30:00.000Z","server_score":62.50,'
        '"server_exp":1E+2,'
        '"server_big":123456789012345678901234567890,'
        '"server_text":"caf\\u00e9 \\"q\\"","server_meta":{"a":[1,2.0]}}';
    await database.execute(
        "UPDATE ps_data__sets SET data = ? WHERE id = 'set-1-2'", [stored]);
    await database.execute(
        "UPDATE ps_data__sets SET data = json_set(data, '\$.reps', '8') "
        "WHERE id = 'set-1-3'");

    // What the app's view reads: coerced by its CASTs.
    final viaView = await database.get(
        "SELECT reps, weight_kg FROM sets WHERE id = 'set-1-2'");
    expect(viaView['reps'], 0);
    expect(viaView['weight_kg'], '62.5');

    final payload = await read(f, database, profile);
    expect(payload.sql.status, CaptureStatus.captured);
    final rows = payload.sql.tables['sets']!;
    final row = rows.singleWhere((r) => r['id'] == 'set-1-2');
    expect(row.keys.toList(), [
      'id', 'session_id', 'exercise_id', 'user_id', 'set_number',
      'weight_kg', 'reps', 'rir', 'is_warmup', 'is_top_set', 'is_pr',
      'created_at', 'server_score', 'server_exp', 'server_big',
      'server_text', 'server_meta',
    ], reason: 'row id, then stored members in stored order; nothing added');
    expect(row['weight_kg'], JsonLiteral('62.50'));
    expect(row['reps'], JsonLiteral('"abc"'));
    expect(row['server_score'], JsonLiteral('62.50'));
    expect(row['server_exp'], JsonLiteral('1E+2'));
    expect(row['server_big'],
        JsonLiteral('123456789012345678901234567890'));
    expect(row['server_text'], JsonLiteral(r'"caf\u00e9 \"q\""'));
    expect(row['server_meta'], JsonLiteral('{"a":[1,2.0]}'));
    expect(row.containsKey('updated_at'), isFalse,
        reason: 'a missing member is not fabricated as null');
    expect(rows.singleWhere((r) => r['id'] == 'set-1-3')['reps'],
        JsonLiteral('"8"'));
    expect(payload.sql.absentColumns['sets']!['updated_at'], greaterThan(0));
    expect(payload.sql.unknownColumns['sets'], [
      'server_big', 'server_exp', 'server_meta', 'server_score', 'server_text',
    ]);
    expect((payload.evidence['sql']! as Map)['absent_view_columns'],
        payload.sql.absentColumns);

    // The written store carries the same literal text, byte for byte.
    final sealed = await seal(payload);
    final sql = File(p.join(sealed.directory.path, 'stores', 'sql.json'))
        .readAsStringSync();
    for (final literal in [
      '"weight_kg":62.50',
      '"reps":"abc"',
      '"server_exp":1E+2',
      '"server_big":123456789012345678901234567890',
      r'"server_text":"caf\u00e9 \"q\""',
      '"server_meta":{"a":[1,2.0]}',
      '"reps":"8"',
    ]) {
      expect(sql, contains(literal));
    }
    expect(sql, contains('{"id":"set-1-2","session_id":"s-1",'));

    // Stored text that cannot be reproduced exactly: unsupported, no rows.
    // (muscle_targets has no JSON index that would refuse malformed text.)
    for (final (text, code) in [
      ('{"reps":', 'stored_data_invalid'),
      ('[1,2]', 'stored_data_invalid'),
      ('{"reps":1,"reps":2}', 'stored_duplicate_key'),
      ('{"reps":1,"Reps":2}', 'column_case_collision'),
      ('{"meta":{"a":1,"A":2}}', 'stored_duplicate_key'),
      ('{"id":"other"}', 'stored_id_key'),
    ]) {
      await database.execute(
          "UPDATE ps_data__muscle_targets SET data = ? "
          "WHERE id = 'synced-mt-chest'", [text]);
      final refused = await read(f, database, profile);
      expect(refused.sql.status, CaptureStatus.unsupported, reason: text);
      expect(refused.sql.detail, code, reason: text);
      expect(refused.sql.tables, isEmpty);
      expect(refused.blockers, contains('sql_snapshot_unsupported'));
    }
  });

  test('queue_entries_the_reader_refuses_block', () async {
    Future<CapturePayload> withQueue(List<(int, int?, String?)> rows) async {
      final (f, database, profile) = await source(queue: false);
      for (final (id, tx, data) in rows) {
        await database.execute(
            'INSERT INTO ps_crud (id, tx_id, data) VALUES (?, ?, ?)',
            [id, tx, data]);
      }
      return read(f, database, profile);
    }

    const ok = '{"op":"DELETE","type":"sets","id":"x"}';
    final clean = await withQueue([(1, 1, ok), (2, 1, ok), (3, 2, ok)]);
    expect(queueEntryBlockers(clean.queue.entries), isEmpty);
    expect(clean.blockers, isEmpty);

    for (final (rows, code) in [
      ([(1, null, ok)], 'upload_queue_tx_id_missing'),
      ([(1, 1, null)], 'upload_queue_data_missing'),
      ([(-1, 1, ok)], 'upload_queue_order_invalid'),
      ([(1, 1, ok), (2, 2, ok), (3, 1, ok)], 'upload_queue_tx_not_contiguous'),
      ([(1, 1000000000000000000, ok)], 'upload_queue_id_beyond_reader'),
    ]) {
      final payload = await withQueue(rows);
      expect(payload.queue.status, CaptureStatus.captured, reason: code);
      expect(payload.queue.entries, hasLength(rows.length),
          reason: 'copied exactly');
      expect(payload.blockers, contains(code));
      final sealed = await seal(payload);
      expect(sealed.usable, isFalse, reason: code);
      expect(sealed.blockers, contains(code));
    }
    // Data stored as a blob is not the ps_crud text: refused while reading.
    final blob = await withQueue([(1, 1, null)]);
    expect(blob.queue.status, CaptureStatus.captured);
    final (g, database, profile) = await source(queue: false);
    await database.execute(
        "INSERT INTO ps_crud (id, tx_id, data) VALUES (1, 1, X'7b7d')");
    final number = await read(g, database, profile);
    expect(number.queue.status, CaptureStatus.unsupported);
    expect(number.queue.detail, 'queue_data_not_text');
    expect(number.blockers, contains('upload_queue_unsupported'));
  });
}
