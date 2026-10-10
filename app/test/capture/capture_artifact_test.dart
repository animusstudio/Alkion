// Host tests for the v1 capture artifact: bounded store files, the exact
// manifest written last, and strict re-verification from disk. Every value is
// synthetic.
//
// `rehearsal_accepts_produced_capture` runs the Hub's pinned Go rehearsal over
// a capture produced from a real PowerSync database. It needs a built
// rehearsal binary in REPS_REHEARSAL_BIN (see `make -C app capture-go-compat`)
// and is skipped without one.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workout_tracker/capture/capture_artifact.dart';
import 'package:workout_tracker/capture/capture_manifest.dart';
import 'package:workout_tracker/capture/capture_profile.dart';
import 'package:workout_tracker/capture/capture_reader.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';
import 'package:workout_tracker/capture/startup_inventory.dart';
import 'package:workout_tracker/sync/schema.dart';

const _captureId = '9c000000-0000-4000-8000-0000000000b2';

const _allAttested = CaptureBoundary(
  sqlSnapshot: 'single_read_transaction',
  mutationPaused: true,
  uploadPaused: true,
  downloadPaused: true,
  editorInputCommitted: true,
  autosaveFlushed: true,
);

CapturePayload synthetic({
  RawStoreCapture? draft,
  List<CaptureExclusion>? exclusions,
}) =>
    CapturePayload(
      captureId: _captureId,
      generation: 3,
      appVersion: '0.18.1+37',
      platform: 'linux',
      syncHistory: 'unknown',
      sql: SqlStoreCapture.captured({
        for (final t in captureTables) t: const <Map<String, Object?>>[],
      }..['sessions'] = [
          {
            'id': 'd1000000-0000-4000-8000-000000000001',
            'date': '2026-10-01',
            'duration_min': -3,
            'notes': null,
            'user_id': null,
          },
        ]),
      queue: QueueStoreCapture.captured(
        [
          const QueueEntryCapture(
            clientId: 9007199254740993,
            txId: 1,
            data: '{"op":"DELETE","type":"sets",'
                '"id":"e1000000-0000-4000-8000-0000000000ff"}',
          ),
        ],
        crudSequence: '9007199254740993',
        localTargetOp: '9223372036854775807',
        coverage: const {
          'crud_sequence': 'observed',
          'local_target_op': 'observed',
        },
      ),
      draft: draft ?? RawStoreCapture.captured(utf8.encode('{"broken"')),
      lastFinished: const RawStoreCapture.absent(),
      preferences: PreferencesCapture.captured(
        const [CapturePreference(key: 'unit', type: 'string', value: 'kg')],
        const {'unit': 'data_setting'},
      ),
      opaque: [
        OpaqueCapture(
          name: 'active_draft_tmp',
          format: 'raw/orphan-tmp',
          bytes: utf8.encode('{"half'),
        ),
      ],
      exclusions: exclusions ??
          const [
            CaptureExclusion('secure_storage', 'credentials'),
            CaptureExclusion('sqlite_wal', 'replica_bookkeeping'),
          ],
      evidence: const {'format': 'reps-capture-evidence', 'version': 1},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final scratch = <Directory>[];

  Future<Directory> tempDir(String name) async {
    final d = await Directory.systemTemp.createTemp(name);
    scratch.add(d);
    return d;
  }

  tearDown(() async {
    for (final d in scratch) {
      if (await d.exists()) await d.delete(recursive: true);
    }
    scratch.clear();
  });

  CaptureManifest manifestFor(CapturePayload payload,
          {CaptureBoundary boundary = _allAttested}) =>
      captureManifestFor(
        payload,
        capturedAt: DateTime.utc(2026, 10, 10, 8, 30, 5, 120),
        boundary: boundary,
      );

  Future<SealedCapture> seal(CapturePayload payload) async =>
      writeAndVerifyCapture(
          await tempDir('reps-capture-staging'), payload, manifestFor(payload));

  /// Every entry under [dir] (links not followed) with its SHA-256.
  Map<String, String> tree(Directory dir) => {
        for (final e in dir.listSync(recursive: true, followLinks: false))
          p.relative(e.path, from: dir.path): switch (e) {
            File f => sha256.convert(f.readAsBytesSync()).toString(),
            Link l => 'link:${l.targetSync()}',
            _ => 'dir',
          },
      };

  Future<Directory> copyOf(Directory source) async {
    final copy = await tempDir('reps-capture-copy');
    for (final e in source.listSync(recursive: true)) {
      final target = p.join(copy.path, p.relative(e.path, from: source.path));
      if (e is Directory) {
        Directory(target).createSync(recursive: true);
      } else if (e is File) {
        File(target).parent.createSync(recursive: true);
        e.copySync(target);
      }
    }
    return copy;
  }

  Matcher artifactError(String code) => throwsA(
      isA<CaptureArtifactException>().having((e) => e.code, 'code', code));

  test('strict_v1_integrity_and_limits', () async {
    final payload = synthetic();
    final sealed = await seal(payload);
    final dir = sealed.directory;
    final manifestBytes =
        File(p.join(dir.path, 'manifest.json')).readAsBytesSync();
    final manifest = jsonDecode(utf8.decode(manifestBytes)) as Map<String, Object?>;

    expect(manifest['format'], 'reps-migration-capture');
    expect(manifest['version'], 1);
    expect(manifest.keys.toSet(), {
      'format', 'version', 'capture_id', 'captured_at', 'source', 'boundary',
      'stores', 'counts',
    });
    expect(manifest['capture_id'], _captureId);
    expect(manifest['captured_at'], '2026-10-10T08:30:05.120Z');
    expect(manifest['source'], {
      'app_version': '0.18.1+37',
      'platform': 'linux',
      'sync_history': 'unknown',
    });
    expect(manifest['boundary'], {
      'sql_snapshot': 'single_read_transaction',
      'mutation_paused': true,
      'upload_paused': true,
      'download_paused': true,
      'editor_input_committed': true,
      'autosave_flushed': true,
    });
    expect(manifest['counts'], {
      for (final t in captureTables) t: t == 'sessions' ? 1 : 0,
      'queue_entries': 1,
    });
    final stores = (manifest['stores']! as List).cast<Map<String, Object?>>();
    expect({for (final s in stores) s['name']: s['role']}, {
      'sql': 'sql_snapshot',
      'upload_queue': 'upload_queue',
      'active_draft': 'active_draft',
      'last_finished': 'last_finished',
      'preferences': 'preferences',
      'active_draft_tmp': 'opaque',
      'capture_evidence': 'opaque',
      'secure_storage': 'excluded',
      'sqlite_wal': 'excluded',
    });
    expect(stores.singleWhere((s) => s['name'] == 'last_finished'), {
      'name': 'last_finished',
      'role': 'last_finished',
      'status': 'absent',
      'format': 'reps-finished-session/0.18',
    });
    expect(stores.singleWhere((s) => s['name'] == 'secure_storage'), {
      'name': 'secure_storage',
      'role': 'excluded',
      'status': 'excluded',
      'reason': 'credentials',
    });

    // The directory holds exactly the manifest and the declared files, each
    // matching its declared size and digest.
    final captured = stores.where((s) => s['status'] == 'captured').toList();
    expect(tree(dir).keys.where((k) => k != 'stores').toSet(),
        {'manifest.json', for (final s in captured) s['path']});
    for (final s in captured) {
      final bytes = File(p.join(dir.path, s['path']! as String)).readAsBytesSync();
      expect(bytes.length, s['bytes']);
      expect(sha256.convert(bytes).toString(), s['sha256']);
      expect(sealed.files[s['path']]!.sha256, s['sha256']);
    }
    expect(sealed.captureId, _captureId);
    expect(sealed.manifestSha256, sha256.convert(manifestBytes).toString());
    expect(sealed.usable, isTrue);
    expect(() => sealed.files['x'] = sealed.files['manifest.json']!,
        throwsUnsupportedError);
    final sqlText =
        File(p.join(dir.path, 'stores', 'sql.json')).readAsStringSync();
    expect(sqlText, contains('"duration_min":-3'));
    expect(jsonDecode(sqlText), {
      'tables': {
        for (final t in captureTables)
          t: t == 'sessions'
              ? [
                  {
                    'date': '2026-10-01',
                    'duration_min': -3,
                    'id': 'd1000000-0000-4000-8000-000000000001',
                    'notes': null,
                    'user_id': null,
                  },
                ]
              : [],
      },
    });
    final verified = await verifyCaptureDirectory(dir);
    expect(verified.manifestSha256, sealed.manifestSha256);

    // Exploratory attestations never make a usable capture.
    final exploratory = await writeAndVerifyCapture(
      await tempDir('reps-capture-staging'),
      payload,
      manifestFor(payload,
          boundary: const CaptureBoundary(
            sqlSnapshot: 'single_read_transaction',
            mutationPaused: true,
            uploadPaused: true,
            downloadPaused: false,
            editorInputCommitted: true,
            autosaveFlushed: true,
          )),
    );
    expect(exploratory.usable, isFalse);
    expect(exploratory.blockers, contains('boundary_not_attested'));

    // Limits: equality succeeds, one byte more fails.
    expect(acceptsManifestBytes(1048576), isTrue);
    expect(acceptsManifestBytes(1048577), false);
    expect(acceptsStoreBytes(67108864), isTrue);
    expect(acceptsStoreBytes(67108865), false);

    final atLimit = Uint8List(67108864)..fillRange(0, 16, 0x7b);
    final big = await seal(synthetic(draft: RawStoreCapture.captured(atLimit)));
    final bigDraft = File(p.join(big.directory.path, 'stores', 'active_draft.json'));
    expect(bigDraft.lengthSync(), 67108864);
    expect(big.usable, isTrue);

    final over = await seal(synthetic(
        draft: RawStoreCapture.captured(Uint8List(67108865))));
    final overManifest = jsonDecode(File(p.join(over.directory.path,
            'manifest.json'))
        .readAsStringSync()) as Map;
    expect(
      (overManifest['stores'] as List)
          .cast<Map>()
          .singleWhere((s) => s['name'] == 'active_draft'),
      {
        'name': 'active_draft',
        'role': 'active_draft',
        'status': 'unsupported',
        'format': 'reps-session-draft/0.18',
        'detail': 'store_oversized',
      },
    );
    expect(File(p.join(over.directory.path, 'stores', 'active_draft.json'))
        .existsSync(), isFalse, reason: 'never truncated or chunked');
    expect(over.usable, isFalse);
    expect(over.blockers, contains('active_draft_unsupported'));

    // A queue the v1 reader would refuse is written exactly but never usable.
    final refusedQueue = CapturePayload(
      captureId: _captureId,
      generation: 3,
      appVersion: '0.18.1+37',
      platform: 'linux',
      syncHistory: 'unknown',
      sql: payload.sql,
      queue: QueueStoreCapture.captured(
        const [
          QueueEntryCapture(clientId: 2, txId: null, data: null),
          QueueEntryCapture(clientId: 2, txId: 1, data: '{}'),
        ],
        coverage: const {'crud_sequence': 'no_row', 'local_target_op': 'no_row'},
      ),
      draft: payload.draft,
      lastFinished: payload.lastFinished,
      preferences: payload.preferences,
    );
    final refused = await seal(refusedQueue);
    expect(refused.usable, isFalse);
    expect(refused.blockers, containsAll([
      'upload_queue_data_missing',
      'upload_queue_order_invalid',
      'upload_queue_tx_id_missing',
    ]));

    // An oversized manifest is refused before anything is written.
    final crowded = synthetic(exclusions: [
      for (var i = 0; i < 20000; i++)
        CaptureExclusion('disposable_cache_entry_$i', 'disposable_cache'),
    ]);
    final crowdedStaging = await tempDir('reps-capture-staging');
    await expectLater(
        writeAndVerifyCapture(crowdedStaging, crowded, manifestFor(crowded)),
        artifactError('manifest_oversized'));
    expect(crowdedStaging.listSync(), isEmpty);

    // Staging must be a new, empty directory.
    await expectLater(writeAndVerifyCapture(dir, payload, manifestFor(payload)),
        artifactError('staging_not_empty'));
    // A manifest that does not describe this payload is refused.
    final other = synthetic(draft: RawStoreCapture.captured(utf8.encode('{}')));
    final mismatchStaging = await tempDir('reps-capture-staging');
    await expectLater(
        writeAndVerifyCapture(mismatchStaging, payload, manifestFor(other)),
        artifactError('manifest_mismatch'));
    expect(mismatchStaging.listSync(), isEmpty);

    // Strict verification from disk, never mutating what it inspects.
    Future<void> rejects(String code,
        void Function(Directory copy) tamper) async {
      final copy = await copyOf(dir);
      tamper(copy);
      final before = tree(copy);
      await expectLater(verifyCaptureDirectory(copy), artifactError(code));
      expect(tree(copy), before, reason: 'verification never mutates');
    }

    void editManifest(Directory copy,
        void Function(Map<String, Object?> manifest) edit) {
      final file = File(p.join(copy.path, 'manifest.json'));
      final m = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      edit(m);
      file.writeAsStringSync(jsonEncode(m));
    }

    List<Map<String, Object?>> storesOf(Map<String, Object?> m) =>
        (m['stores']! as List).cast<Map<String, Object?>>();

    await rejects('unlisted_file', (c) =>
        File(p.join(c.path, 'stores', 'extra.json')).writeAsStringSync('{}'));
    await rejects('unlisted_file', (c) =>
        File(p.join(c.path, 'stores', 'SQL.json')).writeAsStringSync('{}'));
    await rejects('not_regular', (c) {
      final outside = Directory.systemTemp.createTempSync('reps-outside');
      scratch.add(outside);
      final sql = File(p.join(c.path, 'stores', 'sql.json'));
      final moved = sql.copySync(p.join(outside.path, 'sql.json'));
      sql.deleteSync();
      Link(sql.path).createSync(moved.path);
    });
    await rejects('integrity_mismatch', (c) {
      final file = File(p.join(c.path, 'stores', 'upload_queue.json'));
      final bytes = file.readAsBytesSync();
      bytes[bytes.length - 2] ^= 0x01;
      file.writeAsBytesSync(bytes);
    });
    await rejects('store_missing', (c) =>
        File(p.join(c.path, 'stores', 'preferences.json')).deleteSync());
    await rejects('manifest_invalid',
        (c) => editManifest(c, (m) => m['cutover_ready'] = false));
    await rejects('manifest_invalid', (c) => editManifest(
        c, (m) => (m['boundary']! as Map)['global_writer_barrier'] = true));
    await rejects('manifest_invalid',
        (c) => editManifest(c, (m) => storesOf(m).first['owner'] = 'x'));
    await rejects('path_invalid', (c) => editManifest(c,
        (m) => storesOf(m).first['path'] = '../outside/sql.json'));
    await rejects('path_invalid', (c) => editManifest(
        c, (m) => storesOf(m).first['path'] = '/tmp/sql.json'));
    await rejects('path_invalid', (c) => editManifest(
        c, (m) => storesOf(m).first['path'] = 'manifest.json'));
    await rejects('duplicate_store', (c) => editManifest(c, (m) {
          final s = storesOf(m);
          s.add({...s.firstWhere((e) => e['name'] == 'secure_storage')});
        }));
    await rejects('duplicate_store', (c) => editManifest(c, (m) {
          final s = storesOf(m);
          s.add({...s.firstWhere((e) => e['name'] == 'secure_storage'),
            'name': 'Secure_Storage'});
        }));
    await rejects('case_collision', (c) => editManifest(c, (m) {
          final tmp = storesOf(m).firstWhere((e) => e['name'] == 'active_draft_tmp');
          tmp['path'] = 'stores/SQL.json';
          File(p.join(c.path, 'stores', 'active_draft_tmp.bin'))
              .renameSync(p.join(c.path, 'stores', 'SQL.json'));
        }));
    await rejects('duplicate_role', (c) => editManifest(c, (m) {
          final s = storesOf(m);
          s.add({...s.firstWhere((e) => e['name'] == 'last_finished'),
            'name': 'last_finished_2'});
        }));
    await rejects('store_missing', (c) => editManifest(c, (m) {
          storesOf(m).removeWhere((e) => e['role'] == 'last_finished');
        }));
    await rejects('manifest_invalid', (c) => editManifest(c, (m) {
          storesOf(m).firstWhere((e) => e['name'] == 'sqlite_wal')['reason'] =
              'not_needed';
        }));
    await rejects('manifest_invalid', (c) => editManifest(c, (m) {
          storesOf(m).firstWhere((e) => e['name'] == 'last_finished')['path'] =
              'stores/last_finished.json';
        }));
    await rejects('count_mismatch', (c) => editManifest(
        c, (m) => (m['counts']! as Map)['sessions'] = 2));
    await rejects('manifest_invalid', (c) => editManifest(
        c, (m) => (m['counts']! as Map)['unknown_table'] = 0));
    await rejects('duplicate_key', (c) {
      final file = File(p.join(c.path, 'manifest.json'));
      file.writeAsStringSync(
          file.readAsStringSync().replaceFirst('{', '{"version":1,'));
    });
    await rejects('duplicate_key', (c) {
      final file = File(p.join(c.path, 'manifest.json'));
      file.writeAsStringSync(
          file.readAsStringSync().replaceFirst('{', '{"Format":"x",'));
    });
    await rejects('manifest_oversized', (c) {
      final file = File(p.join(c.path, 'manifest.json'));
      file.writeAsStringSync(file.readAsStringSync() + ' ' * 1048576);
    });
    // A store whose contents break the format, re-declared so its digest
    // matches: still refused.
    Future<void> rejectsContent(String code, String name, String text) =>
        rejects(code, (c) {
          final bytes = utf8.encode(text);
          File(p.join(c.path, 'stores', '$name.json')).writeAsBytesSync(bytes);
          editManifest(c, (m) {
            final s = storesOf(m).firstWhere((e) => e['name'] == name);
            s['bytes'] = bytes.length;
            s['sha256'] = sha256.convert(bytes).toString();
          });
        });
    await rejectsContent('credential_in_capture', 'preferences',
        '{"entries":[{"key":"access_token","type":"string","value":"t"}]}');
    await rejectsContent('store_invalid', 'preferences',
        '{"entries":[{"key":"unit","type":"string","value":"kg","Key":"x"}]}');
    await rejectsContent('store_invalid', 'upload_queue', '{"evidence":{}}');
    await rejectsContent('store_invalid', 'upload_queue',
        '{"entries":[{"client_id":1,"tx_id":"1","data":"x"}],"evidence":{}}');
    await rejectsContent('store_invalid', 'upload_queue',
        '{"entries":[{"client_id":1,"tx_id":1,"data":{}}],"evidence":{}}');
    await rejectsContent('count_mismatch', 'upload_queue',
        '{"entries":[],"evidence":{}}');
    await rejectsContent('store_invalid', 'sql', '{"tables":{}}');
  });

  test('rehearsal_accepts_produced_capture', () async {
    final rehearsal = Platform.environment['REPS_REHEARSAL_BIN']!;
    final dir = await tempDir('reps-capture-go-source');
    const user = '00000000-0000-4000-8000-000000000001';
    SharedPreferences.setMockInitialValues({
      'unit': 'kg',
      'identity.current_user_id': user,
      'identity.onboarding_complete': true,
      'absorb.template_ids': ['00000000-0000-4000-8000-0000000000e1'],
      'server_url': 'https://reps.example.invalid',
      'settings.sync_enabled': false,
      'settings.rest_compound_seconds': 180,
      'rest.total': 90,
    });
    final database = PowerSyncDatabase(
        schema: schema, path: p.join(dir.path, 'workout-tracker.db'));
    await database.initialize();
    addTearDown(database.close);
    // Queue ids beyond 2^53, as a long-lived installation could reach.
    await database.execute(
        "INSERT INTO sqlite_sequence (name, seq) VALUES ('ps_crud', ?)",
        [9007199254740992]);
    await database.writeTransaction((tx) async {
      await tx.execute(
          'INSERT INTO "ps_data__exercises" (id, data) VALUES (?, ?)', [
        '00000000-0000-4000-8000-0000000000e1',
        jsonEncode({
          'name': 'Bench Press', 'slug': 'bench-press',
          'muscle_group': 'chest', 'is_template': 1, 'created_by': null,
          'created_at': '2026-01-01T00:00:00Z', 'equip': 'barbell',
          'compound': 1, 'base_weight_kg': '20.00', 'plate_step_kg': '2.50',
        }),
      ]);
    });
    await database.writeTransaction((tx) async {
      await tx.execute(
        'INSERT INTO exercises (id, name, slug, muscle_group, is_template, '
        'created_by, created_at, equip, compound, base_weight_kg, '
        'plate_step_kg) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        ['a1000000-0000-4000-8000-000000000001', 'Cable Fly',
          'cable-fly-a1000000', 'chest', 0, user,
          '2026-10-01T08:00:00.000Z', '', 0, '', '2.50'],
      );
    });
    await database.writeTransaction((tx) async {
      await tx.execute(
        'INSERT INTO sessions (id, user_id, date, split_label, created_at, '
        'duration_min) VALUES (?, ?, ?, ?, ?, ?)',
        ['d1000000-0000-4000-8000-000000000001', user, '2026-10-01',
          'Custom', '2026-10-01T10:00:00.000Z', 45],
      );
      for (final (id, n) in [
        ('e1000000-0000-4000-8000-000000000001', 1),
        ('e1000000-0000-4000-8000-000000000002', 2),
      ]) {
        await tx.execute(
          'INSERT INTO sets (id, session_id, exercise_id, user_id, '
          'set_number, weight_kg, reps, rir, is_warmup, is_top_set, is_pr, '
          'created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [id, 'd1000000-0000-4000-8000-000000000001',
            '00000000-0000-4000-8000-0000000000e1', user, n, '62.5', 8, 1, 0,
            n == 2 ? 1 : 0, 0, '2026-10-01T10:20:00.000Z'],
        );
      }
    });
    await database.writeTransaction((tx) async {
      await tx.execute(
        'INSERT INTO bodyweight_logs (id, user_id, date, weight_kg, '
        'created_at) VALUES (?, ?, ?, ?, ?)',
        ['f1000000-0000-4000-8000-000000000001', user, '2026-10-01', '72.3',
          '2026-10-01T07:00:00.000Z'],
      );
      await tx.execute(
          "UPDATE sets SET rir = NULL WHERE id = 'e1000000-0000-4000-8000-000000000002'");
      await tx.execute(
          "DELETE FROM sets WHERE id = 'e1000000-0000-4000-8000-000000000001'");
    });
    // A malformed draft and an orphan temporary file; no finished snapshot.
    File(p.join(dir.path, 'workout-draft.json'))
        .writeAsStringSync('{"sessionId":null,"startedAt":"2026-10-01T10');
    File(p.join(dir.path, 'workout-draft.json.tmp'))
        .writeAsStringSync('{"sessionId":');

    final runtime = qualifiedSourceProfiles
        .singleWhere((q) => q.runtime.platform == Platform.operatingSystem)
        .runtime;
    final profile = await qualifyCaptureProfile(database, runtime);
    final payload = await readCapturePayload(
      database,
      const SourceHold(_captureId, 1),
      profile,
      const StartupInventory([]),
      source: dir,
      preservation: RawPreservation(
          Directory(p.join(dir.path, 'capture', 'preparation')),
          base: dir),
    );
    expect(payload.blockers, isEmpty);
    expect(payload.queue.entries.first.clientId, greaterThan(9007199254740992));
    final sealed = await writeAndVerifyCapture(
        await tempDir('reps-capture-go-staging'), payload, manifestFor(payload));
    expect(sealed.usable, isTrue);

    final work = p.join((await tempDir('reps-capture-go-work')).path, 'run');
    final run = await Process.run(
        rehearsal, ['-capture', sealed.directory.path, '-work', work]);
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    final summary = jsonDecode(run.stdout as String) as Map<String, Object?>;
    expect(summary['staging_valid'], isTrue);
    expect(summary['exploratory'], isFalse);
    expect(summary['cutover_ready'], isFalse);
    expect((summary['findings']! as Map)['blocking'], 0);

    final report = jsonDecode(File(p.join(work, 'report.json'))
        .readAsStringSync()) as Map<String, Object?>;
    final codes = {
      for (final f in (report['findings']! as List).cast<Map>()) f['code'],
    };
    expect(codes, contains('draft_malformed'));
    expect(codes, contains('opaque_store_preserved'));
    expect(codes, contains('queued_delete_preserved'));
    final staging = File(p.join(work, 'staging.json')).readAsStringSync();
    for (final e in payload.queue.entries) {
      expect(staging, contains(RegExp('"client_id": *${e.clientId},')));
    }
  },
      skip: Platform.environment['REPS_REHEARSAL_BIN'] == null
          ? 'needs REPS_REHEARSAL_BIN (make -C app capture-go-compat)'
          : false);
}
