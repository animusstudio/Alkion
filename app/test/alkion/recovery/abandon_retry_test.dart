import 'dart:convert';
import 'dart:io';

import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/store/generation_selection.dart';
import 'package:alkion/store/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../../tool/alkion_backup_recovery.dart' as proof;

Matcher _category(String category) => throwsA(
  isA<StoreException>().having((e) => e.category, 'category', category),
);

final class AbandonFixture {
  AbandonFixture(this.root, this.directory, this.pending, this.before);
  final Directory root;
  final String directory;
  final PendingRestore pending;
  final CoveredState before;
  RestoreService get service => RestoreService(proof.supportRootOf(root));
  String get database => p.join(
    directory,
    pending.intent['previous'] is Map
        ? (pending.intent['previous'] as Map)['path'] as String
        : generationDatabaseName,
  );
  File get intentFile => File(
    p.join(
      generationDirectory(directory, pending.restoreId),
      restoreIntentName,
    ),
  );
  Directory get markerObstacle => Directory(
    p.join(
      generationDirectory(directory, pending.restoreId),
      '$restoreAbandonedName.tmp',
    ),
  );
  Future<CoveredState> raw() async =>
      (await proof.rawGeneration(database, root)).$1;
  void sql(String sql, [List<Object?> args = const []]) {
    final db = sqlite.sqlite3.open(database);
    try {
      if (sql.startsWith('UPDATE restore_journal ')) {
        // Deliberately corrupt only this disposable fixture, then restore the
        // immutable trigger verbatim before exercising production recovery.
        final trigger =
            db
                    .select(
                      "SELECT sql FROM sqlite_master WHERE name='restore_journal_update_immutable'",
                    )
                    .single['sql']
                as String;
        db.execute('BEGIN IMMEDIATE');
        db.execute('DROP TRIGGER restore_journal_update_immutable');
        db.execute(sql, args);
        db.execute(trigger);
        db.execute('COMMIT');
      } else {
        db.execute(sql, args);
      }
    } finally {
      db.close();
    }
  }

  Map<String, String> fileInventory() => {
    for (final entry in Directory(
      directory,
    ).listSync(recursive: true, followLinks: false).whereType<File>())
      p.relative(entry.path, from: directory): sha256
          .convert(entry.readAsBytesSync())
          .toString(),
  };

  Future<void> changeIntent(void Function(Map<String, dynamic>) change) async {
    final value =
        jsonDecode(await intentFile.readAsString()) as Map<String, dynamic>;
    change(value);
    await intentFile.writeAsString(jsonEncode(value), flush: true);
  }

  Future<void> failMarker() async {
    await markerObstacle.create();
    await expectLater(
      service.abandon(pending.restoreId),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      (await raw()).tables['restore_journal']!.where(
        (r) =>
            r['restore_id'] == pending.restoreId &&
            r['entry_id'] == 'abandoned',
      ),
      hasLength(1),
    );
    expect((await service.pending()).single.restoreId, pending.restoreId);
    await markerObstacle.delete();
  }
}

Future<AbandonFixture> interrupted(
  Directory root,
  String boundary, {
  bool runtimeCompatible = false,
}) async {
  final store = await proof.openStore(root);
  late BackupReceipt backup;
  late CoveredState before;
  try {
    await proof.seedBeforeBackup(store);
    backup = await createBackup(
      store,
      await Directory(p.join(root.path, 'backups')).create(),
    );
    await proof.postBackupWork(store);
    if (runtimeCompatible) {
      final draft = SessionDraft(
        templateId: null,
        name: 'Synthetic recovery workout',
        focus: 'legs',
        startedAt: DateTime.utc(2026, 10, 15, 9),
        blocks: const [],
        identity: 'proof-draft',
      );
      await store.writeTransaction((tx) async {
        await tx.putLocalState(
          LocalStateKind.draft,
          'active',
          localBytes(draft.toJson()),
          expectedRevision: 2,
          status: 'discarded',
        );
        await tx.putLocalState(
          LocalStateKind.timer,
          'active',
          localBytes(draft.timerJson),
          expectedRevision: 2,
          status: 'discarded',
        );
      });
    }
    before = await proof.coveredOf(store);
  } finally {
    await store.close();
  }
  await expectLater(
    RestoreService(
      proof.supportRootOf(root),
      checkpoint: (phase) async {
        if (phase == boundary) throw StateError('controlled interruption');
      },
      workDirectory: root,
    ).restore(File(backup.path)),
    throwsStateError,
  );
  final service = RestoreService(proof.supportRootOf(root));
  return AbandonFixture(
    root,
    await proof.profileDirectoryOf(root),
    (await service.pending()).single,
    before,
  );
}

Future<void> _record(String name, Map<String, Object?> result) async {
  final path = Platform.environment['ALKION_ABANDON_PROOF'];
  if (path == null) return;
  final out = await Directory(path).create(recursive: true);
  await File(
    p.join(out.path, '$name.json'),
  ).writeAsString('${jsonEncode(result)}\n', flush: true);
}

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('alkion-abandon-test-');
  });
  tearDown(() => temp.delete(recursive: true));

  for (final boundary in ['restore-intent', 'restore-fenced']) {
    test(
      'Keep current retries actual committed decision after marker write failure at $boundary',
      () async {
        final f = await interrupted(temp, boundary);
        final staged = File(
          generationDatabasePath(f.directory, f.pending.restoreId),
        );
        final stagedBytes = staged.readAsBytesSync();
        final identity = File(
          p.join(proof.supportRootOf(temp).path, 'local-profile.json'),
        );
        final identityBytes = identity.readAsBytesSync();
        await f.failMarker();
        final committed = await f.raw();
        final generation =
            (f.before.tables['profile_state']!.single['generation'] as int) +
            (boundary == 'restore-fenced' ? 1 : 0);
        expect(
          committed.tables['profile_state']!.single['generation'],
          generation,
        );
        expect(
          committed.tables['profile_state']!.single['write_state'],
          'writable',
        );
        const excluded = {'profile_state', 'restore_journal'};
        expect(
          committed.digest(excluding: excluded),
          f.before.digest(excluding: excluded),
        );
        await expectLater(
          proof.openStore(temp),
          throwsA(
            isA<GenerationSelectionException>().having(
              (e) => e.category,
              'category',
              'restore_interrupted',
            ),
          ),
        );
        await f.service.abandon(f.pending.restoreId);
        expect(await f.service.pending(), isEmpty);
        final launches = <CoveredState>[];
        for (var i = 0; i < 2; i++) {
          final store = await proof.openStore(temp);
          try {
            expect(store.token.generation, generation);
            expect(store.admission, StoreAdmission.open);
            launches.add(await proof.coveredOf(store));
          } finally {
            await store.close();
          }
        }
        for (final launch in launches) {
          expect(launch.digest(), committed.digest());
        }
        expect(staged.readAsBytesSync(), stagedBytes);
        expect(identity.readAsBytesSync(), identityBytes);
        expect(selectedRestoreId(f.directory), isNull);
        await expectLater(
          f.service.abandon(f.pending.restoreId),
          _category('restore_not_pending'),
        );
        await _record('marker-failure-$boundary', {
          'boundary': boundary,
          'failure':
              'marker temporary path is a directory; actual SQLite COMMIT precedes FileSystemException',
          'before': proof.stateJson(f.before),
          'committed_before_retry': proof.stateJson(committed),
          'launches': launches.map(proof.stateJson).toList(),
          'staging_byte_exact': true,
          'identity_byte_exact': true,
        });
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  }

  final mutations = <String, (String, Future<void> Function(AbandonFixture))>{
    'intent-profile': (
      'foreign_profile',
      (f) async => f.changeIntent((v) => v['profile_id'] = 'foreign'),
    ),
    'intent-installation': (
      'foreign_profile',
      (f) async => f.changeIntent((v) => v['installation_id'] = 'foreign'),
    ),
    'intent-restore-id': (
      'restore_intent_invalid',
      (f) async => f.changeIntent(
        (v) => v['restore_id'] = 'rs-00000000000000000000000000000000',
      ),
    ),
    'previous-generation': (
      'restore_source_changed',
      (f) async =>
          f.changeIntent((v) => (v['previous'] as Map)['generation'] = 99),
    ),
    'previous-adjacent-generation': (
      'restore_source_changed',
      (f) async => f.changeIntent(
        (v) => (v['previous'] as Map)['generation'] =
            ((v['previous'] as Map)['generation'] as int) + 1,
      ),
    ),
    'source-boundary-digest': (
      'restore_source_changed',
      (f) async {
        f.sql("UPDATE bodyweight_logs SET weight_kg='999.0' WHERE id='bw-1'");
        final changed = await f.raw();
        await f.changeIntent(
          (v) => (v['previous'] as Map)['covered_sha256'] = changed.digest(
            excluding: const {'profile_state'},
          ),
        );
      },
    ),
    'staging-generation': (
      'restore_staging_changed',
      (f) async =>
          f.changeIntent((v) => (v['staged'] as Map)['generation'] = 99),
    ),
    'staging-inventory': (
      'restore_staging_changed',
      (f) async => f.changeIntent(
        (v) => (v['staged'] as Map)['inventory_sha256'] = 'wrong',
      ),
    ),
    'previous-path': (
      'restore_source_changed',
      (f) async => f.changeIntent(
        (v) => (v['previous'] as Map)['path'] = 'wrong.sqlite',
      ),
    ),
    'database-profile': (
      'foreign_profile',
      (f) async {
        f.sql("UPDATE profile_state SET profile_id='foreign'");
      },
    ),
    'database-installation': (
      'foreign_profile',
      (f) async {
        f.sql("UPDATE profile_state SET installation_id='foreign'");
      },
    ),
    'journal-id': (
      'restore_source_changed',
      (f) async {
        f.sql(
          "UPDATE restore_journal SET restore_id='rs-00000000000000000000000000000000'",
        );
      },
    ),
    'journal-entry': (
      'restore_source_changed',
      (f) async {
        f.sql("UPDATE restore_journal SET entry_id='selection'");
      },
    ),
    'journal-from': (
      'restore_source_changed',
      (f) async {
        f.sql('UPDATE restore_journal SET from_generation=99');
      },
    ),
    'journal-to': (
      'restore_source_changed',
      (f) async {
        f.sql('UPDATE restore_journal SET to_generation=99');
      },
    ),
    'journal-bytes': (
      'restore_source_changed',
      (f) async {
        f.sql("UPDATE restore_journal SET entry_bytes=x'7b7d'");
      },
    ),
    'staging-path': (
      'restore_staging_changed',
      (f) async => f.changeIntent(
        (v) => (v['staged'] as Map)['database'] = 'wrong.sqlite',
      ),
    ),
    'staging-bytes': (
      'restore_staging_changed',
      (f) async {
        final file = File(
          generationDatabasePath(f.directory, f.pending.restoreId),
        );
        final bytes = file.readAsBytesSync()..[100] ^= 1;
        await file.writeAsBytes(bytes, flush: true);
      },
    ),
    'source-bytes': (
      'restore_source_changed',
      (f) async {
        f.sql("UPDATE bodyweight_logs SET weight_kg='999.0' WHERE id='bw-1'");
      },
    ),
    'another-fence': (
      'restore_source_changed',
      (f) async {
        const other = 'rs-00000000000000000000000000000000';
        final directory = await Directory(
          generationDirectory(f.directory, other),
        ).create();
        final value = jsonDecode(await f.intentFile.readAsString()) as Map;
        value['restore_id'] = other;
        await File(
          p.join(directory.path, restoreIntentName),
        ).writeAsString(jsonEncode(value), flush: true);
        f.sql("UPDATE profile_state SET write_state='fenced'");
      },
    ),
  };
  for (final committed in [false, true]) {
    for (final entry in mutations.entries.where(
      (e) => committed || !e.key.startsWith('journal-'),
    )) {
      test(
        '${committed ? 'committed' : 'new'} Keep current refuses ${entry.key} and preserves inventory',
        () async {
          final f = await interrupted(temp, 'restore-fenced');
          if (committed) await f.failMarker();
          await entry.value.$2(f);
          final before = await f.raw();
          final filesBefore = f.fileInventory();
          final intentBytes = f.intentFile.readAsBytesSync();
          final staged = File(
            generationDatabasePath(f.directory, f.pending.restoreId),
          );
          final stagedBytes = staged.readAsBytesSync();
          await expectLater(
            f.service.abandon(f.pending.restoreId),
            _category(entry.value.$1),
          );
          final after = await f.raw();
          expect(after.digest(), before.digest());
          expect(f.fileInventory(), filesBefore);
          expect(f.intentFile.readAsBytesSync(), intentBytes);
          expect(staged.readAsBytesSync(), stagedBytes);
          expect(
            File(
              p.join(
                generationDirectory(f.directory, f.pending.restoreId),
                restoreAbandonedName,
              ),
            ).existsSync(),
            isFalse,
          );
          await _record(
            'refuse-${committed ? 'committed' : 'new'}-${entry.key}',
            {
              'refusal': entry.value.$1,
              'before': proof.stateJson(before),
              'after': proof.stateJson(after),
              'intent_and_staging_unchanged': true,
              'profile_files_before': filesBefore,
              'profile_files_after': f.fileInventory(),
            },
          );
        },
        timeout: const Timeout(Duration(seconds: 120)),
      );
    }
  }
}
